--!strict
--[[
	Portability lint: finds Roblox-only API use in the modules that are meant to run without the
	engine (the "pure closure"), so new engine dependencies there get noticed. It reports; it
	doesn't fix anything, and Roblox-only modules elsewhere are none of its business.

	lune run tools/lune-headless/portability.luau [--check] [--update-baseline] [--json=<path>]

	How:
	1. The pure closure is every module reachable at require time from ROOTS below, following
	   require("Name") through Nevermore's resolution (lib/PackageIndex.luau) and
	   require(script.Parent.X). Comments are stripped first so doc examples aren't followed.
	2. luau-lsp analyzes those files with --platform=standard and portability/portable.d.luau,
	   which declares only what the `basic` host level polyfills (task, warn, tick, Random, ...).
	3. What's left is classified:
	   - runtime: an unknown global such as `game`, `Vector3`, `Instance`. "import" if it's on an
	     unindented line (runs at require time, so it breaks loading), else "call".
	   - type: an unknown Roblox type such as `Instance` or `Enum.KeyCode` in an annotation.
	     Harmless at runtime. "Roblox" means declared in globalTypes.d.lua (downloaded by
	     `npm run lint:luau`); without that file, every unknown bare type name counts.
	   Ignored: the polyfilled debug members, the loader's require line, and module types like
	   `Maid.Maid` (the loader's require is untyped here).

	--check compares against portability/baseline.json and exits 1 if a file gained findings.
	--update-baseline rewrites the baseline from this run.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local PackageIndex = require("./lib/PackageIndex")
local RobloxApi = require("./lib/RobloxApi")

-- Entry points of the engine-free path (agent-handoff/FINDINGS.md §2).
local ROOTS = {
	"ImmediateCoreUtils",
	"ImmediateInstall",
	"ImmediateScheduler",
	"JecsImmediateHookUtils",
	"JecsImmediateHooksCoreHooks",
	"JecsImmediateHooksInstall",
	"JecsImmediateInstall",
	"JecsImmediateUtils",
	"Brio",
	"CancelToken",
	"Maid",
	"Observable",
	"Promise",
	"RandomUtils",
	"Rx",
	"ServiceBag",
	"Signal",
	"Spring",
	"ThrottledFunction",
	"cancellableDelay",
}

-- debug members the `basic` host level adds (lib/Host.luau).
local POLYFILLED_DEBUG = {
	profilebegin = true,
	profileend = true,
	setmemorycategory = true,
	resetmemorycategory = true,
	getmemorycategory = true,
	dumpcodesize = true,
}

local options: { [string]: string } = {}
for _, arg in process.args do
	local key, value = string.match(arg, "^%-%-([%w%-]+)=(.*)$")
	if key and value then
		options[key] = value
	elseif string.match(arg, "^%-%-[%w%-]+$") then
		options[string.sub(arg, 3)] = "true"
	end
end

local root = string.gsub(options.root or process.cwd, "[/\\]+$", "")
local TOOL_DIR = root .. "/tools/lune-headless"
local DEFS = TOOL_DIR .. "/portability/portable.d.luau"
local BASELINE = TOOL_DIR .. "/portability/baseline.json"
local lsp = process.env.LUAU_LSP or "luau-lsp"

local function relative(path: string): string
	if string.sub(path, 1, #root + 1) == root .. "/" then
		return string.sub(path, #root + 2)
	end
	return path
end

local function isFile(path: string): boolean
	local ok, result = pcall(fs.isFile, path)
	return ok and result
end

local function stripComments(source: string): string
	local stripped = string.gsub(source, "%-%-%[(=*)%[.-%]%1%]", "")
	stripped = string.gsub(stripped, "%-%-[^\n]*", "")
	return stripped
end

-- 1. The closure.

local index = PackageIndex.build(root)

-- Roots resolve the way code in the jecs package sees them (Maid, for example, exists in both
-- src/loader and src/maid); a root jecs can't see must be unique in the workspace.
local VANTAGE = "src/jecs"

local function findRoot(name: string): string?
	local resolution = PackageIndex.resolve(index, VANTAGE, VANTAGE, name)
	if resolution then
		return resolution.entry.path
	end
	local found = nil
	for _, pkg in index.packages do
		if pkg.isWorkspace and pkg.modules[name] then
			if found then
				error(`Root "{name}" is defined in more than one package`)
			end
			found = pkg.modules[name].path
		end
	end
	return found
end

local closure: { [string]: boolean } = {}
local order: { string } = {}
local unresolved: { string } = {}
local queue: { string } = {}

local function add(path: string)
	if not closure[path] then
		closure[path] = true
		table.insert(order, path)
		table.insert(queue, path)
	end
end

for _, name in ROOTS do
	local path = findRoot(name)
	if path then
		add(path)
	else
		table.insert(unresolved, `root {name}`)
	end
end

while #queue > 0 do
	local path = table.remove(queue, 1) :: string
	local source = stripComments(fs.readFile(path))
	local fromId = PackageIndex.packageOfPath(index, path)
	for name in string.gmatch(source, 'require%(%s*"([^"]+)"%s*%)') do
		if fromId and not string.find(name, "[/@]") then
			local resolution = PackageIndex.resolve(index, fromId, fromId, name)
			if resolution then
				add(resolution.entry.path)
			else
				table.insert(unresolved, `{relative(path)}: require("{name}")`)
			end
		end
	end
	local dir = string.match(path, "^(.*)/[^/]+$") :: string
	for name in string.gmatch(source, "require%(%s*script%.Parent%.([%w_]+)%s*%)") do
		if name ~= "loader" then
			for _, candidate in
				{ `{dir}/{name}.lua`, `{dir}/{name}.luau`, `{dir}/{name}/init.lua`, `{dir}/{name}/init.luau` }
			do
				if isFile(candidate) then
					add(candidate)
					break
				end
			end
		end
	end
end
table.sort(order)

-- 2. Analyze.

local args = { "analyze", "--platform=standard", "--defs=" .. DEFS, "--flag:LuauSolverV2=false" }
for _, path in order do
	table.insert(args, relative(path))
end
local result = process.exec(lsp, args, { cwd = root })

-- 3. Classify.

type Finding = { file: string, line: number, kind: string, symbol: string, where: string? }

local sourceLines: { [string]: { string } } = {}
local function lineOf(file: string, line: number): string
	local lines = sourceLines[file]
	if not lines then
		lines = string.split(fs.readFile(root .. "/" .. file), "\n")
		sourceLines[file] = lines
	end
	return lines[line] or ""
end

local inClosure: { [string]: boolean } = {}
for _, path in order do
	inClosure[relative(path)] = true
end

-- Roblox type names, from the luau-lsp definitions when available.
local robloxTypes: { [string]: boolean }? = nil
do
	local api = RobloxApi.load(root .. "/globalTypes.d.lua")
	if api then
		local names: { [string]: boolean } = {}
		for name in api do
			names[name] = true
		end
		-- Plain type aliases too (RBXScriptSignal is `export type` there).
		local text = fs.readFile(root .. "/globalTypes.d.lua")
		for name in string.gmatch(text, "\n%s*export type ([%a_][%w_]*)") do
			names[name] = true
		end
		for name in string.gmatch(text, "\n%s*type ([%a_][%w_]*)") do
			names[name] = true
		end
		robloxTypes = names
	end
end
if robloxTypes == nil and (options.check == "true" or options["update-baseline"] == "true") then
	print("globalTypes.d.lua is missing, so Roblox types can't be told apart; run `npm run lint:luau` once first")
	process.exit(1)
end
local function isRobloxType(name: string): boolean
	if string.sub(name, 1, 5) == "Enum." then
		return true
	elseif string.find(name, ".", 1, true) then
		return false -- a module's exported type, e.g. Maid.Maid
	end
	return robloxTypes == nil or (robloxTypes :: { [string]: boolean })[name] == true
end

local findings: { Finding } = {}
local seen: { [string]: boolean } = {}
for line in string.gmatch(result.stdout .. "\n" .. result.stderr, "[^\n]+") do
	local file, lineText, message = string.match(line, "^(.-)%((%d+),%d+%): %w+: (.*)$")
	if not (file and lineText and message) then
		continue
	end
	file = relative(file)
	local lineNumber = tonumber(lineText) :: number
	if not inClosure[file] then
		continue
	end
	local finding: Finding? = nil
	local global = string.match(message, "^Unknown global '([%w_]+)'")
	local typeName = string.match(message, "^Unknown type '([%w_%.]+)'")
	local debugKey = string.match(message, "^Key '([%w_]+)' not found in table 'typeof%(debug%)'")
	if global then
		local text = lineOf(file, lineNumber)
		finding = {
			file = file,
			line = lineNumber,
			kind = "runtime",
			symbol = global,
			where = if string.match(text, "^%S") then "import" else "call",
		}
	elseif typeName and isRobloxType(typeName) then
		finding = { file = file, line = lineNumber, kind = "type", symbol = typeName }
	elseif debugKey and not POLYFILLED_DEBUG[debugKey] then
		finding = { file = file, line = lineNumber, kind = "runtime", symbol = "debug." .. debugKey, where = "call" }
	end
	if finding then
		local key = `{finding.file}:{finding.line}:{finding.kind}:{finding.symbol}`
		if not seen[key] then
			seen[key] = true
			table.insert(findings, finding)
		end
	end
end
table.sort(findings, function(a, b)
	if a.file ~= b.file then
		return a.file < b.file
	end
	return a.line < b.line
end)

-- Report.

local function summarize(kind: string): { string }
	local bySymbol: { [string]: { string } } = {}
	local symbols = {}
	for _, finding in findings do
		if finding.kind == kind then
			if not bySymbol[finding.symbol] then
				bySymbol[finding.symbol] = {}
				table.insert(symbols, finding.symbol)
			end
			local place = `{string.match(finding.file, "[^/]+$")}:{finding.line}`
			if finding.where == "import" then
				place ..= " (import)"
			end
			table.insert(bySymbol[finding.symbol], place)
		end
	end
	table.sort(symbols)
	local out = {}
	for _, symbol in symbols do
		table.insert(
			out,
			string.format("  %-16s %3d  %s", symbol, #bySymbol[symbol], table.concat(bySymbol[symbol], ", "))
		)
	end
	return out
end

local runtimeCount, importCount, typeCount = 0, 0, 0
for _, finding in findings do
	if finding.kind == "runtime" then
		runtimeCount += 1
		if finding.where == "import" then
			importCount += 1
		end
	else
		typeCount += 1
	end
end

print(`Portability: {#order} modules in the pure closure of {#ROOTS} roots`)
print(`Runtime uses of Roblox globals: {runtimeCount} ({importCount} at import time)`)
for _, line in summarize("runtime") do
	print(line)
end
print(`Type-only uses (harmless at runtime): {typeCount}`)
for _, line in summarize("type") do
	print(line)
end
if #unresolved > 0 then
	print(`Not followed ({#unresolved}):`)
	for _, item in unresolved do
		print("  " .. item)
	end
end

local counts: { [string]: { [string]: number } } = {}
for _, finding in findings do
	local key = `{finding.kind} {finding.symbol}`
	counts[finding.file] = counts[finding.file] or {}
	counts[finding.file][key] = (counts[finding.file][key] or 0) + 1
end

local jsonPath = options.json or (TOOL_DIR .. "/out/portability.json")
pcall(fs.writeDir, string.match(jsonPath, "^(.*)/[^/]+$") :: string)
fs.writeFile(
	jsonPath,
	serde.encode("json" :: any, {
		roots = ROOTS,
		modules = (function()
			local list = {}
			for _, path in order do
				table.insert(list, relative(path))
			end
			return list
		end)(),
		findings = findings,
		unresolved = unresolved,
	}, true)
)

if options["update-baseline"] == "true" then
	fs.writeFile(BASELINE, serde.encode("json" :: any, counts, true) .. "\n")
	print(`Baseline written: {relative(BASELINE)}`)
elseif options.check == "true" then
	local ok, baseline = pcall(function()
		return serde.decode("json" :: any, fs.readFile(BASELINE))
	end)
	if not ok then
		print(`No baseline at {relative(BASELINE)}; run with --update-baseline first`)
		process.exit(1)
	end
	local regressions, improvements = {}, {}
	for file, byKey in counts do
		for key, count in byKey do
			local before = (baseline[file] and baseline[file][key]) or 0
			if count > before then
				table.insert(regressions, `{file}: {key} ({before} -> {count})`)
			end
		end
	end
	for file, byKey in baseline do
		for key, before in byKey do
			local count = (counts[file] and counts[file][key]) or 0
			if count < before then
				table.insert(improvements, `{file}: {key} ({before} -> {count})`)
			end
		end
	end
	table.sort(regressions)
	table.sort(improvements)
	for _, item in improvements do
		print("FEWER  " .. item .. " (update the baseline)")
	end
	for _, item in regressions do
		print("NEW    " .. item)
	end
	if #regressions > 0 then
		print(`portability: {#regressions} new Roblox-only use(s) in the pure closure`)
		process.exit(1)
	end
	print("portability: OK (no new Roblox-only use in the pure closure)")
end
