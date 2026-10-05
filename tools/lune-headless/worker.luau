--!strict
--[[
	Runs one spec file and writes its result as JSON. run.luau starts one worker per spec, so every
	spec gets fresh module state (like jest-lua's per-file registry) and a hung spec can be killed.

	lune run tools/lune-headless/worker.luau --root=<repo> --spec=<file> --out=<result.json>
		[--index=<index.json>] [--level=none|basic|roblox|datamodel] [--test-timeout=<seconds>]
		[--filter=<text>] [--verbose]
		datamodel level: [--realm=server|client] [--running] [--studio] [--signals=immediate|deferred]
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local Expect = require("./lib/Expect")
local Fs = require("./lib/Fs")
local Host = require("./lib/Host")
local MiniJest = require("./lib/MiniJest")
local ModuleLoader = require("./lib/ModuleLoader")
local PackageIndex = require("./lib/PackageIndex")
local Scheduler = require("./lib/Scheduler")

local args = Fs.parseArgs(process.args)

local root = assert(args.root, "--root is required")
local specPath = assert(args.spec, "--spec is required")
local outPath = args.out
local level = (args.level or "basic") :: Host.Level
local testTimeout = tonumber(args["test-timeout"]) or 5

local index
if args.index and fs.isFile(args.index) then
	index = PackageIndex.decode(fs.readFile(args.index))
else
	index = PackageIndex.build(root)
end

local started = os.clock()

local jest: MiniJest.MiniJest
local scheduler = Scheduler.new(function(message: string)
	jest:strayError(message)
end)
jest = MiniJest.new({
	scheduler = scheduler,
	testTimeout = testTimeout,
	filter = args.filter,
	verbose = args.verbose == "true",
})
local globals = Host.build({
	level = level :: any,
	scheduler = scheduler,
	log = function(kind: string, message: string)
		jest:log(kind, message)
	end,
	datamodel = {
		isClient = args.realm == "client",
		isRunning = args.running == "true",
		isStudio = args.studio == "true",
		signalMode = if args.signals == "deferred" then "deferred" else "immediate",
		apiPath = root .. "/globalTypes.d.lua",
	},
})
if globals.typeof then
	Expect.hostTypeof = globals.typeof
end
local loader = ModuleLoader.new({
	index = index,
	specPath = specPath,
	globals = globals,
	jestGlobals = jest.Globals,
})

local loadOk, loadError = loader:runSpec()
local tests: { MiniJest.TestResult } = {}
if loadOk then
	tests = jest:run()
end

local counts = { passed = 0, failed = 0, skipped = 0, todo = 0 }
for _, test in tests do
	counts[test.status] += 1
end

local result = {
	spec = specPath,
	level = level,
	status = if not loadOk then "load-error" elseif counts.failed > 0 then "fail" else "pass",
	loadError = loadError,
	passed = counts.passed,
	failed = counts.failed,
	skipped = counts.skipped,
	todo = counts.todo,
	durationMs = math.floor((os.clock() - started) * 1000),
	modulesLoaded = loader.loadedCount,
	notes = if #loader.notes > 0 then loader.notes else nil,
	strayErrors = if #jest:fileStrayErrors() > 0 then jest:fileStrayErrors() else nil,
	tests = tests,
}

local encoded = serde.encode("json" :: any, result, args.verbose == "true")
if outPath then
	fs.writeFile(outPath, encoded)
else
	print(encoded)
end

-- Exit now: Lune would otherwise wait for every leftover task.delay before quitting.
process.exit(0)
