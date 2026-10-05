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
	local NAME, GOLD, TARGET = 1, 3, 5

	local function setup(options: any?)
		local h = ScopeHarness.new(options)
		local world, Net, jecs, scope = h.world, h.Net, h.jecs, h.scope
		local C = {}
		for _, name in { "Name", "Health", "Gold", "Plan", "Target", "Enemy" } do
			C[name] = world:component()
		end
		scope.replicate(C.Name)
		scope.replicate(C.Health)
		scope.replicate(C.Gold, { visibleTo = "owner" })
		scope.replicate(C.Plan)
		scope.replicate(C.Target, { refs = true })
		scope.setDefaultPublic(C.Enemy)

		local red, blue = h:spawn(nil, { Net.Room }, false), h:spawn(nil, { Net.Room }, false)
		local function player(name: string, team: number)
			local p = h:spawn({ [C.Name] = name, [C.Gold] = 100 }, { Net.Public, jecs.pair(Net.Member, team) })
			world:add(p, jecs.pair(Net.Owner, p))
			return p
		end
		local e = { red = red, blue = blue }
		e.alice, e.bob, e.carol = player("alice", red), player("bob", red), player("carol", blue)
		e.tower = h:spawn({ [C.Health] = 500 }, { Net.Public })
		e.redPlan = h:spawn({ [C.Plan] = "rush the left lane" }, { jecs.pair(Net.Audience, red) })
		for _, p in { e.alice, e.bob, e.carol } do
			h:connect(p)
		end
		h:step()
		return h, C, e
	end

	it("shows the team plan to its team only and gold to its owner only", function()
		local h, _C, e = setup()
		expect(h:sees(e.alice, e.redPlan)).toBe(true)
		expect(h:sees(e.bob, e.redPlan)).toBe(true)
		expect(h:sees(e.carol, e.redPlan)).toBe(false)
		expect(h:sees(e.carol, e.tower)).toBe(true)

		local aliceNet = h:netId(e.alice)
		expect(h:replicaOf(e.alice).entities[aliceNet].comps[GOLD]).toBe(100)
		expect(h:replicaOf(e.carol).entities[aliceNet].comps[GOLD]).toBeNil()
		expect(h:replicaOf(e.carol).entities[aliceNet].comps[NAME]).toBe("alice")
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
		local scout = h:spawn({ [C.Health] = 30 }, { jecs.pair(Net.Audience, e.red) })
		world:set(e.tower, C.Target, scout)
		h:step()
		local towerNet = h:netId(e.tower)
		expect(h:replicaOf(e.alice).entities[towerNet].comps[TARGET]).toBe(h:netId(scout))
		expect(h:replicaOf(e.carol).entities[towerNet].comps[TARGET]).toBe(h.scope.REDACTED)

		-- The scout is spotted by blue: carol gets ENTER, then the tower's target re-sent.
		world:add(scout, jecs.pair(Net.Audience, e.blue))
		h:step()
		expect(kinds(h:messagesFor(e.carol))).toEqual({ "ENTER", "SET" })
		expect(h:replicaOf(e.carol).entities[towerNet].comps[TARGET]).toBe(h:netId(scout))

		-- And hidden again: carol forgets the scout and redacts her own reference to it.
		world:remove(scout, jecs.pair(Net.Audience, e.blue))
		h:step()
		expect(kinds(h:messagesFor(e.carol))).toEqual({ "LEAVE" })
		expect(h:replicaOf(e.carol).entities[towerNet].comps[TARGET]).toBe(h.scope.REDACTED)
	end)

	it("sends DEL for a destroyed tower and LEAVE for one that stops replicating", function()
		local h, C, e = setup()
		local towerNet = h:netId(e.tower)
		h.world:delete(e.tower)
		h:step()
		expect(h:lastRemoval(e.carol, towerNet)).toBe("DEL")

		local banner = h:spawn({ [C.Name] = "banner" }, { h.Net.Public })
		h:step()
		local bannerNet = h:netId(banner)
		h.world:remove(banner, h.Net.Replicated)
		h:step()
		expect(h:lastRemoval(e.carol, bannerNet)).toBe("LEAVE")
	end)

	it("makes enemies public as they spawn, with a grant anyone can see in the world", function()
		local h, C, e = setup()
		local enemy = h:spawn({ [C.Health] = 80 }, { C.Enemy })
		h:step()
		expect(h.world:has(enemy, h.Net.Public)).toBe(true)
		expect(h:sees(e.carol, enemy)).toBe(true)
	end)

	it("keeps a predicted spawn in its client's scope until acknowledged, and rolls back the rest", function()
		-- The oracle can't see pins, so it sits this one out.
		local h, C, e = setup({ skipOracle = true })
		local scope = h.scope
		-- alice predicts two spawns in action 1, minting net ids for both.
		scope.clientMinted(e.alice, 1, 1001)
		scope.clientMinted(e.alice, 1, 1002)
		-- The server makes the first, granted to nobody yet, under alice's net id.
		local tower = h:spawn({ [C.Health] = 100 })
		scope.bindMinted(tower, e.alice, 1001)
		h:step()
		expect(h:netId(tower)).toBe(1001)
		expect(h:sees(e.alice, tower)).toBe(true)
		expect(h:sees(e.bob, tower)).toBe(false)

		scope.acknowledge(e.alice, 1)
		h:step()
		expect(h:lastRemoval(e.alice, 1001)).toBe("LEAVE")
		expect(h:lastRemoval(e.alice, 1002)).toBe("ROLLBACK")
	end)
