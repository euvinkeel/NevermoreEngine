--!strict
--[[
	The `task` library, legacy timing globals (tick/time/wait/delay/spawn) and jest fake timers for
	one spec run.

	Real mode wraps Lune's task library so an error in a spawned, deferred or delayed thread is
	reported (like Roblox's output window) instead of setting Lune's process exit code.

	Fake mode follows jest-lua's modern fake timers (jest-fake-timers/src/init.lua): it fakes
	task.delay, task.wait, task.cancel, delay, os.clock, os.time, tick, time and DateTime.now, and
	leaves task.spawn and task.defer real. Two deliberate differences:
	- A fake delay returns a thread (as task.delay does on Roblox) instead of jest-lua's timeout
	  table. task.cancel accepts it either way.
	- A callback runs in its own thread, so a callback that yields doesn't suspend the test. An
	  error in a callback is still rethrown from advanceTimersByTime, as jest-lua does.

	Frame mode (useFrames, for the datamodel host level): real task.wait/task.delay (and the legacy
	wait/delay) resume on frames like on Roblox, when the host calls resumeFrameTimers after a
	step, instead of on Lune's own timer. task.wait() then waits for the next frame.
]]

local DateTimeLib = require("@lune/datetime")
local realTask = require("@lune/task")

local Scheduler = {}
Scheduler.__index = Scheduler

-- A thread waiting on the fake clock (fake timers, in milliseconds) or for a frame (frame mode, in
-- os.clock() seconds).
type Timer = {
	due: number,
	start: number,
	thread: thread,
	args: { n: number, [number]: any }?, -- a delay's arguments; nil for a wait, which gets the elapsed time
}

export type Scheduler = typeof(setmetatable(
	{} :: {
		fake: boolean,
		nowMs: number,
		systemTimeAtZero: number,
		timers: { Timer }, -- fake timers, in due order
		frames: boolean,
		frameTimers: { Timer },
		startClock: number,
		onStrayError: (message: string) -> (),
		task: any,
		os: any,
		globals: { [string]: any },
	},
	Scheduler
))

local MAX_TIMER_LOOPS = 100000

-- Wall-clock seconds with os.clock()'s resolution: DateTime.now() only has milliseconds, and
-- Roblox's tick() is much finer (code orders objects by their creation tick()).
local unixAtStart = DateTimeLib.now().unixTimestampMillis / 1000
local clockAtStart = os.clock()
local function realUnixSeconds(): number
	return unixAtStart + (os.clock() - clockAtStart)
end

local function traceback(err: any): string
	return debug.traceback(tostring(err), 2)
end

local function threadOf(fnOrThread: any): thread
	return if type(fnOrThread) == "thread" then fnOrThread else coroutine.create(fnOrThread)
end

-- Resumes a timer's thread: a delay with its arguments, a wait with the elapsed seconds.
local function resume(timer: Timer, elapsedSeconds: number): (boolean, any)
	local args = timer.args
	if args then
		return coroutine.resume(timer.thread, table.unpack(args, 1, args.n))
	end
	return coroutine.resume(timer.thread, elapsedSeconds)
end

function Scheduler.new(onStrayError: (message: string) -> ()): Scheduler
	local self = setmetatable({
		fake = false,
		nowMs = 0,
		systemTimeAtZero = realUnixSeconds(),
		timers = {},
		frames = false,
		frameTimers = {},
		startClock = os.clock(),
		onStrayError = onStrayError,
		task = nil :: any,
		os = nil :: any,
		globals = {},
	}, Scheduler)

	self.task = self:_buildTask()
	self.os = self:_buildOs()
	self:_buildGlobals()
	return self
end

-- `fn`, reporting its error as a stray error instead of letting it escape the thread.
function Scheduler.guard(self: Scheduler, fn: (...any) -> ...any): (...any) -> ()
	return function(...)
		local ok, err = xpcall(fn, traceback, ...)
		if not ok then
			self.onStrayError(err)
		end
	end
end

-- A thread as is, or a function guarded.
function Scheduler._callable(self: Scheduler, fnOrThread: any): any
	return if type(fnOrThread) == "thread" then fnOrThread else self:guard(fnOrThread)
end

-- Queues `thread` to resume `seconds` from now, on the fake clock or on frames.
function Scheduler._queue(
	self: Scheduler,
	onFakeClock: boolean,
	seconds: number?,
	thread: thread,
	args: { n: number, [number]: any }?
): thread
	local delay = math.max(seconds or 0, 0)
	if onFakeClock then
		local timer = { due = self.nowMs + delay * 1000, start = self.nowMs, thread = thread, args = args }
		local at = #self.timers + 1
		for i, other in self.timers do
			if other.due > timer.due then
				at = i
				break
			end
		end
		table.insert(self.timers, at, timer)
	else
		local now = os.clock()
		table.insert(self.frameTimers, { due = now + delay, start = now, thread = thread, args = args })
	end
	return thread
end

-- A delay that jest fake timers don't touch, for engine-driven timing (Debris, WaitForChild
-- timeouts): frame-aligned in frame mode, Lune's timer otherwise.
function Scheduler.engineDelay(self: Scheduler, seconds: number, fn: () -> ())
	if self.frames then
		self:_queue(false, seconds, coroutine.create(self:guard(fn)), table.pack())
	else
		realTask.delay(seconds, self:guard(fn))
	end
