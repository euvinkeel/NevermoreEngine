--!strict
--[[
	File system, path and command-line helpers shared by the runner's scripts.

	Lune's fs.isFile/isDir throw ("Not a directory") when a path component is a file; these return
	false instead. Listings are sorted and leave out node_modules and dot entries, which no part of
	the runner looks into.
]]

local fs = require("@lune/fs")
local serde = require("@lune/serde")

local Fs = {}

function Fs.isFile(path: string): boolean
	local ok, result = pcall(fs.isFile, path)
	return ok and result
end

function Fs.isDir(path: string): boolean
	local ok, result = pcall(fs.isDir, path)
	return ok and result
end

-- A directory's entries, sorted, without node_modules and dot entries. Empty if it can't be read.
function Fs.listDir(path: string): { string }
	local ok, entries = pcall(fs.readDir, path)
	local kept = {}
	if ok then
		for _, entry in entries do
			if entry ~= "node_modules" and string.sub(entry, 1, 1) ~= "." then
				table.insert(kept, entry)
			end
		end
		table.sort(kept)
	end
	return kept
end

function Fs.readJson(path: string): any?
	if not Fs.isFile(path) then
		return nil
	end
	local ok, decoded = pcall(serde.decode, "json" :: any, fs.readFile(path))
	return if ok then decoded else nil
end

-- Every *.spec.lua(u) file under a directory, sorted.
function Fs.findSpecs(dir: string): { string }
	local found = {}
	local function walk(path: string)
		for _, entry in Fs.listDir(path) do
			local child = path .. "/" .. entry
			if Fs.isDir(child) then
				walk(child)
			elseif string.match(entry, "%.spec%.luau?$") then
				table.insert(found, child)
			end
		end
	end
	walk(dir)
	table.sort(found)
	return found
end

function Fs.dirname(path: string): string
	return string.match(path, "^(.*)/[^/]*$") or path
end

function Fs.basename(path: string): string
	return string.match(path, "([^/]*)$") or path
end

-- `path` relative to `root` when it's inside it.
function Fs.relative(root: string, path: string): string
	if string.sub(path, 1, #root + 1) == root .. "/" then
		return string.sub(path, #root + 2)
	end
	return path
end

function Fs.absolute(root: string, path: string): string
	if string.sub(path, 1, 1) == "/" or string.match(path, "^%a:[/\\]") then
		return path
	end
	return root .. "/" .. path
end

-- `--key=value` options, `--flag` options (as "true"), and the other arguments in order.
function Fs.parseArgs(args: { string }): ({ [string]: string }, { string })
	local options: { [string]: string } = {}
	local positional: { string } = {}
	for _, arg in args do
		local key, value = string.match(arg, "^%-%-([%w%-]+)=(.*)$")
		if key and value then
			options[key] = value
		elseif string.match(arg, "^%-%-[%w%-]+$") then
			options[string.sub(arg, 3)] = "true"
		else
			table.insert(positional, arg)
		end
	end
	return options, positional
end

return Fs
