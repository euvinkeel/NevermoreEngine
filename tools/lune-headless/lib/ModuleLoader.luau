--!strict
--[[
	Loads Nevermore modules for one spec run, the way they load on Roblox:

	- Every module gets its own environment (the host globals plus `script` and `require`), so the
	  source runs unmodified with its original line numbers.
	- `require(script.Parent.loader).load(script)` returns a require that resolves bare names
	  through PackageIndex (Nevermore's loader rules), paths ("./X", "../X", "@self/X") relative
	  to the file, and script nodes directly.
	- `script` is a small filesystem-backed stand-in for the module's Instance: Name, ClassName,
	  Parent, children by name, FindFirstChild/WaitForChild/GetChildren/IsA/GetFullName. It's
	  enough for Instance-style requires such as `require(script.Parent.Util)` in third-party code.
	- Results are cached per file. A module that errors while loading keeps failing, and a module
	  that requires itself recursively errors, matching Roblox's messages.
]]

local luau = require("@lune/luau")
local task = require("@lune/task")

local FileSnapshot = require("./FileSnapshot")
local Fs = require("./Fs")
local PackageIndex = require("./PackageIndex")

local ModuleLoader = {}

export type Options = {
	index: PackageIndex.Index,
	specPath: string,
	globals: { [string]: any },
	jestGlobals: { [string]: any },
}

export type Loader = {
	runSpec: (self: Loader) -> (boolean, string?),
	notes: { string },
	loadedCount: number,
}

local LOADER_MARKER = setmetatable({}, {
	__tostring = function()
		return "loader"
	end,
})

local dirname = Fs.dirname
local basename = Fs.basename

local function normalize(path: string): string
	local parts = {}
	for _, part in string.split(path, "/") do
		if part == ".." then
			table.remove(parts)
		elseif part ~= "." and part ~= "" then
			table.insert(parts, part)
		end
	end
	local prefix = if string.sub(path, 1, 1) == "/" then "/" else ""
	return prefix .. table.concat(parts, "/")
end

function ModuleLoader.new(options: Options): Loader
	local index = options.index
	local root = index.root
	local specPackageId = PackageIndex.packageOfPath(index, options.specPath) or ""

	local self = {
		notes = {} :: { string },
		loadedCount = 0,
	}

	-- Every filesystem question goes through the snapshot, so script-node metamethods never yield.
	local snapshot = FileSnapshot.build(index, specPackageId)
	local function initFileOf(dir: string): string?
		for _, name in { "init.luau", "init.lua" } do
			if snapshot:isFile(dir .. "/" .. name) then
				return dir .. "/" .. name
			end
		end
		return nil
	end
	-- What `base` names, as a child is found on Roblox: base.luau, base.lua, or the folder base.
	local function childPath(base: string): string?
		for _, candidate in { base .. ".luau", base .. ".lua" } do
			if snapshot:isFile(candidate) then
				return candidate
			end
		end
		return if snapshot:isDir(base) then base else nil
	end
	-- The file that runs for `base`: base.luau, base.lua, or the folder's init file.
	local function moduleFileFor(base: string): string?
		local path = childPath(base)
		return if path == base then initFileOf(base) else path
	end

	local cache: { [string]: { value: any } } = {}
	-- path -> the threads in the require chain that is loading it, and threads waiting for it
	local loading: { [string]: { chain: { [thread]: true }, waiting: { thread } } } = {}
	-- thread -> the require chain it is part of (for telling recursion from a concurrent require)
	local chainOf: { [thread]: { [thread]: true } } = setmetatable({}, { __mode = "k" }) :: any
	local failed: { [string]: boolean } = {}
	local packageOfDir: { [string]: string } = {}
	local nodes: { [string]: any } = {}
	local noted: { [string]: boolean } = {}

	local function note(text: string)
		if not noted[text] then
			noted[text] = true
			table.insert(self.notes, text)
		end
	end

	local function packageOf(path: string): string
		local dir = dirname(path)
		local cached = packageOfDir[dir]
		if cached then
			return cached
		end
		local id = PackageIndex.packageOfPath(index, path) or specPackageId
		packageOfDir[dir] = id
		return id
	end

	local function relative(path: string): string
		return Fs.relative(root, path)
	end

	local loadFile: (path: string, isSpec: boolean?) -> any
	local nodeFor: (path: string) -> any
	local makeRequire: (fromPath: string) -> (any) -> any

	-- script nodes

	local NODE_METHODS = {}

	function NODE_METHODS.FindFirstChild(self: any, name: string): any
		local dir = rawget(self, "_childrenDir")
		local path = if dir and name ~= "init" then childPath(dir .. "/" .. name) else nil
		return if path then nodeFor(path) else nil
	end

	function NODE_METHODS.WaitForChild(self: any, name: string): any
		local child = NODE_METHODS.FindFirstChild(self, name)
		if not child then
			error(`[lune-headless] {rawget(self, "Name")}:WaitForChild("{name}") would wait forever`, 2)
		end
		return child
	end

	function NODE_METHODS.GetChildren(self: any): { any }
		local dir = rawget(self, "_childrenDir")
		local children = {}
		if not dir then
			return children
		end
		for _, entry in snapshot:readDir(dir) do
			local path = dir .. "/" .. entry
			if
				snapshot:isDir(path) or (string.match(entry, "%.luau?$") and not string.match(entry, "^init%.luau?$"))
			then
				table.insert(children, nodeFor(path))
			end
		end
		return children
	end

	function NODE_METHODS.IsA(self: any, className: string): boolean
		local class = rawget(self, "ClassName")
		return className == class
			or className == "Instance"
			or (className == "LuaSourceContainer" and class == "ModuleScript")
	end

	function NODE_METHODS.GetFullName(self: any): string
		return relative(rawget(self, "_path") :: string)
	end

	function NODE_METHODS.FindFirstAncestor(self: any, name: string): any
		local parent = self.Parent
		while parent do
			if rawget(parent, "Name") == name then
				return parent
			end
			parent = parent.Parent
		end
		return nil
	end

	-- Source files carry no attributes.
	function NODE_METHODS.GetAttribute(_self: any, _name: string): any
		return nil
	end

	function NODE_METHODS.GetAttributes(_self: any): { [string]: any }
		return {}
	end

	local NODE_MT = {
		__index = function(self: any, key: string): any
			local method = NODE_METHODS[key]
			if method then
				return method
			end
			if key == "Parent" then
				local path = rawget(self, "_path") :: string
				local parentPath = dirname(path)
				if parentPath == path or #parentPath <= #root then
					return nil
				end
				return nodeFor(parentPath)
			end
			local child = NODE_METHODS.FindFirstChild(self, key)
			if child then
				return child
			end
			if key == "loader" then
				return LOADER_MARKER
			end
			error(`{key} is not a valid member of {rawget(self, "ClassName")} "{rawget(self, "Name")}"`, 2)
		end,
		__tostring = function(self: any): string
			return rawget(self, "Name") :: string
		end,
	}

	function nodeFor(path: string): any
		local existing = nodes[path]
		if existing then
			return existing
		end
		local node: any
		if snapshot:isDir(path) then
			local initFile = initFileOf(path)
			node = setmetatable({
				Name = basename(path),
				ClassName = if initFile then "ModuleScript" else "Folder",
				_path = path,
				_moduleFile = initFile,
				_childrenDir = path,
			}, NODE_MT)
		else
			local name = string.match(basename(path), "^(.-)%.luau?$") or basename(path)
			if name == "init" then
				-- A folder's init file is the folder itself on Roblox.
				return nodeFor(dirname(path))
			end
			node = setmetatable({
				Name = name,
				ClassName = "ModuleScript",
				_path = path,
				_moduleFile = path,
				_childrenDir = nil,
			}, NODE_MT)
		end
		nodes[path] = node
		return node
	end

	local function isNode(value: any): boolean
		return type(value) == "table" and getmetatable(value) == NODE_MT
	end

	-- loading

	-- Spec files are run like jest-lua runs them: they don't have to return anything.
	function loadFile(path: string, isSpec: boolean?): any
		local cached = cache[path]
		if cached then
			return cached.value
		end
		if failed[path] then
			error("Requested module experienced an error while loading", 3)
		end
		local current = coroutine.running()
		local inProgress = loading[path]
		if inProgress then
			if inProgress.chain[current] then
				error(`Requested module was required recursively: {relative(path)}`, 3)
			end
			-- Another thread is loading it and yielded: wait for it, as Roblox does.
			table.insert(inProgress.waiting, current)
			coroutine.yield()
			return loadFile(path)
		end
		local chain: { [thread]: true } = chainOf[current] or {}
		chain[current] = true
		chainOf[current] = chain
		local entry = { chain = chain, waiting = {} }
		loading[path] = entry

		local env = table.clone(options.globals)
		env.script = nodeFor(path)
		env.require = makeRequire(path)

		local source = snapshot:readFile(path)
		local ok, results = pcall(function()
			local chunk = luau.load(source, { debugName = "@" .. relative(path), environment = env })
			return table.pack(chunk())
		end)
		loading[path] = nil
		for _, thread in entry.waiting do
			task.defer(thread)
		end
		if not ok then
			failed[path] = true
			error(results, 0)
		end
		if results.n ~= 1 and not isSpec then
			failed[path] = true
			error(`Module code did not return exactly one value: {relative(path)}`, 3)
		end
		cache[path] = { value = results[1] }
		self.loadedCount += 1
		return results[1]
	end

	local function requireByName(fromPath: string, name: string): any
		if name == "Jest" then
			return { Globals = options.jestGlobals }
		elseif name == "JestGlobals" then
			return options.jestGlobals
		end
		local fromId = packageOf(fromPath)
		local resolution = PackageIndex.resolve(index, fromId, specPackageId, name)
		if not resolution then
			error(`[lune-headless] Could not find module "{name}" (required from {relative(fromPath)})`, 3)
		end
		if resolution.global then
			note(`"{name}" from {fromId} resolved only through the global fallback ({resolution.packageId})`)
		end
		return loadFile(resolution.entry.path)
	end

	local function requireByPath(fromPath: string, request: string): any
		local base
		if string.sub(request, 1, 6) == "@self/" then
			local selfDir = if string.match(basename(fromPath), "^init%.luau?$")
				then dirname(fromPath)
				else string.match(fromPath, "^(.-)%.luau?$") or fromPath
			base = selfDir .. "/" .. string.sub(request, 7)
		else
			local dir = dirname(fromPath)
			if string.match(basename(fromPath), "^init%.luau?$") then
				dir = dirname(dir)
			end
			base = dir .. "/" .. request
		end
		local file = moduleFileFor(normalize(base))
		if not file then
			error(`[lune-headless] Could not resolve require("{request}") from {relative(fromPath)}`, 3)
		end
		return loadFile(file)
	end

	function makeRequire(fromPath: string): (any) -> any
		local nameRequire: (any) -> any
		local function requireAny(target: any): any
			if target == LOADER_MARKER then
				return {
					load = function(_script: any)
						return nameRequire
					end,
				}
			elseif isNode(target) then
				local file = rawget(target, "_moduleFile")
				if not file then
					error(`Attempted to call require with invalid argument(s): {rawget(target, "Name")} is a Folder`, 2)
				end
				return loadFile(file)
			elseif type(target) == "string" then
				local prefix = string.sub(target, 1, 1)
				if prefix == "." or prefix == "@" then
					return requireByPath(fromPath, target)
				end
				return requireByName(fromPath, target)
			end
			error(`Attempted to call require with invalid argument(s): {typeof(target)}`, 2)
		end
		nameRequire = requireAny
		return requireAny
	end

	function self.runSpec(_self): (boolean, string?)
		local ok, err = pcall(loadFile, options.specPath, true)
		if not ok then
			return false, tostring(err)
		end
		return true, nil
	end

	return self :: any
end

return ModuleLoader
