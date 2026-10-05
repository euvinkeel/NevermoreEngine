--!strict
--[[
	Random operation sequences on a small jecs world, checked after every operation against a
	plain model of what the world should hold, and against JecsWorkarounds.checkIntegrity. The
	operations are the ones the bugs in this folder need: deletes that cascade along ChildOf,
	ordinary relations pointing anywhere (Follows is exclusive, Attached isn't), reparenting and
	retargeting, removing every target of a relation, and jecs reusing ids.

	`run(seed, steps, useWorkarounds)` returns nil, or the first problem followed by the
	operations that led to it. With `useWorkarounds`, deletes, retargets and remove-alls go
	through JecsWorkarounds; without, through plain jecs calls. check.luau runs both.
]]
local JecsWorkarounds = require("./JecsWorkarounds")
local Rng = require("../statuh-scope/src/Rng")
-- Untyped, like the Statuh core: jecs's phantom entity types would make every id a cast here.
local jecs: any = require("../../src/jecs/node_modules/@quentystudios/jecs/src/jecs")

local RandomWorld = {}

function RandomWorld.run(seed: number, steps: number, useWorkarounds: boolean): string?
	local rng = Rng.new(seed)
	local world = jecs.world()
	local Data = world:component()
	local Follows = world:component()
	world:add(Follows, jecs.Exclusive)
	local Attached = world:component()

	-- The model. `alive` is in creation order, and a parent is always older than its child, so
	-- ChildOf never forms a cycle.
	local alive: { number } = {}
	local dead: { number } = {}
	local data: { [number]: number } = {}
	local parent: { [number]: number } = {}
	local follows: { [number]: number } = {}
	local attached: { [number]: { [number]: boolean } } = {}

	local log: { string } = {}
	local names: { [number]: string } = {}
	local created = 0
	local function name(e: number?): string
		if e == nil then
			return "nil"
		end
		return names[e] or tostring(e)
	end
	local function pick(): number?
		return if #alive > 0 then alive[rng:int(1, #alive)] else nil
	end

	local function retarget(e: number, relation: number, target: number, label: string)
		if useWorkarounds then
			JecsWorkarounds.setTarget(world, e, relation, target)
			table.insert(log, `JecsWorkarounds.setTarget(world, {name(e)}, {label}, {name(target)})`)
		else
			world:add(e, jecs.pair(relation, target))
			table.insert(log, `world:add({name(e)}, pair({label}, {name(target)}))`)
		end
	end

	local ops: { () -> () } = {
		function() -- spawn; jecs reuses the ids of deleted entities
			created += 1
			local e = world:entity()
			names[e] = "e" .. created
			table.insert(log, `{name(e)} = world:entity()`)
			table.insert(alive, e)
			attached[e] = {}
			if rng:chance(0.7) then
				world:set(e, Data, created)
				data[e] = created
				table.insert(log, `world:set({name(e)}, Data, {created})`)
			end
		end,
		function() -- parent to an older entity, which reparents when it has one
			local e = pick()
			local at = e and table.find(alive, e)
			if e and at and at > 1 then
				local p = alive[rng:int(1, at - 1)]
				retarget(e, jecs.ChildOf, p, "ChildOf")
				parent[e] = p
			end
		end,
		function() -- unparent
			local e = pick()
			if e and parent[e] then
				world:remove(e, jecs.pair(jecs.ChildOf, parent[e]))
				table.insert(log, `world:remove({name(e)}, pair(ChildOf, {name(parent[e])}))`)
				parent[e] = nil
			end
		end,
		function() -- follow anything else
			local e, t = pick(), pick()
			if e and t and e ~= t then
				retarget(e, Follows, t, "Follows")
				follows[e] = t
			end
		end,
		function() -- attach to anything else
			local e, t = pick(), pick()
			if e and t and e ~= t then
				world:add(e, jecs.pair(Attached, t))
				table.insert(log, `world:add({name(e)}, pair(Attached, {name(t)}))`)
				attached[e][t] = true
			end
		end,
		function() -- detach from everything
			local e = pick()
			if e and next(attached[e]) then
				if useWorkarounds then
					JecsWorkarounds.removeAll(world, e, Attached)
					table.insert(log, `JecsWorkarounds.removeAll(world, {name(e)}, Attached)`)
				else
					world:remove(e, jecs.pair(Attached, jecs.Wildcard))
					table.insert(log, `world:remove({name(e)}, pair(Attached, Wildcard))`)
				end
				attached[e] = {}
			end
		end,
		function() -- change data
			local e = pick()
			if e then
				local value = rng:int(1000, 9999)
				world:set(e, Data, value)
				data[e] = value
				table.insert(log, `world:set({name(e)}, Data, {value})`)
			end
		end,
		function() -- delete, cascading to ChildOf descendants
			local victim = pick()
			if victim == nil then
				return
			end
			if useWorkarounds then
				JecsWorkarounds.delete(world, victim)
				table.insert(log, `JecsWorkarounds.delete(world, {name(victim)})`)
			else
				world:delete(victim)
				table.insert(log, `world:delete({name(victim)})`)
			end
			local doomed = { [victim] = true }
			for _, e in alive do -- older first, so a parent is decided before its children
				if parent[e] and doomed[parent[e]] then
					doomed[e] = true
				end
			end
			local survivors = {}
			for _, e in alive do
				if doomed[e] then
					table.insert(dead, e)
					data[e], parent[e], follows[e], attached[e] = nil, nil, nil, nil
				else
					table.insert(survivors, e)
				end
			end
			alive = survivors
			for _, e in alive do
				if follows[e] and doomed[follows[e]] then
					follows[e] = nil
				end
				for t in attached[e] do
					if doomed[t] then
						attached[e][t] = nil
					end
				end
			end
		end,
	}

	local function check(): string?
		local problem = JecsWorkarounds.checkIntegrity(world)
		if problem then
			return problem
		end
		local inQuery: { [number]: boolean } = {}
		for e in world:query(Data) do
			inQuery[e] = true
		end
		for _, e in alive do
			if not world:contains(e) then
				return `{name(e)} was deleted, but nothing should have deleted it`
			end
			if data[e] ~= nil then
				local value = world:get(e, Data)
				if value ~= data[e] then
					return `{name(e)}: Data is {tostring(value)}, expected {data[e]} (has = {world:has(e, Data)})`
				end
				if not inQuery[e] then
					return `{name(e)} is missing from query(Data)`
				end
			end
			if world:target(e, jecs.ChildOf, 0) ~= parent[e] then
				return `{name(e)}: parent is {name(world:target(e, jecs.ChildOf, 0))}, expected {name(parent[e])}`
			end
			if world:target(e, Follows, 0) ~= follows[e] then
				return `{name(e)}: follows {name(world:target(e, Follows, 0))}, expected {name(follows[e])}`
			end
			local seen: { [number]: boolean } = {}
			local i = 0
			while true do
				local t = world:target(e, Attached, i)
				if t == nil then
					break
				end
				if not attached[e][t] then
					return `{name(e)} is attached to {name(t)}, which it shouldn't be`
				end
				seen[t] = true
				i += 1
			end
			for t in attached[e] do
				if not seen[t] then
					return `{name(e)} lost its Attached pair to {name(t)}`
				end
			end
		end
		for _, e in dead do
			if world:contains(e) then
				return `{name(e)} should have been deleted`
			end
		end
		return nil
	end

	for _ = 1, steps do
		local op = ops[rng:int(1, #ops)]
		local ok, err = pcall(function()
			op()
		end)
		local problem = if ok then check() else `error: {err}`
		if problem then
			return problem .. "\n  " .. table.concat(log, "\n  ")
		end
	end
	return nil
end

return RandomWorld
