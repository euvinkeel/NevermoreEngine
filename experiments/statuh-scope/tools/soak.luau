--[[
	Runs many fuzz seeds outside the test runner and reports every failing seed.
	lune run experiments/statuh-scope/tools/soak.luau <firstSeed> <lastSeed> [frames] [enterBudget]
]]
local FuzzWorld = require("../src/FuzzWorld")
local process = require("@lune/process")

local first = tonumber(process.args[1]) or 1
local last = tonumber(process.args[2]) or 1000
local frames = tonumber(process.args[3]) or 60
local budget = tonumber(process.args[4])
local failures = 0
local started = os.clock()
for seed = first, last do
	local ok, err = pcall(FuzzWorld.runSeed, seed, frames, { enterBudget = budget })
	if not ok then
		failures += 1
		print(tostring(err))
	end
end
print(
	`soak: seeds {first}..{last}, {frames} frames, budget {budget or "none"}: {failures} failing, {string.format(
		"%.1f",
		os.clock() - started
	)} s`
)
process.exit(if failures == 0 then 0 else 1)
