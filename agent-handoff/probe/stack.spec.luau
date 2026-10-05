--!strict
-- Probe: the full immediateutils + jecs stack a netcode addon would sit on, ticked headlessly.
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

local describe, it, expect = Jest.Globals.describe, Jest.Globals.it, Jest.Globals.expect

describe("immediate stack under Lune", function()
	it("builds a jecs runtime, ticks systems, and hooks keep per-call state", function()
		local scheduler = ImmediateScheduler.new()
		local rt = ImmediateInstall.stack3(
			ImmediateCoreUtils.createImmediateRuntime(ServiceBag.new(), function() return nil end),
			scheduler,
			JecsImmediateInstall({}, false),
			JecsImmediateHooksInstall,
			ImmediateDeferInstall
		)
		local Gold = rt.world:component()
		local hooks = JecsImmediateHooksCommonHooks(rt)

		local created = 0
		scheduler:RegisterSystem({
			name = "spawner",
			notProtected = true,
			system = function(r, h)
				local et = h.cache(function()
					created += 1
					local e = r.world:entity()
					r.world:set(e, Gold, 0)
					return e
				end)
				r.world:set(et, Gold, r.world:get(et, Gold) + 10)
			end,
		})

		for _ = 1, 5 do
			scheduler:Tick(rt, hooks)
		end

		local total = 0
		for _, gold in rt.world:query(Gold) do
			total += gold
		end
		expect(created).toBe(1)
		expect(total).toBe(50)
		expect(Jecs.pair ~= nil).toBe(true)
		rt.Destroy()
	end)
end)
