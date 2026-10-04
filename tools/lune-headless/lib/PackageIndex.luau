--!strict
--[[
	Builds a map of the workspace's Luau packages and their modules, so `require("Name")` can be
	resolved the way Nevermore's loader does it (see src/loader/src/Dependencies/PackageTracker.lua):

	1. modules in the requiring package itself,
	2. modules in the package's direct dependencies (its node_modules),
	3. "implicit parent" packages. On Roblox these are the packages above it in the nested
	   node_modules tree. Headlessly we approximate that with a breadth-first walk of the
	   transitive dependencies, then the spec's own package closure, then a global fallback
	   (which is recorded, since Roblox might not find the module).

	The index is plain data so the orchestrator can build it once and hand it to every worker.
]]

local fs = require("@lune/fs")
local serde = require("@lune/serde")

local PackageIndex = {}

export type ModuleEntry = {
	path: string, -- absolute path of the file that runs for this module
	realm: string, -- "shared" | "server" | "client"
}

export type Package = {
	id: string, -- stable identity: "src/<dir>" or "npm:<name>@<version>"
	name: string, -- npm name, e.g. "@quenty/maid"
	dir: string, -- absolute directory
	projectName: string?, -- default.project.json name
	isWorkspace: boolean,
	treePath: string?, -- absolute path of default.project.json tree.$path
	modules: { [string]: ModuleEntry },
	dependencies: { string }, -- package ids, in a stable order
}

export type Index = {
	root: string,
	packages: { [string]: Package },
	byName: { [string]: string }, -- npm name -> package id (workspace packages only)
	duplicates: { string }, -- "pkg: Name (a, b)" notes for modules defined twice in one package
}

-- fs.isDir/isFile throw ("Not a directory") when a path component is a file, so guard them.
local function isDir(path: string): boolean
	local ok, result = pcall(fs.isDir, path)
	return ok and result
end

local function isFile(path: string): boolean
	local ok, result = pcall(fs.isFile, path)
	return ok and result
end

local function readJson(path: string): any?
	if not isFile(path) then
		return nil
	end
	local ok, decoded = pcall(serde.decode, "json" :: any, fs.readFile(path))
	return if ok then decoded else nil
end

local function readDir(path: string): { string }
	local ok, result = pcall(fs.readDir, path)
	if not ok then
		return {}
	end
	table.sort(result)
	return result
end

-- Rojo turns `Foo.lua` and `Foo/init.lua` into a ModuleScript named Foo. Names with another dot
-- (Foo.spec, Foo.story, Foo.server, Foo.client, GlobalPackageTracker.global) are not loader modules.
local function moduleNameOf(entry: string): string?
	local name = string.match(entry, "^(.+)%.luau?$")
	if not name or string.find(name, ".", 1, true) then
		return nil
	end
	return name
end

local REALM_FOLDERS = { Server = "server", Client = "client", Shared = "shared" }

local function scanModules(
	dir: string,
	realm: string,
	modules: { [string]: ModuleEntry },
	duplicates: { string },
	pkgName: string
)
	for _, entry in readDir(dir) do
		if entry == "node_modules" or string.sub(entry, 1, 1) == "." then
			continue
		end
		local path = dir .. "/" .. entry
		if isDir(path) then
			local childRealm = REALM_FOLDERS[entry] or realm
			local initPath = nil
			for _, initName in { "init.luau", "init.lua" } do
				if isFile(path .. "/" .. initName) then
					initPath = path .. "/" .. initName
					break
				end
			end
			if initPath then
				local existing = modules[entry]
				if existing then
					table.insert(duplicates, `{pkgName}: {entry} ({existing.path}, {initPath})`)
				else
					modules[entry] = { path = initPath, realm = childRealm }
				end
			end
			scanModules(path, childRealm, modules, duplicates, pkgName)
		else
			local name = moduleNameOf(entry)
			if name and name ~= "init" then
				local existing = modules[name]
				if existing then
					table.insert(duplicates, `{pkgName}: {name} ({existing.path}, {path})`)
					-- The runner emulates the server, so prefer shared/server over client copies.
					if existing.realm == "client" and realm ~= "client" then
						modules[name] = { path = path, realm = realm }
					end
				else
					modules[name] = { path = path, realm = realm }
				end
			end
		end
	end
