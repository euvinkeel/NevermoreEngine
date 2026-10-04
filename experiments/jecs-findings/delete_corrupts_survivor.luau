--[[
	jecs 0.11.0-quenty.3: deleting an entity can corrupt another entity that survives the delete.

	The survivor holds an ordinary relation pair to the deleted entity. Afterwards it still has the
	pair to the dead entity, and its other data is gone: world:has returns true, world:get returns
	nil, and no OnRemove hook fired for it. No cascade is needed. It's enough that some entity
	once held a ChildOf pair and another relation pair to the deleted entity at the same time (its
	archetype stays registered after the entity moves on).

	Cause: world_delete's loop over archetypes that hold pairs to the deleted entity collects the
	pairs to remove in `to_remove`. When an archetype also has a ChildOf (delete-policy) pair, the
	loop deletes its entities and `continue`s past `table.clear(to_remove)`, so that archetype's
	pairs leak into the next one. With one real pair plus a leaked one, `next(to_remove)` can pick
	the leaked pair, which the next archetype doesn't have, so removing it resolves to the same
	archetype: each entity is appended to its own archetype again and loses its row's data (the
	same thing wildcard_remove_corrupts_entity.luau shows). Clearing `to_remove` before that
	`continue` fixes this script and the Statuh fuzz seed that found it. Which pair `next` picks
	depends on hashing, so the script declares the relations in the order that shows it.
	JecsWorkarounds.delete avoids it.

	lune run experiments/jecs-findings/delete_corrupts_survivor.luau
]]
local jecs = require("../../src/jecs/node_modules/@quentystudios/jecs/src/jecs")

local world = jecs.world()
local Data = world:component()
local Follows = world:component() -- ordinary relations: deleting the target removes the pair
local Attached = world:component()

local target = world:entity()
local survivor = world:entity()
world:set(survivor, Data, 42)
world:add(survivor, jecs.pair(Follows, target))

-- Another entity was once ChildOf the target while attached to it. It's gone from the target now.
local other = world:entity()
world:add(other, jecs.pair(jecs.ChildOf, target))
world:add(other, jecs.pair(Attached, target))
world:remove(other, jecs.pair(Attached, target))
world:remove(other, jecs.pair(jecs.ChildOf, target))

world:delete(target)

print("survivor alive:", world:contains(survivor))
print("has Data:", world:has(survivor, Data), "get Data:", world:get(survivor, Data), "<- expected 42")
print("still has the pair to the deleted entity:", world:has(survivor, jecs.pair(Follows, target)), "<- expected false")
