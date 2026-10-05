--[[
	Prints how each bug in JecsBugs shows on the jecs installed now, with plain calls and through
	JecsWorkarounds, then runs RandomWorld over many seeds both ways. After a jecs upgrade, this
	says which workarounds can go.

	lune run experiments/jecs-findings/check.luau [seeds] [steps]
]]
local JecsBugs = require("./JecsBugs")
local RandomWorld = require("./RandomWorld")
local process = require("@lune/process")

for _, bug in JecsBugs.bugs do
	print(bug.name)
	print(`  plain jecs calls:  {JecsBugs.run(bug, false) or "fine: fixed in this jecs?"}`)
	print(`  with workarounds:  {JecsBugs.run(bug, true) or "fine"}`)
end

local seeds, steps = tonumber(process.args[1]) or 2000, tonumber(process.args[2]) or 40
for _, fixed in { false, true } do
	local failing, example = 0, nil
	for seed = 1, seeds do
		local problem = RandomWorld.run(seed, steps, fixed)
		if problem then
			failing += 1
			example = example or `seed {seed}: {problem}`
		end
	end
	local label = if fixed then "with workarounds" else "plain jecs calls"
	print(`random worlds, {label}: {failing} of {seeds} went wrong ({steps} operations each)`)
	if fixed and example then
		print(example)
	end
end