end

local function resolveTreePath(pkgDir: string, project: any): string?
	local tree = type(project) == "table" and project.tree
	local treePath = type(tree) == "table" and tree["$path"]
	if type(treePath) ~= "string" then
		return nil
	end
	return pkgDir .. "/" .. treePath
end

-- The entry file for a package whose tree.$path is a file or a folder with init.
local function entryFileOf(treePath: string, projectName: string?): string?
	if isFile(treePath) then
		return treePath
	end
	if not isDir(treePath) then
		return nil
	end
	for _, candidate in { "init.luau", "init.lua", (projectName or "") .. ".luau", (projectName or "") .. ".lua" } do
		if isFile(treePath .. "/" .. candidate) then
			return treePath .. "/" .. candidate
		end
	end
	return nil
end

local function dependencyNames(packageJson: any): { string }
	local names = {}
	for _, field in { "dependencies", "devDependencies" } do
		local deps = packageJson[field]
		if type(deps) == "table" then
			local sorted = {}
			for name in deps do
				table.insert(sorted, name)
			end
			table.sort(sorted)
			for _, name in sorted do
				if not table.find(names, name) then
					table.insert(names, name)
				end
			end
		end
	end
	return names
end

function PackageIndex.build(root: string): Index
	local index: Index = {
		root = root,
		packages = {},
		byName = {},
		duplicates = {},
	}

	-- Pass 1: workspace packages under src/.
	local pending: { { pkg: Package, json: any } } = {}
	for _, entry in readDir(root .. "/src") do
		local dir = root .. "/src/" .. entry
		local packageJson = readJson(dir .. "/package.json")
		if not packageJson or type(packageJson.name) ~= "string" then
			continue
		end
		local project = readJson(dir .. "/default.project.json")
		local treePath = resolveTreePath(dir, project) or (dir .. "/src")
		local pkg: Package = {
			id = "src/" .. entry,
			name = packageJson.name,
			dir = dir,
			projectName = if type(project) == "table" then project.name else nil,
			isWorkspace = true,
			treePath = treePath,
			modules = {},
			dependencies = {},
		}
		if isDir(treePath) then
			scanModules(treePath, "shared", pkg.modules, index.duplicates, pkg.name)
		end
		index.packages[pkg.id] = pkg
		index.byName[pkg.name] = pkg.id
		table.insert(pending, { pkg = pkg, json = packageJson })
	end

	-- Pass 2: dependencies. Workspace deps resolve by name; others are read through node_modules.
	local function addThirdParty(depName: string, depDir: string): string?
		-- Git dependencies without a package.json (e.g. BufferEncoder.git) still have a Rojo project.
		local depJson = readJson(depDir .. "/package.json")
			or (if isFile(depDir .. "/default.project.json") then { name = depName } else nil)
		if not depJson or type(depJson.name) ~= "string" then
			return nil
		end
		local id = `npm:{depJson.name}@{depJson.version or "0"}`
		if index.packages[id] then
			return id
		end
		local project = readJson(depDir .. "/default.project.json")
		local projectName = if type(project) == "table" and type(project.name) == "string" then project.name else nil
		local pkg: Package = {
			id = id,
			name = depJson.name,
			dir = depDir,
			projectName = projectName,
			isWorkspace = false,
			treePath = resolveTreePath(depDir, project),
			modules = {},
			dependencies = {},
		}
		-- A third-party package is one module, named like its Rojo project, at its tree root.
		local entryFile = pkg.treePath and entryFileOf(pkg.treePath, projectName)
		if entryFile and projectName then
			pkg.modules[projectName] = { path = entryFile, realm = "shared" }
		end
		index.packages[id] = pkg
		return id
	end

	for _, item in pending do
		for _, depName in dependencyNames(item.json) do
			local workspaceId = index.byName[depName]
			if workspaceId then
				table.insert(item.pkg.dependencies, workspaceId)
			else
				local depDir = item.pkg.dir .. "/node_modules/" .. depName
				if isDir(depDir) then
					local id = addThirdParty(depName, depDir)
					if id then
						table.insert(item.pkg.dependencies, id)
					end
				end
			end
		end
	end

	return index
