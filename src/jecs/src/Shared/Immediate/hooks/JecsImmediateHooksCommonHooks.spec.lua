--!nonstrict
--[[
	@class JecsImmediateHooksCommonHooks.spec.lua

	Ticks the common hooks pack the way a game does: hooks are called from inside a system, keyed
	by call site, and a hook that isn't called for a whole tick is cleaned up at the end of it.
	Time comes from jest's fake timers, which also drive os.clock().
]]
local require = require(script.Parent.loader).load(script)

local ImmediateCoreUtils = require("ImmediateCoreUtils")
local ImmediateInstall = require("ImmediateInstall")
local ImmediateScheduler = require("ImmediateScheduler")
local JecsImmediateHooksCommonHooks = require("JecsImmediateHooksCommonHooks")
local JecsImmediateHooksCoreHooks = require("JecsImmediateHooksCoreHooks")
local JecsImmediateHooksInstall = require("JecsImmediateHooksInstall")
local JecsImmediateHooksRobloxHooks = require("JecsImmediateHooksRobloxHooks")
local JecsImmediateInstall = require("JecsImmediateInstall")
local Jest = require("Jest")
local ServiceBag = require("ServiceBag")

local afterEach = Jest.Globals.afterEach
local beforeEach = Jest.Globals.beforeEach
local describe = Jest.Globals.describe
local expect = Jest.Globals.expect
local it = Jest.Globals.it
local jest = Jest.Globals.jest

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
	local hooks = JecsImmediateHooksCommonHooks(rt)
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

describe("hooks.cache", function()
	it("computes once per call site and keeps every returned value", function()
		local computed = 0
		local results = {}
		local harness = makeHarness(function(hooks)
			local a, b = hooks.cache(function()
				computed += 1
				return "value", computed
			end)
			table.insert(results, { a, b })
		end)

		harness.tick(3)

		expect(computed).toEqual(1)
		expect(results).toEqual({ { "value", 1 }, { "value", 1 }, { "value", 1 } })
		harness.destroy()
	end)

	it("keeps separate values for separate discriminators", function()
		local seen = {}
		local harness = makeHarness(function(hooks)
			for _, key in { "a", "b" } do
				seen[key] = hooks.cache(function()
					return key .. "!"
				end, key)
			end
		end)

		harness.tick(2)

		expect(seen).toEqual({ a = "a!", b = "b!" })
		harness.destroy()
	end)

	it("runs cleanup with the cached values once the hook goes unused for a tick", function()
		local enabled = true
		local computed = 0
		local cleanedWith = nil
		local harness = makeHarness(function(hooks)
			if enabled then
				hooks.cache(
					function()
						computed += 1
						return "value", computed
					end,
					nil,
					function(...)
						cleanedWith = { ... }
					end
				)
			end
		end)

		harness.tick(2)
		expect(cleanedWith).toBeNil()

		enabled = false
		harness.tick()
		expect(cleanedWith).toEqual({ "value", 1 })

		enabled = true
		harness.tick()
		expect(computed).toEqual(2)
		harness.destroy()
	end)
end)

describe("hooks.throttle", function()
	it("passes on the first call, then at most once per window of os.clock()", function()
		local passes = {}
		local harness = makeHarness(function(hooks)
			table.insert(passes, hooks.throttle(1))
		end)

		harness.tick() -- t = 0
		jest.advanceTimersByTime(500)
		harness.tick() -- t = 0.5
		jest.advanceTimersByTime(500)
		harness.tick() -- t = 1.0
		jest.advanceTimersByTime(999)
		harness.tick() -- t = 1.999
		jest.advanceTimersByTime(1)
		harness.tick() -- t = 2.0

		expect(passes).toEqual({ true, false, true, false, true })
		harness.destroy()
	end)

	it("waits a full window before the first pass when delayOnFirstCall is set", function()
		local passes = {}
		local harness = makeHarness(function(hooks)
			table.insert(passes, hooks.throttle(1, nil, true))
		end)

		harness.tick()
		jest.advanceTimersByTime(1000)
		harness.tick()

		expect(passes).toEqual({ false, true })
		harness.destroy()
	end)

	it("keeps its window through unused ticks until the window has passed", function()
		local enabled = true
		local passes = {}
		local harness = makeHarness(function(hooks)
			if enabled then
				table.insert(passes, hooks.throttle(1))
			end
		end)

		harness.tick() -- t = 0: passes
		enabled = false
		jest.advanceTimersByTime(300)
		harness.tick()
		jest.advanceTimersByTime(300)
		harness.tick() -- unused for two ticks, but the window is still open, so state is kept
		enabled = true
		jest.advanceTimersByTime(300)
		harness.tick() -- t = 0.9: still throttled

		enabled = false
		jest.advanceTimersByTime(1100)
		harness.tick() -- t = 2.0: unused and the window has passed, so state is cleaned up
		enabled = true
		jest.advanceTimersByTime(100)
		harness.tick() -- t = 2.1: fresh state passes immediately

		expect(passes).toEqual({ true, false, true })
		harness.destroy()
	end)
end)

