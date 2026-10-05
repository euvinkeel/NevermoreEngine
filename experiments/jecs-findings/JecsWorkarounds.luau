--!strict
--[[
	Workarounds for the jecs 0.11.0-quenty.3 bugs listed in JecsBugs, for code that has to live with
	that version. Each keeps jecs off a broken code path:

	- `delete` removes every ordinary pair pointing into what a delete takes with it, then deletes,
	  so jecs's own cleanup never has to move an entity (the first three bugs). An entity with no
	  components gets a tag first, so it isn't deleted through the root archetype (the fourth).
	- `setTarget` retargets an exclusive relation (ChildOf, or any with jecs.Exclusive) by removing
	  the old pair before adding the new one, so jecs never replaces a target in place (the fifth).
	- `removeAll` removes a relation's pairs one target at a time, never with jecs.Wildcard (the
	  sixth).
	- `checkIntegrity` reports the damage these bugs leave in jecs's bookkeeping, so tests can catch
	  what the workarounds miss. Comparing two readers of the same world can't: both read the damage.

	Limits: `delete` handles pairs. It doesn't handle an entity that's used as a component or as a
	relation, and it treats a relation as cascading when it has pair(OnDeleteTarget, Delete), like
	ChildOf.
]]

-- Untyped, like the Statuh core: jecs's phantom entity types would make every id a cast here.
local jecs: any = require("../../src/jecs/node_modules/@quentystudios/jecs/src/jecs")

local JecsWorkarounds = {}

type World = any

local ENTITY_MASK = 2 ^ 24 -- jecs's ECS_ENTITY_MASK: an id's low 24 bits, without the generation

local CASCADE = jecs.pair(jecs.OnDeleteTarget, jecs.Delete)

-- A tag per world, for moving an entity out of the root archetype before it's deleted.
local markers: { [World]: number } = setmetatable({}, { __mode = "k" }) :: any

local function marker(world: World): number
	local tag = markers[world]
	if tag == nil then
		tag = world:entity()
		markers[world] = tag
	end
	return tag
end

-- Every (holder, relation) with a pair(relation, target).
local function pairsTo(world: World, target: number): { { holder: number, relation: number } }
	local found = {}
	for holder in world:query(jecs.pair(jecs.Wildcard, target)) do
		for _, id in jecs.record(world, holder).archetype.types do
			if jecs.IS_PAIR(id) and jecs.pair_second(world, id) == target then
				table.insert(found, { holder = holder, relation = jecs.pair_first(world, id) })
			end
		end
	end
	return found
end

--[=[
	`entity` and everything deleting it deletes too: every holder of a cascading pair (ChildOf, or
	any relation with pair(jecs.OnDeleteTarget, jecs.Delete)) to an entity in the set.
]=]
function JecsWorkarounds.doomedBy(world: World, entity: number): { number }
	local doomed = { entity }
	local seen = { [entity] = true }
	local i = 1
	while i <= #doomed do
		for _, found in pairsTo(world, doomed[i]) do
			if not seen[found.holder] and world:has(found.relation, CASCADE) then
				seen[found.holder] = true
				table.insert(doomed, found.holder)
			end
		end
		i += 1
	end
	return doomed
end

--[=[
	world:delete(entity), with every other pair pointing into the deleted set removed first, from
	survivors and doomed entities alike. jecs would remove those pairs anyway; removing them first
	fires the same OnRemove hooks, just before the delete instead of during it.
]=]
function JecsWorkarounds.delete(world: World, entity: number)
	if not world:contains(entity) then
		return
	end
	for _, target in JecsWorkarounds.doomedBy(world, entity) do
		for _, found in pairsTo(world, target) do
			if not world:has(found.relation, CASCADE) then
				world:remove(found.holder, jecs.pair(found.relation, target))
			end
		end
	end
	if jecs.record(world, entity).archetype == world.ROOT_ARCHETYPE then
		world:add(entity, marker(world))
	end
	world:delete(entity)
end

--[=[
	Points `entity`'s exclusive `relation` at `target`, or removes it when `target` is nil. The
	old pair is removed before the new one is added. Use it instead of adding a second target to
	an exclusive relation (reparenting with ChildOf, retargeting VisibleThrough).
]=]
function JecsWorkarounds.setTarget(world: World, entity: number, relation: number, target: number?)
	assert(world:has(relation, jecs.Exclusive), "setTarget is for exclusive relations")
	local current = world:target(entity, relation, 0)
	if current == target then
		return
	end
	if current ~= nil then
		world:remove(entity, jecs.pair(relation, current))
	end
	if target ~= nil then
		world:add(entity, jecs.pair(relation, target))
	end
end

--[=[
	Removes every pair(relation, *) from `entity`, one target at a time.
]=]
function JecsWorkarounds.removeAll(world: World, entity: number, relation: number)
	local targets = {}
	local i = 0
	while true do
		local target = world:target(entity, relation, i)
		if target == nil then
			break
		end
		table.insert(targets, target)
		i += 1
	end
	for _, target in targets do
		world:remove(entity, jecs.pair(relation, target))
	end
end

--[=[
	Checks jecs's bookkeeping. Returns nil when it's consistent, or a description of the first
	problem:
	- an alive entity whose archetype isn't registered (it's gone from every query);
	- an entity listed twice in an archetype, or at a row its record doesn't point to (its data is
	  lost: `has` is true and `get` returns nil);
	- a pair to an entity that isn't alive. Once jecs reuses that entity's id the pair points at
	  the new entity, so this is only caught before the id is reused.
]=]
function JecsWorkarounds.checkIntegrity(world: World): string?
	local index = world.entity_index
	local root = world.ROOT_ARCHETYPE
	for dense = 1, index.alive_count do
		local entity = index.dense_array[dense]
		local record = index.sparse_array[entity % ENTITY_MASK]
		if record == nil or record.dense ~= dense then
			return `entity {entity}: its record doesn't point back at it`
		end
		local archetype = record.archetype
		if archetype ~= nil and archetype ~= root then
			if world.archetypes[archetype.id] ~= archetype then
				return `entity {entity}: archetype {archetype.id} isn't registered, so no query finds it`
			end
			if archetype.entities[record.row] ~= entity then
				return `entity {entity}: row {record.row} of archetype {archetype.id} holds {tostring(
					archetype.entities[record.row]
				)}`
			end
		end
	end
	for archetypeId, archetype in world.archetypes do
		-- jecs doesn't keep the root (empty) archetype's entity list current, so it can't be checked.
		if archetype == root then
			continue
		end
		for row, entity in archetype.entities do
			local record = jecs.record(world, entity)
			if record == nil then
				return `archetype {archetypeId} row {row}: entity {entity} isn't alive`
			end
			if record.archetype ~= archetype or record.row ~= row then
				return `archetype {archetypeId} row {row}: entity {entity} is listed here, but its record says archetype {record.archetype.id} row {record.row}`
			end
		end
		if #archetype.entities > 0 then
			for _, id in archetype.types do
				-- pair_second resolves the target's current generation, or 0 when it isn't alive.
				if jecs.IS_PAIR(id) and jecs.pair_second(world, id) == 0 then
					return `archetype {archetypeId}: entity {archetype.entities[1]} has a pair to dead entity {jecs.ECS_PAIR_SECOND(
						id
					)}`
				end
			end
		end
	end
	return nil
end

return JecsWorkarounds
