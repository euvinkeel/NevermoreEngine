--[[
	The three games from DESIGN.md, run through the prototype. Every step also checks the harness
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
		return h, C, { red = red, blue = blue, alice = alice, bob = bob, carol = carol, tower = tower, redPlan = redPlan }
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
		local h = ScopeHarness.new({ hysteresisFrames = 2 })
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
		-- Neutral resources are only relevant near the player's camera (interest, with hysteresis).
		h:addRule("camera", {
			mode = "relevance",
			appliesTo = C.Resource,
			dependsOn = { C.Cell },
			viewerDependsOn = { C.Focus },
			key = function(entity)
				return world:get(entity, C.Cell)
			end,
			viewerKeys = function(player)
				local focus = world:get(player, C.Focus) or 0
				return { [focus - 1] = true, [focus] = true, [focus + 1] = true }
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
			-- The unit's weapon follows the unit's visibility.
			local weapon = world:entity()
			world:set(weapon, C.Weapon, "spear")
			world:add(weapon, jecs.pair(jecs.ChildOf, u))
			world:add(weapon, jecs.pair(Net.VisibleThrough, jecs.ChildOf))
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
			moved
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

	it("lets a resource linger near the camera edge instead of flapping", function()
		local h, C, e = setup()
		local world = h.world
		expect(h:sees(e.redPlayer, e.ore)).toBe(true)

		world:set(e.redPlayer, C.Focus, 5) -- camera moves away
		h:step()
		expect(h:sees(e.redPlayer, e.ore)).toBe(true) -- lingering
		world:set(e.redPlayer, C.Focus, 1) -- and back before it expires
		h:step()
		expect(h:sees(e.redPlayer, e.ore)).toBe(true)
		local messages = h:messagesFor(e.redPlayer)
		expect(#messages).toBe(0)

		-- With hysteresisFrames = 2 it stays for two frames out of scope and leaves on the third.
		world:set(e.redPlayer, C.Focus, 5)
		h:step()
		h:step()
		expect(h:sees(e.redPlayer, e.ore)).toBe(true)
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
