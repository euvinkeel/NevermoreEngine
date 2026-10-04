--!strict
--[[
	The Roblox globals a spec's modules see, by level:

	- none:   nothing beyond Lune's own globals (plus `script`/`require` from the loader).
	- basic:  task, os, tick/time/wait/delay/spawn, a debug proxy with the Roblox profiling and
	          memory-category functions, warn/print capture, Random, DateTime, TweenInfo, shared,
	          a `typeof` that knows DateTime, and a `game` whose only working service is a pure
	          HttpService.
	- roblox: basic + @lune/roblox Instances and datatypes (Vector3, CFrame, Enum, ...). Lune's
	          Instances have no events, so this level only helps code that reads instance trees.
	- datamodel: basic + @lune/roblox datatypes and Enum, with Instances, `game`, `workspace` and
	          `typeof` from FakeDataModel: instances with events, Bindables, RunService frame signals
	          stepped about 60 times a second in real time, CollectionService. By default it looks like
	          a Nevermore test place: server, not running, not Studio, immediate signals.
]]

local EnumShim = require("./EnumShim")
local FakeDataModel = require("./FakeDataModel")
local RobloxApi = require("./RobloxApi")
local RobloxPure = require("./RobloxPure")
local Scheduler = require("./Scheduler")
local realTask = require("@lune/task")

local Host = {}

export type Level = "none" | "basic" | "roblox" | "datamodel"

export type DataModelOptions = {
	isClient: boolean?,
	isRunning: boolean?,
	isStudio: boolean?,
	signalMode: FakeDataModel.SignalMode?,
	-- luau-lsp definitions (globalTypes.d.lua) for event and method names; optional.
	apiPath: string?,
}

export type Options = {
	level: Level,
	scheduler: Scheduler.Scheduler,
	log: (kind: string, message: string) -> (),
	onStrayError: (message: string) -> (),
	datamodel: DataModelOptions?,
}

local DATATYPES = {
	"Axes",
	"BrickColor",
	"CFrame",
	"Color3",
	"ColorSequence",
	"ColorSequenceKeypoint",
	"Enum",
	"Faces",
	"Font",
	"NumberRange",
	"NumberSequence",
	"NumberSequenceKeypoint",
	"PhysicalProperties",
	"Ray",
	"Rect",
	"Region3",
	"Region3int16",
	"UDim",
	"UDim2",
	"Vector2",
	"Vector2int16",
	"Vector3",
	"Vector3int16",
}

-- Installs @lune/roblox datatypes into `globals` and returns them.
local function installDatatypes(globals: { [string]: any }): { [string]: any }
	local roblox = require("@lune/roblox") :: any
	local datatypes: { [string]: any } = {}
	for _, name in DATATYPES do
		datatypes[name] = roblox[name]
	end
	-- Lune's constructors need arguments where Roblox's have defaults (BrickColor.new() is Medium
	-- stone grey, Ray.new() and Region3.new() are empty at the origin).
	local zeroArgDefaults: { [string]: () -> any } = {
		BrickColor = function()
			return roblox.BrickColor.new("Medium stone grey")
		end,
		Ray = function()
			return roblox.Ray.new(roblox.Vector3.zero, roblox.Vector3.zero)
		end,
		Region3 = function()
			return roblox.Region3.new(roblox.Vector3.zero, roblox.Vector3.zero)
		end,
		Region3int16 = function()
			return roblox.Region3int16.new(roblox.Vector3int16.new(), roblox.Vector3int16.new())
		end,
	}
	for name, makeDefault in zeroArgDefaults do
		local original = roblox[name]
		datatypes[name] = setmetatable({
			new = function(...)
				if select("#", ...) == 0 then
					return makeDefault()
				end
				return original.new(...)
			end,
		}, { __index = original })
	end
	for name, value in datatypes do
		globals[name] = value
	end
	RobloxPure.Vector3 = roblox.Vector3
	return datatypes
end

local function joinArgs(...: any): string
	local parts = table.pack(...)
	for i = 1, parts.n do
		parts[i] = tostring(parts[i])
	end
	return table.concat(parts, " ", 1, parts.n)
end

local function missingService(name: string, level: string): any
	return setmetatable({ Name = name, ClassName = name }, {
		__index = function(_, key)
			error(`[lune-headless] game:GetService("{name}").{key} is not emulated at host level "{level}"`, 2)
		end,
		__tostring = function()
			return name
		end,
	})
end

