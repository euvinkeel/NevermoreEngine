--!strict
--[[
	Type checks the API stubs with luau-lsp and the old solver (as Nevermore's lint does):
	- Statuh.luau and examples/*.luau must have no errors;
	- in mustfail/*.luau, every line marked `-- expect-error` must have an error, and no other.

	lune run experiments/statuh-scope/types/check.luau
	(luau-lsp on PATH, or set LUAU_LSP)
]]

local fs = require("@lune/fs")
local process = require("@lune/process")

local DIR = "experiments/statuh-scope/types"
local lsp = process.env.LUAU_LSP or "luau-lsp"

local function analyze(files: { string }): { [string]: { [number]: { string } } }
	local args = { "analyze", "--platform=standard", "--flag:LuauSolverV2=false" }
	for _, file in files do
		table.insert(args, file)
	end
	local result = process.exec(lsp, args, { cwd = DIR })
	local errors: { [string]: { [number]: { string } } } = {}
	for line in string.gmatch(result.stdout .. "\n" .. result.stderr, "[^\n]+") do
		local file, lineNumber, message = string.match(line, "^(.-)%((%d+),%d+%): (.*)$")
		if file and lineNumber then
			local byLine = errors[file]
			if not byLine then
				byLine = {}
				errors[file] = byLine
			end
			local n = tonumber(lineNumber) :: number
			byLine[n] = byLine[n] or {}
			table.insert(byLine[n], message)
		end
	end
	return errors
end

local function list(dir: string): { string }
	local files = {}
	for _, entry in fs.readDir(DIR .. "/" .. dir) do
		if string.match(entry, "%.luau$") then
			table.insert(files, dir .. "/" .. entry)
		end
	end
	table.sort(files)
	return files
end

local problems = {}

local mustPass = list("examples")
table.insert(mustPass, 1, "Statuh.luau")
local passErrors = analyze(mustPass)
for file, byLine in passErrors do
	for lineNumber, messages in byLine do
		table.insert(problems, `{file}:{lineNumber}: unexpected error: {messages[1]}`)
	end
end

local expected = 0
for _, file in list("mustfail") do
	local errors = analyze({ file })[file] or {}
	local lines = string.split(fs.readFile(DIR .. "/" .. file), "\n")
	for lineNumber, text in lines do
		local marked = string.match(text, "%-%- expect%-error%s*$") ~= nil
		if marked then
			expected += 1
			if not errors[lineNumber] then
				table.insert(problems, `{file}:{lineNumber}: expected a type error, got none`)
			end
		elseif errors[lineNumber] then
			table.insert(problems, `{file}:{lineNumber}: unexpected error: {errors[lineNumber][1]}`)
		end
	end
	-- Errors reported in other files (for example inside Statuh.luau) are problems too.
	for otherFile, byLine in analyze({ file }) do
		if otherFile ~= file then
			for lineNumber, messages in byLine do
				table.insert(problems, `{otherFile}:{lineNumber}: unexpected error: {messages[1]}`)
			end
		end
	end
end

if #problems > 0 then
	for _, problem in problems do
		print(problem)
	end
	process.exit(1)
end
print(`types OK: {#mustPass} files type-check, {expected} must-fail lines all fail`)
