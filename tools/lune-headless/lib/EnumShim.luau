--!strict
--[[
	Roblox-like `Enum` for the datamodel host level, built from @lune/roblox's enum data.

	Lune makes a new EnumItem userdata on every access: `Enum.KeyCode.E == Enum.KeyCode.E` holds
	through __eq, but the two are not the same value, so a table keyed by an EnumItem misses. Roblox
	EnumItems are unique, and Nevermore keys tables by them (input pickers, core GUI states). This
	shim hands out one userdata per item, adds Enum:FromName/FromValue, and converts at the edges:
	`toLune` before a value reaches a Lune datatype constructor, `fromLune` for values coming back
	(reflection defaults, datatype constructors' results).

	Known gap: enum fields read off a Lune datatype (Font.Weight) are still Lune EnumItems.
]]

local EnumShim = {}

export type Shim = {
	Enum: any,
	toLune: (value: any) -> any,
	fromLune: (value: any) -> any,
	typeName: (value: any) -> string?,
	wrapFunctions: (library: any, names: { string }) -> any,
}

function EnumShim.new(luneEnum: any): Shim
	local kinds: { [any]: string } = setmetatable({}, { __mode = "k" }) :: any
	local luneOf: { [any]: any } = setmetatable({}, { __mode = "k" }) :: any
	local enums: { [string]: any } = {}

	local function newUserdata(): (any, any)
		local proxy = newproxy(true)
		return proxy, getmetatable(proxy)
	end

	local function getEnum(name: string): any?
		local existing = enums[name]
		if existing then
			return existing
		end
		local ok, luneEnumType = pcall(function()
			return luneEnum[name]
		end)
		if not ok or luneEnumType == nil then
			return nil
		end

		local enum, enumMeta = newUserdata()
		local byName: { [string]: any } = {}
		local byValue: { [number]: any } = {}
		local ordered: { any } = {}
		for _, luneItem in luneEnumType:GetEnumItems() do
			local itemName: string = luneItem.Name
			local itemValue: number = luneItem.Value
			local item, itemMeta = newUserdata()
			itemMeta.__index = function(_self: any, key: any): any
				if key == "Name" then
					return itemName
				elseif key == "Value" then
					return itemValue
				elseif key == "EnumType" then
					return enum
				elseif key == "IsA" then
					return function(_item: any, enumName: string): boolean
						return enumName == name
					end
				end
				error(`{tostring(key)} is not a valid member of "Enum.{name}.{itemName}"`, 2)
			end
			itemMeta.__tostring = function(): string
				return `Enum.{name}.{itemName}`
			end
			itemMeta.__metatable = "The metatable is locked"
			kinds[item] = "EnumItem"
			luneOf[item] = luneItem
			byName[itemName] = item
			if byValue[itemValue] == nil then
				byValue[itemValue] = item
			end
			table.insert(ordered, item)
		end

		local methods = {
			GetEnumItems = function(_self: any): { any }
				return table.clone(ordered)
			end,
			FromName = function(_self: any, itemName: string): any
				return byName[itemName]
			end,
			FromValue = function(_self: any, value: number): any
				return byValue[value]
			end,
		}
		enumMeta.__index = function(_self: any, key: any): any
			local item = byName[key]
			if item then
				return item
			end
			local method = (methods :: any)[key]
			if method then
				return method
			end
			error(`{tostring(key)} is not a valid member of "Enum.{name}"`, 2)
		end
		enumMeta.__tostring = function(): string
			return name
		end
		enumMeta.__metatable = "The metatable is locked"
		kinds[enum] = "Enum"
		enums[name] = enum
		return enum
	end

	local Enums, enumsMeta = newUserdata()
	enumsMeta.__index = function(_self: any, key: any): any
		if key == "GetEnums" then
			return function(): { any }
				local list = {}
				for _, luneEnumType in luneEnum:GetEnums() do
					local name = string.match(tostring(luneEnumType), "^Enum%.(.+)$") or tostring(luneEnumType)
					table.insert(list, getEnum(name))
				end
				return list
			end
		end
		local enum = if type(key) == "string" then getEnum(key) else nil
		if enum then
			return enum
		end
		error(`{tostring(key)} is not a valid member of "Enums"`, 2)
	end
	enumsMeta.__tostring = function(): string
		return "Enums"
	end
	enumsMeta.__metatable = "The metatable is locked"
	kinds[Enums] = "Enums"

	local function fromLune(value: any): any
		if typeof(value) ~= "EnumItem" or kinds[value] then
			return value
		end
		local enumName, itemName = string.match(tostring(value), "^Enum%.([^%.]+)%.(.+)$")
		local enum = enumName and getEnum(enumName)
		if not enum then
			return value
		end
		return (enum :: any):FromName(itemName) or value
	end

	local function toLune(value: any): any
		return luneOf[value] or value
	end

	local function convertArgs(convert: (any) -> any, ...: any): ...any
		local args = table.pack(...)
		for i = 1, args.n do
			args[i] = convert(args[i])
		end
		return table.unpack(args, 1, args.n)
	end

	-- A copy of `library` whose listed functions take shim EnumItems and return shim EnumItems.
	local function wrapFunctions(library: any, names: { string }): any
		local wrapped = setmetatable({}, { __index = library })
		for _, name in names do
			local fn = library[name]
			if type(fn) == "function" then
				wrapped[name] = function(...)
					return convertArgs(fromLune, fn(convertArgs(toLune, ...)))
				end
			end
		end
		return wrapped
	end

	return {
		Enum = Enums,
		toLune = toLune,
		fromLune = fromLune,
		typeName = function(value: any): string?
			return kinds[value]
		end,
		wrapFunctions = wrapFunctions,
	}
end

return EnumShim
