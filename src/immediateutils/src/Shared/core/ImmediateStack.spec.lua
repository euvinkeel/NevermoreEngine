--!strict
--[[
	@class ImmediateStack.spec.lua

	The immediate runtime as an addon would see it: a core runtime, a scheduler, installers stacked
	with ImmediateInstall, and ImmediateDeferInstall's post-system flush.
]]
local require = require(script.Parent.loader).load(script)

local ImmediateCoreUtils = require("ImmediateCoreUtils")
local ImmediateDeferInstall = require("ImmediateDeferInstall")
local ImmediateInstall = require("ImmediateInstall")
local ImmediateScheduler = require("ImmediateScheduler")
local Jest = require("Jest")
local ServiceBag = require("ServiceBag")

local describe = Jest.Globals.describe
local expect = Jest.Globals.expect
local it = Jest.Globals.it

local function makeRuntime(DEBUG: boolean?)
	return ImmediateCoreUtils.createImmediateRuntime(ServiceBag.new(), function(_path: string)
		return nil
	end, nil, nil, DEBUG)
end

local function findErrorEntry(rt: any, systemName: string): any
	for _, entry in rt.errorlog do
		if type(entry) == "table" and entry.systemName == systemName then
			return entry
		end
	end
	return nil
end

describe("ImmediateInstall.stack3", function()
	it("applies addons in order, handing each the previous result and the scheduler", function()
		local scheduler = ImmediateScheduler.new()
		local order = {}
		local function addA(rt: any, s: any): any
			table.insert(order, "a")
			expect(s).toBe(scheduler)
			rt.a = 1
			return rt
		end
		local function addB(rt: any, s: any): any
			table.insert(order, "b")
			expect(s).toBe(scheduler)
			rt.b = rt.a + 1
			return rt
		end
		local function addC(rt: any, s: any): any
			table.insert(order, "c")
			expect(s).toBe(scheduler)
			rt.c = rt.b + 1
			return rt
		end

		local rt = ImmediateInstall.stack3(makeRuntime(), scheduler, addA, addB, addC)

		expect(order).toEqual({ "a", "b", "c" })
		expect(rt.c).toEqual(3)
		scheduler:Destroy()
	end)
end)

describe("ImmediateScheduler.Tick", function()
	it("runs preTick, then preSystem/system/postSystem around each system, then postTick", function()
		local scheduler = ImmediateScheduler.new()
		local log = {}
		local function record(name: string)
			return function()
				table.insert(log, name)
			end
		end
		scheduler:RegisterSystem({ name = "pre_tick", preTick = true, system = record("preTick") })
		scheduler:RegisterSystem({ name = "post_tick", postTick = true, system = record("postTick") })
		scheduler:RegisterSystem({ name = "pre_system", preSystem = true, system = record("pre") })
		scheduler:RegisterSystem({ name = "post_system", postSystem = true, system = record("post") })
		scheduler:RegisterSystem({ name = "b", system = record("b") })
		scheduler:RegisterSystem({ name = "a", system = record("a") })
		scheduler:RegisterSystem({ name = "z_first", priority = -1, system = record("first") })

		scheduler:Tick(makeRuntime())

		expect(log).toEqual({
			"preTick",
			"pre",
			"first",
			"post",
			"pre",
			"a",
			"post",
			"pre",
			"b",
			"post",
			"postTick",
		})
		scheduler:Destroy()
	end)

	it("passes extra Tick arguments to every system", function()
		local scheduler = ImmediateScheduler.new()
		local received = {}
		scheduler:RegisterSystem({
			name = "a",
			system = function(_rt, first, second)
				table.insert(received, { first, second })
			end,
		})

		scheduler:Tick(makeRuntime(), "x", 2)

		local expected: { any } = { "x", 2 }
		expect(received).toEqual({ expected })
		scheduler:Destroy()
	end)

	it("tracks the previous gameplay system and the previous raw system", function()
		local scheduler = ImmediateScheduler.new()
		local rt = makeRuntime()
		local seenInB: { any } = {}
		local systemA = { name = "a", priority = 1, system = function() end }
		local middleware = { name = "mw", postSystem = true, system = function() end }
		scheduler:RegisterSystem(systemA)
		scheduler:RegisterSystem(middleware)
		scheduler:RegisterSystem({
			name = "b",
			priority = 2,
			system = function(r)
				seenInB = { r.previousSystem, r.previousRawSystem }
			end,
		})

		scheduler:Tick(rt)

		expect(seenInB[1]).toBe(systemA)
		expect(seenInB[2]).toBe(middleware)
		scheduler:Destroy()
	end)

	it("logs a failing system in rt.errorlog and still runs the others", function()
		local scheduler = ImmediateScheduler.new()
		local rt = makeRuntime()
		local ran = 0
		scheduler:RegisterSystem({
			name = "broken",
			priority = 1,
			system = function()
				error("broken system")
			end,
		})
		scheduler:RegisterSystem({
			name = "healthy",
			priority = 2,
			system = function()
				ran += 1
			end,
		})

		-- The log key includes the traceback, so tick from one call site like a game loop does.
		for _ = 1, 2 do
			scheduler:Tick(rt)
		end

		expect(ran).toEqual(2)
		local entry = findErrorEntry(rt, "broken")
		expect(entry).never.toBeNil()
		expect(entry.count).toEqual(2)
		expect(entry.traceback).toContain("broken system")
		scheduler:Destroy()
	end)

	it("in DEBUG mode, logs a system that yields instead of letting it hang the tick", function()
		local scheduler = ImmediateScheduler.new()
		local rt = makeRuntime(true)
		local after = 0
		scheduler:RegisterSystem({
			name = "yielder",
			priority = 1,
			system = function()
				task.wait()
			end,
		})
		scheduler:RegisterSystem({
			name = "after",
			priority = 2,
			system = function()
				after += 1
			end,
		})

		scheduler:Tick(rt)

		expect(after).toEqual(1)
		local entry = findErrorEntry(rt, "yielder")
		expect(entry).never.toBeNil()
		expect(entry.traceback).toContain("yielded")
		scheduler:Destroy()
	end)
end)

