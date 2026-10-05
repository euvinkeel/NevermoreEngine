--!strict
--[[
	Member names (methods, events, properties) of every Roblox class, read from the luau-lsp
	definitions file that `npm run lint:luau` downloads to the repo root (globalTypes.d.lua,
	gitignored). The reflection database bundled with Lune has properties but no events or methods;
	this fills that gap for the datamodel host level:

	- every real event resolves to a signal (inert unless the fake fires it);
	- a real method the fake doesn't implement reports "not emulated" instead of "not a valid member";
	- ReflectionService:GetEventsOfClass/GetMethodsOfClass have something to answer with.

	The datamodel level needs the file; the portability lint can do without it.
]]

local fs = require("@lune/fs")

local Fs = require("./Fs")

local RobloxApi = {}

RobloxApi.MISSING = "[lune-headless] The datamodel level needs luau-lsp's definitions, globalTypes.d.lua in the "
	.. "repo root. Run `npm run lint:luau` once to download them."

export type ApiClass = {
	superclass: string?,
	methods: { [string]: true },
	events: { [string]: true },
	properties: { [string]: true },
}

export type Api = { [string]: ApiClass }

function RobloxApi.parse(source: string): Api
	local api: Api = {}
	local current: ApiClass? = nil
	for _, line in string.split(source, "\n") do
		if current then
			if string.sub(line, 1, 3) == "end" then
				current = nil
			else
				local method = string.match(line, "^%s+function ([%a_][%w_]*)%(")
				if method then
					current.methods[method] = true
				else
					local name, rest = string.match(line, "^%s+([%a_][%w_]*): (.*)$")
					if name and rest then
						if string.sub(rest, 1, 15) == "RBXScriptSignal" then
							current.events[name] = true
						else
							current.properties[name] = true
						end
					end
				end
			end
		else
			local name, superclass = string.match(line, "^declare extern type ([%a_][%w_]*) extends ([%a_][%w_]*) with")
			if not name then
				name = string.match(line, "^declare extern type ([%a_][%w_]*) with")
			end
			if name then
				current = { superclass = superclass, methods = {}, events = {}, properties = {} }
				api[name] = current
			end
		end
	end
	return api
end

-- The parsed definitions at `path`, or nil if the file isn't there.
function RobloxApi.load(path: string): Api?
	return if Fs.isFile(path) then RobloxApi.parse(fs.readFile(path)) else nil
end

return RobloxApi