end

-- Real waits and delays resume on frames from now on (see resumeFrameTimers).
function Scheduler.useFrames(self: Scheduler)
	self.frames = true
end

-- Resumes every frame timer that is due. Ones queued while this runs wait for the next frame.
function Scheduler.resumeFrameTimers(self: Scheduler)
	local now = os.clock()
	local due: { Timer }, waiting: { Timer } = {}, {}
	for _, timer in self.frameTimers do
		table.insert(if timer.due <= now then due else waiting, timer)
	end
	self.frameTimers = waiting
	for _, timer in due do
		if coroutine.status(timer.thread) == "suspended" then
			local ok, err = resume(timer, now - timer.start)
			if not ok then
				self.onStrayError(debug.traceback(timer.thread, tostring(err)))
			end
		end
	end
end

function Scheduler._fire(self: Scheduler, timer: Timer)
	self.nowMs = math.max(self.nowMs, timer.due)
	if coroutine.status(timer.thread) == "suspended" then
		local ok, err = resume(timer, (self.nowMs - timer.start) / 1000)
		if not ok then
			error(err, 0)
		end
	end
end

function Scheduler._buildTask(self: Scheduler): any
	local scheduler = self
	return {
		spawn = function(fnOrThread: any, ...: any): thread
			return realTask.spawn(scheduler:_callable(fnOrThread), ...)
		end,
		defer = function(fnOrThread: any, ...: any): thread
			return realTask.defer(scheduler:_callable(fnOrThread), ...)
		end,
		delay = function(seconds: number?, fnOrThread: any, ...: any): thread
			if scheduler.fake then
				-- Not guarded: advanceTimersByTime rethrows a callback's error, as jest-lua does.
				return scheduler:_queue(true, seconds, threadOf(fnOrThread), table.pack(...))
			elseif scheduler.frames then
				return scheduler:_queue(false, seconds, threadOf(scheduler:_callable(fnOrThread)), table.pack(...))
			end
			return realTask.delay(seconds or 0, scheduler:_callable(fnOrThread), ...)
		end,
		wait = function(seconds: number?): number
			if scheduler.fake or scheduler.frames then
				scheduler:_queue(scheduler.fake, seconds, coroutine.running(), nil)
				return coroutine.yield()
			end
			return realTask.wait(seconds)
		end,
		cancel = function(thread: any)
			for _, timers in { scheduler.timers, scheduler.frameTimers } do
				for i, timer in timers do
					if timer.thread == thread then
						table.remove(timers, i)
						pcall(coroutine.close, thread)
						return
					end
				end
			end
			if type(thread) == "thread" then
				realTask.cancel(thread)
			end
		end,
		synchronize = function() end,
		desynchronize = function() end,
	}
