--!strict
--[[
	An in-memory listing of the files a spec can reach, taken before the spec runs.

	Lune's fs functions yield, and Luau can't yield inside a metamethod. `script.Parent.Foo` goes
	through the script node's __index, so every lookup it makes has to be answered from memory.
	Sources are read eagerly too: a require must never yield (Roblox's doesn't, ServiceBag rejects a
	yielding Init, and a require inside a metamethod can't yield at all). That covers the spec's
	package closure plus every package its require("Name") literals resolve to. Paths outside the
	snapshot fall back to fs, which works everywhere except inside metamethods and yielding-checked
	code.
]]

local fs = require("@lune/fs")

local Fs = require("./Fs")
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
	return Fs.isFile(path)
end

function Snapshot.isDir(self: Snapshot, path: string): boolean
	if self.dirs[path] then
		return true
	elseif self.files[path] or listedInParent(self, path) == false then
		return false
	end
	return Fs.isDir(path)
end

-- Like Fs.listDir: sorted, without node_modules and dot entries.
function Snapshot.readDir(self: Snapshot, path: string): { string }
	return self.dirs[path] or Fs.listDir(path)
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

	local function walk(dir: string)
		if self.dirs[dir] then
			return
		end
		self.dirs[dir] = Fs.listDir(dir)
		for _, entry in self.dirs[dir] do
			local path = dir .. "/" .. entry
			if Fs.isDir(path) then
				walk(path)
			else
				self.files[path] = true
				if string.match(entry, "%.luau?$") then
					self.sources[path] = fs.readFile(path)
				end
			end
		end
	end

	-- The src/ listing lets `script.Parent` chains climb to the package directory and stop there.
	self.dirs[index.root .. "/src"] = Fs.listDir(index.root .. "/src")

	local walked: { [string]: boolean } = {}
	local function walkPackage(id: string)
		local pkg = index.packages[id]
		if walked[id] or not pkg or SKIP_PACKAGES[pkg.name] then
			return
		end
		walked[id] = true
		walk(pkg.dir)
	end
	for _, id in PackageIndex.closure(index, specPackageId) do
		walkPackage(id)
	end

	-- A require can also resolve outside the declared closure (the global fallback). Reading such a
	-- module later would yield inside `require`, which Roblox never does (and ServiceBag rejects a
	-- yielding Init). So follow the require("Name") literals in what was read until nothing new
	-- turns up, and read those packages now too.
	local scanned: { [string]: boolean } = {}
	while true do
		local pending = {}
		for path in self.sources do
			if not scanned[path] then
				table.insert(pending, path)
			end
		end
		if #pending == 0 then
			break
		end
		for _, path in pending do
			scanned[path] = true
			local source = self.sources[path]
			local fromId = PackageIndex.packageOfPath(index, path)
			if not fromId then
				continue
			end
			for name in string.gmatch(source, 'require%(%s*"([%w_%-%.]+)"%s*%)') do
				local resolution = PackageIndex.resolve(index, fromId, specPackageId, name)
				if resolution and not walked[resolution.packageId] then
					walkPackage(resolution.packageId)
				end
			end
		end
	end

	return self
end

return FileSnapshot
