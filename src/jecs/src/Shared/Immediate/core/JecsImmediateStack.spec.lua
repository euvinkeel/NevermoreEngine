--!nonstrict
--[[
	@class JecsImmediateStack.spec.lua

	The full stack a netcode addon would sit on: core runtime, scheduler, a jecs world, the hooks
	infrastructure, rt.defer, and the common hooks pack, ticked like a game loop.
]]
local require = require(script.Parent.loader).load(script)

local ImmediateCoreUtils = require("ImmediateCoreUtils")
local ImmediateDeferInstall = require("ImmediateDeferInstall")
local ImmediateInstall = require("ImmediateInstall")
local ImmediateScheduler = require("ImmediateScheduler")
local Jecs = require("Jecs")
local JecsImmediateHooksCommonHooks = require("JecsImmediateHooksCommonHooks")
local JecsImmediateHooksInstall = require("JecsImmediateHooksInstall")
local JecsImmediateInstall = require("JecsImmediateInstall")
local Jest = require("Jest")
local ServiceBag = require("ServiceBag")

local describe = Jest.Globals.describe
local expect = Jest.Globals.expect
local it = Jest.Globals.it

-- Components declared before any world exists, the way a game declares them.
local Gold = Jecs.component()

local function makeStack()
	local scheduler = ImmediateScheduler.new()
	local rt = ImmediateInstall.stack3(
		ImmediateCoreUtils.createImmediateRuntime(ServiceBag.new(), function(_path: string)
			return nil
		end),
		scheduler,
		JecsImmediateInstall({ Gold = Gold }, false),
		JecsImmediateHooksInstall,
		ImmediateDeferInstall
	)
	local hooks = JecsImmediateHooksCommonHooks(rt)
	return rt, scheduler, hooks
end

local function tick(rt, scheduler, hooks, count: number)
	for _ = 1, count do
		scheduler:Tick(rt, hooks)
	end
end

describe("Jecs immediate stack", function()
	it("exposes the world, jecs and the components it was given", function()
		local rt, scheduler = makeStack()

		expect(rt.world).never.toBeNil()
		expect(rt.jecs).toBe(Jecs)
		expect(rt.comps.Gold).toBe(Gold)
		expect(rt.comps.Maid).never.toBeNil()
		expect(rt.comps.MetaHookState).never.toBeNil()

		rt.Destroy()
		scheduler:Destroy()
	end)

	it("ticks systems that keep per-call-site state with hooks.cache", function()
		local rt, scheduler, hooks = makeStack()
		local created = 0
		scheduler:RegisterSystem({
			name = "spawner",
			system = function(r, h)
				local entity = h.cache(function()
					created += 1
					local e = r.world:entity()
					r.world:set(e, r.comps.Gold, 0)
					return e
				end)
				r.world:set(entity, r.comps.Gold, r.world:get(entity, r.comps.Gold) + 10)
			end,
		})

		tick(rt, scheduler, hooks, 5)

		local total = 0
		for _, gold in rt.world:query(rt.comps.Gold) do
			total += gold
		end
		expect(created).toEqual(1)
		expect(total).toEqual(50)
		rt.Destroy()
		scheduler:Destroy()
	end)

	it("gives each loop iteration its own hook state", function()
		local rt, scheduler, hooks = makeStack()
		local counts = {}
		scheduler:RegisterSystem({
			name = "loop",
			system = function(_r, h)
				for i = 1, 3 do
					counts[i] = h.counter()
				end
			end,
		})

		tick(rt, scheduler, hooks, 4)

		expect(counts).toEqual({ 4, 4, 4 })
		rt.Destroy()
		scheduler:Destroy()
	end)

	it("cleans up a hook that wasn't called for a tick, running its maid", function()
		local rt, scheduler, hooks = makeStack()
		local enabled = true
		local inits = 0
		local cleanups = 0
		scheduler:RegisterSystem({
			name = "toggled",
			system = function(_r, h)
				if enabled then
					h.state(nil, function(_state, maid)
						inits += 1
						maid:GiveTask(function()
							cleanups += 1
						end)
					end)
				end
			end,
		})

		tick(rt, scheduler, hooks, 2)
		expect(inits).toEqual(1)

		enabled = false
		tick(rt, scheduler, hooks, 1)
		expect(cleanups).toEqual(1)

		enabled = true
		tick(rt, scheduler, hooks, 1)
		expect(inits).toEqual(2)
		rt.Destroy()
		scheduler:Destroy()
	end)

	it("applies rt.defer changes after the system's query loop", function()
		local rt, scheduler, hooks = makeStack()
		for _ = 1, 5 do
			rt.world:set(rt.world:entity(), rt.comps.Gold, 1)
		end
		scheduler:RegisterSystem({
			name = "reaper",
			system = function(r)
				for entity in r.world:query(r.comps.Gold) do
					r.defer(function()
						r.world:delete(entity)
					end)
				end
			end,
		})

		tick(rt, scheduler, hooks, 1)

		local remaining = 0
		for _ in rt.world:query(rt.comps.Gold) do
			remaining += 1
		end
		expect(remaining).toEqual(0)
		rt.Destroy()
		scheduler:Destroy()
	end)

	it("cleans up the world and every hook maid on Destroy", function()
		local rt, scheduler, hooks = makeStack()
		local cleaned = 0
		scheduler:RegisterSystem({
			name = "holder",
			system = function(_r, h)
				local maid = h.maid()
				if h.gate() then
					maid:GiveTask(function()
						cleaned += 1
					end)
				end
			end,
		})
		tick(rt, scheduler, hooks, 1)
		local world = rt.world

		rt.Destroy()

		expect(cleaned).toEqual(1)
		expect(next(world)).toBeNil()
		scheduler:Destroy()
	end)
end)
