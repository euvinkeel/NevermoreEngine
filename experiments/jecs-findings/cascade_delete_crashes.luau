--[[
	jecs 0.11.0-quenty.3: deleting a parent can crash when its ChildOf descendants hold relation
	pairs to each other.

	Here two children of `root` both point an ordinary relation at a grandchild. Deleting `root`
	cascades through the children, removes the pairs to the grandchild while the cascade is
	moving entities between archetypes, and errors inside jecs ("attempt to perform arithmetic
	(mod) on nil and number"). Same family as cascade_delete_skips_moved_child.luau: an entity
	is moved mid-cascade. Found by a jecs-only random search
	(experiments/statuh-scope/tools/jecs_delete_search.luau) and shrunk to these five operations.

	lune run experiments/jecs-findings/cascade_delete_crashes.luau
]]
local jecs = require("../../src/jecs/node_modules/@quentystudios/jecs/src/jecs")

for _, exclusive in { false, true } do
	local world = jecs.world()
	local Follows = world:component() -- an ordinary relation
	if exclusive then
		world:add(Follows, jecs.Exclusive)
	end

	local root = world:entity()
	local childA = world:entity()
	local childB = world:entity()
	local grandchild = world:entity()
	world:add(childA, jecs.pair(jecs.ChildOf, root))
	world:add(childB, jecs.pair(jecs.ChildOf, root))
	world:add(grandchild, jecs.pair(jecs.ChildOf, childA))
	world:add(childB, jecs.pair(Follows, grandchild))
	world:add(childA, jecs.pair(Follows, grandchild))

	local ok, err = pcall(function()
		world:delete(root)
	end)
	print(`Follows exclusive={exclusive}: delete(root) {if ok then "ok" else "errors: " .. tostring(err)}`)
end
