--[[
	Runs RandomWorld over many seeds, once with plain jecs calls and once through JecsWorkarounds,
	and reports how many seeds go wrong in each. Plain jecs calls show the bugs in this folder;
	with the workarounds, no seed should go wrong. Prints the first few problems of each kind.

	lune run experiments/jecs-findings/search.luau [seeds] [steps]

	The earlier, delete-only version of this search found cascade_delete_crashes.luau.
]]
local RandomWorld = require("./RandomWorld")
local process = require("@lune/process")

local seeds = tonumber(process.args[1]) or 2000
local steps = tonumber(process.args[2]) or 40

for _, useWorkarounds in { false, true } do
	local label = if useWorkarounds then "with JecsWorkarounds" else "plain jecs calls"
	local failing = 0
	local byKind: { [string]: number } = {}
	local examples: { [string]: string } = {}
	for seed = 1, seeds do
		local problem = RandomWorld.run(seed, steps, useWorkarounds)
		if problem then
			failing += 1
			-- The kind is the first line with the entity names taken out.
			local firstLine = string.match(problem, "^[^\n]*") :: string
			local kind = string.gsub(string.gsub(firstLine, "e%d+", "e"), "%d+", "N")
			byKind[kind] = (byKind[kind] or 0) + 1
			if not examples[kind] then
				examples[kind] = `seed {seed}: {problem}`
			end
		end
	end
	print(`{label}: {failing} of {seeds} seeds went wrong ({steps} operations each)`)
	local kinds = {}
	for kind in byKind do
		table.insert(kinds, kind)
	end
	table.sort(kinds, function(a, b)
		return byKind[a] > byKind[b]
	end)
	for _, kind in kinds do
		print(`  {byKind[kind]} x {kind}`)
	end
	if useWorkarounds then
		for _, kind in kinds do
			print(examples[kind])
		end
	end
end
