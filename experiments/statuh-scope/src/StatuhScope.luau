--!strict
--[[
	StatuhScope: a prototype of Statuh 2.0's selective-replication core. Experiment only, no
	networking. Give it a jecs world and connected players; each `frame()` returns, per client, the
	messages that client should receive, in the fixed order

		ENTER, ops (SET/HIDE/REM), pairs (PAIR_REM/PAIR_ADD), LEAVE, DEL, ROLLBACK

	Visibility is decided by principals (../DESIGN.md has the rest):
	- A viewer holds principals: everyone (ALL), its own player entity, and the rooms it's a member
	  of (pair(Net.Member, room)). Each scope rule is a space of its own principals (cells, chunks),
	  and its viewerKeys say which ones a viewer holds.
	- An entity is granted to principals: ALL when it has Net.Public, its pair(Net.Audience, room)
	  rooms, its pair(Net.Owner, player) owners, and its key under each grant rule. It is also
	  granted to whoever sees the entity named by its pair(Net.VisibleThrough, target).
	- An entity can need principals: Net.VisibleTo ("owner", a room, or "server" for nobody), and
	  its key under each restrict rule. A viewer must hold one principal of every need.
	- A component can have a need of its own: its entity's owners ("owner"), or its entity's key
	  under a rule. A client that loses one that still exists gets HIDE; one that's gone, REM.
	Nothing granted means nobody sees it (fail closed), and visibility only grows when a grant is
	added or a need removed. Scope is permission only: losing it is a LEAVE that frame.

	A client never gets a net id it doesn't have: references to entities it lacks are REDACTED and
	re-sent when the target enters, and pairs are only sent while both ends are delivered. When a
	client loses an entity, it strips pairs to it and redacts its own references to it.

	Hooks on the jecs world only mark things dirty; all reading happens in `frame()`. The core takes
	`jecs` as an argument instead of requiring it, so the same file runs under the headless test
	runner, Lune's native require, and codegen-enabled `luau.load` for benchmarks.
]]

local StatuhScope = {}

export type ReplicateOptions = {
	-- "all" (the default), "owner", or the name of a scope rule (added first): which of the
	-- clients that have the entity also get this component.
	visibleTo: string?,
	-- Entity references in the value: true when the whole value is one, or the fields that are.
	refs: (boolean | { string })?,
}

export type ScopeRule = {
	-- How the entities it applies to use it: "grant" adds the viewers holding the entity's key,
	-- "restrict" needs one.
	mode: "grant" | "restrict",
	-- The entity's key, a principal in this rule's space. nil matches nobody.
	key: (entity: number) -> any,
	-- The keys a viewer holds, from its player entity.
	viewerKeys: (viewerEntity: number) -> { [any]: boolean },
	-- Components whose changes change an entity's key, and a viewer's keys.
	dependsOn: { number },
	viewerDependsOn: { number }?,
	-- Entities with this component when they start replicating are subject to the rule, for life.
	-- Leave it out for a rule that's only a component's visibleTo.
	appliesTo: number?,
}

export type Message = { any }

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

StatuhScope.hasBit = hasBit

-- The wire stand-in for a reference to an entity the receiver doesn't have.
local REDACTED = table.freeze({ redacted = true })
StatuhScope.REDACTED = REDACTED

--[=[
	Returns `value` with every entity reference in it replaced by `fn(reference)`. `refs` is true
	when the whole value is a reference, or the fields that are. Shared by the core, the client
	replica and the tests, so they all agree on what a reference is.
]=]
function StatuhScope.mapRefs(refs: (boolean | { string })?, value: any, fn: (any) -> any): any
	if value == nil or not refs then
		return value
	elseif refs == true then
		return fn(value)
	elseif type(value) ~= "table" then
		return value
	end
	local copy = table.clone(value)
	for _, field in refs :: { string } do
		if copy[field] ~= nil then
			copy[field] = fn(copy[field])
		end
	end
	return copy
end

