--!nonstrict
--[[
	A random world for the invariant tests: rooms, players, grants, needs, VisibleThrough chains and
	loops, grant and restrict rules, references, owner-only data, and a component visible only
	through a rule ("near"), with random edits every frame. ScopeHarness checks its invariants after
	each frame; `runSeed` also checks that narrowing edits never widen visibility. ChildOf and
	Follows are game relations, replicated as data; only VisibleThrough affects visibility.

	Every failure message starts with the seed and frame, so `runSeed(seed, frames)` replays it.
]]
local JecsWorkarounds = require("../../jecs-findings/JecsWorkarounds")
local Rng = require("./Rng")
local ScopeHarness = require("./ScopeHarness")
local ScopeOracle = require("./ScopeOracle")

local FuzzWorld = {}

local CELLS = 12

function FuzzWorld.runSeed(
	seed: number,
	frameCount: number,
	options: {
		enterBudget: number?,
		onFrame: ((any, number) -> ())?,
		-- false: plain jecs calls instead of JecsWorkarounds. ScopeHarness's jecs integrity check
		-- then shows which jecs bugs the fuzz runs into.
		jecsWorkarounds: boolean?,
	}?
)
	local rng = Rng.new(seed)
	local h = ScopeHarness.new({ enterBudget = options and options.enterBudget })
	local world, Net, jecs, scope = h.world, h.Net, h.jecs, h.scope
	local useWorkarounds = not (options and options.jecsWorkarounds == false)

	local C = {}
	for _, name in { "Name", "Hp", "Secret", "Target", "Holder", "Cell", "Pos", "Focus", "Vision" } do
		C[name] = world:component()
	end
	-- Rule tags, spawn-time only (the core latches rules).
	local Spatial, Fogged, Zoned = world:component(), world:component(), world:component()
	local Follows = world:component() -- a game relation, replicated as data
	world:add(Follows, jecs.Exclusive)

	-- Four rules over cells: "near" only decides a component, the others apply to tagged entities.
	local function cellRule(name, mode, appliesTo, size, viewerKeys)
		scope.addScopeRule(name, {
			mode = mode,
			appliesTo = appliesTo,
			dependsOn = { C.Cell },
			viewerDependsOn = { C.Focus, C.Vision },
			key = function(entity)
				local cell = world:get(entity, C.Cell)
				return if cell then cell // size else nil
			end,
			viewerKeys = viewerKeys,
		})
	end
	local function nearFocus(size, reach)
		return function(player)
			local focus, keys = world:get(player, C.Focus), {}
			if focus then
				for d = -reach, reach do
					keys[(focus + d) // size] = true
				end
			end
			return keys
		end
	end
	cellRule("near", "restrict", nil, 3, nearFocus(3, 0))
	cellRule("camera", "restrict", Spatial, 1, nearFocus(1, 1)) -- interest management is just a rule
	cellRule("fog", "grant", Fogged, 1, function(player)
		return world:get(player, C.Vision) or {}
	end)
	cellRule("zone", "restrict", Zoned, 4, nearFocus(4, 0))

	scope.replicate(C.Name)
	scope.replicate(C.Hp)
	scope.replicate(C.Secret, { visibleTo = "owner" })
	scope.replicate(C.Target, { refs = true })
	scope.replicate(C.Holder, { refs = { "who" } })
	scope.replicate(C.Pos, { visibleTo = "near" })
	scope.replicateRelation(jecs.ChildOf)
	scope.replicateRelation(Follows)

	local rooms = {}
	for _ = 1, 3 do
		table.insert(rooms, h:spawn(nil, { Net.Room }, false))
	end
	local players, connected = {}, {}
	for i = 1, 6 do
		local p = h:spawn({ [C.Name] = "player" .. i, [C.Focus] = rng:int(0, CELLS - 1) }, nil, false)
		if rng:chance(0.5) then
			world:add(p, jecs.pair(Net.Member, rng:pick(rooms)))
		end
		if rng:chance(0.5) then
			world:add(p, Net.Public)
			world:add(p, Net.Replicated)
		end
		table.insert(players, p)
	end

	local things = {}
	local function alive()
		local list = {}
		for _, entity in things do
			if world:contains(entity) then
				table.insert(list, entity)
			end
		end
		things = list
		return list
	end
	local function anyEntity()
		return if rng:chance(0.2) then rng:pick(players) else rng:pick(alive())
	end

	-- Replicated values: component, chance at spawn, and a random value (nil: none to give).
	local values = {
		{
			C.Cell,
			0.4,
			function()
				return rng:int(0, CELLS - 1)
			end,
		},
		{
			C.Hp,
			0.5,
			function()
				return rng:int(1, 100)
			end,
		},
		{
			C.Pos,
			0.5,
			function()
				return { x = rng:int(1, 99) }
			end,
		},
		{
			C.Secret,
			0.3,
			function()
				return { code = rng:int(1, 999) }
			end,
		},
		{ C.Target, 0.3, anyEntity },
		{
			C.Holder,
			0.2,
			function()
				local who = anyEntity()
				return if who then { who = who, note = "held" } else nil
			end,
		},
	}

	local function spawn()
		local e = h:spawn({ [C.Name] = "thing" }, nil, false)
		for _, tag in { { Net.Public, 0.3 }, { Spatial, 0.3 }, { Fogged, 0.3 }, { Zoned, 0.2 } } do
			if rng:chance(tag[2]) then
				world:add(e, tag[1])
			end
		end
		for _ = 1, rng:int(0, 2) do
			world:add(e, jecs.pair(Net.Audience, rng:pick(rooms)))
		end
		if rng:chance(0.3) then
			world:add(e, jecs.pair(Net.Owner, rng:pick(players)))
		end
		for _, spec in values do
			local value = rng:chance(spec[2]) and spec[3]()
			if value then
				world:set(e, spec[1], value)
			end
		end
		local list = alive()
		if #list > 0 and rng:chance(0.3) then
			-- ChildOf only to an older entity, so it stays acyclic (deletes cascade along it).
			local parent = rng:pick(list)
			world:add(e, jecs.pair(jecs.ChildOf, parent))
			-- Usually the parent is also what it's visible through, but that's the game's choice.
			if rng:chance(0.6) then
				world:add(e, jecs.pair(Net.VisibleThrough, parent))
			end
		elseif #list > 0 and rng:chance(0.15) then
			world:add(e, jecs.pair(Follows, rng:pick(list)))
		end
		if #list > 0 and not world:target(e, Net.VisibleThrough, 0) and rng:chance(0.15) then
			world:add(e, jecs.pair(Net.VisibleThrough, rng:pick(list)))
		end
		if rng:chance(0.9) then
			world:add(e, Net.Replicated)
		end
		table.insert(things, e)
	end

	-- jecs 0.11.0-quenty.3 has bugs in deletes and in retargeting exclusive relations (see
	-- experiments/jecs-findings), so deletes and retargets go through JecsWorkarounds, as a game
	-- on that version would, and the fuzz tests the scope core rather than those bugs. The arena
	-- scenario covers a VisibleThrough target deleted with plain world:delete.
	local function delete(e)
		if useWorkarounds then
			JecsWorkarounds.delete(world, e)
		else
			world:delete(e)
		end
	end
	-- Points an exclusive relation at `target`, or removes it when `target` is nil.
	local function setTarget(e, relation, target)
		if useWorkarounds then
			JecsWorkarounds.setTarget(world, e, relation, target)
		elseif target then
			world:add(e, jecs.pair(relation, target))
		elseif world:target(e, relation, 0) then
			world:remove(e, jecs.pair(relation, world:target(e, relation, 0)))
		end
	end
	local function toggle(e, id)
		if world:has(e, id) then
			world:remove(e, id)
		else
			world:add(e, id)
		end
	end
	-- An edit of a random thing.
	local function onThing(fn)
		return function()
			local e = rng:pick(alive())
			if e then
				fn(e)
			end
		end
	end
	local function retarget(relation, pickTarget, dropChance)
		return onThing(function(e)
			setTarget(e, relation, if rng:chance(dropChance) then nil else pickTarget(e))
		end)
	end
	local function setValue(e)
		local spec = rng:pick(values)
		local value = rng:chance(0.8) and spec[3]()
		if value then
			world:set(e, spec[1], value)
		else
			world:remove(e, spec[1])
		end
	end

	local edits = {
		spawn,
		onThing(delete),
		onThing(function(e)
			toggle(e, Net.Public)
		end),
		onThing(function(e)
			toggle(e, Net.Replicated)
		end),
		onThing(function(e)
			toggle(e, jecs.pair(Net.Audience, rng:pick(rooms)))
		end),
		onThing(function(e)
			toggle(e, jecs.pair(Net.Owner, rng:pick(players)))
		end),
		onThing(function(e)
			local value = rng:pick({ "server", "owner", rng:pick(rooms), false })
			if value then
				world:set(e, Net.VisibleTo, value)
			else
				world:remove(e, Net.VisibleTo)
			end
		end),
		retarget(jecs.ChildOf, function(e) -- only to an older entity
			local list = alive()
			local at = table.find(list, e)
			return if at > 1 then list[rng:int(1, at - 1)] else nil
		end, 0.3),
		retarget(Net.VisibleThrough, anyEntity, 0.3), -- loops allowed
		retarget(Follows, function()
			return rng:pick(alive())
		end, 0.2),
		function()
			toggle(rng:pick(players), jecs.pair(Net.Member, rng:pick(rooms)))
		end,
		function()
			world:set(rng:pick(players), C.Focus, rng:int(0, CELLS - 1))
		end,
		function()
			local cells = {}
			for _ = 1, rng:int(0, 4) do
				cells[rng:int(0, CELLS - 1)] = true
			end
			world:set(rng:pick(players), C.Vision, cells)
		end,
		function()
			local p = rng:pick(players)
			if connected[p] then
				h:disconnect(p)
			else
				h:connect(p)
			end
			connected[p] = not connected[p]
		end,
	}
	for _ = 1, #values do -- one edit per value kind, so values change as often as the rest
		table.insert(edits, onThing(setValue))
	end

	-- An edit that can only narrow visibility: drop a grant, a membership or rule data, or add a need.
	-- Returns whether it changed anything.
	local function narrow(): boolean
		local e = rng:pick(alive())
		local choice = rng:int(1, 7)
		local removable = ({ Net.Member, Net.Public, C.Cell, Net.Audience, Net.Owner, Net.VisibleThrough })[choice]
		if choice == 1 then
			e = rng:pick(players)
		elseif not e then
			return false
		elseif choice == 7 then
			if world:has(e, Net.VisibleTo) then
				return false
			end
			world:set(e, Net.VisibleTo, if rng:chance(0.5) then "owner" else rng:pick(rooms))
			return true
		end
		local id = if choice == 2 or choice == 3
			then removable
			else jecs.pair(removable, world:target(e, removable, 0) or 0)
		local had = world:has(e, id)
		world:remove(e, id)
		return had
	end

	for _ = 1, 15 do
		spawn()
	end
	for _, p in players do
		if rng:chance(0.7) then
			h:connect(p)
			connected[p] = true
		end
	end

	for frame = 1, frameCount do
		for _ = 1, rng:int(0, 6) do
			rng:pick(edits)()
		end
		if rng:chance(0.3) then
			local before = ScopeOracle.compute(world, scope)
			if narrow() then
				local ok, detail = ScopeOracle.isSubset(ScopeOracle.compute(world, scope), before)
				if not ok then
					error(`seed {seed} frame {frame}: removing a constraint widened visibility: {detail}`, 0)
				end
			end
		end
		local ok, err = pcall(h.step, h)
		if not ok then
			error(`seed {seed} frame {frame}: {err}`, 0)
		end
		if options and options.onFrame then
			options.onFrame(h, frame)
		end
	end
	return h
end

return FuzzWorld