end

function PackageIndex.encode(index: Index): string
	return serde.encode("json" :: any, index)
end

function PackageIndex.decode(text: string): Index
	return serde.decode("json" :: any, text)
end

-- Every package reachable from `startId`, breadth first, starting with itself.
function PackageIndex.closure(index: Index, startId: string): { string }
	local order = { startId }
	local seen = { [startId] = true }
	local i = 1
	while i <= #order do
		local pkg = index.packages[order[i]]
		if pkg then
			for _, dep in pkg.dependencies do
				if not seen[dep] then
					seen[dep] = true
					table.insert(order, dep)
				end
			end
		end
		i += 1
	end
	return order
end

local function findIn(index: Index, pkgId: string, name: string): ModuleEntry?
	local pkg = index.packages[pkgId]
	if not pkg then
		return nil
	end
	return pkg.modules[name]
end

local function findCaseInsensitive(index: Index, pkgId: string, name: string): ModuleEntry?
	local pkg = index.packages[pkgId]
	if not pkg or pkg.isWorkspace then
		return nil
	end
	local lower = string.lower(name)
	for moduleName, entry in pkg.modules do
		if string.lower(moduleName) == lower then
			return entry
		end
	end
	return nil
end

export type Resolution = {
	entry: ModuleEntry,
	packageId: string,
	how: string, -- "own" | "direct" | "transitive" | "spec" | "global"
}

-- Resolve a bare module name requested from inside `fromId`, for a spec living in `specId`.
function PackageIndex.resolve(index: Index, fromId: string, specId: string, name: string): Resolution?
	local own = findIn(index, fromId, name)
	if own then
		return { entry = own, packageId = fromId, how = "own" }
	end

	local fromPkg = index.packages[fromId]
	if fromPkg then
		for _, dep in fromPkg.dependencies do
			local found = findIn(index, dep, name) or findCaseInsensitive(index, dep, name)
			if found then
				return { entry = found, packageId = dep, how = "direct" }
			end
		end
	end

	for _, dep in PackageIndex.closure(index, fromId) do
		local found = findIn(index, dep, name) or findCaseInsensitive(index, dep, name)
		if found then
			return { entry = found, packageId = dep, how = "transitive" }
		end
	end

	for _, dep in PackageIndex.closure(index, specId) do
		local found = findIn(index, dep, name) or findCaseInsensitive(index, dep, name)
		if found then
			return { entry = found, packageId = dep, how = "spec" }
		end
	end

	local ids = {}
	for id in index.packages do
		table.insert(ids, id)
	end
	table.sort(ids)
	for _, id in ids do
		local found = findIn(index, id, name) or findCaseInsensitive(index, id, name)
		if found then
			return { entry = found, packageId = id, how = "global" }
		end
	end

	return nil
end

-- The package that owns a file, by longest matching directory prefix.
function PackageIndex.packageOfPath(index: Index, path: string): string?
	local bestId, bestLen = nil, 0
	for id, pkg in index.packages do
		local dir = pkg.dir .. "/"
		if string.sub(path, 1, #dir) == dir and #dir > bestLen then
			bestId, bestLen = id, #dir
		end
	end
	return bestId
end

-- Every *.spec.lua(u) file under a package's tree, sorted.
function PackageIndex.specsOf(index: Index, pkgId: string): { string }
	local pkg = index.packages[pkgId]
	local found = {}
	if not pkg or not pkg.treePath or not isDir(pkg.treePath) then
		return found
	end
	local function walk(dir: string)
		for _, entry in readDir(dir) do
			if entry == "node_modules" or string.sub(entry, 1, 1) == "." then
				continue
			end
			local path = dir .. "/" .. entry
			if isDir(path) then
				walk(path)
			elseif string.match(entry, "%.spec%.luau?$") then
				table.insert(found, path)
			end
		end
	end
	walk(pkg.treePath)
	table.sort(found)
	return found
end

return PackageIndex
