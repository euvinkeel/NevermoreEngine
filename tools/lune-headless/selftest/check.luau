--!strict
--[[
	Runs the runner's self-test spec and checks every outcome:
	"[fails] ..." tests must fail, "[skipped] ..." tests must be skipped, everything else must pass.

	lune run tools/lune-headless/selftest/check.luau
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local root = process.cwd
local outFile = root .. "/tools/lune-headless/out/selftest.json"
fs.writeDir(root .. "/tools/lune-headless/out")

local result = process.exec(process.env.LUNE or "lune", {
	"run",
	root .. "/tools/lune-headless/worker.luau",
	"--root=" .. root,
	"--spec=" .. root .. "/tools/lune-headless/selftest/Runner.spec.lua",
	"--out=" .. outFile,
})
if not fs.isFile(outFile) then
	print(result.stdout, result.stderr)
	error("worker produced no result")
end

local report = serde.decode("json" :: any, fs.readFile(outFile))
local problems = {}
local counted = 0
for _, test in report.tests do
	counted += 1
	local expected = if string.find(test.name, "[fails]", 1, true)
		then "failed"
		elseif string.find(test.name, "[skipped]", 1, true) then "skipped"
		else "passed"
	if test.status ~= expected then
		table.insert(problems, `{test.name}: expected {expected}, got {test.status} {test.error or ""}`)
	end
end

local strayCount = 0
for _, test in report.tests do
	strayCount += #(test.strayErrors or {})
end
if strayCount ~= 1 then
	table.insert(problems, `expected exactly 1 stray error, got {strayCount}`)
end

if report.status == "load-error" then
	table.insert(problems, "load error: " .. tostring(report.loadError))
end

if #problems > 0 then
	for _, problem in problems do
		print("FAIL " .. problem)
	end
	process.exit(1)
end
print(`selftest OK: {counted} outcomes as expected`)
