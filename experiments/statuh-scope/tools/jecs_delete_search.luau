--[[
	A jecs-only random search for delete bugs: small worlds with ChildOf trees, an ordinary relation
	(Follows), tags and values, then one delete. Afterwards every survivor must keep its values and
	have no dangling ChildOf, and the delete must not error. Prints the first few failing seeds with
	the operations that built them.

	lune run experiments/statuh-scope/tools/jecs_delete_search.luau [seeds]

	It found experiments/jecs-findings/cascade_delete_crashes.luau. It uses a single relation besides
	ChildOf, so it can't hit delete_corrupts_survivor.luau, which needs two.
]]
local Rng = require("../src/Rng")
local jecs = require("../src/Jecs")
local process = require("@lune/process")

local lastLog = {}
local function run(seed: number, verbose: boolean): string?
	local rng = Rng.new(seed)
	local world = jecs.world()
	local Follows = world:component()
	world:add(Follows, jecs.Exclusive)
	local Tag = world:component()
	local Cell = world:component()
	local log = {}
	lastLog = log
	local expected = {} -- entity -> Cell value
	local alive = {}
	local names = {}
	local function name(e)
		return names[e] or tostring(e)
	end
	for i = 1, rng:int(3, 9) do
		local e = world:entity()
		names[e] = "e" .. i
		table.insert(alive, e)
		if rng:chance(0.7) then
			world:set(e, Cell, i * 10)
			expected[e] = i * 10
			table.insert(log, `world:set({name(e)}, Cell, {i * 10})`)
		end
		if rng:chance(0.3) then
			world:add(e, Tag)
			table.insert(log, `world:add({name(e)}, Tag)`)
		end
		if i > 1 and rng:chance(0.5) then
			local p = alive[rng:int(1, i - 1)]
			world:add(e, jecs.pair(jecs.ChildOf, p))
			table.insert(log, `world:add({name(e)}, pair(ChildOf, {name(p)}))`)
		end
		if i > 1 and rng:chance(0.5) then
			local t = alive[rng:int(1, i - 1)]
			world:add(e, jecs.pair(Follows, t))
			table.insert(log, `world:add({name(e)}, pair(Follows, {name(t)}))`)
		end
	end
	-- some follow edges to later entities too
	for _ = 1, rng:int(0, 3) do
		local a, b = alive[rng:int(1, #alive)], alive[rng:int(1, #alive)]
		if a ~= b then
			world:add(a, jecs.pair(Follows, b))
			table.insert(log, `world:add({name(a)}, pair(Follows, {name(b)}))`)
		end
	end
	local victim = alive[rng:int(1, #alive)]
	table.insert(log, `world:delete({name(victim)})`)
	world:delete(victim)
	for _, e in alive do
		if world:contains(e) then
			local want = expected[e]
			local got = world:get(e, Cell)
			if want ~= nil and got ~= want then
				return `{name(e)} Cell {tostring(want)} -> {tostring(got)} (has={world:has(e, Cell)})\n  `
					.. table.concat(log, "\n  ")
			end
			local parent = world:target(e, jecs.ChildOf, 0)
			if parent and not world:contains(parent) then
				return `{name(e)} dangling ChildOf\n  ` .. table.concat(log, "\n  ")
			end
		end
	end
	return nil
end

local found = 0
for seed = 1, tonumber(process.args[1]) or 20000 do
	local okRun, problem = pcall(run, seed, false)
	if not okRun then
		problem = "crash: " .. tostring(problem) .. "\n  " .. table.concat(lastLog, "\n  ")
	end
	if problem then
		print(`seed {seed}: {problem}`)
		found += 1
		if found >= 3 then
			break
		end
	end
end
print("found", found)