end

function Scheduler.unixTime(self: Scheduler): number
	return if self.fake then self.systemTimeAtZero + self.nowMs / 1000 else realUnixSeconds()
end

function Scheduler._buildOs(self: Scheduler): any
	local scheduler = self
	return setmetatable({
		clock = function(): number
			return if scheduler.fake then scheduler.nowMs / 1000 else os.clock()
		end,
		time = function(t: any?): number
			if t ~= nil then
				return os.time(t)
			end
			return if scheduler.fake then scheduler:unixTime() else os.time()
		end,
	}, { __index = os })
end

function Scheduler._buildGlobals(self: Scheduler)
	local scheduler = self
	local taskLib = self.task
	self.globals.tick = function(): number
		return scheduler:unixTime()
	end
	self.globals.time = function(): number
		return if scheduler.fake then scheduler.nowMs / 1000 else os.clock() - scheduler.startClock
	end
	self.globals.elapsedTime = function(): number
		return os.clock() - scheduler.startClock
	end
	self.globals.wait = function(seconds: number?): (number, number)
		local elapsed = taskLib.wait(seconds or 0.03)
		return elapsed, scheduler.globals.time()
	end
	self.globals.delay = function(seconds: number?, fn: any)
		taskLib.delay(seconds or 0.03, fn)
	end
	self.globals.spawn = function(fn: any)
		taskLib.defer(fn)
	end
end

-- jest.* timer controls

function Scheduler.useFakeTimers(self: Scheduler)
	if not self.fake then
		self.fake = true
		self.nowMs = 0
		self.systemTimeAtZero = realUnixSeconds()
		table.clear(self.timers)
	end
end

function Scheduler.useRealTimers(self: Scheduler)
	self.fake = false
end

function Scheduler.clearAllTimers(self: Scheduler)
	table.clear(self.timers)
end

function Scheduler.getTimerCount(self: Scheduler): number
	return #self.timers
end

function Scheduler.setSystemTime(self: Scheduler, now: any?)
	local seconds = if type(now) == "number"
		then now
		elseif type(now) == "table" and type(now.UnixTimestampMillis) == "number" then now.UnixTimestampMillis / 1000
		else realUnixSeconds()
	self.systemTimeAtZero = seconds - self.nowMs / 1000
end

-- Fires fake timers in due order while the next one is due by `untilMs` (nil: until none are left).
function Scheduler._runTimers(self: Scheduler, untilMs: number?)
	local loops = 0
	while self.timers[1] and (untilMs == nil or self.timers[1].due <= untilMs) do
		loops += 1
		if loops > MAX_TIMER_LOOPS then
			error(`Ran {MAX_TIMER_LOOPS} timers, and there are still more! Assuming an infinite loop.`, 3)
		end
		self:_fire(table.remove(self.timers, 1) :: Timer)
	end
end

function Scheduler.advanceTimersByTime(self: Scheduler, ms: number)
	if self.fake then
		local target = self.nowMs + ms
		self:_runTimers(target)
		self.nowMs = math.max(self.nowMs, target)
	end
end

function Scheduler.runAllTimers(self: Scheduler)
	if self.fake then
		self:_runTimers(nil)
	end
end

function Scheduler.runOnlyPendingTimers(self: Scheduler)
	if not self.fake then
		return
	end
	local pending = table.clone(self.timers)
	table.clear(self.timers)
	for _, timer in pending do
		self:_fire(timer)
	end
end

function Scheduler.advanceTimersToNextTimer(self: Scheduler, steps: number?)
	if not self.fake then
		return
	end
	for _ = 1, steps or 1 do
		local nextTimer = self.timers[1]
		if not nextTimer then
			return
		end
		self:advanceTimersByTime(nextTimer.due - self.nowMs)
	end
end

return Scheduler
