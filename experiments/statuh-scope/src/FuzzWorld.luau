--!nonstrict
--[[
	A random world for the invariant tests: rooms, players, grants, overrides, VisibleThrough chains
	and cycles, grant and restrict rules, references, owner-only data and a component visible only
	through a rule ("near"), with random edits every
	frame. ScopeHarness checks its invariants after each frame; `runSeed` also checks that narrowing
	edits never widen visibility. ChildOf and Follows are ordinary game relations, replicated as
	data; only VisibleThrough affects visibility.

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
		beforeStep: ((any, number) -> ())?,
		-- false: plain jecs calls instead of JecsWorkarounds. ScopeHarness's jecs integrity check
		-- then shows which jecs bugs the fuzz runs into.
		jecsWorkarounds: boolean?,
	}?
)
	local rng = Rng.new(seed)
	local h = ScopeHarness.new({
		enterBudget = options and options.enterBudget,
	})
	local world, Net, jecs, scope = h.world, h.Net, h.jecs, h.scope
	local useWorkarounds = not (options and options.jecsWorkarounds == false)

	local C = {
		Name = world:component(),
		Hp = world:component(),
		Secret = world:component(),
		Target = world:component(),
		Holder = world:component(),
		Cell = world:component(),
		Spatial = world:component(),
		Fogged = world:component(),
		Zoned = world:component(),
		Focus = world:component(),
		Vision = world:component(),
		Pos = world:component(),
	}
	-- An ordinary game relation (no cascades), replicated as data.
	local Follows = world:component()
	world:add(Follows, jecs.Exclusive)
	h:replicate(C.Name)
	h:replicate(C.Hp)
	h:replicate(C.Secret, { visibleTo = "owner" })
	h:replicate(C.Target, { isRef = true })
	h:replicate(C.Holder, { refFields = { "who" } })
	h.scope.replicateRelation(jecs.ChildOf)
	h.scope.replicateRelation(Follows)

	-- A component narrower than its entity: Pos goes only to viewers whose focus is near the
	-- entity's cell. The rule has no appliesTo; it's only a component's visibility.
	h:addRule("near", {
		mode = "restrict",
		dependsOn = { C.Cell },
		viewerDependsOn = { C.Focus },
		key = function(entity)
			local cell = world:get(entity, C.Cell)
			return if cell then cell // 3 else nil
		end,
		viewerKeys = function(player)
			local focus = world:get(player, C.Focus)
			return if focus then { [focus // 3] = true } else {}
		end,
	})
	h:replicate(C.Pos, { visibleTo = "near" })

	-- Interest management is game code: a camera rule is an ordinary restrict rule.
	h:addRule("camera", {
		mode = "restrict",
		appliesTo = C.Spatial,
		dependsOn = { C.Cell },
		viewerDependsOn = { C.Focus },
		key = function(entity)
			return world:get(entity, C.Cell)
		end,
		viewerKeys = function(player)
			local focus = world:get(player, C.Focus)
			if focus == nil then
				return {}
			end
			return { [focus - 1] = true, [focus] = true, [focus + 1] = true }
		end,
	})
	h:addRule("fog", {
		mode = "grant",
		appliesTo = C.Fogged,
		dependsOn = { C.Cell },
		viewerDependsOn = { C.Vision },
		key = function(entity)
			return world:get(entity, C.Cell)
		end,
		viewerKeys = function(player)
			return world:get(player, C.Vision) or {}
		end,
	})
	h:addRule("zone", {
		mode = "restrict",
		appliesTo = C.Zoned,
		dependsOn = { C.Cell },
		viewerDependsOn = { C.Focus },
		key = function(entity)
			local cell = world:get(entity, C.Cell)
			return if cell then cell // 4 else nil
		end,
		viewerKeys = function(player)
			local focus = world:get(player, C.Focus)
			return if focus then { [focus // 4] = true } else {}
		end,
	})

	local rooms = {}
	for _ = 1, 3 do
		local room = world:entity()
		world:add(room, Net.Room)
		table.insert(rooms, room)
	end
	local players = {}
	local connected = {}
	for i = 1, 6 do
		local p = world:entity()
		world:set(p, C.Name, "player" .. i)
		world:set(p, C.Focus, rng:int(0, CELLS - 1))
		if rng:chance(0.5) then
			world:add(p, jecs.pair(Net.Member, rooms[rng:int(1, #rooms)]))
		end
		if rng:chance(0.5) then
			world:add(p, Net.Public)
			world:add(p, Net.Replicated)
		end
		table.insert(players, p)
	end

	local things: { number } = {}
	local function alive(): { number }
		local list = {}
		for _, entity in things do
			if world:contains(entity) then
				table.insert(list, entity)
			end
		end
		things = list
		return list
	end
	local function anyEntity(): number?
		local list = alive()
		if rng:chance(0.2) then
			return rng:pick(players)
		end
		return rng:pick(list)
	end

	local function spawn()
		local e = world:entity()
		world:set(e, C.Name, "thing" .. e)
		if rng:chance(0.3) then
			world:add(e, Net.Public)
		end
		for _ = 1, rng:int(0, 2) do
			world:add(e, jecs.pair(Net.Audience, rng:pick(rooms) :: number))
		end
		if rng:chance(0.3) then
			world:add(e, jecs.pair(Net.Owner, rng:pick(players) :: number))
		end
		if rng:chance(0.4) then
			world:set(e, C.Cell, rng:int(0, CELLS - 1))
		end
		-- Rule tags are spawn-time only (the core latches them).
		if rng:chance(0.3) then
			world:add(e, C.Spatial)
		end
		if rng:chance(0.3) then
			world:add(e, C.Fogged)
		end
		if rng:chance(0.2) then
			world:add(e, C.Zoned)
		end
		local list = alive()
		if #list > 0 and rng:chance(0.3) then
			-- ChildOf only to an older entity, so it stays acyclic (deletes cascade along it).
			local parent = rng:pick(list) :: number
			world:add(e, jecs.pair(jecs.ChildOf, parent))
			-- Usually the parent is also what it's visible through, but that's the game's choice.
			if rng:chance(0.6) then
				world:add(e, jecs.pair(Net.VisibleThrough, parent))
			end
		elseif #list > 0 and rng:chance(0.15) then
			world:add(e, jecs.pair(Follows, rng:pick(list) :: number))
		end
		if #list > 0 and not world:target(e, Net.VisibleThrough, 0) and rng:chance(0.15) then
			world:add(e, jecs.pair(Net.VisibleThrough, rng:pick(list) :: number))
		end
		if rng:chance(0.5) then
			world:set(e, C.Hp, rng:int(1, 100))
		end
		if rng:chance(0.5) then
			world:set(e, C.Pos, { x = rng:int(1, 99) })
		end
		if rng:chance(0.3) then
			world:set(e, C.Secret, { code = rng:int(1, 999) })
		end
		local target = anyEntity()
		if target and rng:chance(0.3) then
			world:set(e, C.Target, target)
		end
		local holder = anyEntity()
		if holder and rng:chance(0.2) then
			world:set(e, C.Holder, { who = holder, note = "held" })
		end
		if rng:chance(0.9) then
			world:add(e, Net.Replicated)
		end
		table.insert(things, e)
	end

	-- jecs 0.11.0-quenty.3 has bugs in deletes and in retargeting exclusive relations (see
	-- experiments/jecs-findings), so deletes and retargets go through JecsWorkarounds, as a game
	-- on that version would, and the fuzz tests the scope core rather than those bugs. ScopeHarness
	-- checks jecs's own bookkeeping every frame. The arena scenario covers a VisibleThrough target
	-- deleted with plain world:delete, its pairs left for jecs to remove.
	local function delete(e: number)
		if useWorkarounds then
			JecsWorkarounds.delete(world, e)
		else
			world:delete(e)
		end
	end

	-- Points an exclusive relation at `target`, or removes it when `target` is nil.
	local function setTarget(e: number, relation: number, target: number?)
		if useWorkarounds then
			JecsWorkarounds.setTarget(world, e, relation, target)
		elseif target ~= nil then
			world:add(e, jecs.pair(relation, target))
		else
			local current = world:target(e, relation, 0)
			if current then
				world:remove(e, jecs.pair(relation, current))
			end
		end
	end

	local function togglePair(e: number, relation: number, target: number)
		local id = jecs.pair(relation, target)
		if world:has(e, id) then
			world:remove(e, id)
		else
			world:add(e, id)
		end
	end

	local edits: { () -> () } = {
		spawn,
		function()
			local e = rng:pick(alive())
			if e then
				delete(e)
			end
		end,
		function()
			local e = rng:pick(alive())
			if e then
				togglePair(e, Net.Audience, rng:pick(rooms) :: number)
			end
		end,
		function()
			local e = rng:pick(alive())
			if e then
				if world:has(e, Net.Public) then
					world:remove(e, Net.Public)
				else
					world:add(e, Net.Public)
				end
			end
		end,
		function()
			local e = rng:pick(alive())
			if e then
				togglePair(e, Net.Owner, rng:pick(players) :: number)
			end
		end,
		function()
			local e = rng:pick(alive())
			if e then
				local choice = rng:int(1, 4)
				if choice == 1 then
					world:set(e, Net.VisibleTo, "server")
				elseif choice == 2 then
					world:set(e, Net.VisibleTo, "owner")
				elseif choice == 3 then
					world:set(e, Net.VisibleTo, rng:pick(rooms))
				else
					world:remove(e, Net.VisibleTo)
				end
			end
		end,
		function()
			local e = rng:pick(alive())
			if e then
				if rng:chance(0.8) then
					world:set(e, C.Cell, rng:int(0, CELLS - 1))
				else
					world:remove(e, C.Cell)
				end
			end
		end,
		function()
			local e = rng:pick(alive())
			if e then
				if rng:chance(0.8) then
					world:set(e, C.Hp, rng:int(1, 100))
				else
					world:remove(e, C.Hp)
				end
			end
		end,
		function()
			local e = rng:pick(alive())
			if e then
				if rng:chance(0.7) then
					world:set(e, C.Secret, { code = rng:int(1, 999) })
				else
					world:remove(e, C.Secret)
				end
			end
		end,
		function()
			local e = rng:pick(alive())
			if e then
				if rng:chance(0.8) then
					world:set(e, C.Pos, { x = rng:int(1, 99) })
				else
					world:remove(e, C.Pos)
				end
			end
		end,
		function()
			local e = rng:pick(alive())
			local target = anyEntity()
			if e and target then
				if rng:chance(0.8) then
					world:set(e, C.Target, target)
				else
					world:remove(e, C.Target)
				end
			end
		end,
		function()
			local e = rng:pick(alive())
			local who = anyEntity()
			if e and who then
				if rng:chance(0.8) then
					world:set(e, C.Holder, { who = who, note = "held" })
				else
					world:remove(e, C.Holder)
				end
			end
		end,
		function()
			togglePair(rng:pick(players) :: number, Net.Member, rng:pick(rooms) :: number)
		end,
		function()
			world:set(rng:pick(players) :: number, C.Focus, rng:int(0, CELLS - 1))
		end,
		function()
			local cells = {}
			for _ = 1, rng:int(0, 4) do
				cells[rng:int(0, CELLS - 1)] = true
			end
			world:set(rng:pick(players) :: number, C.Vision, cells)
		end,
		function()
			local p = rng:pick(players) :: number
			if connected[p] then
				h:disconnect(p)
				connected[p] = nil
			else
				h:connect(p)
				connected[p] = true
			end
		end,
		function()
			local list = alive()
			local e = rng:pick(list)
			if e then
				local index = table.find(list, e) :: number
				if index > 1 and rng:chance(0.7) then
					setTarget(e, jecs.ChildOf, list[rng:int(1, index - 1)])
				else
					setTarget(e, jecs.ChildOf, nil)
				end
			end
		end,
		function()
			-- Point VisibleThrough somewhere else (cycles allowed), or drop it.
			local e = rng:pick(alive())
			if e then
				if world:target(e, Net.VisibleThrough, 0) and rng:chance(0.3) then
					setTarget(e, Net.VisibleThrough, nil)
				else
					local target = anyEntity()
					if target then
						setTarget(e, Net.VisibleThrough, target)
					end
				end
			end
		end,
		function()
			local e = rng:pick(alive())
			local target = rng:pick(alive())
			if e and target then
				setTarget(e, Follows, if rng:chance(0.8) then target else nil)
			end
		end,
		function()
			local e = rng:pick(alive())
			if e then
				if world:has(e, Net.Replicated) then
					world:remove(e, Net.Replicated)
				else
					world:add(e, Net.Replicated)
				end
			end
		end,
	}

	-- Edits that can only narrow visibility.
	local narrowing: { () -> boolean } = {
		function()
			local e = rng:pick(alive())
			if e and world:has(e, Net.Public) then
				world:remove(e, Net.Public)
				return true
			end
			return false
		end,
		function()
			local e = rng:pick(alive())
			local room = e and world:target(e, Net.Audience, 0)
			if e and room then
				world:remove(e, jecs.pair(Net.Audience, room))
				return true
			end
			return false
		end,
		function()
			local e = rng:pick(alive())
			local owner = e and world:target(e, Net.Owner, 0)
			if e and owner then
				world:remove(e, jecs.pair(Net.Owner, owner))
				return true
			end
			return false
		end,
		function()
			local p = rng:pick(players) :: number
			local room = world:target(p, Net.Member, 0)
			if room then
				world:remove(p, jecs.pair(Net.Member, room))
				return true
			end
			return false
		end,
		function()
			local e = rng:pick(alive())
			local through = e and world:target(e, Net.VisibleThrough, 0)
			if e and through then
				world:remove(e, jecs.pair(Net.VisibleThrough, through))
				return true
			end
			return false
		end,
		function()
			local e = rng:pick(alive())
			if e and world:has(e, C.Cell) then
				world:remove(e, C.Cell)
				return true
			end
			return false
		end,
		function()
			local e = rng:pick(alive())
			if e and not world:has(e, Net.VisibleTo) then
				world:set(e, Net.VisibleTo, if rng:chance(0.5) then "owner" else rng:pick(rooms))
				return true
			end
			return false
		end,
	}

	local function checkNarrowing(frame: number)
		local before = ScopeOracle.compute(jecs, world, scope, h.rules)
		local edit = narrowing[rng:int(1, #narrowing)]
		if edit() then
			local after = ScopeOracle.compute(jecs, world, scope, h.rules)
			local ok, detail = ScopeOracle.isSubset(after, before)
			if not ok then
				error(`seed {seed} frame {frame}: removing a constraint widened visibility: {detail}`, 0)
			end
		end
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
			edits[rng:int(1, #edits)]()
		end
		if rng:chance(0.3) then
			checkNarrowing(frame)
		end
		if options and options.beforeStep then
			options.beforeStep(h, frame)
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
