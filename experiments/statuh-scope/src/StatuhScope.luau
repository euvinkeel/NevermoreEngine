--!strict
--[[
	StatuhScope: a prototype of Statuh 2.0's selective-replication core. Experiment only, no
	networking. Give it a jecs world and connected players; each `frame()` returns, per client, the
	messages that client should receive, in the fixed order

		ENTER, ops (SET/REM), pairs (PAIR_REM/PAIR_ADD), LEAVE, DEL, ROLLBACK

	Semantics (see ../DESIGN.md, "Chosen design"):
	- Grants say who may see an entity, and they add up: Net.Public, pair(Net.Audience, room),
	  pair(Net.Owner, player), and pair(Net.VisibleThrough, relation), which grants the viewers of
	  the relation's target. An entity with no grants is visible to nobody (fail closed).
	- Grant rules ("grant" mode key functions, like fog-of-war vision) add viewers too.
	- Restrictions narrow that: the Net.VisibleTo override and "restrict"/"relevance" rules. Rules
	  are latched when the entity starts replicating, so they can't fall off later, and a nil rule
	  key matches nobody.
	  So visibility only grows when a grant is added or a restriction removed. Removing a grant
	  never widens it.
	- Authorization (grants, override, grant and restrict rules) is revoked immediately. Relevance
	  rules (spatial interest) let an entity linger `hysteresisFrames` before it LEAVEs.
	- Nothing outside a client's delivered scope goes in its frame: entity references to hidden
	  entities are sent as REDACTED and re-sent when the target enters, pairs are only sent while
	  both ends are delivered, and DEL only goes to clients that had the entity.

	Hooks on the jecs world only mark things dirty; all reading happens in `frame()`.

	The core takes `jecs` as an argument instead of requiring it, so the same file runs under the
	headless test runner, Lune's native require, and codegen-enabled `luau.load` for benchmarks.
]]

local StatuhScope = {}

export type Visibility = "all" | "owner"

export type ReplicateOptions = {
	visibleTo: Visibility?,
	-- The whole value is an entity id (or nil).
	isRef: boolean?,
	-- The value is a table and these fields hold entity ids.
	refFields: { string }?,
}

export type ScopeRule = {
	-- The entity's key under this rule. nil means no viewer passes the rule.
	key: (entity: number) -> any,
	-- The keys a viewer (by its player entity) is interested in.
	viewerKeys: (viewerEntity: number) -> { [any]: boolean },
	-- Components whose changes on an entity change its key.
	dependsOn: { number },
	-- Components whose changes on a viewer's player entity change its keys.
	viewerDependsOn: { number }?,
	-- Entities that have this component when they start replicating are subject to the rule.
	appliesTo: number,
	-- "grant": viewers interested in the entity's key may see it (added to the other grants).
	-- "restrict": only viewers interested in the key may see it (authorization; revoked at once).
	-- "relevance": like restrict, but for interest management, so an exit lingers first.
	mode: RuleMode,
}

export type RuleMode = "grant" | "restrict" | "relevance"

export type Config = {
	-- Max entities ENTERed per client per frame. Inheritance groups are never split, so a frame
	-- may go over this to fit its first group. nil means unlimited.
	enterBudget: number?,
	-- An entity that only fails relevance rules LEAVEs this many frames later. Default 3.
	hysteresisFrames: number?,
	-- VisibleThrough chains deeper than this, or cyclic, are invisible. Default 8.
	maxInheritDepth: number?,
}

export type Message = { any }

export type FrameStats = {
	dirtyEntities: number,
	enters: number,
	ops: number,
	pairs: number,
	leaves: number,
	dels: number,
	rollbacks: number,
	deferredEnters: number,
}

local MAX_VIEWERS = 64

-- Sets of viewer indices 0..63 are two 32-bit words (lo, hi).

local function bitOf(index: number): (number, number)
	if index < 32 then
		return bit32.lshift(1, index), 0
	end
	return 0, bit32.lshift(1, index - 32)
end

local function hasBit(lo: number, hi: number, index: number): boolean
	if index < 32 then
		return bit32.btest(lo, bit32.lshift(1, index))
	end
	return bit32.btest(hi, bit32.lshift(1, index - 32))
end

local function eachBit(lo: number, hi: number, fn: (number) -> ())
	while lo ~= 0 do
		local index = bit32.countrz(lo)
		lo = bit32.band(lo, lo - 1)
		fn(index)
	end
	while hi ~= 0 do
		local index = bit32.countrz(hi)
		hi = bit32.band(hi, hi - 1)
		fn(index + 32)
	end
end

StatuhScope.bitOf = bitOf
StatuhScope.hasBit = hasBit
StatuhScope.eachBit = eachBit

-- The wire stand-in for a reference to an entity the receiver can't see.
local REDACTED = table.freeze({ redacted = true })
StatuhScope.REDACTED = REDACTED

type PairSet = { [number]: { [number]: boolean } } -- relation key -> target entity -> true

type EntityState = {
	entity: number,
	netId: number,
	-- Authorized viewers (grants, override, authorization rules; inherited along VisibleThrough).
	authLo: number,
	authHi: number,
	-- Relevant viewers (relevance rules; every viewer when there are none; inherited too).
	relLo: number,
	relHi: number,
	-- Viewers that have the entity (delivered scope).
	delLo: number,
	delHi: number,
	-- Connected owners, and the owners that hold the owner-only components right now.
	ownerLo: number,
	ownerHi: number,
	ownerSentLo: number,
	ownerSentHi: number,
	-- Clients that minted this entity's net id and haven't had the spawn acknowledged.
	pinLo: number,
	pinHi: number,
	-- Rule indices latched when replication started, and each rule's current key.
	rules: { number },
	ruleKeys: { [number]: any },
	-- VisibleThrough parent and chain depth (0 when not inheriting).
	inheritParent: number?,
	inheritDepth: number,
	-- Viewer index -> frames left before a relevance-only exit becomes a LEAVE.
	linger: { [number]: number }?,
	-- Replicated component keys present at the end of the last frame.
	sent: { [number]: boolean },
	-- Replicated pairs at the end of the last frame.
	pairs: PairSet,
	-- Reference targets per component key, as of the last frame.
	refs: { [number]: { number } },
	-- Audience rooms and VisibleTo room, as indexed in entitiesOfRoom.
	rooms: { [number]: boolean },
	computedFrame: number,
}

