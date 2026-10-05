--!strict
--[[
	RTS with fog of war. Your team always sees its own units. Enemies see a unit only while it's in
	a cell their team has vision of; fog is a grant rule, so leaving vision revokes at once.
	Weapons are visible through their unit, and neutral resources are only sent near your camera:
	interest management is game code, an ordinary restrict rule.
]]
local Statuh = require("../Statuh")

local Net = Statuh.Net
local S = Statuh.S

type PlayerEntity = Statuh.PlayerEntity
type Room = Statuh.Room
type Runtime = Statuh.Runtime

local CELL_SIZE = 32

local C = {
	Unit = Statuh.tag(),
	Resource = Statuh.tag(),
	-- Server-validated positions drive interest; owner-written streams never do (guardrail).
	Cell = Statuh.replicated(S.struct({ x = S.integer(0, 255), y = S.integer(0, 255) })),
	Health = Statuh.replicated(S.integer(0, 1000)),
	Weapon = Statuh.replicated(S.struct({ kind = S.string(16), damage = S.integer(0, 100) })),
	Ore = Statuh.replicated(S.integer(0, 5000)),
	Team = Statuh.serverOnly() :: Statuh.Entity<Room>,
	Camera = Statuh.serverOnly() :: Statuh.Entity<{ x: number, y: number }>,
}

local function cellKey(x: number, y: number): number
	return y * 256 + x
end

-- Cells a team can see, recomputed by a system when units move (then invalidateViewerKeys).
local visionByTeam: { [Room]: { [number]: true } } = {}

local function setup(rt: Runtime)
	local world = rt.world

	rt.net.addScopeRule("fog", {
		mode = "grant",
		appliesTo = C.Unit,
		dependsOn = { C.Cell },
		key = function(unit): number?
			local cell = world:get(unit, C.Cell)
			return if cell then cellKey(cell.x, cell.y) else nil
		end,
		viewerKeys = function(viewer): { [number]: true }
			local team = world:get(viewer, C.Team)
			return if team then visionByTeam[team] or {} else {}
		end,
	})

	rt.net.addScopeRule("camera", {
		mode = "restrict",
		appliesTo = C.Resource,
		dependsOn = { C.Cell },
		viewerDependsOn = { C.Camera },
		key = function(resource): number?
			local cell = world:get(resource, C.Cell)
			return if cell then cellKey(cell.x // 8, cell.y // 8) else nil
		end,
		viewerKeys = function(viewer): { [number]: true }
			local camera = world:get(viewer, C.Camera)
			if not camera then
				return {}
			end
			local chunkX, chunkY = camera.x // (8 * CELL_SIZE), camera.y // (8 * CELL_SIZE)
			local keys: { [number]: true } = {}
			for dx = -1, 1 do
				for dy = -1, 1 do
					keys[cellKey(chunkX + dx, chunkY + dy)] = true
				end
			end
			return keys
		end,
	})
end

local function spawnUnit(rt: Runtime, team: Room, x: number, y: number)
	local world = rt.world
	local unit = world:entity()
	world:add(unit, C.Unit) -- before Replicated: rules latch at spawn
	world:set(unit, C.Cell, { x = x, y = y })
	world:set(unit, C.Health, 100)
	Net.showTo(world, unit, team) -- your own team always sees it
	world:add(unit, Net.Replicated)

	-- Seen exactly when its unit is. If the game also makes it ChildOf the unit, that's just data.
	local weapon = world:entity()
	world:set(weapon, C.Weapon, { kind = "spear", damage = 12 })
	world:set(weapon, Net.VisibleTo, "server") -- hidden while it's forged
	Net.visibleThrough(world, weapon, unit)
	world:add(weapon, Net.Replicated)
	Net.override(world, weapon, nil) -- forged: a deliberate reveal
	return unit, weapon
end

local function updateVision(rt: Runtime, team: Room, cells: { [number]: true })
	visionByTeam[team] = cells
	rt.net.invalidateViewerKeys("fog")
end

local function spawnOre(rt: Runtime, x: number, y: number, amount: number)
	local world = rt.world
	local ore = world:entity()
	world:add(ore, C.Resource)
	world:set(ore, C.Cell, { x = x, y = y })
	world:set(ore, C.Ore, amount)
	Net.makePublic(world, ore)
	world:add(ore, Net.Replicated)
	return ore
end

local function onJoin(rt: Runtime, player: any, team: Room): PlayerEntity
	local me = rt.net.playerEntity(player)
	rt.world:set(me, C.Team, team)
	rt.world:set(me, C.Camera, { x = 0, y = 0 })
	Net.join(rt.world, me, team)
	return me
end

return {
	setup = setup,
	spawnUnit = spawnUnit,
	updateVision = updateVision,
	spawnOre = spawnOre,
	onJoin = onJoin,
}
