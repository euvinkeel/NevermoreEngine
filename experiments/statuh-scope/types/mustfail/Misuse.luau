--!strict
--[[
	Every line marked `-- expect-error` must produce a type error, and no other line may.
	Checked by ../check.luau with the old solver (--flag:LuauSolverV2=false), like Nevermore's lint.
]]
local Statuh = require("../Statuh")

local Net = Statuh.Net
local S = Statuh.S

type Runtime = Statuh.Runtime

local C = {
	Gold = Statuh.replicated(S.integer(0, 1000000), { visibleTo = "owner" }),
	Plan = Statuh.replicated(S.struct({ lane = S.integer(1, 3), note = S.string(64) })),
	Cell = Statuh.replicated(S.integer(0, 255)),
	Unit = Statuh.tag(),
}

local NUMBER_KEYS: { [number]: true } = {}

local function misuse(rt: Runtime, player: any)
	local world = rt.world
	local me = rt.net.playerEntity(player)
	local red = Net.room(world)
	local sword = world:entity()
	local plan = world:entity()
	local notExclusive = Statuh.tag()

	-- Membership and audience take different things: a player joins a room; an entity is shown to a room.
	Net.join(world, red, me) -- expect-error
	Net.showTo(world, sword, me) -- expect-error

	-- Overrides are "server", "owner" or a room.
	Net.override(world, sword, "everyone") -- expect-error
	Net.override(world, sword, me) -- expect-error

	-- Inheritance needs an exclusive relation (one target), like Net.ChildOf.
	Net.follow(world, sword, notExclusive) -- expect-error

	-- Component values are typed by their schema.
	world:set(me, C.Gold, "lots") -- expect-error
	world:set(plan, C.Plan, { lane = 2 }) -- expect-error

	-- Replication options are checked.
	local _bad = Statuh.replicated(S.integer(0, 10), { visibleTo = "owners" }) -- expect-error

	-- There is no Instance schema: Roblox Instances can't go in replicated data.
	local _instance = Statuh.replicated(S.instance()) -- expect-error

	-- Rule modes are a closed set, dependencies are components, and keys must agree.
	rt.net.addScopeRule("a", { mode = "spatial", appliesTo = C.Unit, dependsOn = { C.Cell }, key = function(_e): number? return 1 end, viewerKeys = function(_v): { [number]: true } return {} end }) -- expect-error
	rt.net.addScopeRule("b", { mode = "grant", appliesTo = C.Unit, dependsOn = { "Cell" }, key = function(_e): number? return 1 end, viewerKeys = function(_v): { [number]: true } return {} end }) -- expect-error
	-- (Under the old solver this is only caught when key/viewerKeys aren't annotated; see DESIGN.md.)
	rt.net.addScopeRule("c", { mode = "grant", appliesTo = C.Unit, dependsOn = { C.Cell }, key = function(_e) return "x" end, viewerKeys = function(_v) return NUMBER_KEYS end }) -- expect-error

	-- A removal can be LEAVE, DEL or ROLLBACK (or nil): code can't assume it's one of two.
	local _kind: "LEAVE" | "DEL" = rt.net.removalKind(sword) -- expect-error
end

return misuse
