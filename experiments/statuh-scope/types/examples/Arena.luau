--!strict
--[[
	Arena. Every player is public, so a far-away player still arrives as a name and a team, but
	where they are and what they're doing only goes to players near them: Position and Animation
	are visible through a restrict rule, "near". Game relations like OwnedBy and Held mean nothing
	to visibility. A held item is visible through its holder because the game says so, with
	VisibleThrough.
]]
local Statuh = require("../Statuh")

local Net = Statuh.Net
local S = Statuh.S

type PlayerEntity = Statuh.PlayerEntity
type Runtime = Statuh.Runtime

local CHUNK = 64

local Near = Statuh.rule("near")

local C = {
	Name = Statuh.replicated(S.string(32)),
	Team = Statuh.replicated(S.entity()),
	Position = Statuh.replicated(S.struct({ x = S.number(), z = S.number() }), { visibleTo = Near }),
	Animation = Statuh.replicated(S.string(24), { visibleTo = Near }),
	-- Game relations. OwnedBy is replicated as data; Held stays on the server.
	OwnedBy = Statuh.relation(),
	Held = Statuh.relation(),
}

local function chunkKey(x: number, z: number): number
	return (z // CHUNK) * 4096 + x // CHUNK
end

local function setup(rt: Runtime)
	local world = rt.world
	-- No appliesTo: this rule only decides who gets Position and Animation.
	rt.net.addScopeRule("near", {
		mode = "restrict",
		dependsOn = { C.Position },
		viewerDependsOn = { C.Position },
		key = function(entity): number?
			local position = world:get(entity, C.Position)
			return if position then chunkKey(position.x, position.z) else nil
		end,
		viewerKeys = function(viewer): { [number]: true }
			local position = world:get(viewer, C.Position)
			if not position then
				return {}
			end
			local keys: { [number]: true } = {}
			for dx = -1, 1 do
				for dz = -1, 1 do
					keys[chunkKey(position.x + dx * CHUNK, position.z + dz * CHUNK)] = true
				end
			end
			return keys
		end,
	})
	rt.net.replicateRelation(C.OwnedBy)
end

local function team(rt: Runtime, name: string)
	local world = rt.world
	local t = world:entity()
	world:set(t, C.Name, name)
	Net.makePublic(world, t)
	world:add(t, Net.Replicated)
	return t
end

local function onJoin(rt: Runtime, player: any, onTeam: Statuh.Entity<nil>): PlayerEntity
	local world = rt.world
	local me = rt.net.playerEntity(player)
	world:set(me, C.Name, tostring(player))
	world:set(me, C.Team, onTeam)
	world:set(me, C.Position, { x = 0, z = 0 })
	world:set(me, C.Animation, "idle")
	Net.makePublic(world, me) -- a player, on a team, to everyone
	world:add(me, Net.Replicated)
	return me
end

-- A sword lying in the world. Its owner can be anywhere; the pair to them arrives as data.
local function dropSword(rt: Runtime, owner: PlayerEntity, x: number, z: number)
	local world = rt.world
	local sword = world:entity()
	world:set(sword, C.Name, "sword")
	world:set(sword, C.Position, { x = x, z = z })
	world:add(sword, Statuh.pair(C.OwnedBy, owner))
	Net.makePublic(world, sword)
	world:add(sword, Net.Replicated)
	return sword
end

-- Picking it up: Held is game data, so the item is made visible through its holder explicitly.
local function pickUp(rt: Runtime, item: Statuh.Entity<nil>, holder: PlayerEntity)
	rt.world:add(item, Statuh.pair(C.Held, holder))
	Net.visibleThrough(rt.world, item, holder)
end

local function drop(rt: Runtime, item: Statuh.Entity<nil>, holder: PlayerEntity)
	rt.world:remove(item, Statuh.pair(C.Held, holder))
	Net.visibleThrough(rt.world, item, nil)
end

-- The player left: their entity goes, and the pairs pointing at it (OwnedBy on swords they
-- owned, VisibleThrough on items they held) go with it.
local function onLeave(rt: Runtime, me: PlayerEntity)
	Net.destroy(rt.world, me)
end

-- Client side: a hidden Position means the player went out of range, not that it was removed.
local function onClientTick(rt: Runtime, player: Statuh.Entity<nil>, markers: { [any]: boolean })
	if rt.net.componentRemovalKind(player, C.Position) == "HIDE" then
		markers[player] = false
	end
end

return {
	setup = setup,
	team = team,
	onJoin = onJoin,
	dropSword = dropSword,
	pickUp = pickUp,
	drop = drop,
	onLeave = onLeave,
	onClientTick = onClientTick,
}
