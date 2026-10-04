--!strict
--[[
	Instanced dungeons. Each instance has a party room and a spectator room. Monsters are shown to
	both; loot only to the party, with its rolls only to the looter. The boss is hidden until the
	reveal. Leaving the dungeon revokes everything in it at once.
]]
local Statuh = require("../Statuh")

local Net = Statuh.Net
local S = Statuh.S

type PlayerEntity = Statuh.PlayerEntity
type Room = Statuh.Room
type Runtime = Statuh.Runtime

local C = {
	Name = Statuh.replicated(S.string(32)),
	Health = Statuh.replicated(S.integer(0, 100000)),
	Rolls = Statuh.replicated(
		S.struct({ attack = S.integer(0, 999), crit = S.number(), affixes = S.array(S.string(24), 4) }),
		{ visibleTo = "owner" }
	),
	-- Hideable: a spectator's predicted code must treat "absent" as unknown, not "no loot".
	LootOf = Statuh.replicated(S.entity(), { hideable = true }),
}

export type Instance = {
	party: Room,
	spectators: Room,
	boss: Statuh.Entity<nil>?,
}

local function createInstance(rt: Runtime): Instance
	return {
		party = Net.room(rt.world),
		spectators = Net.room(rt.world),
		boss = nil,
	}
end

local function spawnMonster(rt: Runtime, instance: Instance, name: string, health: number)
	local world = rt.world
	local monster = world:entity()
	world:set(monster, C.Name, name)
	world:set(monster, C.Health, health)
	Net.showTo(world, monster, instance.party)
	Net.showTo(world, monster, instance.spectators)
	world:add(monster, Net.Replicated)
	return monster
end

local function spawnBoss(rt: Runtime, instance: Instance)
	local boss = spawnMonster(rt, instance, "Lich King", 50000)
	Net.override(rt.world, boss, "server") -- nobody sees it yet
	instance.boss = boss
	return boss
end

local function revealBoss(rt: Runtime, instance: Instance)
	local boss = instance.boss
	if boss then
		Net.override(rt.world, boss, nil) -- a deliberate reveal
	end
end

local function dropLoot(rt: Runtime, instance: Instance, looter: PlayerEntity, from: Statuh.Entity<nil>)
	local world = rt.world
	local loot = world:entity()
	world:set(loot, C.Name, "Frostmourne")
	world:set(loot, C.Rolls, { attack = 120, crit = 0.25, affixes = { "of frost" } })
	world:set(loot, C.LootOf, from)
	Net.showTo(world, loot, instance.party) -- not the spectators
	Net.setOwner(world, loot, looter) -- rolls go to the looter only
	world:add(loot, Net.Replicated)
	return loot
end

local function enter(rt: Runtime, instance: Instance, player: PlayerEntity)
	Net.join(rt.world, player, instance.party)
end

local function spectate(rt: Runtime, instance: Instance, player: PlayerEntity)
	Net.join(rt.world, player, instance.spectators)
end

-- Revocation: leaving the dungeon removes everything in it from that client at once, as LEAVE.
local function quit(rt: Runtime, instance: Instance, player: PlayerEntity)
	Net.leave(rt.world, player, instance.party)
end

return {
	createInstance = createInstance,
	spawnMonster = spawnMonster,
	spawnBoss = spawnBoss,
	revealBoss = revealBoss,
	dropLoot = dropLoot,
	enter = enter,
	spectate = spectate,
	quit = quit,
}