end)

describe("RTS with fog of war", function()
	-- The map is a 1D strip of cells. Each team sees the cells near its units.
	local function setup()
		local h = ScopeHarness.new()
		local world, Net, jecs, scope = h.world, h.Net, h.jecs, h.scope
		local C = {}
		for _, name in { "Unit", "Cell", "Team", "Weapon", "Resource", "Focus" } do
			C[name] = world:component()
		end
		scope.replicate(C.Cell)
		scope.replicate(C.Weapon)
		scope.replicate(C.Resource)
		scope.replicateRelation(jecs.ChildOf)

		local red, blue = h:spawn(nil, { Net.Room }, false), h:spawn(nil, { Net.Room }, false)
		local teamOf = {}

		-- Enemies see a unit when it stands in a cell their team has vision of.
		scope.addScopeRule("fog", {
			mode = "grant",
			appliesTo = C.Unit,
			dependsOn = { C.Cell },
			key = function(entity)
				return world:get(entity, C.Cell)
			end,
			viewerKeys = function(player)
				local cells = {}
				for _, cell, team in world:query(C.Cell, C.Team):with(C.Unit) do
					if team == teamOf[player] then
						cells[cell - 1], cells[cell], cells[cell + 1] = true, true, true
					end
				end
				return cells
			end,
		})
		-- Neutral resources are only sent near the player's camera. Interest management is game
		-- code: an ordinary restrict rule. A game that wants things to linger at the edge keeps
		-- old cells in its keys for a while (`trail`, cleared by the game when it decides to).
		local trail: { [number]: { [number]: true } } = {}
		scope.addScopeRule("camera", {
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
			local p = h:spawn({ [C.Focus] = focus }, { jecs.pair(Net.Member, team) }, false)
			teamOf[p] = team
			return p
		end
		local function unit(team: number, cell: number)
			-- Your own team always sees your units.
			local u = h:spawn({ [C.Team] = team, [C.Cell] = cell }, { C.Unit, jecs.pair(Net.Audience, team) })
			-- The weapon is the unit's child (game data) and visible through the unit (replication).
			local weapon = h:spawn({ [C.Weapon] = "spear" }, {
				jecs.pair(jecs.ChildOf, u),
				jecs.pair(Net.VisibleThrough, u),
			})
			return u, weapon
		end
		local e = { redPlayer = player(red, 0), bluePlayer = player(blue, 10) }
		e.redUnit, e.redWeapon = unit(red, 0)
		e.blueUnit, e.blueWeapon = unit(blue, 10)
		e.ore = h:spawn({ [C.Cell] = 1 }, { C.Resource, Net.Public })
		h:connect(e.redPlayer)
		h:connect(e.bluePlayer)
		h:step()

		local function moved()
			scope.invalidateViewerKeys("fog")
		end
		-- Game-side lingering: move the camera but keep the old view's cells for now.
		local function panKeepingTrail(p: number, focus: number)
			local old = world:get(p, C.Focus) or 0
			trail[p] = { [old - 1] = true, [old] = true, [old + 1] = true }
			world:set(p, C.Focus, focus)
		end
		local function dropTrail(p: number)
			trail[p] = nil
			scope.invalidateViewerKeys("camera", p)
		end
		return h, C, e, moved, panKeepingTrail, dropTrail
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
		h.world:set(e.redUnit, C.Cell, 9) -- next to the blue unit
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
		h.world:set(e.redUnit, C.Cell, 0)
		moved()
		h:step()
		expect(h:sees(e.redPlayer, e.blueUnit)).toBe(false)
		expect(h:lastRemoval(e.redPlayer, h:netId(e.blueUnit))).toBe("LEAVE")
	end)

	it("hides a resource as soon as the camera moves away, and shows it again on return", function()
		local h, C, e = setup()
		expect(h:sees(e.redPlayer, e.ore)).toBe(true)
		h.world:set(e.redPlayer, C.Focus, 5) -- camera moves away
		h:step()
		expect(h:sees(e.redPlayer, e.ore)).toBe(false)
		expect(h:lastRemoval(e.redPlayer, h:netId(e.ore))).toBe("LEAVE")
		h.world:set(e.redPlayer, C.Focus, 1) -- and back
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
	local ROLLS = 3

	local function setup(options: any?)
		local h = ScopeHarness.new(options)
		local world, Net, jecs, scope = h.world, h.Net, h.jecs, h.scope
		local C = { Name = world:component(), Health = world:component(), Rolls = world:component() }
		scope.replicate(C.Name)
		scope.replicate(C.Health)
		scope.replicate(C.Rolls, { visibleTo = "owner" })

		local party, spectators = h:spawn(nil, { Net.Room }, false), h:spawn(nil, { Net.Room }, false)
		local function player(name: string, room: number)
			return h:spawn({ [C.Name] = name }, { jecs.pair(Net.Member, room) }, false)
		end
		local e = { party = party, spectators = spectators, goblins = {} }
		e.tank, e.healer, e.viewer = player("tank", party), player("healer", party), player("viewer", spectators)
		local function monster(name: string)
			return h:spawn({ [C.Name] = name, [C.Health] = 100 }, {
				jecs.pair(Net.Audience, party),
				jecs.pair(Net.Audience, spectators),
			})
		end
		for i = 1, 6 do
			e.goblins[i] = monster("goblin " .. i)
		end
		e.boss = monster("boss")
		world:set(e.boss, Net.VisibleTo, "server") -- hidden until the reveal
		-- Spectators don't see loot; its rolls go to the looter only.
		e.loot = h:spawn({ [C.Name] = "sword", [C.Rolls] = { attack = 12 } }, {
			jecs.pair(Net.Audience, party),
			jecs.pair(Net.Owner, e.tank),
		})
		h:connect(e.tank)
		h:connect(e.healer)
		return h, C, e
	end

	it("shows monsters to party and spectators, loot to the party, rolls to the owner", function()
		local h, _C, e = setup()
		h:connect(e.viewer)
		h:step()
		expect(h:sees(e.viewer, e.goblins[1])).toBe(true)
		expect(h:sees(e.viewer, e.loot)).toBe(false)
		expect(h:sees(e.healer, e.loot)).toBe(true)
		local lootNet = h:netId(e.loot)
		expect(h:replicaOf(e.tank).entities[lootNet].comps[ROLLS]).toEqual({ attack = 12 })
		expect(h:replicaOf(e.healer).entities[lootNet].comps[ROLLS]).toBeNil()
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
		expect(h:replicaOf(e.tank).entities[lootNet].comps[ROLLS]).toBeNil()
		expect(h:replicaOf(e.healer).entities[lootNet].comps[ROLLS]).toEqual({ attack = 12 })
		-- The rolls still exist, so the old owner is told they're hidden, not removed.
		expect(h:lastRemoval(e.tank, lootNet, ROLLS)).toBe("HIDE")
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
	local NAME, TEAM, POSITION, ANIMATION = 1, 2, 3, 4
	local OWNED_BY = 1

	local function setup()
		local h = ScopeHarness.new()
		local world, Net, jecs, scope = h.world, h.Net, h.jecs, h.scope
		local C = {}
		for _, name in { "Name", "Team", "Position", "Animation" } do
			C[name] = world:component()
		end
		-- Game relations. They mean nothing to visibility; OwnedBy is replicated as data.
		local OwnedBy, Held = world:component(), world:component()

		-- Ten-stud chunks on a line. A player is near the chunks next to their own.
		scope.addScopeRule("near", {
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
		scope.replicate(C.Name)
		scope.replicate(C.Team, { refs = true })
		scope.replicate(C.Position, { visibleTo = "near" })
		scope.replicate(C.Animation, { visibleTo = "near" })
		scope.replicateRelation(OwnedBy)

		local red, blue = h:spawn({ [C.Name] = "red" }, { Net.Public }), h:spawn({ [C.Name] = "blue" }, { Net.Public })
		local function player(name: string, team: number, x: number)
			return h:spawn({ [C.Name] = name, [C.Team] = team, [C.Position] = { x = x }, [C.Animation] = "idle" }, {
				Net.Public,
			})
		end
		local e = { blue = blue, Held = Held }
		e.alice, e.bob = player("alice", red, 0), player("bob", blue, 100)
		-- A sword on the ground near alice, owned by far-away bob.
		e.sword = h:spawn({ [C.Name] = "sword", [C.Position] = { x = 5 } }, { jecs.pair(OwnedBy, e.bob), Net.Public })
		h:connect(e.alice)
		h:step()
		return h, C, e
	end

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
		h.world:set(e.bob, C.Position, { x = 12 })
		h:step()
		expect(kinds(h:messagesFor(e.alice))).toEqual({ "SET", "SET" })
		local bob = h:replicaOf(e.alice).entities[h:netId(e.bob)]
		expect(bob.comps[POSITION]).toEqual({ x = 12 })
		expect(bob.comps[ANIMATION]).toBe("idle")

		h.world:set(e.bob, C.Position, { x = 100 })
		h:step()
		expect(kinds(h:messagesFor(e.alice))).toEqual({ "HIDE", "HIDE" })
		expect(h:lastRemoval(e.alice, h:netId(e.bob), POSITION)).toBe("HIDE")
		expect(h:sees(e.alice, e.bob)).toBe(true) -- still a player on a team
	end)

	it("sends REM, not HIDE, when a component the client can see is removed", function()
		local h, C, e = setup()
		h.world:set(e.bob, C.Position, { x = 12 })
		h:step()
		h.world:remove(e.bob, C.Animation)
		h:step()
		expect(kinds(h:messagesFor(e.alice))).toEqual({ "REM" })
		expect(h:lastRemoval(e.alice, h:netId(e.bob), ANIMATION)).toBe("REM")
	end)

	it("follows the viewer: walking up to a player shows them without re-entering anything", function()
		local h, C, e = setup()
		h.world:set(e.alice, C.Position, { x = 95 })
		h:step()
		local replica = h:replicaOf(e.alice)
		expect(replica.entities[h:netId(e.bob)].comps[POSITION]).toEqual({ x = 100 })
		expect(replica.entities[h:netId(e.sword)].comps[POSITION]).toBeNil()
		expect(h:lastRemoval(e.alice, h:netId(e.sword), POSITION)).toBe("HIDE")
		for _, message in h:messagesFor(e.alice) do
			expect(message[1] == "ENTER" or message[1] == "LEAVE").toBe(false)
		end
	end)

	it("gives a game relation like Held no say in visibility, and VisibleThrough the say", function()
		local h, C, e = setup()
		local world, Net, jecs = h.world, h.Net, h.jecs
		-- A dagger bob is holding. It has no grants of its own, so holding it shows it to nobody.
		local dagger = h:spawn({ [C.Name] = "dagger" }, { jecs.pair(e.Held, e.bob) })
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
