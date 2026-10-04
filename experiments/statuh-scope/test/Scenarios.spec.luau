--[[
	The four games from DESIGN.md, run through the prototype. Every step also checks the harness
	invariants (protocol, oracle agreement, projection, no out-of-scope ids), so these tests fail on
	any leak even when the assertion they make is about something else.
]]
local Jest = require("Jest")
local ScopeHarness = require("../src/ScopeHarness")

local describe = Jest.Globals.describe
local expect = Jest.Globals.expect
local it = Jest.Globals.it

local function kinds(messages: { { any } }): { string }
	local list = {}
	for _, message in messages do
		table.insert(list, message[1])
	end
	return list
end

describe("tower defense: two teams, private inventories", function()
	local function setup()
		local h = ScopeHarness.new()
		local world, Net, jecs = h.world, h.Net, h.jecs
		local C = {
			Name = world:component(),
			Health = world:component(),
			Gold = world:component(),
			Plan = world:component(),
			Target = world:component(),
		}
		h:replicate(C.Name)
		h:replicate(C.Health)
		h:replicate(C.Gold, { visibleTo = "owner" })
		h:replicate(C.Plan)
		h:replicate(C.Target, { isRef = true })

		local red, blue = world:entity(), world:entity()
		world:add(red, Net.Room)
		world:add(blue, Net.Room)

		local function player(name: string, team: number)
			local p = world:entity()
			world:set(p, C.Name, name)
			world:set(p, C.Gold, 100)
			world:add(p, jecs.pair(Net.Owner, p))
			world:add(p, Net.Public)
			world:add(p, jecs.pair(Net.Member, team))
			world:add(p, Net.Replicated)
			return p
		end
		local alice, bob, carol = player("alice", red), player("bob", red), player("carol", blue)

		local tower = world:entity()
		world:set(tower, C.Health, 500)
		world:add(tower, Net.Public)
		world:add(tower, Net.Replicated)

		local redPlan = world:entity()
		world:set(redPlan, C.Plan, "rush the left lane")
		world:add(redPlan, jecs.pair(Net.Audience, red))
		world:add(redPlan, Net.Replicated)

		for _, p in { alice, bob, carol } do
			h:connect(p)
		end
		h:step()
		return h,
			C,
			{ red = red, blue = blue, alice = alice, bob = bob, carol = carol, tower = tower, redPlan = redPlan }
	end

	it("shows the team plan to its team only and gold to its owner only", function()
		local h, C, e = setup()
		expect(h:sees(e.alice, e.redPlan)).toBe(true)
		expect(h:sees(e.bob, e.redPlan)).toBe(true)
		expect(h:sees(e.carol, e.redPlan)).toBe(false)
		expect(h:sees(e.carol, e.tower)).toBe(true)

		local goldKey = 3
		local aliceNet = h:netId(e.alice)
		expect(h:replicaOf(e.alice).entities[aliceNet].comps[goldKey]).toBe(100)
		expect(h:replicaOf(e.carol).entities[aliceNet].comps[goldKey]).toBeNil()
		expect(h:replicaOf(e.carol).entities[aliceNet].comps[1]).toBe("alice")
		expect(C).never.toBeNil()
	end)

	it("revokes a team swap immediately and never shows the plan to anyone in between", function()
		local h, _C, e = setup()
		local world, Net, jecs = h.world, h.Net, h.jecs

		world:remove(e.alice, jecs.pair(Net.Member, e.red))
		world:add(e.alice, jecs.pair(Net.Member, e.blue))
		h:step()

		expect(h:sees(e.alice, e.redPlan)).toBe(false)
		expect(h:lastRemoval(e.alice, h:netId(e.redPlan))).toBe("LEAVE")

		-- Re-targeting the plan: drop red first, add blue next frame. In between it's private.
		world:remove(e.redPlan, jecs.pair(Net.Audience, e.red))
		h:step()
		for _, p in { e.alice, e.bob, e.carol } do
			expect(h:sees(p, e.redPlan)).toBe(false)
		end
		world:add(e.redPlan, jecs.pair(Net.Audience, e.blue))
		h:step()
		expect(h:sees(e.carol, e.redPlan)).toBe(true)
		expect(h:sees(e.alice, e.redPlan)).toBe(true)
		expect(h:sees(e.bob, e.redPlan)).toBe(false)
	end)

	it("redacts a reference to a hidden entity and fixes it up when the target enters", function()
		local h, C, e = setup()
		local world, Net, jecs = h.world, h.Net, h.jecs
		local scout = world:entity()
		world:set(scout, C.Health, 30)
		world:add(scout, jecs.pair(Net.Audience, e.red))
		world:add(scout, Net.Replicated)
		world:set(e.tower, C.Target, scout)
		h:step()

		local targetKey = 5
		local towerNet = h:netId(e.tower)
		expect(h:replicaOf(e.alice).entities[towerNet].comps[targetKey]).toBe(h:netId(scout))
		expect(h:replicaOf(e.carol).entities[towerNet].comps[targetKey]).toBe(h.scope.REDACTED)

		-- The scout is spotted by blue: carol gets ENTER, then the tower's target re-sent.
		world:add(scout, jecs.pair(Net.Audience, e.blue))
		h:step()
		expect(kinds(h:messagesFor(e.carol))).toEqual({ "ENTER", "SET" })
		expect(h:replicaOf(e.carol).entities[towerNet].comps[targetKey]).toBe(h:netId(scout))

		-- And hidden again: the target is redacted before the LEAVE.
		world:remove(scout, jecs.pair(Net.Audience, e.blue))
		h:step()
		expect(kinds(h:messagesFor(e.carol))).toEqual({ "SET", "LEAVE" })
		expect(h:replicaOf(e.carol).entities[towerNet].comps[targetKey]).toBe(h.scope.REDACTED)
	end)

	it("sends DEL for a destroyed tower and LEAVE for one that stops replicating", function()
		local h, C, e = setup()
		local world, Net = h.world, h.Net
		local towerNet = h:netId(e.tower)
		world:delete(e.tower)
		h:step()
		expect(h:lastRemoval(e.carol, towerNet)).toBe("DEL")

		local banner = world:entity()
		world:set(banner, C.Name, "banner")
		world:add(banner, Net.Public)
		world:add(banner, Net.Replicated)
		h:step()
		local bannerNet = h:netId(banner)
		world:remove(banner, Net.Replicated)
		h:step()
		expect(h:lastRemoval(e.carol, bannerNet)).toBe("LEAVE")
	end)
end)