describe("ImmediateDeferInstall", function()
	it("runs deferred callbacks right after the system that queued them", function()
		local scheduler = ImmediateScheduler.new()
		local rt = ImmediateInstall.stack1(makeRuntime(), scheduler, ImmediateDeferInstall)
		local log = {}
		scheduler:RegisterSystem({
			name = "a",
			priority = 1,
			system = function()
				rt.defer(function()
					table.insert(log, "deferred from a")
				end)
				table.insert(log, "a")
			end,
		})
		scheduler:RegisterSystem({
			name = "b",
			priority = 2,
			system = function()
				table.insert(log, "b")
			end,
		})

		scheduler:Tick(rt)

		expect(log).toEqual({ "a", "deferred from a", "b" })
		expect(#rt.defer_buffer).toEqual(0)
		scheduler:Destroy()
	end)

	it("runs a callback deferred during a flush after the next system", function()
		local scheduler = ImmediateScheduler.new()
		local rt = ImmediateInstall.stack1(makeRuntime(), scheduler, ImmediateDeferInstall)
		local log = {}
		scheduler:RegisterSystem({
			name = "a",
			priority = 1,
			system = function()
				rt.defer(function()
					table.insert(log, "first")
					rt.defer(function()
						table.insert(log, "nested")
					end)
				end)
			end,
		})
		scheduler:RegisterSystem({
			name = "b",
			priority = 2,
			system = function()
				table.insert(log, "b")
			end,
		})

		scheduler:Tick(rt)

		expect(log).toEqual({ "first", "b", "nested" })
		scheduler:Destroy()
	end)

	it("never runs a failing callback twice", function()
		local scheduler = ImmediateScheduler.new()
		local rt = ImmediateInstall.stack1(makeRuntime(), scheduler, ImmediateDeferInstall)
		local attempts = 0
		local queued = false
		scheduler:RegisterSystem({
			name = "a",
			system = function()
				if not queued then
					queued = true
					rt.defer(function()
						attempts += 1
						error("deferred failure")
					end)
				end
			end,
		})

		scheduler:Tick(rt)
		scheduler:Tick(rt)

		expect(attempts).toEqual(1)
		expect(#rt.defer_buffer).toEqual(0)
		expect(findErrorEntry(rt, "mw_immediate_defer_flush")).never.toBeNil()
		scheduler:Destroy()
	end)
end)

describe("ImmediateRuntime.Destroy", function()
	it("cleans up the runtime's maid and clears the runtime table", function()
		local rt = makeRuntime()
		local cleaned = false
		rt.maid:GiveTask(function()
			cleaned = true
		end)

		rt.Destroy()

		expect(cleaned).toEqual(true)
		expect(next(rt)).toBeNil()
	end)
end)
