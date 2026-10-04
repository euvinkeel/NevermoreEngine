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

	-- Membership and audience take different things: a player joins a room; an entity is shown to a room.
	Net.join(world, red, me) -- expect-error
	Net.showTo(world, sword, me) -- expect-error

	-- Overrides are "server", "owner" or a room.
	Net.override(world, sword, "everyone") -- expect-error
	Net.override(world, sword, me) -- expect-error

	-- Something is visible through an entity or a player, never through a room.
	Net.visibleThrough(world, sword, red) -- expect-error

	-- Component values are typed by their schema.
	world:set(me, C.Gold, "lots") -- expect-error
	world:set(plan, C.Plan, { lane = 2 }) -- expect-error

	-- Visibility is "all", "owner" or a rule named through Statuh.rule.
	local _owners = Statuh.replicated(S.integer(0, 10), { visibleTo = "owners" }) -- expect-error
	local _bareName = Statuh.replicated(S.integer(0, 10), { visibleTo = "near" }) -- expect-error

	-- There is no Instance schema: Roblox Instances can't go in replicated data.
	local _instance = Statuh.replicated(S.instance()) -- expect-error

	-- Rule modes are a closed set (relevance is game code now), dependencies are components, and
	-- keys must agree.
	-- (The old solver reports a bad mode on the table, not the field.)
	rt.net.addScopeRule("a", { -- expect-error
		mode = "relevance",
		appliesTo = C.Unit,
		dependsOn = { C.Cell },
		key = function(_e): number?
			return 1
		end,
		viewerKeys = function(_v): { [number]: true }
			return {}
		end,
	})
	rt.net.addScopeRule("b", {
		mode = "grant",
		appliesTo = C.Unit,
		dependsOn = { "Cell" }, -- expect-error
		key = function(_e): number?
			return 1
		end,
		viewerKeys = function(_v): { [number]: true }
			return {}
		end,
	})
	-- (Under the old solver this is only caught when key/viewerKeys aren't annotated; see DESIGN.md.)
	rt.net.addScopeRule("c", {
		mode = "grant",
		appliesTo = C.Unit,
		dependsOn = { C.Cell },
		key = function(_e)
			return "x"
		end,
		viewerKeys = function(_v)
			return NUMBER_KEYS -- expect-error
		end,
	})

	-- A removal can be LEAVE, DEL or ROLLBACK (or nil): code can't assume it's one of two.
	local _kind: "LEAVE" | "DEL" = rt.net.removalKind(sword) -- expect-error
	-- And a component can be hidden as well as removed.
	local _componentKind: "REM" = rt.net.componentRemovalKind(sword, C.Cell) -- expect-error
end

return misuse
