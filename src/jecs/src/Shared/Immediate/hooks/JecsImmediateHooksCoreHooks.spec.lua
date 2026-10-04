--!nonstrict
--[[
	@class JecsImmediateHooksCoreHooks.spec.lua

	Ticks the engine-free hooks pack on its own, the way a game does: hooks are called from inside
	a system, keyed by call site, and cleaned up after a tick without a call. Time comes from jest's
	fake timers, which also drive os.clock().
]]
local require = require(script.Parent.loader).load(script)

local ImmediateCoreUtils = require("ImmediateCoreUtils")
local ImmediateInstall = require("ImmediateInstall")
local ImmediateScheduler = require("ImmediateScheduler")
local JecsImmediateHooksCoreHooks = require("JecsImmediateHooksCoreHooks")
local JecsImmediateHooksInstall = require("JecsImmediateHooksInstall")
local JecsImmediateInstall = require("JecsImmediateInstall")
local Jest = require("Jest")
local ServiceBag = require("ServiceBag")
local Signal = require("Signal")

local afterEach = Jest.Globals.afterEach
local beforeEach = Jest.Globals.beforeEach
local describe = Jest.Globals.describe
local expect = Jest.Globals.expect
local it = Jest.Globals.it
local jest = Jest.Globals.jest

local GUID_PATTERN = "^{%x%x%x%x%x%x%x%x%-%x%x%x%x%-4%x%x%x%-[89AB]%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x}$"

-- Builds a runtime with one gameplay system that calls `body(hooks)` every tick. Each body is
-- one function for the whole test, so its hook calls keep the same call sites from tick to tick.
local function makeHarness(body: (hooks: any) -> ())
	local scheduler = ImmediateScheduler.new()
	local rt = ImmediateInstall.stack2(
		ImmediateCoreUtils.createImmediateRuntime(ServiceBag.new(), function(_path: string)
			return nil
		end),
		scheduler,
		JecsImmediateInstall({}, false),
		JecsImmediateHooksInstall
	)
	local hooks = JecsImmediateHooksCoreHooks(rt)
	scheduler:RegisterSystem({
		name = "body",
		notProtected = true,
		system = function(_rt, h)
			body(h)
		end,
	})

	local harness = {}
	function harness.tick(count: number?)
		for _ = 1, count or 1 do
			scheduler:Tick(rt, hooks)
		end
	end
	-- Advances fake time, then ticks once.
	function harness.after(seconds: number)
		jest.advanceTimersByTime(seconds * 1000)
		harness.tick()
	end
	function harness.destroy()
		rt.Destroy()
		scheduler:Destroy()
	end
	return harness
end

beforeEach(function()
	jest.useFakeTimers()
end)

afterEach(function()
	jest.useRealTimers()
end)

describe("JecsImmediateHooksCoreHooks", function()
	it("has none of the Roblox pack's hooks", function()
		local harness = makeHarness(function() end)
		local hooks = JecsImmediateHooksCoreHooks({} :: any)

		for _, name in { "filterDescendants", "findChild", "useBinder", "useTieInterface", "value" } do
			expect(hooks[name]).toBeNil()
		end
		expect(type(hooks.guid)).toBe("function")
		harness.destroy()
	end)
end)

describe("hooks.counter", function()
	it("counts per call site, not per hook", function()
		local first, second = {}, {}
		local harness = makeHarness(function(hooks)
			table.insert(first, hooks.counter())
			table.insert(second, hooks.counter())
		end)

		harness.tick(3)

		expect(first).toEqual({ 1, 2, 3 })
		expect(second).toEqual({ 1, 2, 3 })
		harness.destroy()
	end)
end)

describe("hooks.guid", function()
	it("returns one HttpService-format GUID per call site", function()
		local a, b = {}, {}
		local harness = makeHarness(function(hooks)
			table.insert(a, hooks.guid())
			table.insert(b, hooks.guid())
		end)

		harness.tick(2)

		expect(string.match(a[1], GUID_PATTERN)).never.toBeNil()
		expect(a[2]).toBe(a[1])
		expect(b[2]).toBe(b[1])
		expect(b[1]).never.toBe(a[1])
		harness.destroy()
	end)
end)

describe("hooks.delayed", function()
	it("fires once per elapsed period, starting one period after the first call", function()
		local fired = {}
		local harness = makeHarness(function(hooks)
			table.insert(fired, hooks.delayed(1))
		end)

		harness.tick()
		harness.after(0.5)
		harness.after(0.5)
		harness.after(0.5)
		harness.after(0.5)

		expect(fired).toEqual({ false, false, true, false, true })
		harness.destroy()
	end)
end)

describe("hooks.deltatime and hooks.difference", function()
	it("report the change since the previous tick, zero on the first", function()
		local dts, diffs = {}, {}
		local value = 10
		local harness = makeHarness(function(hooks)
			table.insert(dts, hooks.deltatime())
			table.insert(diffs, hooks.difference(value))
		end)

		harness.tick()
		value = 13
		harness.after(0.25)
		value = 12
		harness.after(1)

		expect(dts[1]).toBe(0)
		expect(dts[2]).toBeCloseTo(0.25, 5)
		expect(dts[3]).toBeCloseTo(1, 5)
		expect(diffs).toEqual({ 0, 3, -1 })
		harness.destroy()
	end)

	it("keep the reference point when told not to update", function()
		local diffs = {}
		local value = 1
		local harness = makeHarness(function(hooks)
			table.insert(diffs, hooks.difference(value, nil, false))
		end)

		harness.tick()
		value = 4
		harness.tick()
		value = 6
		harness.tick()

		expect(diffs).toEqual({ 0, 3, 5 })
		harness.destroy()
	end)
end)

