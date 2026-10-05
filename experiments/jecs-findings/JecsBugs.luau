--!strict
--[[
	The six jecs 0.11.0-quenty.3 bugs, each as a minimal scenario that runs two ways: with plain jecs
	calls, which shows the bug, and through JecsWorkarounds, which avoids it. `run(bug, fixed)`
	returns what went wrong, or nil. JecsBugs.spec.luau runs every bug both ways, and check.luau
	prints how each one shows on the jecs installed now.
]]
local JecsWorkarounds = require("./JecsWorkarounds")
local jecs: any = require("../../src/jecs/node_modules/@quentystudios/jecs/src/jecs")

export type Bug = { name: string, scenario: (world: any, fixed: boolean) -> string? }

local function delete(world: any, entity: number, fixed: boolean)
	if fixed then
		JecsWorkarounds.delete(world, entity)
	else
		world:delete(entity)
	end
end

local function retarget(world: any, entity: number, relation: number, target: number, fixed: boolean)
	if fixed then
		JecsWorkarounds.setTarget(world, entity, relation, target)
	else
		world:add(entity, jecs.pair(relation, target))
	end
end

local function found(world: any, component: number, entity: number): boolean
	for e in world:query(component) do
		if e == entity then
			return true
		end
	end
	return false
end

local JecsBugs = {}

JecsBugs.bugs = {
	{
		-- No cascade is needed: it's enough that some entity once held a ChildOf pair and another
		-- pair to the deleted entity at the same time, as a weapon ChildOf and VisibleThrough its
		-- unit does. Which leaked pair jecs picks depends on hashing; this relation order shows it.
		name = "a delete corrupts an entity that survives it and pointed at the deleted one",
		scenario = function(world, fixed)
			local Data, Follows, Attached = world:component(), world:component(), world:component()
			local target, survivor, other = world:entity(), world:entity(), world:entity()
			world:set(survivor, Data, 42)
			world:add(survivor, jecs.pair(Follows, target))
			world:add(other, jecs.pair(jecs.ChildOf, target))
			world:add(other, jecs.pair(Attached, target))
			world:remove(other, jecs.pair(Attached, target))
			world:remove(other, jecs.pair(jecs.ChildOf, target))
			delete(world, target, fixed)
			if world:get(survivor, Data) ~= 42 then
				return `the survivor's data reads {world:get(survivor, Data)}, not 42`
			end
			return nil
		end,
	},
	{
		-- b points at its sibling a, and b's archetype is older than a's.
		name = "a cascade leaves alive a child that a sibling's deletion moved",
		scenario = function(world, fixed)
			local Follows, Marker = world:component(), world:component()
			local parent, a, b = world:entity(), world:entity(), world:entity()
			world:add(b, jecs.pair(Follows, a))
			world:add(b, jecs.pair(jecs.ChildOf, parent))
			world:set(a, Marker, true)
			world:add(a, jecs.pair(jecs.ChildOf, parent))
			delete(world, parent, fixed)
			return if world:contains(b) then "the child is still alive" else nil
		end,
	},
	{
		name = "a cascade crashes when two children point at a grandchild",
		scenario = function(world, fixed)
			local Follows = world:component()
			local root, childA, childB, grandchild = world:entity(), world:entity(), world:entity(), world:entity()
			world:add(childA, jecs.pair(jecs.ChildOf, root))
			world:add(childB, jecs.pair(jecs.ChildOf, root))
			world:add(grandchild, jecs.pair(jecs.ChildOf, childA))
			world:add(childB, jecs.pair(Follows, grandchild))
			world:add(childA, jecs.pair(Follows, grandchild))
			delete(world, root, fixed)
			return nil
		end,
	},
	{
		-- `moved` went through the root archetype (no components) and out again.
		name = "deleting an entity with no components corrupts another",
		scenario = function(world, fixed)
			local Data, Tag = world:component(), world:component()
			local moved = world:entity()
			world:add(moved, Tag)
			world:remove(moved, Tag)
			world:set(moved, Data, 42)
			delete(world, world:entity(), fixed)
			if world:get(moved, Data) ~= 42 then
				return `the other entity's data reads {world:get(moved, Data)}, not 42`
			end
			return nil
		end,
	},
	{
		-- ChildOf is exclusive, so reparenting is a retarget too.
		name = "retargeting an exclusive relation can drop an entity from every query",
		scenario = function(world, fixed)
			local Data = world:component()
			local x, y, first, second = world:entity(), world:entity(), world:entity(), world:entity()
			world:set(first, Data, 1)
			world:add(first, jecs.pair(jecs.ChildOf, x))
			retarget(world, first, jecs.ChildOf, y, fixed)
			delete(world, y, fixed)
			local reused = world:entity() -- jecs reuses y's id
			world:set(second, Data, 2)
			world:add(second, jecs.pair(jecs.ChildOf, x))
			retarget(world, second, jecs.ChildOf, reused, fixed)
			return if found(world, Data, second) then nil else "the retargeted entity is missing from query(Data)"
		end,
	},
	{
		name = "removing pair(R, Wildcard) leaves the pair and corrupts the entity",
		scenario = function(world, fixed)
			local Name = world:component()
			local parent, e = world:entity(), world:entity()
			world:set(e, Name, "thing")
			world:add(e, jecs.pair(jecs.ChildOf, parent))
			if fixed then
				JecsWorkarounds.removeAll(world, e, jecs.ChildOf)
			else
				world:remove(e, jecs.pair(jecs.ChildOf, jecs.Wildcard))
			end
			if world:get(e, Name) ~= "thing" then
				return `the entity's data reads {world:get(e, Name)}`
			elseif world:has(e, jecs.pair(jecs.ChildOf, parent)) then
				return "the pair is still there"
			end
			return nil
		end,
	},
} :: { Bug }

-- Runs a bug's scenario in a new world, plainly or through the workarounds. Returns what went
-- wrong (an error, a wrong result, or damage to jecs's bookkeeping), or nil.
function JecsBugs.run(bug: Bug, fixed: boolean): string?
	local world = jecs.world()
	local ok, problem = pcall(bug.scenario, world, fixed)
	if not ok then
		return `error: {problem}`
	end
	return problem or JecsWorkarounds.checkIntegrity(world)
end

return JecsBugs