-- Iterates a table that may be nil (the old solver can't iterate `t or {}`).
local function orEmpty<K, V>(t: { [K]: V }?): { [K]: V }
	return (t or {}) :: any
end

local function addToIndex(index: { [any]: { [any]: boolean } }, key: any, value: any)
	local set = index[key]
	if not set then
		set = {}
		index[key] = set
	end
	set[value] = true
end

local function removeFromIndex(index: { [any]: { [any]: boolean } }, key: any, value: any)
	local set = index[key]
	if set then
		set[value] = nil
		if next(set) == nil then
			index[key] = nil
		end
	end
end

-- The principal every viewer holds.
local ALL = table.freeze({ all = true })

type Bits = { lo: number, hi: number }
type PairSet = { [number]: { [number]: boolean } } -- relation key -> targets

-- Who holds which principals: the built-in space (ALL, players, rooms), or a rule's.
type Space = {
	holders: { [any]: Bits },
	heldBy: { [number]: { [any]: boolean } }, -- viewer index -> the principals it holds
	watchers: { [any]: { [number]: boolean } }, -- principal -> entities whose scope mentions it
	principalsOf: (viewerEntity: number) -> { [any]: boolean },
	stale: { [number]: boolean }, -- viewers whose principals must be read again
}

-- A viewer that holds any of these principals.
type Need = { space: Space, principals: { any } }

type Rule = ScopeRule & { name: string, space: Space }

type ReplicatedComponent = {
	key: number,
	component: number,
	visibleTo: string,
	rule: Rule?,
	refs: (boolean | { string })?,
}

type EntityState = {
	entity: number,
	netId: number,
	-- Latched when replication started.
	rules: { Rule },
	-- Read from the world when the entity is dirty.
	grants: { Need },
	needs: { Need },
	componentNeeds: { [number]: Need }, -- component key -> its need (visibility other than "all")
	pin: Need, -- clients that minted this net id and haven't acknowledged the spawn
	parent: number?, -- the VisibleThrough target
	pairs: PairSet, -- as of the last frame
	refs: { [number]: { number } }, -- component key -> reference targets, as of the last frame
	-- Viewer sets: own grants, needs and pin; authorized (after inheritance); delivered; waiting to
	-- ENTER; and per component key, the clients holding it.
	grantLo: number,
	grantHi: number,
	needLo: number,
	needHi: number,
	pinLo: number,
	pinHi: number,
	authLo: number,
	authHi: number,
	delLo: number,
	delHi: number,
	pendLo: number,
	pendHi: number,
	heldLo: { [number]: number },
	heldHi: { [number]: number },
}

type Viewer = {
	index: number,
	entity: number,
	pendingEnter: { [number]: boolean },
	minted: { [number]: { number } }, -- action sequence -> net ids this client minted
	rollbacks: { number },
}

local function newSpace(principalsOf: (number) -> { [any]: boolean }): Space
	return { holders = {}, heldBy = {}, watchers = {}, principalsOf = principalsOf, stale = {} }
end

function StatuhScope.new(jecs: any, world: any, config: { enterBudget: number? }?)
	-- Max entities ENTERed per client per frame. Inheritance groups are never split, so a frame
	-- may go over this to fit its first group. nil means unlimited.
	local enterBudget = config and config.enterBudget

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
	-- One VisibleThrough target per entity, so removing a pair can never promote another.
	world:add(Net.VisibleThrough, jecs.Exclusive)

	local states: { [number]: EntityState } = {}
	local byNet: { [number]: number } = {}
	local nextNetId = 1

	local viewers: { [number]: Viewer } = {}
	local viewerOf: { [number]: number } = {}
	local allLo, allHi = 0, 0

	local replicatedByKey: { ReplicatedComponent } = {}
	local restricted: { ReplicatedComponent } = {} -- the ones whose visibility isn't "all"
	local relations: { number } = {} -- relation key -> relation
	local defaultPublic: { [number]: boolean } = {}
	local rules: { [string]: Rule } = {}

	-- Reverse indexes: parent -> inheritors, and target -> entities referring or paired to it.
	local inheritors: { [number]: { [number]: boolean } } = {}
	local refsTo: { [number]: { [number]: boolean } } = {}
	local pairsTo: { [number]: { [number]: boolean } } = {}

	-- dirty: read the entity's scope and pairs from the world again. dirtyScope: recompute who
	-- it's visible to. dirtyComps: component values that changed.
	local newlyReplicated: { [number]: boolean } = {}
	local dirty: { [number]: boolean } = {}
	local dirtyScope: { [number]: boolean } = {}
	local dirtyComps: { [number]: { [number]: boolean } } = {}
	-- Entities that stopped replicating since the last frame: LEAVE if alive, DEL if destroyed.
	local removed: { { netId: number, delLo: number, delHi: number, entity: number } } = {}

	local scope = { Net = Net, REDACTED = REDACTED, jecs = jecs }

	local function targetsOf(entity: number, relation: number): { number }
		local list = {}
		while true do
			local target = world:target(entity, relation, #list)
			if target == nil then
				return list
			end
			table.insert(list, target)
		end
	end

	-- The built-in space: every viewer holds ALL, its player entity and its rooms.
	local identity = newSpace(function(player)
		local principals: { [any]: boolean } = { [ALL] = true, [player] = true }
		for _, room in targetsOf(player, Net.Member) do
			principals[room] = true
		end
		return principals
	end)
	local spaces: { Space } = { identity }

	local function touch(entity: number)
		if states[entity] then
			dirty[entity] = true
		end
	end

	-- Viewers holding principals.

	local function setPrincipals(space: Space, v: number, new: { [any]: boolean }?)
		local old = orEmpty(space.heldBy[v])
		local now = orEmpty(new)
		local bl, bh = bitOf(v)
		local function flip(principal: any, held: boolean)
			local bits: Bits = space.holders[principal] or { lo = 0, hi = 0 }
			if held then
				bits.lo, bits.hi = bit32.bor(bits.lo, bl), bit32.bor(bits.hi, bh)
			else
				bits.lo, bits.hi = bit32.band(bits.lo, bit32.bnot(bl)), bit32.band(bits.hi, bit32.bnot(bh))
			end
			space.holders[principal] = if bits.lo == 0 and bits.hi == 0 then nil :: any else bits
			for entity in orEmpty(space.watchers[principal]) do
				dirtyScope[entity] = true
			end
		end
		for principal in old do
			if not now[principal] then
				flip(principal, false)
			end
		end
		for principal in now do
			if not old[principal] then
				flip(principal, true)
			end
		end
		space.heldBy[v] = if next(now) then table.clone(now) else nil :: any
	end

	local function anyHolder(need: Need): (number, number)
		local lo, hi = 0, 0
		for _, principal in need.principals do
			local bits = need.space.holders[principal]
			if bits then
				lo, hi = bit32.bor(lo, bits.lo), bit32.bor(hi, bits.hi)
			end
		end
		return lo, hi
	end

	-- Entities' scope, read from the world.

	local function ruleNeed(rule: Rule, entity: number): Need
		local key = rule.key(entity)
		return { space = rule.space, principals = if key ~= nil then { key } else {} }
	end

	local function watch(state: EntityState, add: boolean)
		local function each(need: Need)
			for _, principal in need.principals do
				if add then
					addToIndex(need.space.watchers, principal, state.entity)
				else
					removeFromIndex(need.space.watchers, principal, state.entity)
				end
			end
		end
		for _, list in { state.grants, state.needs, state.componentNeeds } do
			for _, need in list do
				each(need)
			end
		end
		each(state.pin)
		if state.parent then
			if add then
				addToIndex(inheritors, state.parent, state.entity)
			else
				removeFromIndex(inheritors, state.parent, state.entity)
			end
		end
	end

	local function readScope(state: EntityState)
		local entity = state.entity
		watch(state, false)
		local owners = targetsOf(entity, Net.Owner)
		local granted: { any } = targetsOf(entity, Net.Audience)
		table.move(owners, 1, #owners, #granted + 1, granted)
		if world:has(entity, Net.Public) then
			table.insert(granted, ALL)
		end
		state.grants = { { space = identity, principals = granted } }
		state.needs = {}
		if world:has(entity, Net.VisibleTo) then
			local value = world:get(entity, Net.VisibleTo)
			local principals = if value == "owner" then owners elseif type(value) == "number" then { value } else {}
			table.insert(state.needs, { space = identity, principals = principals })
		end
		for _, rule in state.rules do
			table.insert(if rule.mode == "grant" then state.grants else state.needs, ruleNeed(rule, entity))
		end
		state.componentNeeds = {}
		for _, info in restricted do
			state.componentNeeds[info.key] = if info.rule
				then ruleNeed(info.rule, entity)
				else { space = identity, principals = owners }
		end
		state.parent = world:target(entity, Net.VisibleThrough, 0)
		watch(state, true)
		dirtyScope[entity] = true
	end

	local function indexTargets(index: { [number]: { [number]: boolean } }, entity: number, map: any, add: boolean)
		for _, targets in map do
			for k, v in targets do
				-- Pair sets map target -> true; ref lists map position -> target.
				local target = if v == true then k else v
				if add then
					addToIndex(index, target, entity)
				else
					removeFromIndex(index, target, entity)
				end
			end
		end
	end

	local function currentPairs(entity: number): PairSet
		local result = {}
		for key, relation in relations do
			for _, target in targetsOf(entity, relation) do
				result[key] = result[key] or {}
				result[key][target] = true
			end
		end
		return result
	end

	local function readRefs(state: EntityState, info: ReplicatedComponent)
		local targets: { number } = {}
		if world:has(state.entity, info.component) then
			StatuhScope.mapRefs(info.refs, world:get(state.entity, info.component), function(ref)
				table.insert(targets, ref)
				return ref
			end)
		end
		indexTargets(refsTo, state.entity, state.refs, false)
		state.refs[info.key] = if #targets > 0 then targets else nil :: any
		indexTargets(refsTo, state.entity, state.refs, true)
	end

	-- Inheritance: final(e) = (grants(e) | final(parent)) & needs(e), following VisibleThrough up
	-- from the entity and stopping at an entity already visited. Removing a link only drops terms
	-- from the union, so it can't widen anything; a loop shares its members' grants.
	local chain: { EntityState } = {}
	local onChain: { [EntityState]: boolean } = {}
	local function computeAuth(state: EntityState)
		table.clear(chain)
		table.clear(onChain)
		chain[1], onChain[state] = state, true
		while true do
			local parent = chain[#chain].parent
			local parentState = if parent ~= nil then states[parent] else nil
			if not parentState or onChain[parentState] then
				break
			end
			table.insert(chain, parentState)
			onChain[parentState] = true
		end
		local lo, hi = 0, 0
		for i = #chain, 1, -1 do
			local link = chain[i]
			lo = bit32.band(bit32.bor(link.grantLo, lo), link.needLo)
			hi = bit32.band(bit32.bor(link.grantHi, hi), link.needHi)
		end
		-- The pin keeps a minting client in scope until its spawn is acknowledged.
		state.authLo = bit32.band(bit32.bor(lo, state.pinLo), allLo)
		state.authHi = bit32.band(bit32.bor(hi, state.pinHi), allHi)
	end

	-- Clients that may see the component, before "has the entity" is taken into account.
	local function visibleBits(state: EntityState, info: ReplicatedComponent): (number, number)
		local need = state.componentNeeds[info.key]
		if need then
			return anyHolder(need)
		end
		return allLo, allHi
	end

	local function isHeld(state: EntityState, key: number, v: number): boolean
		return hasBit(state.heldLo[key] or 0, state.heldHi[key] or 0, v)
	end

	local function setHeld(state: EntityState, key: number, v: number, held: boolean)
		local bl, bh = bitOf(v)
		local lo, hi = state.heldLo[key] or 0, state.heldHi[key] or 0
		if held then
			lo, hi = bit32.bor(lo, bl), bit32.bor(hi, bh)
		else
			lo, hi = bit32.band(lo, bit32.bnot(bl)), bit32.band(hi, bit32.bnot(bh))
		end
		state.heldLo[key] = if lo ~= 0 then lo else nil :: any
		state.heldHi[key] = if hi ~= 0 then hi else nil :: any
	end

	-- The client lost the whole entity, so it holds none of its components either.
	local function forgetViewerBits(state: EntityState, nl: number, nh: number)
		state.delLo, state.delHi = bit32.band(state.delLo, nl), bit32.band(state.delHi, nh)
		for key, lo in state.heldLo do
			state.heldLo[key] = if bit32.band(lo, nl) ~= 0 then bit32.band(lo, nl) else nil :: any
		end
		for key, hi in state.heldHi do
			state.heldHi[key] = if bit32.band(hi, nh) ~= 0 then bit32.band(hi, nh) else nil :: any
		end
	end

	-- What goes on the wire for a component value, for viewer `v`, given what it has right now.
	local function wireValue(info: ReplicatedComponent, value: any, v: number): any
		return StatuhScope.mapRefs(info.refs, value, function(ref)
			local target = states[ref]
			return if target and hasBit(target.delLo, target.delHi, v) then target.netId else REDACTED
		end)
	end

	-- Entity lifecycle.

	world:added(Net.Replicated, function(entity)
		if states[entity] then
			return
		end
		local netId = nextNetId
		nextNetId += 1
		states[entity] = {
			entity = entity,
			netId = netId,
			rules = {},
			grants = {},
			needs = {},
			componentNeeds = {},
			pin = { space = identity, principals = {} },
			parent = nil,
			pairs = {},
			refs = {},
			grantLo = 0,
			grantHi = 0,
			needLo = 0,
			needHi = 0,
			pinLo = 0,
			pinHi = 0,
			authLo = 0,
			authHi = 0,
			delLo = 0,
			delHi = 0,
			pendLo = 0,
			pendHi = 0,
			heldLo = {},
			heldHi = {},
		}
		byNet[netId] = entity
		newlyReplicated[entity] = true
		dirty[entity] = true
	end)

	world:removed(Net.Replicated, function(entity)
		local state = states[entity]
		if not state then
			return
		end
		watch(state, false)
		indexTargets(refsTo, entity, state.refs, false)
		indexTargets(pairsTo, entity, state.pairs, false)
		for child in orEmpty(inheritors[entity]) do
			dirtyScope[child] = true
		end
		eachBit(state.pendLo, state.pendHi, function(v)
			viewers[v].pendingEnter[entity] = nil
		end)
		states[entity] = nil
		byNet[state.netId] = nil
		newlyReplicated[entity], dirty[entity], dirtyScope[entity], dirtyComps[entity] = nil, nil, nil, nil
		table.insert(removed, { netId = state.netId, delLo = state.delLo, delHi = state.delHi, entity = entity })
	end)

	for _, id in { Net.Public, Net.Audience, Net.Owner, Net.VisibleThrough, Net.VisibleTo } do
		world:added(id, touch)
		world:removed(id, touch)
	end
	world:changed(Net.VisibleTo, touch)

	-- Memberships are read at the next frame: the pair isn't final inside the hook.
	local function onMembership(player: number)
		local v = viewerOf[player]
		if v ~= nil then
			identity.stale[v] = true
		end
	end
	world:added(Net.Member, onMembership)
	world:removed(Net.Member, onMembership)

	-- Public API.

	--[=[
		Declares a replicated component. `visibleTo` narrows it below the entity: "owner" sends it
		only to the entity's owners, and a rule's name only to the clients holding the entity's key
		under that rule. `refs` marks entity references, redacted for clients without the target.
	]=]
	function scope.replicate(component: number, options: ReplicateOptions?): number
		local visibleTo = options and options.visibleTo or "all"
		local rule: Rule? = nil
		if visibleTo ~= "all" and visibleTo ~= "owner" then
			rule = rules[visibleTo]
			assert(rule ~= nil, `visibleTo = "{visibleTo}" names no rule; add the rule first`)
		end
		local info: ReplicatedComponent = {
			key = #replicatedByKey + 1,
			component = component,
			visibleTo = visibleTo,
			rule = rule,
			refs = options and options.refs,
		}
		table.insert(replicatedByKey, info)
		if visibleTo ~= "all" then
			table.insert(restricted, info)
			for entity in states do
				dirty[entity] = true
			end
		end
		local function onChange(entity: number)
			if states[entity] then
				local keys = dirtyComps[entity] or {}
				dirtyComps[entity] = keys
				keys[info.key] = true
			end
		end
		world:added(component, onChange)
		world:changed(component, onChange)
		world:removed(component, onChange)
		return info.key
	end

	--[=[
		Declares a relation whose pairs replicate as data (e.g. jecs.ChildOf), sent while both ends
		are delivered. It never affects who sees what; pair(Net.VisibleThrough, target) does that.
	]=]
	function scope.replicateRelation(relation: number): number
		table.insert(relations, relation)
		world:added(relation, touch)
		world:removed(relation, touch)
		return #relations
	end

	-- Entities with `component` when they start replicating get Net.Public, once.
	function scope.setDefaultPublic(component: number)
		defaultPublic[component] = true
	end

	--[=[
		Adds a scope rule: a space of principals (the keys), which entities are granted to or need.
		Add rules before the entities they apply to start replicating.
	]=]
	function scope.addScopeRule(name: string, definition: ScopeRule)
		assert(rules[name] == nil, `rule {name} already exists`)
		assert(definition.mode == "grant" or definition.mode == "restrict", "mode is grant or restrict")
		local rule: Rule = table.clone(definition) :: any
		rule.name = name
		rule.space = newSpace(definition.viewerKeys)
		rules[name] = rule
		table.insert(spaces, rule.space)
		for v in viewers do
			rule.space.stale[v] = true
		end
		for _, component in definition.dependsOn do
			world:added(component, touch)
			world:changed(component, touch)
			world:removed(component, touch)
		end
		local function onViewerChange(entity: number)
			local v = viewerOf[entity]
			if v ~= nil then
				rule.space.stale[v] = true
			end
		end
		for _, component in orEmpty(definition.viewerDependsOn) do
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
		local rule = assert(rules[ruleName], "unknown rule")
		for v, viewer in viewers do
			if playerEntity == nil or viewer.entity == playerEntity then
				rule.space.stale[v] = true
			end
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
		viewers[index] = { index = index, entity = playerEntity, pendingEnter = {}, minted = {}, rollbacks = {} }
		viewerOf[playerEntity] = index
		local bl, bh = bitOf(index)
		allLo, allHi = bit32.bor(allLo, bl), bit32.bor(allHi, bh)
		for _, space in spaces do
			space.stale[index] = true
		end
		return index
	end

	function scope.removeViewer(playerEntity: number)
		local index = assert(viewerOf[playerEntity], "player not connected")
		for _, space in spaces do
			setPrincipals(space, index, nil)
			space.stale[index] = nil
		end
		viewers[index] = nil
		viewerOf[playerEntity] = nil
		local bl, bh = bitOf(index)
		local nl, nh = bit32.bnot(bl), bit32.bnot(bh)
		allLo, allHi = bit32.band(allLo, nl), bit32.band(allHi, nh)
		-- The connection is gone, so its delivered scope is dropped without messages, including
		-- removals queued for the next frame (another player may get this index before then).
		for _, item in removed do
			item.delLo, item.delHi = bit32.band(item.delLo, nl), bit32.band(item.delHi, nh)
		end
		for _, state in states do
			forgetViewerBits(state, nl, nh)
			state.pendLo, state.pendHi = bit32.band(state.pendLo, nl), bit32.band(state.pendHi, nh)
		end
	end

	function scope.viewerIndexOf(playerEntity: number): number?
		return viewerOf[playerEntity]
	end

	function scope.netIdOf(entity: number): number?
		local state = states[entity]
		return state and state.netId
	end

	--[=[
		Prediction. A client predicted a spawn and minted `netId` in action `actionSeq`. If the server
		makes it, `bindMinted` gives it that net id and keeps the client in its scope (the pin)
		until `acknowledge`. If the action is acknowledged without the spawn, the client gets ROLLBACK.
	]=]
	function scope.clientMinted(playerEntity: number, actionSeq: number, netId: number)
		local viewer = viewers[assert(viewerOf[playerEntity], "player not connected")]
		viewer.minted[actionSeq] = viewer.minted[actionSeq] or {}
		table.insert(viewer.minted[actionSeq], netId)
	end

	function scope.bindMinted(entity: number, playerEntity: number, netId: number)
		local state = assert(states[entity], "entity is not replicated")
		assert(byNet[netId] == nil or byNet[netId] == entity, "net id already in use")
		assert(state.delLo == 0 and state.delHi == 0, "bind the net id before the entity is delivered")
		byNet[state.netId] = nil
		state.netId = netId
		byNet[netId] = entity
		watch(state, false)
		state.pin = { space = identity, principals = { playerEntity, table.unpack(state.pin.principals) } }
		watch(state, true)
		dirtyScope[entity] = true
	end

	function scope.acknowledge(playerEntity: number, actionSeq: number)
		local viewer = viewers[assert(viewerOf[playerEntity], "player not connected")]
		for _, netId in orEmpty(viewer.minted[actionSeq]) do
			local entity = byNet[netId]
			local state = if entity then states[entity] else nil
			if state then
				watch(state, false)
				local pinned = table.clone(state.pin.principals)
				table.remove(pinned, table.find(pinned, playerEntity) or #pinned + 1)
				state.pin = { space = identity, principals = pinned }
				watch(state, true)
				dirtyScope[entity] = true
			else
				table.insert(viewer.rollbacks, netId)
			end
		end
		viewer.minted[actionSeq] = nil
	end

	-- Frame building.

	function scope.frame(): { [number]: { Message } }
		local out: { [number]: { Message } } = {}
		local function emit(v: number, message: Message)
			out[v] = out[v] or {}
			table.insert(out[v], message)
		end

		-- 1. Settle new entities, then read what changed: viewers' principals, entities' scope,
		--    pairs and references.
		for entity in newlyReplicated do
			local state = states[entity]
			for _, rule in rules do
				if rule.appliesTo ~= nil and world:has(entity, rule.appliesTo) then
					table.insert(state.rules, rule)
				end
			end
			-- An archetype default is a grant applied once, so it's visible in the world.
			for component in defaultPublic do
				if world:has(entity, component) then
					world:add(entity, Net.Public)
				end
			end
			for _, info in replicatedByKey do
				if info.refs then
					readRefs(state, info)
				end
			end
		end
		table.clear(newlyReplicated)
		for _, space in spaces do
			for v in space.stale do
				setPrincipals(space, v, space.principalsOf(viewers[v].entity))
			end
			table.clear(space.stale)
		end
		local pairDiffs: { [number]: { { key: number, target: number, added: boolean } } } = {}
		for entity in dirty do
			local state = states[entity]
			readScope(state)
			local now = currentPairs(entity)
			local diff = {}
			local function missing(from: PairSet, other: PairSet, added: boolean)
				for key, targets in from do
					for target in targets do
						if not (other[key] and other[key][target]) then
							table.insert(diff, { key = key, target = target, added = added })
						end
					end
				end
			end
			missing(state.pairs, now, false) -- removals first
			missing(now, state.pairs, true)
			pairDiffs[entity] = if #diff > 0 then diff else nil :: any
			indexTargets(pairsTo, entity, state.pairs, false)
			state.pairs = now
			indexTargets(pairsTo, entity, now, true)
		end
		table.clear(dirty)
		for entity, keys in dirtyComps do
			for key in keys do
				if replicatedByKey[key].refs then
					readRefs(states[entity], replicatedByKey[key])
				end
			end
		end

		-- 2. Recompute who may see each changed entity, and its inheritors, then turn the changes
		--    into pending ENTERs and immediate LEAVEs.
		local spread = {}
		for entity in dirtyScope do
			table.insert(spread, entity)
		end
		for _, entity in spread do
			for child in orEmpty(inheritors[entity]) do
				if not dirtyScope[child] then
					dirtyScope[child] = true
					table.insert(spread, child)
				end
			end
		end
		for entity in dirtyScope do
			local state = states[entity]
			local gLo, gHi = 0, 0
			for _, need in state.grants do
				local lo, hi = anyHolder(need)
				gLo, gHi = bit32.bor(gLo, lo), bit32.bor(gHi, hi)
			end
			local nLo, nHi = allLo, allHi
			for _, need in state.needs do
				local lo, hi = anyHolder(need)
				nLo, nHi = bit32.band(nLo, lo), bit32.band(nHi, hi)
			end
			state.grantLo, state.grantHi, state.needLo, state.needHi = gLo, gHi, nLo, nHi
			state.pinLo, state.pinHi = anyHolder(state.pin)
		end
		local leaves: { [number]: { EntityState } } = {}
		for entity in dirtyScope do
			local state = states[entity]
			computeAuth(state)
			local enterLo = bit32.band(state.authLo, bit32.bnot(state.delLo))
			local enterHi = bit32.band(state.authHi, bit32.bnot(state.delHi))
			eachBit(bit32.bxor(enterLo, state.pendLo), bit32.bxor(enterHi, state.pendHi), function(v)
				viewers[v].pendingEnter[entity] = if hasBit(enterLo, enterHi, v) then true else nil :: any
			end)
			state.pendLo, state.pendHi = enterLo, enterHi
			local outLo = bit32.band(state.delLo, bit32.bnot(state.authLo))
			local outHi = bit32.band(state.delHi, bit32.bnot(state.authHi))
			eachBit(outLo, outHi, function(v)
				local bl, bh = bitOf(v)
				forgetViewerBits(state, bit32.bnot(bl), bit32.bnot(bh))
				leaves[v] = leaves[v] or {}
				table.insert(leaves[v], state)
			end)
		end

		-- Components whose visibility flipped, entity by entity, for the clients that have the
		-- entity (key -> false: send only if the client's copy is now wrong).
		local flipsFor: { [number]: { [number]: { [number]: boolean } } } = {}
		for entity in dirtyScope do
			local state = states[entity]
			if state.delLo == 0 and state.delHi == 0 then
				continue
			end
			for _, info in restricted do
				local wantLo, wantHi = 0, 0
				if world:has(entity, info.component) then
					local vl, vh = visibleBits(state, info)
					wantLo, wantHi = bit32.band(vl, state.delLo), bit32.band(vh, state.delHi)
				end
				local flipLo = bit32.bxor(wantLo, state.heldLo[info.key] or 0)
				eachBit(flipLo, bit32.bxor(wantHi, state.heldHi[info.key] or 0), function(v)
					local byEntity: { [number]: { [number]: boolean } } = flipsFor[v] or {}
					flipsFor[v] = byEntity
					byEntity[entity] = byEntity[entity] or {}
					byEntity[entity][info.key] = false
				end)
			end
		end

		-- 3. Per client: ENTER, ops, pairs, LEAVE.
		for v, viewer in viewers do
			local bl, bh = bitOf(v)
			local function has(entity: number): boolean
				local state = states[entity]
				return state ~= nil and hasBit(state.delLo, state.delHi, v)
			end

			-- ENTER. Inheritance groups (an entity with its entering VisibleThrough descendants)
			-- enter whole: the budget takes whole groups, at least one. Within the frame, parents
			-- and reference targets go before the entities that need them.
			local candidates = viewer.pendingEnter
			local rootOf: { [number]: number } = {}
			local function root(entity: number): number
				local path, onPath = {}, {}
				local current = entity
				while rootOf[current] == nil do
					table.insert(path, current)
					onPath[current] = true
					local parent = states[current].parent
					if parent == nil or not candidates[parent] or onPath[parent] then
						rootOf[current] = current -- the top of the chain, or where a loop closes
						break
					end
					current = parent
				end
				for _, member in path do
					rootOf[member] = rootOf[current]
				end
				return rootOf[current]
			end
			local groups: { [number]: { number } } = {}
			local roots: { number } = {}
			for entity in candidates do
				local r = root(entity)
				if not groups[r] then
					groups[r] = {}
					table.insert(roots, r)
				end
				table.insert(groups[r], entity)
			end
			table.sort(roots, function(a, b)
				return states[a].netId < states[b].netId
			end)
			local chosen: { [number]: boolean } = {}
			local count = 0
			for _, r in roots do
				if not (enterBudget and count > 0 and count + #groups[r] > enterBudget) then
					count += #groups[r]
					for _, entity in groups[r] do
						chosen[entity] = true
					end
				end
			end
			local enteredAt: { [number]: number } = {}
			local function enter(entity: number)
				if not chosen[entity] or enteredAt[entity] then
					return
				end
				enteredAt[entity] = 0 -- visiting; guards loops
				local state = states[entity]
				if state.parent then
					enter(state.parent)
				end
				for _, targets in state.refs do
					for _, target in targets do
						enter(target)
					end
				end
				candidates[entity] = nil
				state.pendLo, state.pendHi =
					bit32.band(state.pendLo, bit32.bnot(bl)), bit32.band(state.pendHi, bit32.bnot(bh))
				state.delLo, state.delHi = bit32.bor(state.delLo, bl), bit32.bor(state.delHi, bh)
				local comps = {}
				for _, info in replicatedByKey do
					local vl, vh = visibleBits(state, info)
					if hasBit(vl, vh, v) and world:has(entity, info.component) then
						comps[info.key] = wireValue(info, world:get(entity, info.component), v)
						setHeld(state, info.key, v, true)
					end
				end
				emit(v, { "ENTER", state.netId, comps })
				enteredAt[entity] = #out[v]
			end
			for _, r in roots do
				for _, entity in groups[r] do
					enter(entity)
				end
			end

			-- Ops for entities the client already had: changed values, components whose visibility
			-- flipped, and references to targets that just entered, from entities that had them
			-- redacted. force: send even if the client already holds the component.
			local function hadBefore(entity: number): boolean
				return has(entity) and not enteredAt[entity]
			end
			local function decide(entity: number, key: number, force: boolean)
				local state = states[entity]
				local info = replicatedByKey[key]
				local present = world:has(entity, info.component)
				local vl, vh = visibleBits(state, info)
				local held = isHeld(state, key, v)
				if present and hasBit(vl, vh, v) then
					if force or not held then
						emit(v, { "SET", state.netId, key, wireValue(info, world:get(entity, info.component), v) })
						setHeld(state, key, v, true)
					end
				elseif held then
					emit(v, { if present then "HIDE" else "REM", state.netId, key })
					setHeld(state, key, v, false)
				end
			end
			for entity, keys in dirtyComps do
				if hadBefore(entity) then
					for key in keys do
						decide(entity, key, true)
					end
				end
			end
			local extra: { [number]: { [number]: boolean } } = flipsFor[v] or {}
			for target, at in enteredAt do
				for referrer in orEmpty(refsTo[target]) do
					if hadBefore(referrer) or (enteredAt[referrer] or math.huge) < at then
						for key, targets in states[referrer].refs do
							if table.find(targets, target) then
								extra[referrer] = extra[referrer] or {}
								extra[referrer][key] = true
							end
						end
					end
				end
			end
			for entity, keys in extra do
				local changed = if hadBefore(entity) then dirtyComps[entity] else nil
				for key, force in keys do
					if not (changed and changed[key]) then -- already decided above
						decide(entity, key, force)
					end
				end
			end

			-- Pairs between entities the client has: all of an entering entity's pairs, pairs
			-- pointing at an entering entity, and this frame's changes between the others.
			local function pairsOf(entity: number, target: number?, fn: (number, number) -> ())
				for key, targets in states[entity].pairs do
					for t in targets do
						if (target == nil or t == target) and has(t) then
							fn(key, t)
						end
					end
				end
			end
			for entity in enteredAt do
				local netId = states[entity].netId
				pairsOf(entity, nil, function(key, t)
					emit(v, { "PAIR_ADD", netId, key, states[t].netId })
				end)
				for referrer in orEmpty(pairsTo[entity]) do
					if hadBefore(referrer) then
						pairsOf(referrer, entity, function(key, t)
							emit(v, { "PAIR_ADD", states[referrer].netId, key, states[t].netId })
						end)
					end
				end
			end
			for entity, diff in pairDiffs do
				if hadBefore(entity) then
					for _, change in diff do
						if hadBefore(change.target) then
							local kind = if change.added then "PAIR_ADD" else "PAIR_REM"
							emit(v, { kind, states[entity].netId, change.key, states[change.target].netId })
						end
					end
				end
			end
			for _, state in orEmpty(leaves[v]) do
				emit(v, { "LEAVE", state.netId })
			end
		end

		-- 4. Entities that stopped replicating: LEAVE if still alive, then DEL if destroyed. Only
		--    to clients that had them.
		for _, kind in { "LEAVE", "DEL" } do
			for _, item in removed do
				if (kind == "LEAVE") == world:contains(item.entity) then
					eachBit(item.delLo, item.delHi, function(v)
						emit(v, { kind, item.netId })
					end)
				end
			end
		end
		table.clear(removed)

		-- 5. ROLLBACK for predicted spawns the server didn't make.
		for v, viewer in viewers do
			for _, netId in viewer.rollbacks do
				emit(v, { "ROLLBACK", netId })
			end
			table.clear(viewer.rollbacks)
		end

		table.clear(dirtyScope)
		table.clear(dirtyComps)
		return out
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

	function scope.scopeBits(entity: number): (number, number)
		local state = states[entity]
		return if state then state.authLo else 0, if state then state.authHi else 0
	end

	function scope.isPendingEnter(entity: number, v: number): boolean
		return viewers[v] ~= nil and viewers[v].pendingEnter[entity] == true
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

	function scope.ruleList(): { [string]: Rule }
		return rules
	end

	return scope
end

return StatuhScope