describe("hooks.changed", function()
	it("is false on the first call, then true whenever the value changes", function()
		local values = { 1, 1, 2, 2, 3 }
		local index = 0
		local results = {}
		local harness = makeHarness(function(hooks)
			index += 1
			table.insert(results, hooks.changed(values[index]))
		end)

		harness.tick(#values)

		expect(results).toEqual({ false, false, true, false, true })
		harness.destroy()
	end)

	it("is true on the first call when runFirst is set", function()
		local results = {}
		local harness = makeHarness(function(hooks)
			table.insert(results, hooks.changed("same", nil, true))
		end)

		harness.tick(2)

		expect(results).toEqual({ true, false })
		harness.destroy()
	end)

	it("only reports changes to onlyOnEqualTo when it is given", function()
		local values = { 1, 2, 2, 3, 2 }
		local index = 0
		local results = {}
		local harness = makeHarness(function(hooks)
			index += 1
			table.insert(results, hooks.changed(values[index], nil, false, 2))
		end)

		harness.tick(#values)

		expect(results).toEqual({ false, true, false, false, true })
		harness.destroy()
	end)
end)

describe("hooks.state", function()
	it("runs init once and returns the same table and maid every tick", function()
		local inits = 0
		local states = {}
		local maids = {}
		local harness = makeHarness(function(hooks)
			local state, maid = hooks.state(nil, function(s, _maid)
				inits += 1
				s.count = 0
			end)
			state.count += 1
			table.insert(states, state)
			table.insert(maids, maid)
		end)

		harness.tick(3)

		expect(inits).toEqual(1)
		expect(states[1]).toBe(states[3])
		expect(maids[1]).toBe(maids[3])
		expect(states[3].count).toEqual(3)
		harness.destroy()
	end)
end)

describe("hooks.gate", function()
	it("opens once, and again only after the hook was cleaned up", function()
		local enabled = true
		local results = {}
		local harness = makeHarness(function(hooks)
			if enabled then
				table.insert(results, hooks.gate())
			end
		end)

		harness.tick(2)
		enabled = false
		harness.tick()
		enabled = true
		harness.tick(2)

		expect(results).toEqual({ true, false, true, false })
		harness.destroy()
	end)

	it("keeps one gate per call site", function()
		local results = {}
		local harness = makeHarness(function(hooks)
			local first = hooks.gate()
			local second = hooks.gate()
			table.insert(results, { first, second })
		end)

		harness.tick(2)

		expect(results).toEqual({ { true, true }, { false, false } })
		harness.destroy()
	end)
end)

describe("JecsImmediateHooksCommonHooks (facade)", function()
	it("has every core hook and every Roblox hook, and nothing else", function()
		local hooks = JecsImmediateHooksCommonHooks({} :: any)
		local expected = {}
		for name in JecsImmediateHooksCoreHooks({} :: any) do
			expected[name] = true
		end
		for name in JecsImmediateHooksRobloxHooks({} :: any) do
			expected[name] = true
		end

		local actual = {}
		for name, hook in hooks do
			expect(type(hook)).toBe("function")
			actual[name] = true
		end
		expect(actual).toEqual(expected)
	end)

	it("keys a Roblox-pack hook by the game's call site, so nothing wraps it", function()
		-- State is keyed by the caller's file:line plus the call's order on that line. A wrapper
		-- would put every call on the wrapper's line, so skipping the first call site would shift
		-- the second one onto the first one's state.
		local callFirst = true
		local first, second = {}, {}
		local harness = makeHarness(function(hooks)
			if callFirst then
				table.insert(first, hooks.guid())
			end
			table.insert(second, hooks.guid())
		end)

		harness.tick()
		callFirst = false
		harness.tick()

		expect(type(second[1])).toBe("string")
		expect(second[1]).never.toBe(first[1])
		expect(second[2]).toBe(second[1])
		harness.destroy()
	end)
end)
