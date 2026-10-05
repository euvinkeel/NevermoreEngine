--!strict
--[[
	Typed stubs for the chosen scope API (DESIGN.md, design A: grants and rules). Types only; the
	runtime behind them is the untyped prototype in ../src. Examples in ./examples must type-check
	and every marked line in ./mustfail must not (see ./check.luau).

	Typing choices:
	- Rooms and players are phantom-typed entities (Entity<RoomTag> etc.), so the typed helpers
	  reject a player where a room goes (membership vs audience, game guardrail 6), and a room as
	  the entity something is visible through.
	- Schema values are typed as the value they validate (S.integer(0, 10) is a number), so
	  S.struct({ ... }) infers the component's type with no annotations. There is no Instance
	  schema, so Roblox Instances can't go in replicated data (guardrail 2).
	- Override values, rule modes and component visibility are closed unions. A component that's
	  visible through a rule names it with Statuh.rule(name), so a misspelled "owner" doesn't
	  type-check. A rule's key type ties `key` to `viewerKeys`.
]]

local Jecst = require("../../../src/jecs/src/Shared/Jecst")

export type Entity<T = nil> = Jecst.Entity<T>
export type World = Jecst.World

export type RoomTag = { __statuhRoom: true }
export type PlayerTag = { __statuhPlayer: true }

export type Room = Entity<RoomTag>
export type PlayerEntity = Entity<PlayerTag>

-- A scope rule named for a component's `visibleTo`. It must be a restrict rule; core checks that
-- when the component starts replicating.
export type RuleRef = { __statuhRule: string }

export type Override = "server" | "owner" | Room
export type RuleMode = "grant" | "restrict"
-- Which clients that have an entity also get this component of it: all of them (the default),
-- the entity's owners, or the ones a restrict rule lets through.
export type Visibility = "all" | "owner" | RuleRef
export type RemovalKind = "LEAVE" | "DEL" | "ROLLBACK"
-- HIDE: the component still exists, but this client may no longer see it. REM: it was removed.
export type ComponentRemovalKind = "HIDE" | "REM"

export type ReplicatedOptions = {
	-- A component whose visibility isn't "all" is hideable: on a client, absent means unknown,
	-- not "none".
	visibleTo: Visibility?,
}

export type SchemaLib = {
	number: () -> number,
	integer: (min: number, max: number) -> number,
	string: (maxLength: number?) -> string,
	boolean: () -> boolean,
	-- A replicated entity reference; sent as Redacted to clients that can't see the target.
	entity: () -> Entity<any>,
	optional: <T>(schema: T) -> T?,
	array: <T>(item: T, maxLength: number) -> { T },
	struct: <T>(fields: T) -> T,
}

export type ScopeRule<Key> = {
	-- "grant" adds the viewers interested in the key (fog of war vision); "restrict" keeps only
	-- them. Both take effect at once: losing scope is a LEAVE that frame. Lingering at the edge of
	-- a camera is up to the game, through the keys it returns.
	mode: RuleMode,
	-- Entities with this component when they start replicating are subject to the rule, for life.
	-- Leave it out for a rule that's only used as a component's visibility.
	appliesTo: Entity<any>?,
	dependsOn: { Entity<any> },
	viewerDependsOn: { Entity<any> }?,
	key: (entity: Entity<any>) -> Key?,
	viewerKeys: (viewer: PlayerEntity) -> { [Key]: true },
}

export type NetVocabulary = {
	Replicated: Entity<nil>,
	Public: Entity<nil>,
	-- pair(Member, room) on a player; pair(Audience, room) on anything it should see.
	Member: Entity<nil>,
	Audience: Entity<nil>,
	-- pair(Owner, player): a grant, and who gets owner-only components.
	Owner: Entity<nil>,
	-- pair(VisibleThrough, target): also visible to whoever sees the target. It's the only
	-- relation that means anything to visibility; game relations (ChildOf, Held, OwnedBy) are data.
	VisibleThrough: Entity<nil>,
	-- Narrows visibility; removing it is a deliberate reveal.
	VisibleTo: Entity<Override>,

	room: (world: World) -> Room,
	join: (world: World, player: PlayerEntity, room: Room) -> (),
	leave: (world: World, player: PlayerEntity, room: Room) -> (),
	showTo: (world: World, entity: Entity<any>, room: Room) -> (),
	hideFrom: (world: World, entity: Entity<any>, room: Room) -> (),
	makePublic: (world: World, entity: Entity<any>) -> (),
	setOwner: (world: World, entity: Entity<any>, owner: PlayerEntity) -> (),
	-- Visible to whoever sees `target`, an entity or a player (not a room). nil removes the link.
	-- It removes the old pair before adding the new one, because jecs 0.11.0-quenty.3 can lose an
	-- entity from every query when an exclusive relation is retargeted in place.
	visibleThrough: (world: World, entity: Entity<any>, target: (Entity<nil> | PlayerEntity)?) -> (),
	override: (world: World, entity: Entity<any>, value: Override?) -> (),
	-- Deletes the entity and its ChildOf descendants. Use it instead of world:delete: it removes
	-- the pairs pointing into what it deletes first, which jecs 0.11.0-quenty.3 needs to delete
	-- without corrupting other entities (experiments/jecs-findings).
	destroy: (world: World, entity: Entity<any>) -> (),
}

export type Net = {
	addScopeRule: <Key>(name: string, rule: ScopeRule<Key>) -> (),
	invalidateViewerKeys: (ruleName: string, viewer: PlayerEntity?) -> (),
	-- Entities with this component when they start replicating get Net.Public once.
	setDefaultPublic: (component: Entity<any>) -> (),
	-- A game relation whose pairs replicate as data, sent while both ends are delivered. It has
	-- no say in visibility.
	replicateRelation: (relation: Entity<any>) -> (),
	-- Client side: why an entity went away this tick, and the per-tick lists.
	removalKind: (entity: Entity<any>) -> RemovalKind?,
	left: () -> { Entity<any> },
	deleted: () -> { Entity<any> },
	rolledBack: () -> { Entity<any> },
	-- Client side: why one of an entity's components went away this tick.
	componentRemovalKind: (entity: Entity<any>, component: Entity<any>) -> ComponentRemovalKind?,
	-- Client side: true once the initial ENTERs after joining have arrived.
	ready: () -> boolean,
	playerEntity: (player: any) -> PlayerEntity,
	now: () -> number,
}

export type Runtime = {
	world: World,
	net: Net,
}

local function stub(): any
	error("types-only stub; see ../src for the prototype", 2)
end

local Statuh = {
	S = (nil :: any) :: SchemaLib,
	Net = (nil :: any) :: NetVocabulary,
	replicated = function<T>(_schema: T, _options: ReplicatedOptions?): Entity<T>
		return stub()
	end,
	-- Names a scope rule for a component's `visibleTo`. Add the rule before the component
	-- starts replicating.
	rule = function(_name: string): RuleRef
		return stub()
	end,
	-- A plain component that is never replicated (server-only state).
	serverOnly = function<T>(): Entity<T>
		return stub()
	end,
	-- A tag component, never replicated, used as a rule's appliesTo or a default-public marker.
	tag = function(): Entity<nil>
		return stub()
	end,
	-- A game relation (ChildOf, OwnedBy, Held, ...). Its pairs are server-only unless
	-- rt.net.replicateRelation sends them as data; either way they mean nothing to visibility.
	relation = function(): Entity<nil>
		return stub()
	end,
	-- jecs.pair, typed like it.
	pair = function<P, O>(_first: Entity<P>, _second: Entity<O>): Jecst.Pair<P, O>
		return stub()
	end,
}

return Statuh
