--[[
	Randomized invariant tests. Each seed builds a random world (rooms, players, grants, overrides,
	inheritance chains and cycles, all three rule modes, references, owner-only data), then applies
	random edits every frame. After every frame ScopeHarness checks, among others:

	- no out-of-scope net id ever appears in any client's output (invariant 3, and the replica's
	  own check that every id a message mentions is one it has);
	- LEAVE and DEL are never confused (invariant 6);
	- inheritance groups enter atomically (invariant 7);
	- every client equals the projection of the server onto its delivered scope (invariant 4).

	"Removing a constraint never widens visibility" is checked directly: at random points the test
	snapshots the oracle, applies one narrowing edit (drop a grant, a membership or rule data, or
	add a restriction), and checks nothing became visible. The engine equals the oracle every frame
	(invariant 2), so the property holds for the engine too.

	Every failure message starts with the seed and frame, so a run can be replayed with runSeed().
]]
local FuzzWorld = require("../src/FuzzWorld")
local Jest = require("Jest")

local describe = Jest.Globals.describe
local expect = Jest.Globals.expect
local it = Jest.Globals.it

describe("scope invariants on random worlds", function()
	it("hold for 150 seeds x 40 frames, unlimited ENTER budget", function()
		for seed = 1, 150 do
			FuzzWorld.runSeed(seed, 40)
		end
		expect(true).toBe(true)
	end, 60)

	it("hold for 100 seeds x 40 frames with an ENTER budget of 2", function()
		for seed = 1001, 1100 do
			FuzzWorld.runSeed(seed, 40, { enterBudget = 2 })
		end
		expect(true).toBe(true)
	end, 60)
end)
