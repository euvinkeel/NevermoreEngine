--!strict
--[[
	The Roblox globals a spec's modules see, by level:

	- none:   nothing beyond Lune's own globals (plus `script`/`require` from the loader).
	- basic:  task, os, tick/time/wait/delay/spawn, a debug proxy with the Roblox profiling and
	          memory-category functions, warn/print capture, Random, DateTime, TweenInfo, shared,
	          and a `game` whose only working service is a pure HttpService.
	- roblox: basic + @lune/roblox Instances and datatypes (Vector3, CFrame, Enum, ...). Lune's
	          Instances have no events, so this level only helps code that reads instance trees.
]]

local RobloxPure = require("./RobloxPure")
local Scheduler = require("./Scheduler")

local Host = {}

export type Level = "none" | "basic" | "roblox"

export type Options = {
	level: Level,
	scheduler: Scheduler.Scheduler,
	log: (kind: string, message: string) -> (),
}

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
		for _, name in
			{
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
		do
			globals[name] = roblox[name]
		end
		-- Lune's BrickColor.new() needs an argument; Roblox's defaults to Medium stone grey.
		globals.BrickColor = setmetatable({
			new = function(...)
				if select("#", ...) == 0 then
					return roblox.BrickColor.new("Medium stone grey")
				end
				return roblox.BrickColor.new(...)
			end,
		}, { __index = roblox.BrickColor })
		RobloxPure.Vector3 = roblox.Vector3
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
	end

	return globals
end

return Host
