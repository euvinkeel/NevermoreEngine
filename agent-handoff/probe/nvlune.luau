--[[
	Probe harness v2: run a Nevermore spec under Lune with no Roblox engine.

	lune run nvlune.luau <nevermore src dir> <spec file> [--shim=<level>]

	--shim=none   only what Nevermore's loader convention strictly needs (script/require/Jest)
	--shim=basic  + Lune task, fake `game` services, debug.profilebegin/profileend (default)

	Prints one machine-readable line at the end:
	RESULT {"passed":n,"failed":n,"loadError":"..."|null,"failures":[...]}
]]
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local serde = require("@lune/serde")
local realTask = require("@lune/task")

local SRC = process.args[1]
local SPEC = process.args[2]
local SHIM = "basic"
for _, a in process.args do
	local level = string.match(a, "^%-%-shim=(%w+)$")
	if level then
		SHIM = level
	end
end

-- Module index, mirroring Nevermore's loader: require("Name") resolves by module name.
local index: { [string]: string } = {}
local function scan(dir: string)
	for _, entry in fs.readDir(dir) do
		if entry == "node_modules" or entry == ".git" or entry == "test" then
			continue
		end
		local path = dir .. "/" .. entry
		if fs.isDir(path) then
			scan(path)
		else
			local name = string.match(entry, "^(.+)%.luau?$")
			if name and not string.find(name, "%.") and not index[name] then
				index[name] = path
			end
		end
	end
end
scan(SRC)

-- Third-party npm packages expose one module named by their default.project.json.
local thirdParty: { [string]: string } = {}
local PNPM = SRC .. "/../node_modules/.pnpm"
if fs.isDir(PNPM) then
	for _, pkgDir in fs.readDir(PNPM) do
		local scopeRoot = PNPM .. "/" .. pkgDir .. "/node_modules"
		if not fs.isDir(scopeRoot) then
			continue
		end
		for _, scope in fs.readDir(scopeRoot) do
			local roots = {}
			if string.sub(scope, 1, 1) == "@" and fs.isDir(scopeRoot .. "/" .. scope) then
				for _, inner in fs.readDir(scopeRoot .. "/" .. scope) do
					table.insert(roots, scopeRoot .. "/" .. scope .. "/" .. inner)
				end
			else
				table.insert(roots, scopeRoot .. "/" .. scope)
			end
			for _, root in roots do
				local projectFile = root .. "/default.project.json"
				if fs.isFile(projectFile) then
					local ok, project = pcall(serde.decode, "json", fs.readFile(projectFile))
					local treePath = ok and project.tree and project.tree["$path"]
					if type(treePath) == "string" then
						local full = root .. "/" .. treePath
						for _, entry in { full, full .. "/init.luau", full .. "/init.lua", full .. "/" .. project.name .. ".luau" } do
							if fs.isFile(entry) then
								thirdParty[string.lower(project.name)] = entry
								break
							end
						end
					end
				end
			end
		end
	end
end

-- Virtual time for jest fake timers.
local fake = false
local fakeNow = 0
local timers: { { due: number, seq: number, fn: any, args: { any } } } = {}
local timerSeq = 0
local function schedule(delay: number, fn: any, ...: any)
	timerSeq += 1
	local t = { due = fakeNow + (delay or 0), seq = timerSeq, fn = fn, args = table.pack(...) }
	table.insert(timers, t)
	return t
end
local function runDue(untilTime: number)
	while true do
		local nextIndex, nextTimer = nil, nil
		for i, t in timers do
			if t.due <= untilTime and (nextTimer == nil or t.due < nextTimer.due or (t.due == nextTimer.due and t.seq < nextTimer.seq)) then
				nextIndex, nextTimer = i, t
			end
		end
		if not nextTimer then
			break
		end
		table.remove(timers, nextIndex)
		fakeNow = math.max(fakeNow, nextTimer.due)
		if type(nextTimer.fn) == "thread" then
			coroutine.resume(nextTimer.fn, table.unpack(nextTimer.args, 1, nextTimer.args.n))
		else
			local co = coroutine.create(nextTimer.fn)
			local ok, err = coroutine.resume(co, table.unpack(nextTimer.args, 1, nextTimer.args.n))
			if not ok then
				error(err, 0)
			end
		end
	end
	fakeNow = math.max(fakeNow, untilTime)