type Rule = ScopeRule & {
	index: number,
	name: string,
	entitiesByKey: { [any]: { [number]: boolean } },
	viewersByKey: { [any]: { lo: number, hi: number } },
	keysOfViewer: { [number]: { [any]: boolean } },
}

type Viewer = {
	index: number,
	entity: number,
	-- Entities waiting to ENTER (new this frame, or deferred by the budget).
	pendingEnter: { [number]: boolean },
	-- Net ids this client minted, by action sequence number.
	minted: { [number]: { number } },
	rollbacks: { number },
}

type ReplicatedComponent = {
	key: number,
	component: number,
	visibleTo: Visibility,
	isRef: boolean,
	refFields: { string }?,
}

local function addToIndex(index: { [number]: { [number]: boolean } }, key: number, value: number)
	local set = index[key]
	if not set then
		set = {}
		index[key] = set
	end
	set[value] = true
end

local function removeFromIndex(index: { [number]: { [number]: boolean } }, key: number, value: number)
	local set = index[key]
	if set then
		set[value] = nil
		if next(set) == nil then
			index[key] = nil
		end
	end
end

function StatuhScope.new(jecs: any, world: any, config: Config?)
	local options = config or {}
	local enterBudget = options.enterBudget
	local hysteresisFrames = options.hysteresisFrames or 3
	local maxInheritDepth = options.maxInheritDepth or 8

	-- Vocabulary. Rooms, membership and audience are server-only and never replicated.
	local Net = {
		Replicated = world:component(),
		Room = world:component(),
		Public = world:component(),
		Member = world:component(),
		Audience = world:component(),
		Owner = world:component(),
		VisibleThrough = world:component(),
		VisibleTo = world:component(),
	}

	local states: { [number]: EntityState } = {}
	local byNet: { [number]: number } = {}
	local nextNetId = 1

	local viewers: { [number]: Viewer } = {}
	local viewerOf: { [number]: number } = {}
	local allLo, allHi = 0, 0

	local roomMembers: { [number]: { lo: number, hi: number } } = {} -- room -> connected member bits
	local roomsOfPlayer: { [number]: { [number]: boolean } } = {} -- player -> rooms (connected or not)
	local entitiesOfRoom: { [number]: { [number]: boolean } } = {} -- room -> entities mentioning it
	local inheritors: { [number]: { [number]: boolean } } = {} -- parent -> inheriting entities
	local refsTo: { [number]: { [number]: { [number]: boolean } } } = {} -- target -> referrer -> keys
	local pairsTo: { [number]: { [number]: { [number]: boolean } } } = {} -- target -> referrer -> keys

	local replicatedByKey: { ReplicatedComponent } = {}
	local relations: { number } = {} -- relation key -> relation entity
	local watchedRelations: { [number]: boolean } = {}
	local defaultPublic: { [number]: boolean } = {}
	local rules: { Rule } = {}
	local ruleNames: { [string]: Rule } = {}

	local dirtyScope: { [number]: boolean } = {}
	local dirtyComps: { [number]: { [number]: boolean } } = {}
	local dirtyPairs: { [number]: boolean } = {}
	local dirtyRuleKeys: { [number]: boolean } = {}
	local dirtyViewerKeys: { [number]: { [number]: boolean } } = {} -- rule index -> viewer indices
	local newlyReplicated: { [number]: boolean } = {}
	local deleted: { { netId: number, delLo: number, delHi: number, entity: number } } = {}
	-- Entities destroyed or unreplicated since the last frame; references to them get redacted.
	local gone: { [number]: boolean } = {}
	local unreplicated: { { netId: number, delLo: number, delHi: number, entity: number } } = {}
	local lingering: { [number]: boolean } = {}
	local frameNumber = 0

	local scope = {
		Net = Net,
		REDACTED = REDACTED,
	}

	local function markScope(entity: number)
		if states[entity] then
			dirtyScope[entity] = true
		end
	end

	local function markComp(entity: number, key: number)
		if states[entity] then
			local set = dirtyComps[entity]
			if not set then
				set = {}
				dirtyComps[entity] = set
			end
			set[key] = true
		end
	end

	-- Room membership (connected viewers only).

	local function refreshRoomBits(room: number)
		local lo, hi = 0, 0
		for _, viewer in viewers do
			local rooms = roomsOfPlayer[viewer.entity]
			if rooms and rooms[room] then
				local bl, bh = bitOf(viewer.index)
				lo, hi = bit32.bor(lo, bl), bit32.bor(hi, bh)
			end
		end
		roomMembers[room] = if lo == 0 and hi == 0 then nil else { lo = lo, hi = hi }
		for entity in entitiesOfRoom[room] or {} do
			markScope(entity)
		end
	end

	-- Entity references inside component values.

	local function refTargetsOf(info: ReplicatedComponent, entity: number): { number }
		local targets = {}
		if not (info.isRef or info.refFields) or not world:has(entity, info.component) then
			return targets
		end
		local value = world:get(entity, info.component)
		if info.isRef then
			if value ~= nil then
				table.insert(targets, value)
			end
		elseif type(value) == "table" then
			for _, field in info.refFields :: { string } do
				local target = value[field]
				if target ~= nil then
					table.insert(targets, target)
				end
			end
		end
		return targets
	end

	local function setRefs(state: EntityState, key: number, targets: { number }?)
		local entity = state.entity
		for _, target in state.refs[key] or {} do
			local referrers = refsTo[target]
			local keys = referrers and referrers[entity]
			if keys then
				keys[key] = nil
				if next(keys) == nil then
					referrers[entity] = nil
					if next(referrers) == nil then
						refsTo[target] = nil
					end
				end
			end
		end
		state.refs[key] = if targets and #targets > 0 then targets else nil
		for _, target in targets or {} do
			local referrers = refsTo[target]
			if not referrers then
				referrers = {}
				refsTo[target] = referrers
			end
			local keys = referrers[entity]
			if not keys then
				keys = {}
				referrers[entity] = keys
			end
			keys[key] = true
		end
	end

	-- What goes on the wire for a component value, for viewer `v`, given what it has right now.
	local function wireValue(info: ReplicatedComponent, value: any, v: number): any
		if info.isRef then
			local target = states[value]
			if target and hasBit(target.delLo, target.delHi, v) then
				return target.netId
			end
			return REDACTED
		elseif info.refFields and type(value) == "table" then
			local copy = table.clone(value)
			for _, field in info.refFields do
				local ref = value[field]
				if ref ~= nil then
					local target = states[ref]
					copy[field] = if target and hasBit(target.delLo, target.delHi, v) then target.netId else REDACTED
				end
			end
			return copy
		end
		return value
	end

	-- Replicated pairs.

	local function currentPairs(entity: number): PairSet
		local result: PairSet = {}
		for key, relation in relations do
			local index = 0
			while true do
				local target = world:target(entity, relation, index)
				if target == nil then
					break
				end
				local set = result[key]
				if not set then
					set = {}
					result[key] = set
				end
				set[target] = true
				index += 1
			end
		end
		return result
	end

	local function setPairs(state: EntityState, new: PairSet)
		local entity = state.entity
		for key, targets in state.pairs do
			for target in targets do
				local referrers = pairsTo[target]
				local keys = referrers and referrers[entity]
				if keys then
					keys[key] = nil
					if next(keys) == nil then
						referrers[entity] = nil
						if next(referrers) == nil then
							pairsTo[target] = nil
						end
					end
				end
			end
		end
		state.pairs = new
		for key, targets in new do
			for target in targets do
				local referrers = pairsTo[target]
				if not referrers then
					referrers = {}
					pairsTo[target] = referrers
				end
				local keys = referrers[entity]
				if not keys then
					keys = {}
					referrers[entity] = keys
				end
				keys[key] = true
			end
		end
	end

	-- Rules.

	local function setEntityRuleKey(state: EntityState, rule: Rule)
		local entity = state.entity
		local oldKey = state.ruleKeys[rule.index]
		local newKey = rule.key(entity)
		if oldKey == newKey then
			return
		end
		if oldKey ~= nil then
			local set = rule.entitiesByKey[oldKey]
			if set then
				set[entity] = nil
				if next(set) == nil then
					rule.entitiesByKey[oldKey] = nil
				end
			end
		end
		state.ruleKeys[rule.index] = newKey
		if newKey ~= nil then
			local set = rule.entitiesByKey[newKey]
			if not set then
				set = {}
				rule.entitiesByKey[newKey] = set
			end
			set[entity] = true
		end
		dirtyScope[entity] = true
	end

	local function setViewerKeys(rule: Rule, viewerIndex: number, keys: { [any]: boolean }?)
		local old = rule.keysOfViewer[viewerIndex] or {}
		local new = keys or {}
		local bl, bh = bitOf(viewerIndex)
		for key in old do
			if not new[key] then
				local bits = rule.viewersByKey[key]
				if bits then
					bits.lo = bit32.band(bits.lo, bit32.bnot(bl))
					bits.hi = bit32.band(bits.hi, bit32.bnot(bh))
					if bits.lo == 0 and bits.hi == 0 then
						rule.viewersByKey[key] = nil
					end
				end
				for entity in rule.entitiesByKey[key] or {} do
					dirtyScope[entity] = true
				end
			end
		end
		for key in new do
			if not old[key] then
				local bits = rule.viewersByKey[key]
				if not bits then
					bits = { lo = 0, hi = 0 }
					rule.viewersByKey[key] = bits
				end
				bits.lo = bit32.bor(bits.lo, bl)
				bits.hi = bit32.bor(bits.hi, bh)
				for entity in rule.entitiesByKey[key] or {} do
					dirtyScope[entity] = true
				end
			end
		end
		rule.keysOfViewer[viewerIndex] = if keys then table.clone(keys) else nil
	end

	-- Entity lifecycle.

	local function forget(entity: number): EntityState?
		local state = states[entity]
		if not state then
			return nil
		end
		for _, ruleIndex in state.rules do
			local key = state.ruleKeys[ruleIndex]
			if key ~= nil then
				local set = rules[ruleIndex].entitiesByKey[key]
				if set then
					set[entity] = nil
					if next(set) == nil then
						rules[ruleIndex].entitiesByKey[key] = nil
					end
				end
			end
		end
		for key in state.refs do
			setRefs(state, key, nil)
		end
		setPairs(state, {})
		for room in state.rooms do
			removeFromIndex(entitiesOfRoom, room, entity)
		end
		if state.inheritParent then
			removeFromIndex(inheritors, state.inheritParent, entity)
		end
		for child in inheritors[entity] or {} do
			markScope(child)
		end
		for _, viewer in viewers do
			viewer.pendingEnter[entity] = nil
		end
		states[entity] = nil
		byNet[state.netId] = nil
		lingering[entity] = nil
		newlyReplicated[entity] = nil
		dirtyScope[entity] = nil
		dirtyComps[entity] = nil
		dirtyPairs[entity] = nil
		dirtyRuleKeys[entity] = nil
		return state
	end

	world:added(Net.Replicated, function(entity)
		if states[entity] then
			return
		end
		local netId = nextNetId
		nextNetId += 1
		states[entity] = {
			entity = entity,
			netId = netId,
			authLo = 0,
			authHi = 0,
			relLo = 0,
			relHi = 0,
			delLo = 0,
			delHi = 0,
			ownerLo = 0,
			ownerHi = 0,
			ownerSentLo = 0,
			ownerSentHi = 0,
			pinLo = 0,
			pinHi = 0,
			rules = {},
			ruleKeys = {},
			inheritParent = nil,
			inheritDepth = 0,
			linger = nil,
			sent = {},
			pairs = {},
			refs = {},
			rooms = {},
			computedFrame = -1,
		}
		byNet[netId] = entity
		newlyReplicated[entity] = true
		dirtyScope[entity] = true
	end)
	world:removed(Net.Replicated, function(entity, _id, isDelete)
		local state = forget(entity)
		if state then
			gone[entity] = true
			local item = { netId = state.netId, delLo = state.delLo, delHi = state.delHi, entity = entity }
			-- A destroyed entity is a DEL. One that's alive but no longer replicated is a LEAVE.
			table.insert(if isDelete then deleted else unreplicated, item)
		end
	end)

	for _, tagOrRelation in { Net.Public, Net.Audience, Net.Owner, Net.VisibleThrough, Net.VisibleTo } do
		world:added(tagOrRelation, markScope)
		world:removed(tagOrRelation, markScope)
	end
	world:changed(Net.VisibleTo, markScope)

	local membershipDirty = false
	local function onMembership(player: number)
		if viewerOf[player] ~= nil then
			-- Read memberships at the next frame; the pair isn't final inside the hook.
			membershipDirty = true
		end
	end
	world:added(Net.Member, onMembership)
	world:removed(Net.Member, onMembership)

	-- Public API.

	--[=[
		Declares a replicated component. `visibleTo = "owner"` sends it only to the entity's owners.
		`isRef`/`refFields` mark entity references, redacted for viewers that can't see the target.
	]=]
	function scope.replicate(component: number, replicateOptions: ReplicateOptions?): number
		local opts = replicateOptions or {}
		local info: ReplicatedComponent = {
			key = #replicatedByKey + 1,
			component = component,
			visibleTo = opts.visibleTo or "all",
			isRef = opts.isRef == true,
			refFields = opts.refFields,
		}
		table.insert(replicatedByKey, info)
		local function onChange(entity: number)
			markComp(entity, info.key)
		end
		world:added(component, onChange)
		world:changed(component, onChange)
		world:removed(component, onChange)
		return info.key
	end

	local function watchRelation(relation: number)
		if watchedRelations[relation] then
			return
		end
		watchedRelations[relation] = true
		local function onPair(entity: number)
			if states[entity] then
				dirtyPairs[entity] = true
				-- VisibleThrough(relation) follows the pair's target.
				dirtyScope[entity] = true
			end
		end
		world:added(relation, onPair)
		world:removed(relation, onPair)
	end

	--[=[
		Declares a relation whose pairs replicate (e.g. jecs.ChildOf). A pair is sent to a client
		only while both ends are delivered to it. Also makes the relation usable with VisibleThrough.
	]=]
	function scope.replicateRelation(relation: number): number
		local key = #relations + 1
		relations[key] = relation
		watchRelation(relation)
		return key
	end

	--[=[
		Makes a relation usable with VisibleThrough without replicating its pairs.
	]=]
	function scope.inheritVia(relation: number)
		watchRelation(relation)
	end

	--[=[
		Entities that have `component` when they start replicating get Net.Public, once.
		Nothing else is public by default.
	]=]
	function scope.setDefaultPublic(component: number)
		defaultPublic[component] = true
	end

	--[=[
		Adds a scope rule. Add rules before the entities they apply to start replicating.
	]=]
	function scope.addScopeRule(name: string, definition: ScopeRule)
		assert(ruleNames[name] == nil, `rule {name} already exists`)
		local rule: Rule = table.clone(definition) :: any
		rule.index = #rules + 1
		rule.name = name
		rule.entitiesByKey = {}
		rule.viewersByKey = {}
		rule.keysOfViewer = {}
		rules[rule.index] = rule
		ruleNames[name] = rule
		local dirtyViewers = {}
		dirtyViewerKeys[rule.index] = dirtyViewers
		for _, viewer in viewers do
			dirtyViewers[viewer.index] = true
		end

		local function onChange(entity: number)
			if states[entity] then
				dirtyRuleKeys[entity] = true
			end
		end
		for _, component in definition.dependsOn do
			world:added(component, onChange)
			world:changed(component, onChange)
			world:removed(component, onChange)
		end
		local function onViewerChange(entity: number)
			local viewerIndex = viewerOf[entity]
			if viewerIndex ~= nil then
				dirtyViewers[viewerIndex] = true
			end
		end
		for _, component in definition.viewerDependsOn or {} do
			world:added(component, onViewerChange)
			world:changed(component, onViewerChange)
			world:removed(component, onViewerChange)
		end
	end

	--[=[
		Marks viewer keys for `ruleName` as stale, for rules whose viewer keys depend on more than
		the viewer's own components (team vision, say). nil refreshes every viewer.
	]=]
	function scope.invalidateViewerKeys(ruleName: string, playerEntity: number?)
		local rule = assert(ruleNames[ruleName], "unknown rule")
		for _, viewer in viewers do
			if playerEntity == nil or viewer.entity == playerEntity then
				dirtyViewerKeys[rule.index][viewer.index] = true
			end
		end
	end

	local function markEverything()
		for entity in states do
			dirtyScope[entity] = true
		end
	end

	function scope.addViewer(playerEntity: number): number
		assert(viewerOf[playerEntity] == nil, "player already connected")
		local index = nil
		for i = 0, MAX_VIEWERS - 1 do
			if viewers[i] == nil then
				index = i
				break
			end
		end
		assert(index ~= nil, "too many viewers")
		viewers[index] = {
			index = index,
			entity = playerEntity,
			pendingEnter = {},
			minted = {},
			rollbacks = {},
		}
		viewerOf[playerEntity] = index
		local bl, bh = bitOf(index)
		allLo, allHi = bit32.bor(allLo, bl), bit32.bor(allHi, bh)
		-- Memberships are read from the world, which is final outside hooks.
		local rooms = {}
		local i = 0
		while true do
			local room = world:target(playerEntity, Net.Member, i)
			if room == nil then
				break
			end
			rooms[room] = true
			i += 1
		end
		roomsOfPlayer[playerEntity] = rooms
		for room in rooms do
			refreshRoomBits(room)
		end
		for _, rule in rules do
			dirtyViewerKeys[rule.index][index] = true
		end
		-- A join can change anything's visibility (Public, ownership), so recompute everything once.
		markEverything()
		return index
	end

	function scope.removeViewer(playerEntity: number)
		local index = viewerOf[playerEntity]
		assert(index ~= nil, "player not connected")
		for _, rule in rules do
			setViewerKeys(rule, index, nil)
			dirtyViewerKeys[rule.index][index] = nil
		end
		viewers[index] = nil
		viewerOf[playerEntity] = nil
		local bl, bh = bitOf(index)
		local nl, nh = bit32.bnot(bl), bit32.bnot(bh)
		allLo, allHi = bit32.band(allLo, nl), bit32.band(allHi, nh)
		-- The connection is gone, so its delivered scope is dropped without messages.
		for _, state in states do
			state.delLo, state.delHi = bit32.band(state.delLo, nl), bit32.band(state.delHi, nh)
			state.ownerSentLo, state.ownerSentHi = bit32.band(state.ownerSentLo, nl), bit32.band(state.ownerSentHi, nh)
			state.pinLo, state.pinHi = bit32.band(state.pinLo, nl), bit32.band(state.pinHi, nh)
			if state.linger then
				state.linger[index] = nil
			end
		end
		local rooms = roomsOfPlayer[playerEntity] or {}
		roomsOfPlayer[playerEntity] = nil
		for room in rooms do
			refreshRoomBits(room)
		end
		markEverything()
	end

	function scope.viewerIndexOf(playerEntity: number): number?
		return viewerOf[playerEntity]
	end

	function scope.netIdOf(entity: number): number?
		local state = states[entity]
		return state and state.netId
	end

	function scope.entityOf(netId: number): number?
		return byNet[netId]
	end

	--[=[
		Prediction. A client predicted a spawn and minted `netId` in action `actionSeq`. If the server
		makes it, `bindMinted` gives it that net id and keeps the client in its scope (the owner pin)
		until `acknowledge`. If the action is acknowledged without the spawn, the client gets ROLLBACK.
	]=]
	function scope.clientMinted(playerEntity: number, actionSeq: number, netId: number)
		local viewer = viewers[assert(viewerOf[playerEntity], "player not connected")]
		local list = viewer.minted[actionSeq]
		if not list then
			list = {}
			viewer.minted[actionSeq] = list
		end
		table.insert(list, netId)
	end

	function scope.bindMinted(entity: number, playerEntity: number, netId: number)
		local state = assert(states[entity], "entity is not replicated")
		assert(byNet[netId] == nil or byNet[netId] == entity, "net id already in use")
		assert(state.delLo == 0 and state.delHi == 0, "bind the net id before the entity is delivered")
		byNet[state.netId] = nil
		state.netId = netId
		byNet[netId] = entity
		local viewerIndex = viewerOf[playerEntity]
		if viewerIndex ~= nil then
			local bl, bh = bitOf(viewerIndex)
			state.pinLo, state.pinHi = bit32.bor(state.pinLo, bl), bit32.bor(state.pinHi, bh)
			dirtyScope[entity] = true
		end
	end

	function scope.acknowledge(playerEntity: number, actionSeq: number)
		local viewer = viewers[assert(viewerOf[playerEntity], "player not connected")]
		local list = viewer.minted[actionSeq]
		viewer.minted[actionSeq] = nil
		local bl, bh = bitOf(viewer.index)
		local nl, nh = bit32.bnot(bl), bit32.bnot(bh)
		for _, netId in list or {} do
			local entity = byNet[netId]
			local state = if entity then states[entity] else nil
			if state then
				state.pinLo, state.pinHi = bit32.band(state.pinLo, nl), bit32.band(state.pinHi, nh)
				dirtyScope[state.entity] = true
			else
				table.insert(viewer.rollbacks, netId)
			end
		end
	end

	-- Scope computation.

	local inProgress: { [number]: boolean } = {}

	local function computeState(state: EntityState)
		if state.computedFrame == frameNumber then
			return
		end
		state.computedFrame = frameNumber
		local entity = state.entity
		inProgress[entity] = true

		local ownerLo, ownerHi = 0, 0
		local i = 0
		while true do
			local owner = world:target(entity, Net.Owner, i)
			if owner == nil then
				break
			end
			local viewerIndex = viewerOf[owner]
			if viewerIndex ~= nil then
				local bl, bh = bitOf(viewerIndex)
				ownerLo, ownerHi = bit32.bor(ownerLo, bl), bit32.bor(ownerHi, bh)
			end
			i += 1
		end
		state.ownerLo, state.ownerHi = ownerLo, ownerHi

		-- Grants.
		local authLo, authHi = 0, 0
		local relLo, relHi = allLo, allHi
		local through = world:target(entity, Net.VisibleThrough, 0)
		local parent = if through ~= nil then world:target(entity, through, 0) else nil
		if state.inheritParent ~= parent then
			if state.inheritParent then
				removeFromIndex(inheritors, state.inheritParent, entity)
			end
			if parent then
				addToIndex(inheritors, parent, entity)
			end
			state.inheritParent = parent
		end
		state.inheritDepth = 0
		if through ~= nil then
			local parentState = if parent then states[parent] else nil
			if parentState and inProgress[parentState.entity] then
				-- A VisibleThrough cycle.
				parentState = nil
			end
			if parentState then
				if dirtyScope[parent :: number] and parentState.computedFrame ~= frameNumber then
					computeState(parentState)
				end
				state.inheritDepth = parentState.inheritDepth + 1
			end
			if parentState and state.inheritDepth <= maxInheritDepth then
				-- Inherit the parent's viewers (and its relevance, so a group lingers and leaves
				-- together). This is a grant: own grants below are added to it, never replaced.
				authLo, authHi = parentState.authLo, parentState.authHi
				relLo, relHi = parentState.relLo, parentState.relHi
			else
				-- No replicated parent, a cycle, or too deep: the parent contributes nobody.
				state.inheritDepth = maxInheritDepth + 1
			end
		end
		if world:has(entity, Net.Public) then
			authLo, authHi = allLo, allHi
		else
			i = 0
			while true do
				local room = world:target(entity, Net.Audience, i)
				if room == nil then
					break
				end
				local bits = roomMembers[room]
				if bits then
					authLo, authHi = bit32.bor(authLo, bits.lo), bit32.bor(authHi, bits.hi)
				end
				i += 1
			end
			authLo, authHi = bit32.bor(authLo, ownerLo), bit32.bor(authHi, ownerHi)
		end

		-- Grant rules add viewers interested in the entity's key.
		for _, ruleIndex in state.rules do
			local rule = rules[ruleIndex]
			if rule.mode == "grant" then
				local key = state.ruleKeys[ruleIndex]
				local bits = if key ~= nil then rule.viewersByKey[key] else nil
				if bits then
					authLo, authHi = bit32.bor(authLo, bits.lo), bit32.bor(authHi, bits.hi)
				end
			end
		end

		-- Keep the room index current (Audience rooms and a VisibleTo room).
		local rooms: { [number]: boolean } = {}
		i = 0
		while true do
			local room = world:target(entity, Net.Audience, i)
			if room == nil then
				break
			end
			rooms[room] = true
			i += 1
		end

		-- Restrictions: the override, then the latched rules.
		if world:has(entity, Net.VisibleTo) then
			local value = world:get(entity, Net.VisibleTo)
			if value == "owner" then
				authLo, authHi = bit32.band(authLo, ownerLo), bit32.band(authHi, ownerHi)
			elseif type(value) == "number" then
				rooms[value] = true
				local bits = roomMembers[value]
				authLo = bit32.band(authLo, if bits then bits.lo else 0)
				authHi = bit32.band(authHi, if bits then bits.hi else 0)
			else
				-- "server", or anything unrecognized: fail closed.
				authLo, authHi = 0, 0
			end
		end
		for room in state.rooms do
			if not rooms[room] then
				removeFromIndex(entitiesOfRoom, room, entity)
			end
		end
		for room in rooms do
			if not state.rooms[room] then
				addToIndex(entitiesOfRoom, room, entity)
			end
		end
		state.rooms = rooms

		for _, ruleIndex in state.rules do
			local rule = rules[ruleIndex]
			if rule.mode ~= "grant" then
				local key = state.ruleKeys[ruleIndex]
				local bits = if key ~= nil then rule.viewersByKey[key] else nil
				local lo = if bits then bits.lo else 0
				local hi = if bits then bits.hi else 0
				if rule.mode == "relevance" then
					relLo, relHi = bit32.band(relLo, lo), bit32.band(relHi, hi)
				else
					authLo, authHi = bit32.band(authLo, lo), bit32.band(authHi, hi)
				end
			end
		end

		-- The owner pin keeps a minting client in scope until its spawn is acknowledged.
		authLo, authHi = bit32.bor(authLo, state.pinLo), bit32.bor(authHi, state.pinHi)
		relLo, relHi = bit32.bor(relLo, state.pinLo), bit32.bor(relHi, state.pinHi)

		state.authLo, state.authHi = bit32.band(authLo, allLo), bit32.band(authHi, allHi)
		state.relLo, state.relHi = bit32.band(relLo, allLo), bit32.band(relHi, allHi)
		inProgress[entity] = nil
	end

	-- Frame building.

	function scope.frame(): ({ [number]: { Message } }, FrameStats)
		frameNumber += 1
		local stats: FrameStats = {
			dirtyEntities = 0,
			enters = 0,
			ops = 0,
			pairs = 0,
			leaves = 0,
			dels = 0,
			rollbacks = 0,
			deferredEnters = 0,
		}
		local out: { [number]: { Message } } = {}
		local function emit(v: number, message: Message)
			local list = out[v]
			if not list then
				list = {}
				out[v] = list
			end
			table.insert(list, message)
		end

		-- 0. Settle what the hooks recorded.
		for entity in newlyReplicated do
			local state = states[entity]
			-- Latch the rules that apply now. They can't fall off later.
			for _, rule in rules do
				if world:has(entity, rule.appliesTo) then
					table.insert(state.rules, rule.index)
				end
			end
			for _, ruleIndex in state.rules do
				setEntityRuleKey(state, rules[ruleIndex])
			end
			-- An archetype default is a grant applied once, so it's visible in the world.
			for component in defaultPublic do
				if world:has(entity, component) and not world:has(entity, Net.Public) then
					world:add(entity, Net.Public)
					break
				end
			end
			for _, info in replicatedByKey do
				setRefs(state, info.key, refTargetsOf(info, entity))
			end
			setPairs(state, currentPairs(entity))
		end
		table.clear(newlyReplicated)

		if membershipDirty then
			membershipDirty = false
			local changedRooms: { [number]: boolean } = {}
			for _, viewer in viewers do
				local rooms = {}
				local i = 0
				while true do
					local room = world:target(viewer.entity, Net.Member, i)
					if room == nil then
						break
					end
					rooms[room] = true
					i += 1
				end
				local old = roomsOfPlayer[viewer.entity] or {}
				for room in rooms do
					if not old[room] then
						changedRooms[room] = true
					end
				end
				for room in old do
					if not rooms[room] then
						changedRooms[room] = true
					end
				end
				roomsOfPlayer[viewer.entity] = rooms
			end
			for room in changedRooms do
				refreshRoomBits(room)
			end
		end

		for entity, keys in dirtyComps do
			local state = states[entity]
			for key in keys do
				local info = replicatedByKey[key]
				if info.isRef or info.refFields then
					setRefs(state, key, refTargetsOf(info, entity))
				end
			end
		end

		-- Pair diffs since the last frame, before anything is entered.
		local pairDiffs: { [number]: { added: { { number } }, removed: { { number } } } } = {}
		for entity in dirtyPairs do
			local state = states[entity]
			local current = currentPairs(entity)
			local diff = { added = {}, removed = {} }
			for key, targets in state.pairs do
				for target in targets do
					if not (current[key] and current[key][target]) then
						table.insert(diff.removed, { key, target })
					end
				end
			end
			for key, targets in current do
				for target in targets do
					if not (state.pairs[key] and state.pairs[key][target]) then
						table.insert(diff.added, { key, target })
					end
				end
			end
			pairDiffs[entity] = diff
			setPairs(state, current)
		end

		-- 1. Rule keys: viewers, then entities.
		for _, rule in rules do
			local dirty = dirtyViewerKeys[rule.index]
			for v in dirty do
				local viewer = viewers[v]
				if viewer then
					setViewerKeys(rule, v, rule.viewerKeys(viewer.entity))
				end
			end
			table.clear(dirty)
		end
		for entity in dirtyRuleKeys do
			local state = states[entity]
			for _, ruleIndex in state.rules do
				setEntityRuleKey(state, rules[ruleIndex])
			end
		end
		table.clear(dirtyRuleKeys)

		-- 2. Spread dirtiness to inheritors (old and new parents' children alike).
		local queue = {}
		for entity in dirtyScope do
			table.insert(queue, entity)
		end
		local head = 1
		while head <= #queue do
			local entity = queue[head]
			head += 1
			for child in inheritors[entity] or {} do
				if not dirtyScope[child] then
					dirtyScope[child] = true
					table.insert(queue, child)
				end
			end
		end

		-- 3. Recompute, then turn changes into per-viewer transitions.
		local leaves: { [number]: { EntityState } } = {}
		local function leave(state: EntityState, v: number)
			local bl, bh = bitOf(v)
			local nl, nh = bit32.bnot(bl), bit32.bnot(bh)
			state.delLo, state.delHi = bit32.band(state.delLo, nl), bit32.band(state.delHi, nh)
			state.ownerSentLo = bit32.band(state.ownerSentLo, nl)
			state.ownerSentHi = bit32.band(state.ownerSentHi, nh)
			local linger = state.linger
			if linger then
				linger[v] = nil
				if next(linger) == nil then
					state.linger = nil
					lingering[state.entity] = nil
				end
			end
			local list = leaves[v]
			if not list then
				list = {}
				leaves[v] = list
			end
			table.insert(list, state)
		end

		for entity in dirtyScope do
			stats.dirtyEntities += 1
			computeState(states[entity])
		end
		for entity in dirtyScope do
			local state = states[entity]
			local inLo = bit32.band(state.authLo, state.relLo)
			local inHi = bit32.band(state.authHi, state.relHi)
			eachBit(bit32.band(inLo, bit32.bnot(state.delLo)), bit32.band(inHi, bit32.bnot(state.delHi)), function(v)
				viewers[v].pendingEnter[entity] = true
			end)
			for _, viewer in viewers do
				if viewer.pendingEnter[entity] and not hasBit(inLo, inHi, viewer.index) then
					viewer.pendingEnter[entity] = nil
				end
			end
			-- Delivered but out of scope: revoke now, or linger if only relevance failed.
			eachBit(bit32.band(state.delLo, bit32.bnot(inLo)), bit32.band(state.delHi, bit32.bnot(inHi)), function(v)
				if not hasBit(state.authLo, state.authHi, v) then
					leave(state, v)
				else
					local linger = state.linger
					if not linger then
						linger = {}
						state.linger = linger
					end
					if linger[v] == nil then
						-- +1 because the countdown below also runs this frame.
						linger[v] = hysteresisFrames + 1
						lingering[entity] = true
					end
				end
			end)
			local linger = state.linger
			if linger then
				for v in linger do
					if hasBit(inLo, inHi, v) then
						linger[v] = nil
					end
				end
				if next(linger) == nil then
					state.linger = nil
					lingering[entity] = nil
				end
			end
		end

		-- 4. Countdowns for relevance-only exits.
		for entity in lingering do
			local state = states[entity]
			local linger = state.linger :: { [number]: number }
			for v, framesLeft in linger do
				if framesLeft <= 1 then
					leave(state, v)
				else
					linger[v] = framesLeft - 1
				end
			end
		end

		-- 5. Per viewer: ENTER, ops, pairs, LEAVE.
		local enteredAny: { [number]: boolean } = {}

		for _, viewer in viewers do
			local v = viewer.index
			local bl, bh = bitOf(v)
			local enteredNow: { [number]: boolean } = {}
			local leavingNow: { [number]: boolean } = {}
			for _, state in leaves[v] or {} do
				leavingNow[state.entity] = true
			end

			-- ENTER. Candidates are grouped under their inheritance root; groups are ordered so that
			-- reference targets come before referrers, parents come before inheritors inside a group,
			-- and a group is never split by the budget.
			local candidates = viewer.pendingEnter
			local groups: { { EntityState } } = {}
			local groupOfRoot: { [number]: { EntityState } } = {}
			local rootOf: { [number]: number } = {}
			local function findRoot(entity: number): number
				local cached = rootOf[entity]
				if cached then
					return cached
				end
				local parent = states[entity].inheritParent
				local root = if parent ~= nil
						and candidates[parent]
						and parent ~= entity
					then findRoot(parent)
					else entity
				rootOf[entity] = root
				return root
			end
			for entity in candidates do
				local root = findRoot(entity)
				local group = groupOfRoot[root]
				if not group then
					group = {}
					groupOfRoot[root] = group
					table.insert(groups, group)
				end
				table.insert(group, states[entity])
			end
			for _, group in groups do
				table.sort(group, function(a, b)
					if a.inheritDepth ~= b.inheritDepth then
						return a.inheritDepth < b.inheritDepth
					end
					return a.netId < b.netId
				end)
			end
			table.sort(groups, function(a, b)
				return a[1].netId < b[1].netId
			end)
			local groupIndexOf: { [number]: number } = {}
			for i, group in groups do
				for _, state in group do
					groupIndexOf[state.entity] = i
				end
			end
			local order: { number } = {}
			local visited: { [number]: boolean } = {}
			local function visit(i: number)
				if visited[i] then
					return
				end
				visited[i] = true
				for _, state in groups[i] do
					for _, targets in state.refs do
						for _, target in targets do
							local j = groupIndexOf[target]
							if j then
								visit(j)
							end
						end
					end
				end
				table.insert(order, i)
			end
			for i in groups do
				visit(i)
			end

			local count = 0
			for _, i in order do
				local group = groups[i]
				if enterBudget and count > 0 and count + #group > enterBudget then
					stats.deferredEnters += #group
					continue
				end
				for _, state in group do
					local entity = state.entity
					candidates[entity] = nil
					state.delLo, state.delHi = bit32.bor(state.delLo, bl), bit32.bor(state.delHi, bh)
					enteredNow[entity] = true
					enteredAny[entity] = true
					local isOwner = hasBit(state.ownerLo, state.ownerHi, v)
					if isOwner then
						state.ownerSentLo, state.ownerSentHi =
							bit32.bor(state.ownerSentLo, bl), bit32.bor(state.ownerSentHi, bh)
					end
					local comps = {}
					for _, info in replicatedByKey do
						if (info.visibleTo == "all" or isOwner) and world:has(entity, info.component) then
							comps[info.key] = wireValue(info, world:get(entity, info.component), v)
						end
					end
					emit(v, { "ENTER", state.netId, comps })
					stats.enters += 1
					count += 1
				end
			end

			-- Ops for entities this viewer already had.
			local resend: { [number]: { [number]: boolean } } = {}
			local function queueResend(entity: number, key: number)
				local state = states[entity]
				if enteredNow[entity] or not hasBit(state.delLo, state.delHi, v) then
					return
				end
				local set = resend[entity]
				if not set then
					set = {}
					resend[entity] = set
				end
				set[key] = true
			end
			for entity, keys in dirtyComps do
				for key in keys do
					queueResend(entity, key)
				end
			end
			-- References to entities that just entered can go out unredacted now, and references
			-- to entities leaving now must be redacted before the LEAVE.
			for target in enteredNow do
				for referrer, keys in refsTo[target] or {} do
					for key in keys do
						queueResend(referrer, key)
					end
				end
			end
			for target in gone do
				for referrer, keys in refsTo[target] or {} do
					for key in keys do
						queueResend(referrer, key)
					end
				end
			end
			for target in leavingNow do
				for referrer, keys in refsTo[target] or {} do
					if not leavingNow[referrer] then
						for key in keys do
							queueResend(referrer, key)
						end
					end
				end
			end
			for entity, keys in resend do
				local state = states[entity]
				local isOwner = hasBit(state.ownerLo, state.ownerHi, v)
				for key in keys do
					local info = replicatedByKey[key]
					if info.visibleTo == "all" or isOwner then
						if world:has(entity, info.component) then
							emit(v, { "SET", state.netId, key, wireValue(info, world:get(entity, info.component), v) })
							stats.ops += 1
						elseif state.sent[key] then
							emit(v, { "REM", state.netId, key })
							stats.ops += 1
						end
					end
				end
			end
			-- Ownership changed for an entity this viewer had: owner-only components come or go.
			for entity in dirtyScope do
				local state = states[entity]
				if not enteredNow[entity] and not leavingNow[entity] and hasBit(state.delLo, state.delHi, v) then
					local isOwner = hasBit(state.ownerLo, state.ownerHi, v)
					if isOwner ~= hasBit(state.ownerSentLo, state.ownerSentHi, v) then
						for _, info in replicatedByKey do
							if info.visibleTo == "owner" and not (resend[entity] and resend[entity][info.key]) then
								if isOwner and world:has(entity, info.component) then
									emit(v, {
										"SET",
										state.netId,
										info.key,
										wireValue(info, world:get(entity, info.component), v),
									})
									stats.ops += 1
								elseif not isOwner and state.sent[info.key] then
									emit(v, { "REM", state.netId, info.key })
									stats.ops += 1
								end
							end
						end
						if isOwner then
							state.ownerSentLo, state.ownerSentHi =
								bit32.bor(state.ownerSentLo, bl), bit32.bor(state.ownerSentHi, bh)
						else
							state.ownerSentLo = bit32.band(state.ownerSentLo, bit32.bnot(bl))
							state.ownerSentHi = bit32.band(state.ownerSentHi, bit32.bnot(bh))
						end
					end
				end
			end

			-- Pairs, from three disjoint sources:
			--  a) the subject just entered: all its pairs to targets this viewer has;
			--  b) the target just entered (subject already here): pairs pointing at it;
			--  c) neither entered: this frame's changes, when both ends are here.
			local function has(entity: number): boolean
				local state = states[entity]
				return state ~= nil and hasBit(state.delLo, state.delHi, v)
			end
			for entity in enteredNow do
				local state = states[entity]
				for key, targets in state.pairs do
					for target in targets do
						if has(target) then
							emit(v, { "PAIR_ADD", state.netId, key, states[target].netId })
							stats.pairs += 1
						end
					end
				end
				for referrer, keys in pairsTo[entity] or {} do
					if has(referrer) and not enteredNow[referrer] then
						for key in keys do
							emit(v, { "PAIR_ADD", states[referrer].netId, key, state.netId })
							stats.pairs += 1
						end
					end
				end
			end
			for entity, diff in pairDiffs do
				if has(entity) and not enteredNow[entity] then
					local netId = states[entity].netId
					for _, item in diff.removed do
						local target = item[2]
						if has(target) and not enteredNow[target] then
							emit(v, { "PAIR_REM", netId, item[1], states[target].netId })
							stats.pairs += 1
						end
					end
					for _, item in diff.added do
						local target = item[2]
						if has(target) and not enteredNow[target] then
							emit(v, { "PAIR_ADD", netId, item[1], states[target].netId })
							stats.pairs += 1
						end
					end
				end
			end

			-- LEAVE. The client forgets the entity and strips pairs to it, without cleanup traits.
			for _, state in leaves[v] or {} do
				emit(v, { "LEAVE", state.netId })
				stats.leaves += 1
			end
		end

		-- 6. Entities no longer replicated (LEAVE) or destroyed (DEL), only to clients that had them.
		for _, item in unreplicated do
			-- Destroyed after it stopped replicating: that's a DEL by the time it's sent.
			if not world:contains(item.entity) then
				table.insert(deleted, item)
				continue
			end
			eachBit(item.delLo, item.delHi, function(v)
				if viewers[v] then
					emit(v, { "LEAVE", item.netId })
					stats.leaves += 1
				end
			end)
		end
		table.clear(unreplicated)
		for _, item in deleted do
			eachBit(item.delLo, item.delHi, function(v)
				if viewers[v] then
					emit(v, { "DEL", item.netId })
					stats.dels += 1
				end
			end)
		end
		table.clear(deleted)

		-- 7. ROLLBACK for predicted spawns the server didn't make.
		for _, viewer in viewers do
			for _, netId in viewer.rollbacks do
				emit(viewer.index, { "ROLLBACK", netId })
				stats.rollbacks += 1
			end
			table.clear(viewer.rollbacks)
		end

		-- Remember which components are present, for next frame's REM decisions.
		local function snapshot(entity: number)
			local state = states[entity]
			for _, info in replicatedByKey do
				state.sent[info.key] = if world:has(entity, info.component) then true else nil
			end
		end
		for entity in dirtyComps do
			snapshot(entity)
		end
		for entity in enteredAny do
			snapshot(entity)
		end

		table.clear(dirtyScope)
		table.clear(dirtyComps)
		table.clear(dirtyPairs)
		table.clear(gone)
		return out, stats
	end

	-- Introspection, for tests and tools.

	function scope.deliveredTo(v: number): { [number]: boolean }
		local result = {}
		for entity, state in states do
			if hasBit(state.delLo, state.delHi, v) then
				result[entity] = true
			end
		end
		return result
	end

	function scope.scopeBits(entity: number): (number, number, number, number)
		local state = states[entity]
		if not state then
			return 0, 0, 0, 0
		end
		return state.authLo, state.authHi, state.relLo, state.relHi
	end

	function scope.isLingering(entity: number, v: number): boolean
		local state = states[entity]
		return state ~= nil and state.linger ~= nil and state.linger[v] ~= nil
	end

	function scope.isPendingEnter(entity: number, v: number): boolean
		local viewer = viewers[v]
		return viewer ~= nil and viewer.pendingEnter[entity] == true
	end

	function scope.replicatedComponents(): { ReplicatedComponent }
		return replicatedByKey
	end

	function scope.relationList(): { number }
		return relations
	end

	function scope.viewerList(): { [number]: Viewer }
		return viewers
	end

	return scope
end

return StatuhScope
