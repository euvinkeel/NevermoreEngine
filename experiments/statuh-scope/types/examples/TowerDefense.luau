--!strict
--[[
	Tower defense: two teams on shared lanes. Towers and enemy waves are public, each team's plans
	are team-only, and gold and inventories are owner-only.
]]
local Statuh = require("../Statuh")

local Net = Statuh.Net
local S = Statuh.S

type PlayerEntity = Statuh.PlayerEntity
type Room = Statuh.Room
type Runtime = Statuh.Runtime

local C = {
	Tower = Statuh.replicated(S.struct({ kind = S.string(16), level = S.integer(1, 5) })),
	Health = Statuh.replicated(S.integer(0, 10000)),
	Lane = Statuh.replicated(S.integer(1, 3)),
	-- Who a tower is shooting at. Clients that can't see the target get Redacted.
	Target = Statuh.replicated(S.optional(S.entity())),
	Plan = Statuh.replicated(S.struct({ lane = S.integer(1, 3), note = S.string(64) })),
	Gold = Statuh.replicated(S.integer(0, 1000000), { visibleTo = "owner" }),
	Inventory = Statuh.replicated(
		S.array(S.struct({ item = S.string(32), count = S.integer(1, 99) }), 40),
		{ visibleTo = "owner" }
	),
	Enemy = Statuh.tag(),
}

local Teams: { red: Room?, blue: Room? } = {}

local function setup(rt: Runtime)
	Teams.red = Net.room(rt.world)
	Teams.blue = Net.room(rt.world)
	-- Enemy waves are public: applied once at spawn as a visible grant, never as a fallback.
	rt.net.setDefaultPublic(C.Enemy)
end

local function onJoin(rt: Runtime, player: any, team: Room): PlayerEntity
	local world = rt.world
	local me = rt.net.playerEntity(player)
	Net.makePublic(world, me) -- everyone sees every player
	Net.setOwner(world, me, me) -- gold and inventory go to me only
	Net.join(world, me, team)
	world:set(me, C.Gold, 100)
	world:set(me, C.Inventory, {})
	world:add(me, Net.Replicated)
	return me
end

local function buildTower(rt: Runtime, owner: PlayerEntity, lane: number)
	local world = rt.world
	local tower = world:entity()
	world:set(tower, C.Tower, { kind = "archer", level = 1 })
	world:set(tower, C.Health, 500)
	world:set(tower, C.Lane, lane)
	Net.makePublic(world, tower)
	Net.setOwner(world, tower, owner)
	world:add(tower, Net.Replicated)
	return tower
end

local function spawnEnemy(rt: Runtime, lane: number)
	local world = rt.world
	local enemy = world:entity()
	world:add(enemy, C.Enemy)
	world:set(enemy, C.Health, 80)
	world:set(enemy, C.Lane, lane)
	world:add(enemy, Net.Replicated)
	return enemy
end

local function postPlan(rt: Runtime, team: Room, lane: number, note: string)
	local plan = rt.world:entity()
	rt.world:set(plan, C.Plan, { lane = lane, note = note })
	Net.showTo(rt.world, plan, team)
	rt.world:add(plan, Net.Replicated)
end

-- Leave first, join after: in between the player sees neither team's plans, never both.
local function switchTeam(rt: Runtime, me: PlayerEntity, from: Room, to: Room)
	Net.leave(rt.world, me, from)
	Net.join(rt.world, me, to)
end

-- Client side: a tower's target disappearing doesn't mean it died. Ask why it went.
local function onClientTick(rt: Runtime, killFeed: { string })
	for _ in rt.net.deleted() do
		table.insert(killFeed, "an enemy was destroyed")
	end
	for _, entity in rt.net.left() do
		local kind = rt.net.removalKind(entity)
		if kind == "LEAVE" then
			continue -- out of view, nothing happened to it
		end
	end
end

return {
	setup = setup,
	onJoin = onJoin,
	buildTower = buildTower,
	spawnEnemy = spawnEnemy,
	postPlan = postPlan,
	switchTeam = switchTeam,
	onClientTick = onClientTick,
}
