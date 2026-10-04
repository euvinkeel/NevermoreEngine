--!nonstrict
--[[
	A random world for the invariant tests: rooms, players, grants, overrides, inheritance chains
	and cycles, all three rule modes, references and owner-only data, with random edits every
	frame. ScopeHarness checks its invariants after each frame; `runSeed` also checks that narrowing
	edits never widen visibility.

	Every failure message starts with the seed and frame, so `runSeed(seed, frames)` replays it.
]]
local Rng = require("./Rng")
local ScopeHarness = require("./ScopeHarness")
local ScopeOracle = require("./ScopeOracle")

local FuzzWorld = {}

local CELLS = 12

function FuzzWorld.runSeed(
	seed: number,
	frameCount: number,
	options: { enterBudget: number?, onFrame: ((any, number) -> ())? }?
)
	local rng = Rng.new(seed)
	local h = ScopeHarness.new({
		enterBudget = options and options.enterBudget,
		hysteresisFrames = rng:int(1, 3),
		maxInheritDepth = 4,
	})
	local world, Net, jecs, scope = h.world, h.Net, h.jecs, h.scope

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
	}
	-- An exclusive relation without delete cascades, so inheritance cycles can form.
	local Follows = world:component()
	world:add(Follows, jecs.Exclusive)
	h:replicate(C.Name)
	h:replicate(C.Hp)
	h:replicate(C.Secret, { visibleTo = "owner" })
	h:replicate(C.Target, { isRef = true })
	h:replicate(C.Holder, { refFields = { "who" } })
	h.scope.replicateRelation(jecs.ChildOf)
	h.scope.replicateRelation(Follows)

	h:addRule("camera", {
		mode = "relevance",
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
			world:add(e, jecs.pair(jecs.ChildOf, rng:pick(list) :: number))
			if rng:chance(0.7) then
				world:add(e, jecs.pair(Net.VisibleThrough, jecs.ChildOf))
			end
		elseif #list > 0 and rng:chance(0.15) then
			world:add(e, jecs.pair(Follows, rng:pick(list) :: number))
			world:add(e, jecs.pair(Net.VisibleThrough, Follows))
		end
		if rng:chance(0.5) then
			world:set(e, C.Hp, rng:int(1, 100))
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

	-- jecs 0.11.0-quenty.3 bug (see experiments/jecs-findings): a cascade delete along ChildOf skips
	-- a child that gets moved mid-cascade, which happens when it has an ordinary relation pair to
	-- a sibling being deleted. The skipped child keeps a dangling ChildOf that later resolves to a
	-- recycled id. Detach those pairs first so the fuzz tests the scope core, not that bug.
	local function safeDelete(e: number)
		local doomed = { e }
		local i = 1
		while i <= #doomed do
			for child in world:query(jecs.pair(jecs.ChildOf, doomed[i])) do
				table.insert(doomed, child)
			end
			i += 1
		end
		for _, target in doomed do
			local followers = {}
			for follower in world:query(jecs.pair(Follows, target)) do
				table.insert(followers, follower)
			end
			for _, follower in followers do
				world:remove(follower, jecs.pair(Follows, target))
			end
		end
		world:delete(e)
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
				safeDelete(e)
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
					world:add(e, jecs.pair(jecs.ChildOf, list[rng:int(1, index - 1)]))
				else
					-- Explicit target: removing pair(R, Wildcard) fires OnRemove but keeps the pair.
					local parent = world:target(e, jecs.ChildOf, 0)
					if parent then
						world:remove(e, jecs.pair(jecs.ChildOf, parent))
					end
				end
			end
		end,
		function()
			local e = rng:pick(alive())
			if e then
				local relation = if rng:chance(0.5) then jecs.ChildOf else Follows
				togglePair(e, Net.VisibleThrough, relation)
			end
		end,
		function()
			local e = rng:pick(alive())
			local target = rng:pick(alive())
			if e and target then
				local followed = world:target(e, Follows, 0)
				if followed then
					world:remove(e, jecs.pair(Follows, followed))
				end
				if rng:chance(0.8) then
					world:add(e, jecs.pair(Follows, target)) -- cycles allowed
				end
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
		local before = ScopeOracle.compute(jecs, world, scope, h.rules, 4)
		local edit = narrowing[rng:int(1, #narrowing)]
		if edit() then
			local after = ScopeOracle.compute(jecs, world, scope, h.rules, 4)
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