describe("RTS with fog of war", function()
	-- The map is a 1D strip of cells. Each team sees the cells near its units.
	local function setup()
		local h = ScopeHarness.new()
		local world, Net, jecs = h.world, h.Net, h.jecs
		local C = {
			Unit = world:component(),
			Cell = world:component(),
			Team = world:component(),
			Weapon = world:component(),
			Resource = world:component(),
			Focus = world:component(),
		}
		h:replicate(C.Cell)
		h:replicate(C.Weapon)
		h:replicate(C.Resource)
		h.scope.replicateRelation(jecs.ChildOf)

		local red, blue = world:entity(), world:entity()
		world:add(red, Net.Room)
		world:add(blue, Net.Room)
		local teamOf = {}

		local function vision(team: number): { [any]: boolean }
			local cells = {}
			for unit, cell, unitTeam in world:query(C.Cell, C.Team):with(C.Unit) do
				if unitTeam == team then
					for c = cell - 1, cell + 1 do
						cells[c] = true
					end
				end
			end
			return cells
		end
		-- Enemies see a unit when it stands in a cell their team has vision of.
		h:addRule("fog", {
			mode = "grant",
			appliesTo = C.Unit,
			dependsOn = { C.Cell },
			key = function(entity)
				return world:get(entity, C.Cell)
			end,
			viewerKeys = function(player)
				return vision(teamOf[player])
			end,
		})
		-- Neutral resources are only sent near the player's camera. Interest management is game
		-- code: an ordinary restrict rule. A game that wants things to linger at the edge keeps
		-- old cells in its keys for a while (`trail`, cleared by the game when it decides to).
		local trail: { [number]: { [number]: true } } = {}
		h:addRule("camera", {
			mode = "restrict",
			appliesTo = C.Resource,
			dependsOn = { C.Cell },
			viewerDependsOn = { C.Focus },
			key = function(entity)
				return world:get(entity, C.Cell)
			end,
			viewerKeys = function(player)
				local focus = world:get(player, C.Focus) or 0
				local keys = { [focus - 1] = true, [focus] = true, [focus + 1] = true }
				for cell in trail[player] or {} do
					keys[cell] = true
				end
				return keys
			end,
		})

		local function player(team: number, focus: number)
			local p = world:entity()
			teamOf[p] = team
			world:set(p, C.Focus, focus)
			world:add(p, jecs.pair(Net.Member, team))
			return p
		end
		local redPlayer, bluePlayer = player(red, 0), player(blue, 10)

		local function unit(team: number, cell: number)
			local u = world:entity()
			world:add(u, C.Unit)
			world:set(u, C.Team, team)
			world:set(u, C.Cell, cell)
			world:add(u, jecs.pair(Net.Audience, team)) -- your own team always sees your units
			world:add(u, Net.Replicated)
			-- The weapon is the unit's child (game data) and visible through the unit (replication).
			local weapon = world:entity()
			world:set(weapon, C.Weapon, "spear")
			world:add(weapon, jecs.pair(jecs.ChildOf, u))
			world:add(weapon, jecs.pair(Net.VisibleThrough, u))
			world:add(weapon, Net.Replicated)
			return u, weapon
		end
		local redUnit, redWeapon = unit(red, 0)
		local blueUnit, blueWeapon = unit(blue, 10)

		local ore = world:entity()
		world:add(ore, C.Resource)
		world:set(ore, C.Cell, 1)
		world:add(ore, Net.Public)
		world:add(ore, Net.Replicated)

		h:connect(redPlayer)
		h:connect(bluePlayer)
		h:step()

		local function moved()
			h.scope.invalidateViewerKeys("fog")
		end
		-- Game-side lingering: move the camera but keep the old view's cells for now.
		local function panKeepingTrail(player: number, focus: number)
			local old = world:get(player, C.Focus) or 0
			trail[player] = { [old - 1] = true, [old] = true, [old + 1] = true }
			world:set(player, C.Focus, focus)
		end
		local function dropTrail(player: number)
			trail[player] = nil
			h.scope.invalidateViewerKeys("camera", player)
		end
		return h,
			C,
			{
				redPlayer = redPlayer,
				bluePlayer = bluePlayer,
				redUnit = redUnit,
				redWeapon = redWeapon,
				blueUnit = blueUnit,
				blueWeapon = blueWeapon,
				ore = ore,
			},
			moved,
			panKeepingTrail,
			dropTrail
	end

	it("hides enemy units outside your vision, weapons included", function()
		local h, _C, e = setup()
		expect(h:sees(e.redPlayer, e.redUnit)).toBe(true)
		expect(h:sees(e.redPlayer, e.redWeapon)).toBe(true)
		expect(h:sees(e.redPlayer, e.blueUnit)).toBe(false)
		expect(h:sees(e.redPlayer, e.blueWeapon)).toBe(false)
	end)

	it("reveals a scouted unit and its weapon in the same frame, and revokes them at once", function()
		local h, C, e, moved = setup()
		local world = h.world
		world:set(e.redUnit, C.Cell, 9) -- next to the blue unit
		moved()
		h:step()
		expect(h:sees(e.redPlayer, e.blueUnit)).toBe(true)
		expect(h:sees(e.redPlayer, e.blueWeapon)).toBe(true)
		local entered = {}
		for _, message in h:messagesFor(e.redPlayer) do
			if message[1] == "ENTER" then
				table.insert(entered, message[2])
			end
		end
		expect(entered).toEqual({ h:netId(e.blueUnit), h:netId(e.blueWeapon) })

		-- Retreat: fog is authorization, so no lingering.
		world:set(e.redUnit, C.Cell, 0)
		moved()
		h:step()
		expect(h:sees(e.redPlayer, e.blueUnit)).toBe(false)
		expect(h:lastRemoval(e.redPlayer, h:netId(e.blueUnit))).toBe("LEAVE")
	end)

	it("hides a resource as soon as the camera moves away, and shows it again on return", function()
		local h, C, e = setup()
		local world = h.world
		expect(h:sees(e.redPlayer, e.ore)).toBe(true)

		world:set(e.redPlayer, C.Focus, 5) -- camera moves away
		h:step()
		expect(h:sees(e.redPlayer, e.ore)).toBe(false)
		expect(h:lastRemoval(e.redPlayer, h:netId(e.ore))).toBe("LEAVE")

		world:set(e.redPlayer, C.Focus, 1) -- and back
		h:step()
		expect(h:sees(e.redPlayer, e.ore)).toBe(true)
	end)

	it("leaves lingering to the game, which can keep old camera cells in its keys", function()
		local h, _C, e, _moved, panKeepingTrail, dropTrail = setup()
		expect(h:sees(e.redPlayer, e.ore)).toBe(true)

		panKeepingTrail(e.redPlayer, 5) -- the old view's cells stay in the keys
		h:step()
		expect(h:sees(e.redPlayer, e.ore)).toBe(true)
		expect(#h:messagesFor(e.redPlayer)).toBe(0)

		dropTrail(e.redPlayer) -- the game decides the linger is over
		h:step()
		expect(h:sees(e.redPlayer, e.ore)).toBe(false)
		expect(h:lastRemoval(e.redPlayer, h:netId(e.ore))).toBe("LEAVE")
	end)
end)

describe("instanced dungeons with parties and spectators", function()
	local function setup(options: any?)
		local h = ScopeHarness.new(options)
		local world, Net, jecs = h.world, h.Net, h.jecs
		local C = {
			Name = world:component(),
			Health = world:component(),
			Rolls = world:component(),
		}
		h:replicate(C.Name)
		h:replicate(C.Health)
		h:replicate(C.Rolls, { visibleTo = "owner" })

		local function room()
			local r = world:entity()
			world:add(r, Net.Room)
			return r
		end
		local party, spectators = room(), room()

		local function player(name: string, ...: number)
			local p = world:entity()
			world:set(p, C.Name, name)
			for _, r in { ... } do
				world:add(p, jecs.pair(Net.Member, r))
			end
			return p
		end
		local tank, healer, viewer = player("tank", party), player("healer", party), player("viewer", spectators)

		local function monster(name: string)
			local m = world:entity()
			world:set(m, C.Name, name)
			world:set(m, C.Health, 100)
			world:add(m, jecs.pair(Net.Audience, party))
			world:add(m, jecs.pair(Net.Audience, spectators))
			world:add(m, Net.Replicated)
			return m
		end
		local goblins = {}
		for i = 1, 6 do
			goblins[i] = monster("goblin " .. i)
		end
		local boss = monster("boss")
		world:set(boss, Net.VisibleTo, "server") -- hidden until the reveal

		local loot = world:entity()
		world:set(loot, C.Name, "sword")
		world:set(loot, C.Rolls, { attack = 12 })
		world:add(loot, jecs.pair(Net.Audience, party)) -- spectators don't see loot
		world:add(loot, jecs.pair(Net.Owner, tank))
		world:add(loot, Net.Replicated)

		h:connect(tank)
		h:connect(healer)
		return h,
			C,
			{
				party = party,
				spectators = spectators,
				tank = tank,
				healer = healer,
				viewer = viewer,
				goblins = goblins,
				boss = boss,
				loot = loot,
			}
	end

	it("shows monsters to party and spectators, loot to the party, rolls to the owner", function()
		local h, C, e = setup()
		h:connect(e.viewer)
		h:step()
		expect(h:sees(e.viewer, e.goblins[1])).toBe(true)
		expect(h:sees(e.viewer, e.loot)).toBe(false)
		expect(h:sees(e.healer, e.loot)).toBe(true)
		local lootNet = h:netId(e.loot)
		expect(h:replicaOf(e.tank).entities[lootNet].comps[3]).toEqual({ attack = 12 })
		expect(h:replicaOf(e.healer).entities[lootNet].comps[3]).toBeNil()
		expect(C).never.toBeNil()
	end)

	it("keeps the boss hidden until the reveal, then shows it to everyone in the instance", function()
		local h, _C, e = setup()
		h:connect(e.viewer)
		h:step()
		expect(h:sees(e.tank, e.boss)).toBe(false)
		h.world:remove(e.boss, h.Net.VisibleTo)
		h:step()
		expect(h:sees(e.tank, e.boss)).toBe(true)
		expect(h:sees(e.viewer, e.boss)).toBe(true)
	end)

	it("gives loot rolls to a new owner and takes them from the old one", function()
		local h, _C, e = setup()
		h:step()
		local world, Net, jecs = h.world, h.Net, h.jecs
		world:remove(e.loot, jecs.pair(Net.Owner, e.tank))
		world:add(e.loot, jecs.pair(Net.Owner, e.healer))
		h:step()
		local lootNet = h:netId(e.loot)
		expect(h:replicaOf(e.tank).entities[lootNet].comps[3]).toBeNil()
		expect(h:replicaOf(e.healer).entities[lootNet].comps[3]).toEqual({ attack = 12 })
		-- The rolls still exist, so the old owner is told they're hidden, not removed.
		expect(h:lastComponentRemoval(e.tank, e.loot, 3)).toBe("HIDE")
	end)

	it("sends LEAVE to a player who quits the dungeon and DEL when the boss dies", function()
		local h, _C, e = setup()
		h:step()
		local world, Net, jecs = h.world, h.Net, h.jecs
		world:remove(e.boss, Net.VisibleTo)
		h:step()
		world:remove(e.healer, jecs.pair(Net.Member, e.party))
		h:step()
		expect(h:lastRemoval(e.healer, h:netId(e.goblins[1]))).toBe("LEAVE")
		local bossNet = h:netId(e.boss)
		world:delete(e.boss)
		h:step()
		expect(h:lastRemoval(e.tank, bossNet)).toBe("DEL")
		-- The healer had already lost the boss, so it gets no DEL for it.
		expect(h:lastRemoval(e.healer, bossNet)).toBe("LEAVE")
	end)

	it("lets a late spectator join through budgeted ENTERs", function()
		local h, _C, e = setup({ enterBudget = 3 })
		h:step()
		h:connect(e.viewer)
		local frames = 0
		repeat
			h:step()
			frames += 1
		until h:sees(e.viewer, e.goblins[6]) or frames > 10
		expect(frames).toBe(2) -- 6 goblins at 3 per frame
	end)
end)

describe("arena: far-away players arrive as a name and a team", function()
	-- Every player is public, but where they are and what they're doing goes only to players near
	-- them. A far-away player is still there to refer to: a player, on a team.
	local function setup()
		local h = ScopeHarness.new()
		local world, Net, jecs = h.world, h.Net, h.jecs
		local C = {
			Name = world:component(),
			Team = world:component(),
			Position = world:component(),
			Animation = world:component(),
		}
		-- Game relations. They mean nothing to visibility; OwnedBy is replicated as data.
		local OwnedBy = world:component()
		local Held = world:component()

		-- Ten-stud chunks on a line. A player is near the chunks next to their own.
		h:addRule("near", {
			mode = "restrict",
			dependsOn = { C.Position },
			viewerDependsOn = { C.Position },
			key = function(entity)
				local position = world:get(entity, C.Position)
				return if position then position.x // 10 else nil
			end,
			viewerKeys = function(player)
				local position = world:get(player, C.Position)
				if position == nil then
					return {}
				end
				local chunk = position.x // 10
				return { [chunk - 1] = true, [chunk] = true, [chunk + 1] = true }
			end,
		})
		h:replicate(C.Name)
		h:replicate(C.Team, { isRef = true })
		h:replicate(C.Position, { visibleTo = "near" })
		h:replicate(C.Animation, { visibleTo = "near" })
		h.scope.replicateRelation(OwnedBy)

		local function team(name: string)
			local t = world:entity()
			world:set(t, C.Name, name)
			world:add(t, Net.Public)
			world:add(t, Net.Replicated)
			return t
		end
		local red, blue = team("red"), team("blue")

		local function player(name: string, onTeam: number, x: number)
			local p = world:entity()
			world:set(p, C.Name, name)
			world:set(p, C.Team, onTeam)
			world:set(p, C.Position, { x = x })
			world:set(p, C.Animation, "idle")
			world:add(p, Net.Public)
			world:add(p, Net.Replicated)
			return p
		end
		local alice = player("alice", red, 0)
		local bob = player("bob", blue, 100)

		-- A sword on the ground near alice, owned by far-away bob.
		local sword = world:entity()
		world:set(sword, C.Name, "sword")
		world:set(sword, C.Position, { x = 5 })
		world:add(sword, jecs.pair(OwnedBy, bob))
		world:add(sword, Net.Public)
		world:add(sword, Net.Replicated)

		h:connect(alice)
		h:step()
		return h, C, { blue = blue, alice = alice, bob = bob, sword = sword, Held = Held }
	end
	local NAME, TEAM, POSITION, ANIMATION = 1, 2, 3, 4
	local OWNED_BY = 1

	it("sends a far-away player as a name and a team, without position or animation", function()
		local h, _C, e = setup()
		local bob = h:replicaOf(e.alice).entities[h:netId(e.bob)]
		expect(bob.comps[NAME]).toBe("bob")
		expect(bob.comps[TEAM]).toBe(h:netId(e.blue))
		expect(bob.comps[POSITION]).toBeNil()
		expect(bob.comps[ANIMATION]).toBeNil()

		-- The sword near alice comes whole, with its owner as a pair to that far-away player.
		local sword = h:replicaOf(e.alice).entities[h:netId(e.sword)]
		expect(sword.comps[POSITION]).toEqual({ x = 5 })
		expect(sword.pairs[OWNED_BY][h:netId(e.bob)]).toBe(true)
	end)

	it("sends position and animation when a player comes near, and hides them when they go", function()
		local h, C, e = setup()
		local world = h.world
		world:set(e.bob, C.Position, { x = 12 })
		h:step()
		expect(kinds(h:messagesFor(e.alice))).toEqual({ "SET", "SET" })
		local bob = h:replicaOf(e.alice).entities[h:netId(e.bob)]
		expect(bob.comps[POSITION]).toEqual({ x = 12 })
		expect(bob.comps[ANIMATION]).toBe("idle")

		world:set(e.bob, C.Position, { x = 100 })
		h:step()
		expect(kinds(h:messagesFor(e.alice))).toEqual({ "HIDE", "HIDE" })
		expect(h:lastComponentRemoval(e.alice, e.bob, POSITION)).toBe("HIDE")
		expect(h:sees(e.alice, e.bob)).toBe(true) -- still a player on a team
	end)

	it("sends REM, not HIDE, when a component the client can see is removed", function()
		local h, C, e = setup()
		local world = h.world
		world:set(e.bob, C.Position, { x = 12 })
		h:step()
		world:remove(e.bob, C.Animation)
		h:step()
		expect(kinds(h:messagesFor(e.alice))).toEqual({ "REM" })
		expect(h:lastComponentRemoval(e.alice, e.bob, ANIMATION)).toBe("REM")
	end)

	it("follows the viewer: walking up to a player shows them without re-entering anything", function()
		local h, C, e = setup()
		h.world:set(e.alice, C.Position, { x = 95 })
		h:step()
		local replica = h:replicaOf(e.alice)
		expect(replica.entities[h:netId(e.bob)].comps[POSITION]).toEqual({ x = 100 })
		expect(replica.entities[h:netId(e.sword)].comps[POSITION]).toBeNil()
		expect(h:lastComponentRemoval(e.alice, e.sword, POSITION)).toBe("HIDE")
		for _, message in h:messagesFor(e.alice) do
			expect(message[1] == "ENTER" or message[1] == "LEAVE").toBe(false)
		end
	end)

	it("gives a game relation like Held no say in visibility, and VisibleThrough the say", function()
		local h, C, e = setup()
		local world, Net, jecs = h.world, h.Net, h.jecs
		-- A dagger bob is holding. It has no grants of its own, so holding it shows it to nobody.
		local dagger = world:entity()
		world:set(dagger, C.Name, "dagger")
		world:add(dagger, jecs.pair(e.Held, e.bob))
		world:add(dagger, Net.Replicated)
		h:step()
		expect(h:sees(e.alice, dagger)).toBe(false)

		-- Visible through bob: whoever has bob gets the dagger, near or far.
		world:add(dagger, jecs.pair(Net.VisibleThrough, e.bob))
		h:step()
		expect(h:sees(e.alice, dagger)).toBe(true)

		-- bob leaves the game. jecs removes the pairs pointing at him, so the dagger loses its
		-- only grant, and the sword stays without its owner pair.
		local bobNet, daggerNet = h:netId(e.bob), h:netId(dagger)
		world:delete(e.bob)
		h:step()
		expect(h:lastRemoval(e.alice, bobNet)).toBe("DEL")
		expect(h:lastRemoval(e.alice, daggerNet)).toBe("LEAVE")
		local sword = h:replicaOf(e.alice).entities[h:netId(e.sword)]
		expect(next(sword.pairs[OWNED_BY] or {})).toBeNil()
	end)
end)
