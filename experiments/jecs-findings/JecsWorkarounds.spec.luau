--[[
	JecsWorkarounds against each jecs 0.11.0-quenty.3 bug in this folder: the workaround keeps the
	world consistent, and checkIntegrity reports the damage the plain jecs call leaves.

	The second block describes jecs as it is. When a jecs upgrade fixes a bug, its test there
	fails; that's the sign the matching workaround can go.
]]
local JecsWorkarounds = require("./JecsWorkarounds")
local Jest = require("Jest")
local RandomWorld = require("./RandomWorld")
local jecs: any = require("../../src/jecs/node_modules/@quentystudios/jecs/src/jecs")

local describe = Jest.Globals.describe
local expect = Jest.Globals.expect
local it = Jest.Globals.it

-- delete_corrupts_survivor: the survivor follows the target, and another entity once held a
-- ChildOf pair and another pair to the target at the same time.
local function survivorWorld()
	local world = jecs.world()
	local Data = world:component()
	local Follows = world:component()
	local Attached = world:component()
	local target = world:entity()
	local survivor = world:entity()
	world:set(survivor, Data, 42)
	world:add(survivor, jecs.pair(Follows, target))
	local other = world:entity()
	world:add(other, jecs.pair(jecs.ChildOf, target))
	world:add(other, jecs.pair(Attached, target))
	world:remove(other, jecs.pair(Attached, target))
	world:remove(other, jecs.pair(jecs.ChildOf, target))
	return world, { Data = Data, Follows = Follows, target = target, survivor = survivor }
end

-- cascade_delete_skips_moved_child: b points at its sibling a, and b's archetype is older.
local function siblingsWorld()
	local world = jecs.world()
	local Follows = world:component()
	local Marker = world:component()
	local parent = world:entity()
	local a = world:entity()
	local b = world:entity()
	world:add(b, jecs.pair(Follows, a))
	world:add(b, jecs.pair(jecs.ChildOf, parent))
	world:set(a, Marker, true)
	world:add(a, jecs.pair(jecs.ChildOf, parent))
	return world, { parent = parent, a = a, b = b }
end

-- cascade_delete_crashes: two children point at a grandchild.
local function grandchildWorld()
	local world = jecs.world()
	local Follows = world:component()
	local root = world:entity()
	local childA = world:entity()
	local childB = world:entity()
	local grandchild = world:entity()
	world:add(childA, jecs.pair(jecs.ChildOf, root))
	world:add(childB, jecs.pair(jecs.ChildOf, root))
	world:add(grandchild, jecs.pair(jecs.ChildOf, childA))
	world:add(childB, jecs.pair(Follows, grandchild))
	world:add(childA, jecs.pair(Follows, grandchild))
	return world, { root = root, childA = childA, childB = childB, grandchild = grandchild }
end

-- delete_bare_entity_corrupts_another: `moved` went through the root archetype and out again.
local function bareWorld()
	local world = jecs.world()
	local Data = world:component()
	local Tag = world:component()
	local moved = world:entity()
	world:add(moved, Tag)
	world:remove(moved, Tag)
	world:set(moved, Data, 42)
	local bare = world:entity()
	return world, { Data = Data, moved = moved, bare = bare }
end

-- wildcard_remove_corrupts_entity
local function attachedWorld()
	local world = jecs.world()
	local Name = world:component()
	local parent = world:entity()
	local e = world:entity()
	world:set(e, Name, "thing")
	world:add(e, jecs.pair(jecs.ChildOf, parent))
	return world, { Name = Name, parent = parent, e = e }
end

-- exclusive_retarget_loses_entity: `first` was retargeted to y, y was deleted and its id reused.
local function retargetWorld(useChildOf: boolean)
	local world = jecs.world()
	local Data = world:component()
	local R = jecs.ChildOf
	if not useChildOf then
		R = world:component()
		world:add(R, jecs.Exclusive)
	end
	local x = world:entity()
	local y = world:entity()
	local first = world:entity()
	world:set(first, Data, 1)
	world:add(first, jecs.pair(R, x))
	return world, { Data = Data, R = R, x = x, y = y, first = first }
end

local function finishRetarget(world: any, e: any, setTarget: (any, number, number, number) -> ())
	setTarget(world, e.first, e.R, e.y)
	world:delete(e.y)
	local reused = world:entity()
	local second = world:entity()
	world:set(second, e.Data, 2)
	world:add(second, jecs.pair(e.R, e.x))
	setTarget(world, second, e.R, reused)
	local found = false
	for entity in world:query(e.Data) do
		if entity == second then
			found = true
		end
	end
	return second, reused, found
end

local function plainSetTarget(world: any, entity: number, relation: number, target: number)
	world:add(entity, jecs.pair(relation, target))
end

