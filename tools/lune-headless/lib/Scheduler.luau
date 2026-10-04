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
	wait/delay) resume on frames like on Roblox, when the host calls resumeFrameWaiters after a
	step, instead of on Lune's own timer. task.wait() then waits for the next frame.
]]

local DateTimeLib = require("@lune/datetime")
local realTask = require("@lune/task")

local Scheduler = {}
Scheduler.__index = Scheduler

type Timer = {
	dueMs: number,
	seq: number,
	thread: thread,
	args: { any },
	resumeValue: boolean, -- true for task.wait: resume with the elapsed time
	startMs: number,
}

type FrameWaiter = {
	dueClock: number,
	thread: thread,
	args: { any },
	resumeValue: boolean,
	startClock: number,
}

export type Scheduler = typeof(setmetatable(
	{} :: {
		fake: boolean,
		nowMs: number,
		systemTimeAtZero: number,
		timers: { Timer },
		frameWaiters: { FrameWaiter }?,
		seq: number,
		startClock: number,
		onStrayError: (message: string) -> (),
		task: any,
		os: any,
		globals: { [string]: any },
	},
	Scheduler
))

local MAX_TIMER_LOOPS = 100000

local function realUnixSeconds(): number
	return DateTimeLib.now().unixTimestampMillis / 1000
end

local function traceback(err: any): string
	return debug.traceback(tostring(err), 2)
end

