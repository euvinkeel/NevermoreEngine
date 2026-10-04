--[[
	jecs 0.11.0-quenty.3: retargeting an exclusive relation can make an entity vanish from every
	query.

	Adding a second target to an exclusive relation (reparenting with ChildOf, which is exclusive,
	or retargeting any relation with jecs.Exclusive) replaces the old pair in place. jecs caches
	that move as a one-way link between the two archetypes. When the new target is deleted, the
	archetype holding pairs to it is destroyed, but the link to it stays. Pairs don't carry
	generations, so once the target's id is reused, retargeting another entity from the same
	archetype to the new entity follows the stale link into the destroyed archetype. That entity
	is then missing from every query, even one for a plain component, while `has` still says it
	has the pair and `target` returns nil.

	Removing the old pair before adding the new one avoids it (JecsWorkarounds.setTarget).

	lune run experiments/jecs-findings/exclusive_retarget_loses_entity.luau
]]
local jecs = require("../../src/jecs/node_modules/@quentystudios/jecs/src/jecs")

for _, label in { "a relation with jecs.Exclusive", "jecs.ChildOf" } do
	local world = jecs.world()
	local Data = world:component()
	local R = jecs.ChildOf
	if label ~= "jecs.ChildOf" then
		R = world:component()
		world:add(R, jecs.Exclusive)
	end

	local x = world:entity()
	local y = world:entity()
	local first = world:entity()
	world:set(first, Data, 1)
	world:add(first, jecs.pair(R, x))
	world:add(first, jecs.pair(R, y)) -- replaces (R, x) in place

	world:delete(y)
	local reused = world:entity() -- jecs reuses y's id

	local second = world:entity()
	world:set(second, Data, 2)
	world:add(second, jecs.pair(R, x))
	world:add(second, jecs.pair(R, reused)) -- follows the stale link

	local found = false
	for e in world:query(Data) do
		if e == second then
			found = true
		end
	end
	print(`{label}: query(Data) finds the entity: {found} <- expected true`)
	print(
		`  has the pair: {world:has(second, jecs.pair(R, reused))}, target: {world:target(second, R, 0)} <- expected {reused}`
	)
end