describe("JecsWorkarounds with jecs 0.11.0-quenty.3", function()
	it("deletes without corrupting a survivor that pointed at the deleted entity", function()
		local world, e = survivorWorld()
		JecsWorkarounds.delete(world, e.target)
		expect(world:get(e.survivor, e.Data)).toBe(42)
		expect(world:has(e.survivor, jecs.pair(e.Follows, e.target))).toBe(false)
		expect(JecsWorkarounds.checkIntegrity(world)).toBeNil()
	end)

	it("deletes a whole ChildOf tree, even when a child points at a sibling", function()
		local world, e = siblingsWorld()
		JecsWorkarounds.delete(world, e.parent)
		expect(world:contains(e.a)).toBe(false)
		expect(world:contains(e.b)).toBe(false)
		expect(JecsWorkarounds.checkIntegrity(world)).toBeNil()
	end)

	it("deletes a tree whose children point at a grandchild", function()
		local world, e = grandchildWorld()
		JecsWorkarounds.delete(world, e.root)
		for _, entity in { e.root, e.childA, e.childB, e.grandchild } do
			expect(world:contains(entity)).toBe(false)
		end
		expect(JecsWorkarounds.checkIntegrity(world)).toBeNil()
	end)

	it("deletes an entity with no components without touching another entity", function()
		local world, e = bareWorld()
		JecsWorkarounds.delete(world, e.bare)
		expect(world:contains(e.bare)).toBe(false)
		expect(world:get(e.moved, e.Data)).toBe(42)
		expect(JecsWorkarounds.checkIntegrity(world)).toBeNil()
	end)

	it("removes every target of a relation and keeps the entity's data", function()
		local world, e = attachedWorld()
		JecsWorkarounds.removeAll(world, e.e, jecs.ChildOf)
		expect(world:has(e.e, jecs.pair(jecs.ChildOf, e.parent))).toBe(false)
		expect(world:get(e.e, e.Name)).toBe("thing")
		expect(JecsWorkarounds.checkIntegrity(world)).toBeNil()
	end)

	it("retargets an exclusive relation without losing the entity from queries", function()
		for _, useChildOf in { false, true } do
			local world, e = retargetWorld(useChildOf)
			local second, reused, found = finishRetarget(world, e, JecsWorkarounds.setTarget)
			expect(found).toBe(true)
			expect(world:target(second, e.R, 0)).toBe(reused)
			expect(JecsWorkarounds.checkIntegrity(world)).toBeNil()
		end
	end)

	it("lists what a delete takes with it: ChildOf descendants, not ordinary followers", function()
		local world, e = siblingsWorld()
		local follower = world:entity()
		world:add(follower, jecs.pair(world:component(), e.parent))
		local doomed = JecsWorkarounds.doomedBy(world, e.parent)
		table.sort(doomed)
		local expected = { e.parent, e.a, e.b }
		table.sort(expected)
		expect(doomed).toEqual(expected)
	end)

	it("keeps random worlds equal to a plain model: 1,000 seeds x 60 operations", function()
		for seed = 1, 1000 do
			local problem = RandomWorld.run(seed, 60, true)
			if problem then
				error(`seed {seed}: {problem}`, 0)
			end
		end
		expect(true).toBe(true)
	end, 60)
end)

describe("jecs 0.11.0-quenty.3 bugs, still present (a failure means jecs fixed one)", function()
	it("delete corrupts a survivor", function()
		local world, e = survivorWorld()
		world:delete(e.target)
		expect(world:get(e.survivor, e.Data)).toBeNil()
		expect(JecsWorkarounds.checkIntegrity(world)).never.toBeNil()
	end)

	it("a cascade skips a child that a sibling's deletion moved", function()
		local world, e = siblingsWorld()
		world:delete(e.parent)
		expect(world:contains(e.b)).toBe(true)
		expect(JecsWorkarounds.checkIntegrity(world)).never.toBeNil()
	end)

	it("a cascade crashes when children point at a grandchild", function()
		local world, e = grandchildWorld()
		local ok = pcall(function()
			world:delete(e.root)
		end)
		expect(ok).toBe(false)
	end)

	it("deleting an entity with no components corrupts another", function()
		local world, e = bareWorld()
		world:delete(e.bare)
		expect(world:get(e.moved, e.Data)).toBeNil()
		expect(JecsWorkarounds.checkIntegrity(world)).never.toBeNil()
	end)

	it("removing pair(R, Wildcard) corrupts the entity", function()
		local world, e = attachedWorld()
		world:remove(e.e, jecs.pair(jecs.ChildOf, jecs.Wildcard))
		expect(world:get(e.e, e.Name)).toBeNil()
		expect(JecsWorkarounds.checkIntegrity(world)).never.toBeNil()
	end)

	it("retargeting an exclusive relation can lose the entity from every query", function()
		for _, useChildOf in { false, true } do
			local world, e = retargetWorld(useChildOf)
			local _second, _reused, found = finishRetarget(world, e, plainSetTarget)
			expect(found).toBe(false)
			expect(JecsWorkarounds.checkIntegrity(world)).never.toBeNil()
		end
	end)
end)
