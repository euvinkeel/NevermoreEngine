--!strict
--[[
	An in-memory listing of the files a spec can reach, taken before the spec runs.

	Lune's fs functions yield, and Luau can't yield inside a metamethod. `script.Parent.Foo` goes
	through the script node's __index, so every lookup it makes has to be answered from memory.
	Workspace sources are read eagerly too, so a require that happens inside a metamethod (lazy
	module tables) doesn't hit the same wall. Paths outside the snapshot fall back to fs, which
	works everywhere except inside metamethods.
]]

local fs = require("@lune/fs")

local PackageIndex = require("./PackageIndex")

local FileSnapshot = {}

export type Snapshot = {
	dirs: { [string]: { string } }, -- dir -> sorted entry names
	files: { [string]: boolean },
	sources: { [string]: string },
	isFile: (self: Snapshot, path: string) -> boolean,
	isDir: (self: Snapshot, path: string) -> boolean,
	readDir: (self: Snapshot, path: string) -> { string },
	readFile: (self: Snapshot, path: string) -> string,
}

local function fsIsDir(path: string): boolean
	local ok, result = pcall(fs.isDir, path)
	return ok and result
end

local function fsIsFile(path: string): boolean
	local ok, result = pcall(fs.isFile, path)
	return ok and result
end

-- jest-lua is replaced by MiniJest, so its large tree is never needed.
local SKIP_PACKAGES = {
	["@quentystudios/jest-lua"] = true,
}

local Snapshot = {}
Snapshot.__index = Snapshot

-- nil when the parent wasn't listed, otherwise whether the parent's listing has this entry.
local function listedInParent(self: Snapshot, path: string): boolean?
	local parent, name = string.match(path, "^(.*)/([^/]*)$")
	if not parent or not name then
		return nil
	end
	local entries = self.dirs[parent]
	if not entries then
		return nil
	end
	return table.find(entries, name) ~= nil
end

function Snapshot.isFile(self: Snapshot, path: string): boolean
	if self.files[path] then
		return true
	elseif self.dirs[path] or listedInParent(self, path) == false then
		return false
	end
	return fsIsFile(path)
end

function Snapshot.isDir(self: Snapshot, path: string): boolean
	if self.dirs[path] then
		return true
	elseif self.files[path] or listedInParent(self, path) == false then
		return false
	end
	return fsIsDir(path)
end

function Snapshot.readDir(self: Snapshot, path: string): { string }
	local listed = self.dirs[path]
	if listed then
		return listed
	end
	local ok, entries = pcall(fs.readDir, path)
	if not ok then
		return {}
	end
	table.sort(entries)
	return entries
end

function Snapshot.readFile(self: Snapshot, path: string): string
	local cached = self.sources[path]
	if cached then
		return cached
	end
	local source = fs.readFile(path)
	self.sources[path] = source
	return source
end

function FileSnapshot.build(index: PackageIndex.Index, specPackageId: string): Snapshot
	local self: Snapshot = setmetatable({
		dirs = {},
		files = {},
		sources = {},
	}, Snapshot) :: any

	local function walk(dir: string, readSources: boolean)
		if self.dirs[dir] then
			return
		end
		local ok, entries = pcall(fs.readDir, dir)
		if not ok then
			return
		end
		table.sort(entries)
		local kept = {}
		for _, entry in entries do
			if entry == "node_modules" or string.sub(entry, 1, 1) == "." then
				continue
			end
			table.insert(kept, entry)
		end
		self.dirs[dir] = kept
		for _, entry in kept do
			local path = dir .. "/" .. entry
			if fsIsDir(path) then
				walk(path, readSources)
			else
				self.files[path] = true
				if readSources and string.match(entry, "%.luau?$") then
					self.sources[path] = fs.readFile(path)
				end
			end
		end
	end

	-- The src/ listing lets `script.Parent` chains climb to the package directory and stop there.
	local srcDir = index.root .. "/src"
	local ok, srcEntries = pcall(fs.readDir, srcDir)
	if ok then
		table.sort(srcEntries)
		self.dirs[srcDir] = srcEntries
	end

	for _, id in PackageIndex.closure(index, specPackageId) do
		local pkg = index.packages[id]
		if pkg and not SKIP_PACKAGES[pkg.name] then
			walk(pkg.dir, pkg.isWorkspace)
		end
	end

	return self
end

return FileSnapshot