function Host.build(options: Options): { [string]: any }
	local globals: { [string]: any } = {}
	if options.level == "none" then
		return globals
	end

	local scheduler = options.scheduler
	local log = options.log

	globals.task = scheduler.task
	globals.os = scheduler.os
	for key, value in scheduler.globals do
		globals[key] = value
	end

	globals.debug = setmetatable({
		profilebegin = function(_label: string) end,
		profileend = function() end,
		setmemorycategory = function(_tag: string) end,
		resetmemorycategory = function() end,
		getmemorycategory = function(): string
			return ""
		end,
		dumpcodesize = function() end,
	}, { __index = debug })

	globals.warn = function(...)
		log("warn", joinArgs(...))
	end
	globals.print = function(...)
		log("print", joinArgs(...))
	end

	globals.Random = RobloxPure.Random
	globals.DateTime = RobloxPure.makeDateTime(function()
		return scheduler:unixTime()
	end)
	globals.TweenInfo = RobloxPure.TweenInfo
	globals.shared = {}
	globals.typeof = function(value: any): string
		return RobloxPure.typeName(value) or typeof(value)
	end

	local services: { [string]: any } = {
		HttpService = RobloxPure.HttpService,
	}
	local level = options.level
	local function getService(name: string): any
		local service = services[name]
		if not service then
			service = missingService(name, level)
			services[name] = service
		end
		return service
	end
	globals.game = setmetatable({
		Name = "Game",
		ClassName = "DataModel",
		GetService = function(_self, name: string)
			return getService(name)
		end,
		FindService = function(_self, name: string)
			return services[name]
		end,
		IsLoaded = function()
			return true
		end,
	}, {
		__tostring = function()
			return "Game"
		end,
	})

	if level == "roblox" then
		local roblox = require("@lune/roblox") :: any
		local dataModel = roblox.Instance.new("DataModel")
		globals.Instance = roblox.Instance
		installDatatypes(globals)
		globals.workspace = dataModel:GetService("Workspace")
		globals.game = setmetatable({
			GetService = function(_self, name: string)
				return services[name] or dataModel:GetService(name)
			end,
			FindService = function(_self, name: string)
				return services[name] or dataModel:FindService(name)
			end,
		}, {
			__index = function(_, key)
				local value = (dataModel :: any)[key]
				if type(value) == "function" then
					return function(_self, ...)
						return value(dataModel, ...)
					end
				end
				return value
			end,
		})
	elseif level == "datamodel" then
		local dmOptions: DataModelOptions = options.datamodel or {}
		local isClient = dmOptions.isClient == true
		local roblox = require("@lune/roblox") :: any
		local datatypes = installDatatypes(globals)
		-- Unique EnumItems (see EnumShim), converted where they cross into Lune datatypes.
		local enumShim = EnumShim.new(roblox.Enum)
		datatypes.Enum = enumShim.Enum
		local enumTakers: { [string]: { string } } = {
			Axes = { "new" },
			Faces = { "new" },
			Font = { "new", "fromEnum", "fromName", "fromId" },
			PhysicalProperties = { "new" },
			Vector3 = { "FromNormalId", "FromAxis" },
		}
		for name, functions in enumTakers do
			datatypes[name] = enumShim.wrapFunctions(datatypes[name], functions)
		end
		for name, value in datatypes do
			globals[name] = value
		end
		local dm = FakeDataModel.new({
			scheduler = scheduler,
			signalMode = dmOptions.signalMode or "immediate",
			isClient = isClient,
			isServer = not isClient,
			isStudio = dmOptions.isStudio == true,
			isRunning = dmOptions.isRunning == true,
			datatypes = datatypes,
			enumShim = enumShim,
			reflection = roblox.getReflectionDatabase(),
			api = if dmOptions.apiPath then RobloxApi.load(dmOptions.apiPath) else nil,
			onStrayError = options.onStrayError,
		})
		globals.Instance = dm.Instance
		globals.game = dm.game
		globals.workspace = dm.workspace
		globals.typeof = dm.typeof

		-- Step frames in real time, whatever the fake timers do (Roblox keeps stepping too). Real
		-- waits and delays resume after each frame's Heartbeat. The worker exits the process when
		-- the spec is done, which ends this loop.
		scheduler:useFrames()
		local lastClock = os.clock()
		realTask.spawn(function()
			while true do
				realTask.wait(1 / 60)
				local now = os.clock()
				dm.step(now - lastClock)
				lastClock = now
				scheduler:resumeFrameWaiters()
			end
		end)
	end

	return globals
end

return Host
