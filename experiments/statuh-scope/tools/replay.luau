--[[
	Replays one fuzz seed outside the test runner and prints the error, if any.
	lune run experiments/statuh-scope/tools/replay.luau <seed> [frames] [enterBudget]
	(set JECS_WORKAROUNDS=0 to run plain jecs calls)
]]
local FuzzWorld = require("../src/FuzzWorld")
local process = require("@lune/process")

local seed = tonumber(process.args[1]) or 1
local frames = tonumber(process.args[2]) or 40
local budget = tonumber(process.args[3])
local ok, err = pcall(FuzzWorld.runSeed, seed, frames, {
	enterBudget = budget,
	jecsWorkarounds = process.env.JECS_WORKAROUNDS ~= "0",
})
print(if ok then `seed {seed}: ok` else tostring(err))