function Scheduler.new(onStrayError: (message: string) -> ()): Scheduler
	local self = setmetatable({
		fake = false,
		nowMs = 0,
		systemTimeAtZero = realUnixSeconds(),
		timers = {},
		frameWaiters = nil,
		seq = 0,
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

-- Runs fn and reports an error instead of letting it escape the thread.
function Scheduler._guard(self: Scheduler, fn: (...any) -> ...any): (...any) -> ()
	return function(...)
		local ok, err = xpcall(fn, traceback, ...)
		if not ok then
			self.onStrayError(err)
		end
	end
end

function Scheduler._insertTimer(self: Scheduler, timer: Timer)
	local insertAt = #self.timers + 1
	for i, other in self.timers do
		if other.dueMs > timer.dueMs then
			insertAt = i
			break
		end
	end
	table.insert(self.timers, insertAt, timer)
end

function Scheduler._fakeDelay(self: Scheduler, seconds: number?, fnOrThread: any, ...: any): thread
	local thread = if type(fnOrThread) == "thread" then fnOrThread else coroutine.create(fnOrThread)
	self.seq += 1
	self:_insertTimer({
		dueMs = self.nowMs + math.max(seconds or 0, 0) * 1000,
		seq = self.seq,
		thread = thread,
		args = table.pack(...),
		resumeValue = false,
		startMs = self.nowMs,
	})
	return thread
end

function Scheduler._fakeWait(self: Scheduler, seconds: number?): number
	local thread = coroutine.running()
	self.seq += 1
	self:_insertTimer({
		dueMs = self.nowMs + math.max(seconds or 0, 0) * 1000,
		seq = self.seq,
		thread = thread,
		args = {},
		resumeValue = true,
		startMs = self.nowMs,
	})
	return coroutine.yield()
end

-- Removes the timer for `thread`. Returns true if one was pending.
function Scheduler._cancelFake(self: Scheduler, thread: any): boolean
	for i, timer in self.timers do
		if timer.thread == thread then
			table.remove(self.timers, i)
			return true
		end
	end
	return false
end

function Scheduler._frameWait(self: Scheduler, waiters: { FrameWaiter }, seconds: number?): number
	local now = os.clock()
	table.insert(waiters, {
		dueClock = now + math.max(seconds or 0, 0),
		thread = coroutine.running(),
		args = {},
		resumeValue = true,
		startClock = now,
	})
	return coroutine.yield()
end

function Scheduler._frameDelay(
	self: Scheduler,
	waiters: { FrameWaiter },
	seconds: number?,
	fnOrThread: any,
	...: any
): thread
	local thread = if type(fnOrThread) == "thread" then fnOrThread else coroutine.create(self:_guard(fnOrThread))
	local now = os.clock()
	table.insert(waiters, {
		dueClock = now + math.max(seconds or 0, 0),
		thread = thread,
		args = table.pack(...) :: any,
		resumeValue = false,
		startClock = now,
	})
	return thread
end

function Scheduler._cancelFrame(self: Scheduler, thread: any): boolean
	local waiters = self.frameWaiters
	if not waiters then
		return false
	end
	for i, waiter in waiters do
		if waiter.thread == thread then
			table.remove(waiters, i)
			return true
		end
	end
	return false
end

-- Real waits and delays resume on frames from now on (see resumeFrameWaiters).
function Scheduler.useFrames(self: Scheduler)
	self.frameWaiters = self.frameWaiters or {}
end

-- Resumes every frame-aligned wait and delay that is due. Ones queued while this runs wait for
-- the next frame.
function Scheduler.resumeFrameWaiters(self: Scheduler)
	local waiters = self.frameWaiters
	if not waiters or #waiters == 0 then
		return
	end
	local now = os.clock()
	local due = {}
	local index = 1
	while index <= #waiters do
		local waiter = waiters[index]
		if waiter.dueClock <= now then
			table.insert(due, waiter)
			table.remove(waiters, index)
		else
			index += 1
		end
	end
	for _, waiter in due do
		if coroutine.status(waiter.thread) == "suspended" then
			local ok, err
			if waiter.resumeValue then
				ok, err = coroutine.resume(waiter.thread, now - waiter.startClock)
			else
				ok, err = coroutine.resume(waiter.thread, table.unpack(waiter.args, 1, (waiter.args :: any).n))
			end
			if not ok then
				self.onStrayError(debug.traceback(waiter.thread, tostring(err)))
			end
		end
	end
end

function Scheduler._fire(self: Scheduler, timer: Timer)
	self.nowMs = math.max(self.nowMs, timer.dueMs)
	local status = coroutine.status(timer.thread)
	if status ~= "suspended" then
		return
	end
	local ok, err
	if timer.resumeValue then
		ok, err = coroutine.resume(timer.thread, (self.nowMs - timer.startMs) / 1000)
	else
		ok, err = coroutine.resume(timer.thread, table.unpack(timer.args, 1, (timer.args :: any).n))
	end
	if not ok then
		error(err, 0)
	end
end

function Scheduler._buildTask(self: Scheduler): any
	local scheduler = self
	return {
		spawn = function(fnOrThread: any, ...: any): thread
			if type(fnOrThread) == "thread" then
				return realTask.spawn(fnOrThread, ...)
			end
			return realTask.spawn(scheduler:_guard(fnOrThread), ...)
		end,
		defer = function(fnOrThread: any, ...: any): thread
			if type(fnOrThread) == "thread" then
				return realTask.defer(fnOrThread, ...)
			end
			return realTask.defer(scheduler:_guard(fnOrThread), ...)
		end,
		delay = function(seconds: number?, fnOrThread: any, ...: any): thread
			if scheduler.fake then
				return scheduler:_fakeDelay(seconds, fnOrThread, ...)
			end
			if scheduler.frameWaiters then
				return scheduler:_frameDelay(scheduler.frameWaiters, seconds, fnOrThread, ...)
			end
			if type(fnOrThread) == "thread" then
				return realTask.delay(seconds or 0, fnOrThread, ...)
			end
			return realTask.delay(seconds or 0, scheduler:_guard(fnOrThread), ...)
		end,
		wait = function(seconds: number?): number
			if scheduler.fake then
				return scheduler:_fakeWait(seconds)
			end
			if scheduler.frameWaiters then
				return scheduler:_frameWait(scheduler.frameWaiters, seconds)
			end
			return realTask.wait(seconds)
		end,
		cancel = function(thread: any)
			if scheduler:_cancelFake(thread) or scheduler:_cancelFrame(thread) then
				pcall(coroutine.close, thread)
				return
			end
			if type(thread) == "thread" then
				realTask.cancel(thread)
			end
		end,
		synchronize = function() end,
		desynchronize = function() end,
	}
end

function Scheduler.clock(self: Scheduler): number
	return if self.fake then self.nowMs / 1000 else os.clock()
end

function Scheduler.unixTime(self: Scheduler): number
	return if self.fake then self.systemTimeAtZero + self.nowMs / 1000 else realUnixSeconds()
end

function Scheduler._buildOs(self: Scheduler): any
	local scheduler = self
	return setmetatable({
		clock = function(): number
			return scheduler:clock()
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
		self:reset()
	end
end

function Scheduler.useRealTimers(self: Scheduler)
	self.fake = false
end

function Scheduler.reset(self: Scheduler)
	self.nowMs = 0
	self.systemTimeAtZero = realUnixSeconds()
	table.clear(self.timers)
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

function Scheduler.advanceTimersByTime(self: Scheduler, ms: number)
	if not self.fake then
		return
	end
	local target = self.nowMs + ms
	local loops = 0
	while self.timers[1] and self.timers[1].dueMs <= target do
		loops += 1
		if loops > MAX_TIMER_LOOPS then
			error(`Ran {MAX_TIMER_LOOPS} timers, and there are still more! Assuming an infinite loop.`, 2)
		end
		local timer = table.remove(self.timers, 1) :: Timer
		self:_fire(timer)
	end
	self.nowMs = math.max(self.nowMs, target)
end

function Scheduler.runAllTimers(self: Scheduler)
	if not self.fake then
		return
	end
	local loops = 0
	while self.timers[1] do
		loops += 1
		if loops > MAX_TIMER_LOOPS then
			error(`Ran {MAX_TIMER_LOOPS} timers, and there are still more! Assuming an infinite loop.`, 2)
		end
		local timer = table.remove(self.timers, 1) :: Timer
		self:_fire(timer)
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
		self:advanceTimersByTime(nextTimer.dueMs - self.nowMs)
	end
end

return Scheduler
