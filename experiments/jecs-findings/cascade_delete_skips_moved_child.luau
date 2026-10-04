--[[
	jecs 0.11.0-quenty.3: deleting a parent can leave one of its ChildOf children alive.

	The child survives when, during the cascade, deleting a sibling moves it to another archetype
	(here: it held an ordinary relation pair to that sibling, which jecs removes), and its old
	archetype is older than the sibling's. The survivor keeps a dangling (ChildOf, parent) pair, and
	once jecs recycles the parent's id, world:target(child, ChildOf) returns the new, unrelated entity.

	lune run experiments/jecs-findings/cascade_delete_skips_moved_child.luau
]]
local jecs = require("../../src/jecs/node_modules/@quentystudios/jecs/src/jecs")

local world = jecs.world()
local Follows = world:component() -- an ordinary relation: deleting the target removes the pair
local Marker = world:component()

local parent = world:entity()
local a = world:entity()
local b = world:entity()
-- b's archetype is created first, so it's older than a's.
world:add(b, jecs.pair(Follows, a))
world:add(b, jecs.pair(jecs.ChildOf, parent))
world:set(a, Marker, true)
world:add(a, jecs.pair(jecs.ChildOf, parent))

world:delete(parent)

print("a (child) alive:", world:contains(a))
print("b (child) alive:", world:contains(b), "<- expected false")
local recycled = world:entity()
print(
	"after recycling the parent's id, b's ChildOf target:",
	world:contains(b) and world:target(b, jecs.ChildOf, 0),
	"new entity:",
	recycled
)