end
local fakeTask = {
	delay = function(delay: number, fn: any, ...)
		return schedule(delay, fn, ...)
	end,
	defer = function(fn: any, ...)
		return schedule(0, fn, ...)
	end,
	wait = function(delay: number?)
		local start = fakeNow
		schedule(delay or 0, coroutine.running())
		coroutine.yield()
		return fakeNow - start
	end,
	cancel = function(t: any)
		for i, v in timers do
			if v == t then
				table.remove(timers, i)
				return
			end
		end
		if type(t) == "thread" then
			pcall(coroutine.close, t)
		end
	end,
}
local TASK = setmetatable({}, {
	__index = function(_, key)
		if fake and fakeTask[key] then
			return fakeTask[key]
		end
		return (realTask :: any)[key]
	end,
})
local OS = setmetatable({
	clock = function()
		return if fake then fakeNow else os.clock()
	end,
}, { __index = os })

-- Minimal jest: describe/it/expect + the matchers the closure's specs use, hooks, fake timers.
local passed, failed = 0, 0
local failures = {}
local stack = {}
local afterEachHooks, beforeEachHooks = {}, {}
local function deepEqual(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for k, v in a do
		if not deepEqual(v, b[k]) then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
end
local function show(v: any): string
	if type(v) == "table" then
		local ok, s = pcall(serde.encode, "json", v)
		return if ok then s else tostring(v)
	end
	return tostring(v)
end
local function expect(actual: any)
	local function matchers(negate: boolean)
		local m = {}
		local function check(ok: boolean, msg: string)
			if negate then
				ok = not ok
			end
			if not ok then
				error((if negate then "[never] " else "") .. msg, 3)
			end
		end
		function m.toBe(expected)
			check(actual == expected, `expected {show(actual)} to be {show(expected)}`)
		end
		function m.toEqual(expected)
			check(deepEqual(actual, expected), `expected {show(actual)} to equal {show(expected)}`)
		end
		function m.toBeNil()
			check(actual == nil, `expected {show(actual)} to be nil`)
		end
		function m.toHaveLength(n)
			check(#actual == n, `expected length {#actual} to be {n}`)
		end
		function m.toThrow(pattern: string?)
			local ok, err = pcall(actual)
			local matched = not ok and (pattern == nil or string.find(tostring(err), pattern, 1, true) ~= nil)
			check(matched, `expected function to throw{if pattern then " " .. pattern else ""}, got {if ok then "no error" else tostring(err)}`)
		end
		return m
	end
	local m = matchers(false)
	m.never = matchers(true)
	return m
end
local jestObject = {
	useFakeTimers = function()
		fake = true
		fakeNow = 0
		table.clear(timers)
	end,
	useRealTimers = function()
		fake = false
		table.clear(timers)
	end,
	advanceTimersByTime = function(ms: number)
		runDue(fakeNow + ms / 1000)
	end,
	runAllTimers = function()
		runDue(math.huge)
	end,
}
local Jest = {
	Globals = {
		describe = function(name: string, fn: () -> ())
			table.insert(stack, name)
			local ok, err = pcall(fn)
			if not ok then
				failed += 1
				table.insert(failures, table.concat(stack, " > ") .. " [describe body] " .. tostring(err))
			end
			table.remove(stack)
		end,
		it = function(name: string, fn: () -> ())
			local full = table.concat(stack, " > ") .. " > " .. name
			for _, h in beforeEachHooks do
				h()
			end
			local co = coroutine.create(fn)
			local ok, err = coroutine.resume(co)
			if ok and coroutine.status(co) ~= "dead" and not fake then
				-- Let Lune's real scheduler resume threads that yielded on task.wait/task.delay.
				local waited = 0
				while coroutine.status(co) ~= "dead" and waited < 5 do
					waited += realTask.wait(0.005)
				end
			end
			if ok and coroutine.status(co) ~= "dead" then
				ok, err = false, "test yielded and never resumed (needs a real scheduler)"
			end
			for _, h in afterEachHooks do
				local hookOk, hookErr = pcall(h)
				if ok and not hookOk then
					ok, err = false, hookErr
				end
			end
			fake = false
			table.clear(timers)
			if ok then
				passed += 1
			else
				failed += 1
				table.insert(failures, full .. " :: " .. string.sub(tostring(err), 1, 300))
			end
		end,
		expect = expect,
		jest = jestObject,
		afterEach = function(fn)
			table.insert(afterEachHooks, fn)
		end,
		beforeEach = function(fn)
			table.insert(beforeEachHooks, fn)
		end,
	},
}

-- Roblox surface shims (basic level).
local LOADER_MARKER = newproxy(false)
local fakeGame = {
	GetService = function(_self, name: string)
		return setmetatable({ Name = name, ClassName = name }, {
			__index = function(_, key)
				error(`[shim] game:GetService("{name}").{key} is not available outside Roblox`, 2)
			end,
		})
	end,
}
local debugShim = setmetatable({
	profilebegin = function() end,
	profileend = function() end,
	setmemorycategory = function() end,
	resetmemorycategory = function() end,
}, { __index = debug })

-- Roblox level: Lune's Instance tree + datatypes (no events), plus pure-Luau Random/DateTime/TweenInfo.
local ROBLOX_GLOBALS: { [string]: any } = {}
if SHIM == "roblox" then
	local roblox = require("@lune/roblox") :: any
	local dataModel = roblox.Instance.new("DataModel")
	ROBLOX_GLOBALS.Instance = roblox.Instance
	ROBLOX_GLOBALS.game = dataModel
	ROBLOX_GLOBALS.workspace = dataModel:GetService("Workspace")
	for _, name in { "Vector3", "Vector2", "CFrame", "Color3", "UDim", "UDim2", "Enum", "NumberRange", "NumberSequence", "ColorSequence", "BrickColor", "Rect", "Ray", "Region3", "Font", "Axes", "Faces", "PhysicalProperties", "NumberSequenceKeypoint", "ColorSequenceKeypoint" } do
		ROBLOX_GLOBALS[name] = roblox[name]
	end

	-- xorshift-based Random with the methods Nevermore uses
	local RandomClass = {}
	RandomClass.__index = RandomClass
	local function step(self)
		local x = self._s
		x = bit32.bxor(x, bit32.lshift(x, 13))
		x = bit32.bxor(x, bit32.rshift(x, 17))
		x = bit32.bxor(x, bit32.lshift(x, 5))
		self._s = x
		return x / 4294967296
	end
	ROBLOX_GLOBALS.Random = {
		new = function(seed: number?)
			local s = bit32.band(math.floor((seed or os.clock() * 1e6) % 4294967295), 0xFFFFFFFF)
			return setmetatable({ _s = if s == 0 then 2463534242 else s }, RandomClass)
		end,
	}
	function RandomClass:NextNumber(min: number?, max: number?)
		local r = step(self)
		if min == nil then
			return r
		end
		return (min :: number) + r * ((max :: number) - (min :: number))
	end
	function RandomClass:NextInteger(min: number, max: number)
		return min + math.floor(step(self) * (max - min + 1))
	end
	function RandomClass:Clone()
		return setmetatable({ _s = self._s }, RandomClass)
	end
	function RandomClass:Shuffle(t: { any })
		for i = #t, 2, -1 do
			local j = self:NextInteger(1, i)
			t[i], t[j] = t[j], t[i]
		end
	end
	ROBLOX_GLOBALS.DateTime = {
		now = function()
			local ms = math.floor(os.time() * 1000)
			return { UnixTimestampMillis = ms, UnixTimestamp = math.floor(ms / 1000) }
		end,
	}
	ROBLOX_GLOBALS.TweenInfo = {
		new = function(time, style, direction, repeatCount, reverses, delayTime)
			return { Time = time or 1, EasingStyle = style, EasingDirection = direction, RepeatCount = repeatCount or 0, Reverses = reverses or false, DelayTime = delayTime or 0 }
		end,
	}
	fakeGame = dataModel
end

local cache: { [string]: any } = {}
local nameRequire
local function loadFile(name: string, path: string): any
	local env: { [string]: any } = {
		script = { Name = name, Parent = { Name = "Parent", loader = LOADER_MARKER } },
		require = function(target: any)
			if target == LOADER_MARKER then
				return {
					load = function(_script)
						return nameRequire
					end,
				}
			elseif type(target) == "string" then
				return nameRequire(target)
			end
			error(`[shim] unsupported require target {target}`)
		end,
	}
	if SHIM ~= "none" then
		env.task = TASK
		env.os = OS
		env.game = fakeGame
		env.debug = debugShim
		env.warn = function(...) end
	end
	if SHIM == "roblox" then
		for key, value in ROBLOX_GLOBALS do
			env[key] = value
		end
	end
	local chunk = luau.load(fs.readFile(path), { debugName = name, environment = env })
	return chunk()
end
function nameRequire(name: string): any
	if name == "Jest" or name == "JestGlobals" then
		return Jest
	end
	if cache[name] ~= nil then
		return cache[name]
	end
	local path = index[name] or thirdParty[string.lower(name)]
	if not path then
		error(`[shim] module "{name}" not found`, 2)
	end
	cache[name] = loadFile(name, path)
	return cache[name]
end

local ok, err = pcall(loadFile, "spec", SPEC)
local loadError = if ok then nil else string.sub(tostring(err), 1, 400)
print("RESULT " .. serde.encode("json", {
	passed = passed,
	failed = failed,
	loadError = loadError,
	failures = failures,
}))
