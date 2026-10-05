--[[
	Every jecs bug in JecsBugs, run both ways: through JecsWorkarounds it must leave the world
	consistent, and with plain jecs calls it must still go wrong. When a jecs upgrade fixes a bug,
	its "still present" test fails; that's the sign its workaround can go.
]]
local JecsBugs = require("./JecsBugs")
local JecsWorkarounds = require("./JecsWorkarounds")
local Jest = require("Jest")
local RandomWorld = require("./RandomWorld")
local jecs: any = require("../../src/jecs/node_modules/@quentystudios/jecs/src/jecs")

local describe = Jest.Globals.describe
local expect = Jest.Globals.expect
local it = Jest.Globals.it

describe("jecs 0.11.0-quenty.3 bugs", function()
	for _, bug in JecsBugs.bugs do
		it(`are avoided by the workarounds: {bug.name}`, function()
			expect(JecsBugs.run(bug, true)).toBeNil()
		end)
		it(`are still present with plain jecs calls: {bug.name}`, function()
			expect(JecsBugs.run(bug, false)).never.toBeNil()
		end)
	end

	it("leave random worlds equal to a plain model with the workarounds: 1,000 seeds x 60 operations", function()
		for seed = 1, 1000 do
			local problem = RandomWorld.run(seed, 60, true)
			if problem then
				error(`seed {seed}: {problem}`, 0)
			end
		end
		expect(true).toBe(true)
	end, 60)
end)

describe("JecsWorkarounds.doomedBy", function()
	it("lists what a delete takes with it: ChildOf descendants, not ordinary followers", function()
		local world = jecs.world()
		local Follows = world:component()
		local parent, child, grandchild, follower = world:entity(), world:entity(), world:entity(), world:entity()
		world:add(child, jecs.pair(jecs.ChildOf, parent))
		world:add(grandchild, jecs.pair(jecs.ChildOf, child))
		world:add(follower, jecs.pair(Follows, parent))
		local doomed = JecsWorkarounds.doomedBy(world, parent)
		table.sort(doomed)
		expect(doomed).toEqual({ parent, child, grandchild })
	end)
end)
