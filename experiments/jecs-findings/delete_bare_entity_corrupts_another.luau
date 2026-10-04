--[[
	jecs 0.11.0-quenty.3: deleting an entity with no components can corrupt another entity.

	An entity that loses its last component moves into the root (empty) archetype and is listed
	there. When it gains a component again it moves out, but stays listed. Deleting an entity that
	is in the root archetype removes it from that list by moving the list's last entry into its
	row, and rewrites that entry's record. If the last entry is an entity that has since moved on,
	its record now points at the wrong row of its real archetype, so its data reads nil. A fresh
	entity that never had a component is in the root archetype at row 0, so deleting it writes
	row 0.

	Giving the entity a component before deleting it avoids the root archetype's list
	(JecsWorkarounds.delete does this).

	lune run experiments/jecs-findings/delete_bare_entity_corrupts_another.luau
]]
local jecs = require("../../src/jecs/node_modules/@quentystudios/jecs/src/jecs")

local world = jecs.world()
local Data = world:component()
local Tag = world:component()

local moved = world:entity()
world:add(moved, Tag)
world:remove(moved, Tag) -- into the root archetype, and listed there
world:set(moved, Data, 42) -- out again, but still listed

local bare = world:entity() -- in the root archetype, never listed
world:delete(bare)

print("has Data:", world:has(moved, Data), "get Data:", world:get(moved, Data), "<- expected 42")
