--!strict
--[[
	Headless spec runner for Nevermore under Lune.

	lune run tools/lune-headless/run.luau [options] [spec files or package dirs...]

	Which specs run (default: every spec in the immediateutils closure):
		--all                     every spec under src/
		--package=<a,b>           packages by directory or npm name (e.g. maid,@quenty/rx)
		<paths>                   spec files, package directories, or other directories of specs

	Options:
		--level=basic             host level: none | basic | roblox (see lib/Host.luau)
		--jobs=4                  specs run in parallel, one Lune process each
		--timeout=60              seconds before a whole spec process is killed
		--test-timeout=5          seconds a single test (or hook) may take
		--filter=<text>           only run tests whose full name contains <text>
		--json=<path>             summary path (default tools/lune-headless/out/results.json)
		--expect=<path>           expectations file; exit code reflects it (see README)
		--detail                  include every test in the summary, not just failures
		--quiet                   print only the totals
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local task = require("@lune/task")

local Expectations = require("./lib/Expectations")
local PackageIndex = require("./lib/PackageIndex")

local DEFAULT_ROOTS = { "@quenty/immediateutils", "@quenty/jecs", "@quenty/iris" }

-- Arguments

local options: { [string]: string } = {}
local positional: { string } = {}
for _, arg in process.args do
	local key, value = string.match(arg, "^%-%-([%w%-]+)=(.*)$")
	if key and value then
		options[key] = value
	elseif string.match(arg, "^%-%-[%w%-]+$") then
		options[string.sub(arg, 3)] = "true"
	else
		table.insert(positional, arg)
	end
end

local root = options.root or process.cwd
root = string.gsub(root, "[/\\]+$", "")
if not fs.isDir(root .. "/src") then
	error(`{root} doesn't look like the Nevermore repo (no src/ directory). Run from the repo root or pass --root.`)
end

local TOOL_DIR = root .. "/tools/lune-headless"
local OUT_DIR = TOOL_DIR .. "/out"
local level = options.level or "basic"
local jobs = math.max(1, tonumber(options.jobs) or 4)
local specTimeout = tonumber(options.timeout) or 60
local lune = process.env.LUNE or "lune"
local quiet = options.quiet == "true"

local function relative(path: string): string
	if string.sub(path, 1, #root + 1) == root .. "/" then
		return string.sub(path, #root + 2)
	end
	return path
end

local function absolute(path: string): string
	if string.sub(path, 1, 1) == "/" or string.match(path, "^%a:[/\\]") then
		return path
	end
	return root .. "/" .. path
end

local started = os.clock()
local index = PackageIndex.build(root)
fs.writeDir(OUT_DIR .. "/specs")
local indexPath = OUT_DIR .. "/index.json"
fs.writeFile(indexPath, PackageIndex.encode(index))

-- Spec selection

local specs: { string } = {}
local seenSpecs: { [string]: boolean } = {}
local function addSpec(path: string)
	if not seenSpecs[path] then
		seenSpecs[path] = true
		table.insert(specs, path)
	end
end

local function packageIdFor(nameOrDir: string): string?
	if index.packages["src/" .. nameOrDir] then
		return "src/" .. nameOrDir
	end
	if index.byName[nameOrDir] then
		return index.byName[nameOrDir]
	end
	if index.byName["@quenty/" .. nameOrDir] then
		return index.byName["@quenty/" .. nameOrDir]
	end
	return nil
end

local function addPackage(id: string)
	for _, spec in PackageIndex.specsOf(index, id) do
		addSpec(spec)
	end
end

local selection
if options.all == "true" then
	selection = "all"
	local ids = {}
	for id, pkg in index.packages do
		if pkg.isWorkspace then
			table.insert(ids, id)
		end
	end
	table.sort(ids)
	for _, id in ids do
		addPackage(id)
	end
elseif options.package or #positional > 0 then
	selection = "explicit"
	local packageNames: { string } = if options.package then string.split(options.package, ",") else {}
	for _, name in packageNames do
		local id = packageIdFor(name)
		if not id then
			error(`Unknown package "{name}"`)
		end
		addPackage(id)
	end
	for _, arg in positional do
		local path = absolute(arg)
		path = string.gsub(path, "[/\\]+$", "")
		if fs.isFile(path) then
			addSpec(path)
		else
			local id = PackageIndex.packageOfPath(index, path .. "/") or packageIdFor(arg)
			if id then
				addPackage(id)
			elseif fs.isDir(path) then
				-- A plain directory outside src/ (e.g. experiments/): every spec file under it.
				local found = {}
				local function walk(dir: string)
					local entries = fs.readDir(dir)
					table.sort(entries)
					for _, entry in entries do
						local child = dir .. "/" .. entry
						if entry ~= "node_modules" and string.sub(entry, 1, 1) ~= "." then
							if fs.isDir(child) then
								walk(child)
							elseif string.match(entry, "%.spec%.luau?$") then
								table.insert(found, child)
							end
						end
					end
				end
				walk(path)
				for _, spec in found do
					addSpec(spec)
				end
			else
				error(`"{arg}" is neither a spec file, a package nor a directory`)
			end
		end
	end
else
	selection = "closure:" .. table.concat(DEFAULT_ROOTS, ",")
	local ids = {}
	local seen = {}
	for _, rootName in DEFAULT_ROOTS do
		local rootId = index.byName[rootName]
		if rootId then
			for _, id in PackageIndex.closure(index, rootId) do
				local pkg = index.packages[id]
				if not seen[id] and pkg and pkg.isWorkspace then
					seen[id] = true
					table.insert(ids, id)
				end
			end
		end
	end
	for _, id in ids do
		addPackage(id)
	end
end

if #specs == 0 then
	print("No specs selected.")
	process.exit(0)
end

-- Running

type SpecResult = { [string]: any }

local function resultFileFor(spec: string): string
	local name = string.gsub(relative(spec), "[^%w%.%-]", "_")
	return OUT_DIR .. "/specs/" .. name .. ".json"
end

local function runOne(spec: string): SpecResult
	local outFile = resultFileFor(spec)
	if fs.isFile(outFile) then
		fs.removeFile(outFile)
	end
	local workerArgs = {
		"run",
		TOOL_DIR .. "/worker.luau",
		"--root=" .. root,
		"--spec=" .. spec,
		"--out=" .. outFile,
		"--index=" .. indexPath,
		"--level=" .. level,
	}
	for _, key in { "test-timeout", "filter" } do
		if options[key] then
			table.insert(workerArgs, `--{key}={options[key]}`)
		end
	end
	if options.detail == "true" then
		table.insert(workerArgs, "--detail")
	end

	local specStarted = os.clock()
	local child = process.create(lune, workerArgs, { cwd = root })
	local stdout, stderr = "", ""
	local readers = 2
	task.spawn(function()
		stdout = child.stdout:readToEnd()
		readers -= 1
	end)
	task.spawn(function()
		stderr = child.stderr:readToEnd()
		readers -= 1
	end)
	local finished = false
	local timedOut = false
	task.delay(specTimeout, function()
		if not finished then
			timedOut = true
			child:kill()
		end
	end)
	local status = child:status()
	finished = true
	while readers > 0 do
		task.wait()
	end
	local elapsedMs = math.floor((os.clock() - specStarted) * 1000)

	if fs.isFile(outFile) then
		local ok, decoded = pcall(serde.decode, "json" :: any, fs.readFile(outFile))
		if ok then
			decoded.wallMs = elapsedMs
			return decoded
		end
	end
	local output = string.sub(stderr .. stdout, 1, 2000)
	return {
		spec = spec,
		status = if timedOut then "timeout" else "crash",
		loadError = if timedOut
			then `Spec process killed after {specTimeout} s (a test likely looped forever without yielding)`
			else `Worker exited with code {status.code} without a result:\n{output}`,
		passed = 0,
		failed = 0,
		skipped = 0,
		todo = 0,
		wallMs = elapsedMs,
		tests = {},
	}
end

local results: { SpecResult } = table.create(#specs)
local nextIndex = 1
local active = 0
for _ = 1, math.min(jobs, #specs) do
	active += 1
	task.spawn(function()
		while nextIndex <= #specs do
			local i = nextIndex
			nextIndex += 1
			results[i] = runOne(specs[i])
		end
		active -= 1
	end)
end
while active > 0 do
	task.wait(0.01)
end

-- Summary

local totals = {
	specs = #specs,
	pass = 0,
	fail = 0,
	loadError = 0,
	timeout = 0,
	crash = 0,
	tests = 0,
	passed = 0,
	failed = 0,
	skipped = 0,
	todo = 0,
}
local summarySpecs = {}
for _, result in results do
	local status = result.status
	local key = if status == "load-error" then "loadError" else status
	totals[key] = (totals[key] or 0) + 1
	totals.passed += result.passed or 0
	totals.failed += result.failed or 0
	totals.skipped += result.skipped or 0
	totals.todo += result.todo or 0

	local failures = {}
	local strayCount = #(result.strayErrors or {})
	for _, test in result.tests or {} do
		if test.status == "failed" then
			table.insert(failures, { name = test.name, error = test.error, logs = test.logs })
		end
		strayCount += #(test.strayErrors or {})
	end
	local packageId = PackageIndex.packageOfPath(index, result.spec) or "?"
	table.insert(summarySpecs, {
		package = string.gsub(packageId, "^src/", ""),
		spec = relative(result.spec),
		status = status,
		passed = result.passed,
		failed = result.failed,
		skipped = result.skipped,
		todo = result.todo,
		durationMs = result.durationMs,
		wallMs = result.wallMs,
		modulesLoaded = result.modulesLoaded,
		loadError = result.loadError,
		failures = if #failures > 0 then failures else nil,
		strayErrorCount = if strayCount > 0 then strayCount else nil,
		strayErrors = result.strayErrors,
		notes = result.notes,
		tests = if options.detail == "true" then result.tests else nil,
	})
end
totals.tests = totals.passed + totals.failed

local expectationReport = nil
if options.expect then
	expectationReport = Expectations.check(fs.readFile(absolute(options.expect)), summarySpecs)
end

local summary = {
	tool = "lune-headless",
	level = level,
	selection = selection,
	durationMs = math.floor((os.clock() - started) * 1000),
	totals = totals,
	expectations = expectationReport,
	specs = summarySpecs,
}
local jsonPath = if options.json then absolute(options.json) else OUT_DIR .. "/results.json"
fs.writeFile(jsonPath, serde.encode("json" :: any, summary, true))

local function firstLine(text: string?): string
	if not text then
		return ""
	end
	local line = string.match(text, "^[^\n]*") or text
	return string.sub(line, 1, 110)
end

if not quiet then
	for _, spec in summarySpecs do
		local label = string.upper(spec.status)
		local count = `{spec.passed}/{spec.passed + spec.failed}`
		local detail = ""
		if spec.loadError then
			detail = firstLine(spec.loadError)
		elseif spec.failures then
			detail = firstLine(spec.failures[1].name .. " :: " .. (spec.failures[1].error or ""))
		end
		print(
			string.format(
				"%-10s %-20s %-44s %8s  %s",
				label,
				string.sub(spec.package, 1, 20),
				string.sub(string.match(spec.spec, "[^/]+$") or spec.spec, 1, 44),
				count,
				detail
			)
		)
	end
	print("")
end
print(
	string.format(
		"specs: %d  pass: %d  fail: %d  load-error: %d  timeout: %d  crash: %d | tests passed: %d  failed: %d  skipped: %d | %.1f s",
		totals.specs,
		totals.pass,
		totals.fail,
		totals.loadError,
		totals.timeout,
		totals.crash,
		totals.passed,
		totals.failed,
		totals.skipped,
		summary.durationMs / 1000
	)
)
print(`summary: {relative(jsonPath)}`)

if expectationReport then
	for _, line in expectationReport.messages do
		print(line)
	end
	process.exit(if expectationReport.ok then 0 else 1)
end
process.exit(if totals.pass == totals.specs then 0 else 1)
