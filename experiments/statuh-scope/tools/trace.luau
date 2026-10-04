--[[
	Replays a fuzz seed and prints every message to one viewer that mentions the given net ids.
	lune run experiments/statuh-scope/tools/trace.luau <seed> <frames> <viewerIndex> <netId>...
	(set BUDGET=<n> to replay a seed from the budgeted run)
]]
local FuzzWorld = require("../src/FuzzWorld")
local process = require("@lune/process")

local seed = tonumber(process.args[1]) or 1
local frames = tonumber(process.args[2]) or 40
local viewer = tonumber(process.args[3]) or 0
local watch = {}
for i = 4, #process.args do
	watch[tonumber(process.args[i]) :: number] = true
end

local function render(message)
	local parts = {}
	for i, part in message do
		parts[i] = if type(part) == "table" then "{..}" else tostring(part)
	end
	return table.concat(parts, " ")
end

local budget = tonumber(process.env.BUDGET or "")
local ok, err = pcall(FuzzWorld.runSeed, seed, frames, {
	enterBudget = budget,
	onFrame = function(h, frame)
		for _, message in h.lastMessages[viewer] or {} do
			if watch[message[2]] or (message[1]:match("PAIR") and watch[message[4]]) then
				print(`frame {frame}: {render(message)}`)
			end
		end
	end,
})
print(if ok then "ok" else tostring(err))
