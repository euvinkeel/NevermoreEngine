--!strict
--[[
	Typed stubs for the chosen scope API (DESIGN.md, design A: grants and rules). Types only; the
	runtime behind them is the untyped prototype in ../src. Examples in ./examples must type-check
	and every marked line in ./mustfail must not (see ./check.luau).

	Typing choices:
	- Rooms, players and inheritable relations are phantom-typed entities (Entity<RoomTag> etc.), so
	  the typed helpers reject a player where a room goes (membership vs audience, guardrail 6) and
	  a non-exclusive relation for inheritance.
	- Schema values are typed as the value they validate (S.integer(0, 10) is a number), so
	  S.struct({ ... }) infers the component's type with no annotations. There is no Instance
	  schema, so Roblox Instances can't go in replicated data (guardrail 2).
	- Override values and rule modes are literal unions; a rule's key type ties `key` to
	  `viewerKeys`.
]]

local Jecst = require("../../../src/jecs/src/Shared/Jecst")

export type Entity<T = nil> = Jecst.Entity<T>
export type World = Jecst.World

export type RoomTag = { __statuhRoom: true }
export type PlayerTag = { __statuhPlayer: true }
export type ExclusiveTag = { __statuhExclusive: true }

export type Room = Entity<RoomTag>
export type PlayerEntity = Entity<PlayerTag>
export type ExclusiveRelation = Entity<ExclusiveTag>

export type Override = "server" | "owner" | Room
export type RuleMode = "grant" | "restrict" | "relevance"
export type Visibility = "all" | "owner"
export type RemovalKind = "LEAVE" | "DEL" | "ROLLBACK"

export type ReplicatedOptions = {
	-- "owner" sends the component only to the entity's owners.
	visibleTo: Visibility?,
	-- Absent means unknown (not "none") to predicted code on clients that may not see it.
	hideable: boolean?,
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
	-- "grant" adds viewers interested in the key (fog of war vision); "restrict" keeps only them
	-- (authorization, revoked immediately); "relevance" keeps only them for interest management
	-- (an exit lingers a few frames).
	mode: RuleMode,
	-- Entities with this component when they start replicating are subject to the rule, for life.
	appliesTo: Entity<any>,
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
	-- pair(VisibleThrough, relation): also visible to whoever sees the relation's target.
	VisibleThrough: Entity<nil>,
	-- Narrows visibility; removing it is a deliberate reveal.
	VisibleTo: Entity<Override>,
	-- jecs.ChildOf, typed as the exclusive relation it is.
	ChildOf: ExclusiveRelation,

	room: (world: World) -> Room,
	exclusiveRelation: (world: World) -> ExclusiveRelation,
	join: (world: World, player: PlayerEntity, room: Room) -> (),
	leave: (world: World, player: PlayerEntity, room: Room) -> (),
	showTo: (world: World, entity: Entity<any>, room: Room) -> (),
	hideFrom: (world: World, entity: Entity<any>, room: Room) -> (),
	makePublic: (world: World, entity: Entity<any>) -> (),
	setOwner: (world: World, entity: Entity<any>, owner: PlayerEntity) -> (),
	follow: (world: World, child: Entity<any>, relation: ExclusiveRelation) -> (),
	override: (world: World, entity: Entity<any>, value: Override?) -> (),
}

export type Net = {
	addScopeRule: <Key>(name: string, rule: ScopeRule<Key>) -> (),
	invalidateViewerKeys: (ruleName: string, viewer: PlayerEntity?) -> (),
	-- Entities with this component when they start replicating get Net.Public once.
	setDefaultPublic: (component: Entity<any>) -> (),
	-- Client side: why an entity went away this tick, and the per-tick lists.
	removalKind: (entity: Entity<any>) -> RemovalKind?,
	left: () -> { Entity<any> },
	deleted: () -> { Entity<any> },
	rolledBack: () -> { Entity<any> },
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
	-- A plain component that is never replicated (server-only state).
	serverOnly = function<T>(): Entity<T>
		return stub()
	end,
	-- A tag component, never replicated, used as a rule's appliesTo or a default-public marker.
	tag = function(): Entity<nil>
		return stub()
	end,
}

return Statuh