describe("hooks.conditionSustained", function()
	it("measures how long a condition has held and resets when it breaks", function()
		local held = {}
		local condition = true
		local harness = makeHarness(function(hooks)
			table.insert(held, hooks.conditionSustained(condition))
		end)

		harness.tick()
		harness.after(2)
		condition = false
		harness.after(1)
		condition = true
		harness.after(1)
		harness.after(0.5)

		expect(held[1]).toBe(0)
		expect(held[2]).toBeCloseTo(2, 5)
		expect(held[3]).toBe(0)
		expect(held[4]).toBe(0)
		expect(held[5]).toBeCloseTo(0.5, 5)
		harness.destroy()
	end)
end)

describe("hooks.linearWalk", function()
	it("walks a number toward its goal at a fixed speed and stops there", function()
		local positions = {}
		local harness = makeHarness(function(hooks)
			table.insert(positions, hooks.linearWalk(nil, 10, 0, 2))
		end)

		harness.tick()
		harness.after(1)
		harness.after(1)
		harness.after(10)

		expect(positions[1]).toBe(0)
		expect(positions[2]).toBeCloseTo(2, 5)
		expect(positions[3]).toBeCloseTo(4, 5)
		expect(positions[4]).toBe(10)
		harness.destroy()
	end)

	it("derives the speed from a duration", function()
		local positions = {}
		local harness = makeHarness(function(hooks)
			table.insert(positions, hooks.linearWalk(nil, 8, 0, nil, 4))
		end)

		harness.tick()
		harness.after(1)
		harness.after(3)

		expect(positions[2]).toBeCloseTo(2, 5)
		expect(positions[3]).toBe(8)
		harness.destroy()
	end)
end)

describe("hooks.random, hooks.noise and hooks.sin", function()
	it("stay within their range, and random keeps its value per call site", function()
		local randoms, noises, sines = {}, {}, {}
		local harness = makeHarness(function(hooks)
			table.insert(randoms, hooks.random(nil, 5, 6))
			table.insert(noises, hooks.noise(nil, -1, 1, 3))
			table.insert(sines, hooks.sin(nil, 10, 20, 0.5))
		end)

		harness.tick()
		for _ = 1, 20 do
			harness.after(0.1)
		end

		for i = 1, #randoms do
			expect(randoms[i]).toBe(randoms[1])
			expect(noises[i] >= -1 and noises[i] <= 1).toBe(true)
			expect(sines[i] >= 10 and sines[i] <= 20).toBe(true)
		end
		expect(randoms[1] >= 5 and randoms[1] < 6).toBe(true)
		harness.destroy()
	end)
end)

describe("hooks.slidingAvg", function()
	it("averages the last N values", function()
		local averages = {}
		local value = 0
		local harness = makeHarness(function(hooks)
			table.insert(averages, (hooks.slidingAvg(value, 2)))
		end)

		for _, v in { 2, 4, 6, 8 } do
			value = v
			harness.tick()
		end

		expect(averages).toEqual({ 2, 3, 5, 7 })
		harness.destroy()
	end)
end)

describe("hooks.spring", function()
	it("moves a number toward its target over time", function()
		local positions = {}
		local harness = makeHarness(function(hooks)
			table.insert(positions, (hooks.spring(nil, 1, 0, 20, 1)))
		end)

		harness.tick()
		harness.after(0.05)
		harness.after(1)

		expect(positions[1]).toBe(0)
		expect(positions[2] > 0 and positions[2] < 1).toBe(true)
		expect(positions[3]).toBeCloseTo(1, 2)
		harness.destroy()
	end)
end)

describe("hooks.subscribe", function()
	it("drains what a signal fired since the last tick", function()
		local signal = Signal.new()
		local drained = {}
		local harness = makeHarness(function(hooks)
			local seen = {}
			for _, value in hooks.subscribe(signal) do
				table.insert(seen, value)
			end
			table.insert(drained, seen)
		end)

		harness.tick()
		signal:Fire("a")
		signal:Fire("b")
		harness.tick()
		harness.tick()
		signal:Fire("c")
		harness.tick()

		expect(drained).toEqual({ {}, { "a", "b" }, {}, { "c" } })
		signal:Destroy()
		harness.destroy()
	end)
end)

describe("hooks.async", function()
	it("starts the function once and hands back the same result table", function()
		local starts = 0
		local results = {}
		local harness = makeHarness(function(hooks)
			table.insert(
				results,
				hooks.async(function(ret)
					starts += 1
					ret.done = true
				end)
			)
		end)

		harness.tick(3)

		expect(starts).toBe(1)
		expect(results[1].done).toBe(true)
		expect(results[3]).toBe(results[1])
		harness.destroy()
	end)
end)

describe("hooks.maid", function()
	it("cleans its tasks once the hook goes unused for a tick", function()
		local enabled = true
		local cleaned = 0
		local harness = makeHarness(function(hooks)
			if enabled then
				local maid = hooks.maid()
				if not maid._given then
					maid._given = true
					maid:GiveTask(function()
						cleaned += 1
					end)
				end
			end
		end)

		harness.tick(2)
		expect(cleaned).toBe(0)

		enabled = false
		harness.tick(2)

		expect(cleaned).toBe(1)
		harness.destroy()
	end)
end)
