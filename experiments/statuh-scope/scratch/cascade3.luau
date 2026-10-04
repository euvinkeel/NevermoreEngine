local jecs = require("../src/Jecs")
for _, order in { "b archetype older", "a archetype older" } do
	local world = jecs.world()
	local Follows = world:component()
	local X = world:component()
	local parent = world:entity()
	local a = world:entity()
	local b = world:entity()
	if order == "b archetype older" then
		world:add(b, jecs.pair(Follows, a))
		world:add(b, jecs.pair(jecs.ChildOf, parent))
		world:set(a, X, 1)
		world:add(a, jecs.pair(jecs.ChildOf, parent))
	else
		world:set(a, X, 1)
		world:add(a, jecs.pair(jecs.ChildOf, parent))
		world:add(b, jecs.pair(Follows, a))
		world:add(b, jecs.pair(jecs.ChildOf, parent))
	end
	world:delete(parent)
	print(order, "| a alive:", world:contains(a), "| b alive:", world:contains(b), "| b ChildOf ->", world:contains(b) and world:target(b, jecs.ChildOf, 0))
end
