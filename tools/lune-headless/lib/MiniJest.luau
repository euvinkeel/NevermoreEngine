--!strict
--[[
	A small Jest for headless runs, shaped like the jest-lua API Nevermore specs use:
	`Jest.Globals.describe/it/test/expect/jest/beforeAll/afterAll/beforeEach/afterEach`.

	Like Jest, it collects first and runs afterwards: describe bodies run while the spec file loads,
	and test bodies run later, one at a time, each in its own thread. A test passes only if its
	thread *finishes* without error before the timeout, so a test that yields and then fails is
	reported as failed (the probe harness counted those as passes). Hooks are scoped to the
	describe block they were declared in.
]]

local Expect = require("./Expect")
local Scheduler = require("./Scheduler")

local realTask = require("@lune/task")

local MiniJest = {}

type Mode = "run" | "skip" | "only" | "todo"

type Hook = { fn: (...any) -> ...any, timeout: number? }

type Hooks = { beforeAll: { Hook }, afterAll: { Hook }, beforeEach: { Hook }, afterEach: { Hook } }

type Block = {
	name: string,
	parent: Block?,
	children: { Node },
	mode: Mode,
	hooks: Hooks,
	collectError: string?,
}

type Test = {
	name: string,
	parent: Block,
	fn: ((...any) -> ...any)?,
	mode: Mode,
	timeout: number?,
}

type Node = { kind: "block", block: Block } | { kind: "test", test: Test }

export type TestResult = {
	name: string,
	status: "passed" | "failed" | "skipped" | "todo",
	durationMs: number,
	error: string?,
	strayErrors: { string }?,
	logs: { string }?,
}

export type Options = {
	scheduler: Scheduler.Scheduler,
	testTimeout: number, -- seconds
	filter: string?, -- only run tests whose full name contains this text
	verbose: boolean?,
}

local MAX_LOG_LINES = 50

local HOOK_KINDS = { "beforeAll", "afterAll", "beforeEach", "afterEach" }

local function newBlock(name: string, parent: Block?, mode: Mode): Block
	return {
		name = name,
		parent = parent,
		children = {},
		mode = mode,
		hooks = { beforeAll = {}, afterAll = {}, beforeEach = {}, afterEach = {} },
		collectError = nil,
	}
end

-- The names from the outermost describe block down to `block`.
local function pathOf(block: Block?): { string }
	local parts = {}
	while block and block.parent do
		table.insert(parts, 1, block.name)
		block = block.parent
	end
	return parts
end

local function traceback(err: any): string
	if type(err) == "table" and err.message ~= nil then
		err = err.message
	end
	return debug.traceback(tostring(err), 2)
end

-- Keep the error line and the frames from spec/module code, dropping the harness's own frames.
local function trimTraceback(text: string): string
	local lines = string.split(text, "\n")
	local kept = {}
	for i, line in lines do
		if i == 1 or not (string.find(line, "lune-headless", 1, true) or string.find(line, "[C]", 1, true)) then
			table.insert(kept, line)
		end
		if #kept >= 12 then
			break
		end
	end
	return table.concat(kept, "\n")
end

local function callable(fn: (...any) -> ...any, extras: { [string]: any }): any
	return setmetatable(extras, {
		__call = function(_, ...)
			return fn(...)
		end,
	})
end

export type MiniJest = {
	Globals: { [string]: any },
	run: (self: MiniJest) -> { TestResult },
	log: (self: MiniJest, kind: string, message: string) -> (),
	strayError: (self: MiniJest, message: string) -> (),
	fileStrayErrors: (self: MiniJest) -> { string },
}

