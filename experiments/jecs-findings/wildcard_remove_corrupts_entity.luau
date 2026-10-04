--[[
	jecs 0.11.0-quenty.3: world:remove(e, pair(R, jecs.Wildcard)) doesn't remove the pair, still fires
	OnRemove hooks for it, and corrupts the entity's other data (has() says true, get() returns nil).
	JecsWorkarounds.removeAll removes the targets one at a time instead.

	lune run experiments/jecs-findings/wildcard_remove_corrupts_entity.luau
]]
local jecs = require("../../src/jecs/node_modules/@quentystudios/jecs/src/jecs")

local world = jecs.world()
local Name = world:component()
local hooks = 0
world:removed(jecs.ChildOf, function()
	hooks += 1
end)

local parent = world:entity()
local e = world:entity()
world:set(e, Name, "thing")
world:add(e, jecs.pair(jecs.ChildOf, parent))

world:remove(e, jecs.pair(jecs.ChildOf, jecs.Wildcard))

print("OnRemove hooks fired:", hooks)
print("pair still there:", world:has(e, jecs.pair(jecs.ChildOf, parent)), "<- expected false")
print("has Name:", world:has(e, Name), "get Name:", world:get(e, Name), "<- expected thing")
