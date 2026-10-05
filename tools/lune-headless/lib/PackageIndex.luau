--!strict
--[[
	Builds a map of the workspace's Luau packages and their modules, so `require("Name")` can be
	resolved the way Nevermore's loader does it (see src/loader/src/Dependencies/PackageTracker.lua):

	1. modules in the requiring package itself,
	2. modules in the package's direct dependencies (its node_modules),
	3. "implicit parent" packages. On Roblox these are the packages above it in the nested
	   node_modules tree. Headlessly that's approximated by the rest of a breadth-first walk of
	   its dependencies, then the spec's own package closure, then a global fallback (which is
	   recorded, since Roblox might not find the module).

	The index is plain data so the orchestrator can build it once and hand it to every worker.
]]

local serde = require("@lune/serde")

local Fs = require("./Fs")

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

-- Rojo turns `Foo.lua` and `Foo/init.lua` into a ModuleScript named Foo. Names with another dot
-- (Foo.spec, Foo.story, Foo.server, Foo.client, GlobalPackageTracker.global) are not loader modules.
local function moduleNameOf(entry: string): string?
	local name = string.match(entry, "^(.+)%.luau?$")
	if not name or string.find(name, ".", 1, true) then
		return nil
	end
	return name
end

-- The first of `names` that is a file in `dir`.
local function firstFile(dir: string, names: { string }): string?
	for _, name in names do
		if Fs.isFile(dir .. "/" .. name) then
			return dir .. "/" .. name
		end
	end
	return nil
end

local REALM_FOLDERS = { Server = "server", Client = "client", Shared = "shared" }

local function scanModules(
	dir: string,
	realm: string,
	modules: { [string]: ModuleEntry },
	duplicates: { string },
	pkgName: string
)
	for _, entry in Fs.listDir(dir) do
		local path = dir .. "/" .. entry
		if Fs.isDir(path) then
			local childRealm = REALM_FOLDERS[entry] or realm
			local initPath = firstFile(path, { "init.luau", "init.lua" })
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
	for _, entry in Fs.listDir(root .. "/src") do
		local dir = root .. "/src/" .. entry
		local packageJson = Fs.readJson(dir .. "/package.json")
		if not packageJson or type(packageJson.name) ~= "string" then
			continue
		end
		local project = Fs.readJson(dir .. "/default.project.json")
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
		if Fs.isDir(treePath) then
			scanModules(treePath, "shared", pkg.modules, index.duplicates, pkg.name)
		end
		index.packages[pkg.id] = pkg
		index.byName[pkg.name] = pkg.id
		table.insert(pending, { pkg = pkg, json = packageJson })
	end

	-- Pass 2: dependencies. Workspace deps resolve by name; others are read through node_modules.
	local function addThirdParty(depName: string, depDir: string): string?
		-- Git dependencies without a package.json (e.g. BufferEncoder.git) still have a Rojo project.
		local depJson = Fs.readJson(depDir .. "/package.json")
			or (if Fs.isFile(depDir .. "/default.project.json") then { name = depName } else nil)
		if not depJson or type(depJson.name) ~= "string" then
			return nil
		end
		local id = `npm:{depJson.name}@{depJson.version or "0"}`
		if index.packages[id] then
			return id
		end
		local project = Fs.readJson(depDir .. "/default.project.json")
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
		-- A third-party package is one module, named like its Rojo project: its tree.$path file, or
		-- that folder's init file or file named like the project.
		local treePath = pkg.treePath
		if treePath and projectName then
			local entryFile = if Fs.isFile(treePath)
				then treePath
				else firstFile(
					treePath,
					{ "init.luau", "init.lua", projectName .. ".luau", projectName .. ".lua" }
				)
			if entryFile then
				pkg.modules[projectName] = { path = entryFile, realm = "shared" }
			end
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
				if Fs.isDir(depDir) then
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

-- The module `name` in a package. A third-party package's one module also matches ignoring case:
-- BufferEncoder's Rojo project is named "bufferencoder", and code requires it either way.
local function find(index: Index, pkgId: string, name: string): ModuleEntry?
	local pkg = index.packages[pkgId]
	if not pkg then
		return nil
	elseif pkg.modules[name] or pkg.isWorkspace then
		return pkg.modules[name]
	end
	for moduleName, entry in pkg.modules do
		if string.lower(moduleName) == string.lower(name) then
			return entry
		end
	end
	return nil
end

export type Resolution = {
	entry: ModuleEntry,
	packageId: string,
	global: boolean, -- found only by the last-resort search of every package
}

-- Resolve a bare module name requested from inside `fromId`, for a spec living in `specId`: the
-- requiring package and its dependencies breadth first (own modules, then direct dependencies,
-- then transitive ones), then the spec's package closure, then every package.
function PackageIndex.resolve(index: Index, fromId: string, specId: string, name: string): Resolution?
	local function search(ids: { string }, global: boolean): Resolution?
		for _, id in ids do
			local found = find(index, id, name)
			if found then
				return { entry = found, packageId = id, global = global }
			end
		end
		return nil
	end
	local resolution = search(PackageIndex.closure(index, fromId), false)
		or search(PackageIndex.closure(index, specId), false)
	if resolution then
		return resolution
	end
	local ids = {}
	for id in index.packages do
		table.insert(ids, id)
	end
	table.sort(ids)
	return search(ids, true)
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
	return if pkg and pkg.treePath then Fs.findSpecs(pkg.treePath) else {}
end

return PackageIndex