function MiniJest.new(options: Options): MiniJest
	local scheduler = options.scheduler
	local root = newBlock("", nil, "run")
	local current: Block = root
	local running = false
	local hasOnly = false

	local currentLogs: { string } = {}
	local currentStray: { string } = {}
	local fileStray: { string } = {}
	local inTest = false

	local self = {} :: any

	function self.log(_self, kind: string, message: string)
		if options.verbose then
			print(`[{kind}] {message}`)
		end
		local logs = if inTest then currentLogs else fileStray
		if #logs < MAX_LOG_LINES then
			table.insert(logs, `[{kind}] {message}`)
		end
	end

	function self.strayError(_self, message: string)
		if options.verbose then
			print(`[stray error] {message}`)
		end
		local list = if inTest then currentStray else fileStray
		if #list < MAX_LOG_LINES then
			table.insert(list, trimTraceback(message))
		end
	end

	-- Collection

	local function assertCollecting(what: string)
		if running and inTest then
			error(`{what} cannot be called inside a test`, 3)
		end
	end

	local function addTest(mode: Mode, name: string, fn: ((...any) -> ...any)?, timeout: number?)
		assertCollecting("it/test")
		if mode == "only" then
			hasOnly = true
		end
		table.insert(current.children, {
			kind = "test",
			test = { name = tostring(name), parent = current, fn = fn, mode = mode, timeout = timeout },
		})
	end

	local function addBlock(mode: Mode, name: string, fn: () -> ())
		assertCollecting("describe")
		if mode == "only" then
			hasOnly = true
		end
		local block = newBlock(tostring(name), current, mode)
		table.insert(current.children, { kind = "block", block = block })
		local parent = current
		current = block
		local ok, err = xpcall(fn :: any, traceback)
		current = parent
		if not ok then
			block.collectError = trimTraceback(err)
		end
	end

	local function addHook(kind: string, fn: any, timeout: number?)
		assertCollecting(kind)
		table.insert((current.hooks :: any)[kind], { fn = fn, timeout = timeout })
	end

	local it = callable(function(name, fn, timeout)
		addTest("run", name, fn, timeout)
	end, {
		skip = function(name, fn)
			addTest("skip", name, fn, nil)
		end,
		only = function(name, fn, timeout)
			addTest("only", name, fn, timeout)
		end,
		todo = function(name)
			addTest("todo", name, nil, nil)
		end,
	})

	local describe = callable(function(name, fn)
		addBlock("run", name, fn)
	end, {
		skip = function(name, fn)
			addBlock("skip", name, fn)
		end,
		only = function(name, fn)
			addBlock("only", name, fn)
		end,
	})

	local jestObject = {
		fn = Expect.fn,
		spyOn = Expect.spyOn,
		clearAllMocks = Expect.clearAllMocks,
		resetAllMocks = Expect.resetAllMocks,
		restoreAllMocks = Expect.restoreAllMocks,
		isMockFunction = Expect.isMock,
	}
	local function chain(fn: () -> ())
		return function(...)
			fn()
			return jestObject
		end
	end
	jestObject.useFakeTimers = chain(function()
		scheduler:useFakeTimers()
	end)
	jestObject.useRealTimers = chain(function()
		scheduler:useRealTimers()
	end)
	for _, name in
		{
			"advanceTimersByTime",
			"runAllTimers",
			"runOnlyPendingTimers",
			"advanceTimersToNextTimer",
			"clearAllTimers",
			"getTimerCount",
			"setSystemTime",
		}
	do
		jestObject[name] = function(...)
			return (scheduler :: any)[name](scheduler, ...)
		end
	end
	jestObject.now = function()
		return scheduler.nowMs
	end

	self.Globals = {
		describe = describe,
		xdescribe = describe.skip,
		fdescribe = describe.only,
		it = it,
		test = it,
		xit = it.skip,
		xtest = it.skip,
		fit = it.only,
		expect = Expect.expect,
		jest = jestObject,
	}
	for _, kind in HOOK_KINDS do
		self.Globals[kind] = function(fn, timeout)
			addHook(kind, fn, timeout)
		end
	end

	-- Running

	-- Runs fn in its own thread and waits for it to finish, letting Lune's scheduler resume it
	-- while it waits. Returns ok plus an error message.
	local function runAsync(fn: (...any) -> ...any, timeout: number): (boolean, string?)
		local state = { done = false, ok = true, err = nil :: string? }
		local function finish(ok: boolean, err: any?)
			if not state.done then
				state.done = true
				state.ok = ok
				state.err = if err ~= nil then tostring(err) else nil
			end
		end

		local nparams = debug.info(fn, "a")
		local thread = coroutine.create(function()
			if nparams >= 1 then
				-- Callback-style async test: finishes when done() is called.
				local function done(err: any?)
					if err ~= nil then
						finish(false, err)
					else
						finish(true)
					end
				end
				local ok, err = xpcall(fn, traceback, done)
				if not ok then
					finish(false, err)
				end
			else
				local ok, err = xpcall(fn, traceback)
				finish(ok, err)
			end
		end)

		local resumed, resumeErr = coroutine.resume(thread)
		if not resumed then
			finish(false, resumeErr)
		end

		local deadline = os.clock() + timeout
		while not state.done do
			if os.clock() >= deadline then
				if coroutine.status(thread) == "suspended" then
					pcall(coroutine.close, thread)
				end
				finish(false, `Exceeded timeout of {timeout} s: the test yielded and did not finish`)
				break
			end
			realTask.wait()
		end

		return state.ok, if state.err then trimTraceback(state.err) else nil
	end

	local function fullName(test: Test): string
		local parts = pathOf(test.parent)
		table.insert(parts, test.name)
		return table.concat(parts, " > ")
	end

	local function runHook(hook: Hook): (boolean, string?)
		return runAsync(hook.fn, hook.timeout or options.testTimeout)
	end

	local function effectiveMode(test: Test): Mode
		if test.mode == "todo" then
			return "todo"
		end
		local only = test.mode == "only"
		local block: Block? = test.parent
		while block do
			if block.mode == "skip" then
				return "skip"
			elseif block.mode == "only" then
				only = true
			end
			block = block.parent
		end
		if test.mode == "skip" then
			return "skip"
		end
		if hasOnly and not only then
			return "skip"
		end
		if options.filter and not string.find(fullName(test), options.filter, 1, true) then
			return "skip"
		end
		return "run"
	end

	local function hasRunnable(block: Block): boolean
		for _, node in block.children do
			if node.kind == "test" then
				if effectiveMode(node.test) == "run" then
					return true
				end
			elseif hasRunnable(node.block) then
				return true
			end
		end
		return false
	end

	local results: { TestResult } = {}

	local function record(result: TestResult)
		table.insert(results, result)
	end

	local function runTest(test: Test, inheritedError: string?)
		local name = fullName(test)
		local mode = effectiveMode(test)
		if mode ~= "run" then
			record({ name = name, status = if mode == "todo" then "todo" else "skipped", durationMs = 0 })
			return
		end

		local started = os.clock()
		currentLogs = {}
		currentStray = {}
		inTest = true

		local err: string? = inheritedError
		local chainBlocks: { Block } = {}
		local b: Block? = test.parent
		while b do
			table.insert(chainBlocks, 1, b)
			b = b.parent
		end

		for _, block in chainBlocks do
			for _, hook in block.hooks.beforeEach do
				if err then
					break
				end
				local ok, hookErr = runHook(hook)
				if not ok then
					err = "beforeEach: " .. tostring(hookErr)
				end
			end
		end

		if not err and test.fn then
			local ok, testErr = runAsync(test.fn, test.timeout or options.testTimeout)
			if not ok then
				err = testErr
			end
		end

		for i = #chainBlocks, 1, -1 do
			for _, hook in chainBlocks[i].hooks.afterEach do
				local ok, hookErr = runHook(hook)
				if not ok and not err then
					err = "afterEach: " .. tostring(hookErr)
				end
			end
		end

		inTest = false
		record({
			name = name,
			status = if err then "failed" else "passed",
			durationMs = math.floor((os.clock() - started) * 1e4) / 10,
			error = err,
			strayErrors = if #currentStray > 0 then currentStray else nil,
			logs = if err and #currentLogs > 0 then currentLogs else nil,
		})
	end

	local function runBlock(block: Block)
		local path = table.concat(pathOf(block), " > ")
		if block.collectError then
			record({ name = path .. " [describe body]", status = "failed", durationMs = 0, error = block.collectError })
		end

		-- beforeAll and afterAll hooks run only around a block with a test that runs.
		local runnable = hasRunnable(block)
		local beforeAllError: string? = nil
		if runnable then
			for _, hook in block.hooks.beforeAll do
				local ok, hookErr = runHook(hook)
				if not ok then
					beforeAllError = "beforeAll: " .. tostring(hookErr)
					break
				end
			end
		end

		for _, node in block.children do
			if node.kind == "test" then
				runTest(node.test, beforeAllError)
			else
				runBlock(node.block)
			end
		end

		if runnable then
			for _, hook in block.hooks.afterAll do
				local ok, hookErr = runHook(hook)
				if not ok then
					record({
						name = (if block.parent then path .. " " else "") .. "[afterAll]",
						status = "failed",
						durationMs = 0,
						error = "afterAll: " .. tostring(hookErr),
					})
				end
			end
		end
	end

	-- Errors and logs from threads that ran outside any test (while loading, or after their test).
	function self.fileStrayErrors(_self): { string }
		return fileStray
	end

	function self.run(_self): { TestResult }
		running = true
		runBlock(root)
		running = false
		return results
	end

	return self :: MiniJest
end

return MiniJest
