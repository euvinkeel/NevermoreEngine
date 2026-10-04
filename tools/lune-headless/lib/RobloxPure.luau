--!strict
--[[
	Pure-Luau stand-ins for Roblox globals that have no Instance behind them: Random, DateTime,
	TweenInfo, and an HttpService with JSONEncode/JSONDecode/GenerateGUID/UrlEncode.

	These match the Roblox API shape, not its exact output: Random is a seeded xorshift128 (Roblox
	uses PCG, so sequences differ), and DateTime covers the members Nevermore uses.
]]

local DateTimeLib = require("@lune/datetime")
local serde = require("@lune/serde")

local RobloxPure = {}

-- Set by the host when a Vector3 implementation is available (the roblox level).
RobloxPure.Vector3 = nil :: any

-- Random

local RandomClass = {}
RandomClass.__index = RandomClass
RandomClass.__type = "Random"

local function nextU32(self: any): number
	local t = bit32.bxor(self._x, bit32.lshift(self._x, 11))
	self._x, self._y, self._z = self._y, self._z, self._w
	self._w = bit32.bxor(self._w, bit32.rshift(self._w, 19), t, bit32.rshift(t, 8))
	return self._w
end

local function seedState(seed: number): (number, number, number, number)
	-- splitmix-style scrambling of the seed into four nonzero words
	local s = math.floor(math.abs(seed) * 1000003) % 4294967296
	local words = {}
	for i = 1, 4 do
		s = (s * 1103515245 + 12345 + i * 2654435761) % 4294967296
		local w = bit32.bxor(s, bit32.rshift(s, 15))
		words[i] = if w == 0 then 0x9E3779B9 else w
	end
	return words[1], words[2], words[3], words[4]
end

function RobloxPure.Random_new(seed: number?): any
	local self = setmetatable({}, RandomClass)
	self._x, self._y, self._z, self._w = seedState(seed or (os.clock() * 1e6 + os.time()))
	for _ = 1, 8 do
		nextU32(self)
	end
	return self
end

function RandomClass.NextNumber(self: any, min: number?, max: number?): number
	-- 53 random bits from two draws
	local high = bit32.rshift(nextU32(self), 5)
	local low = bit32.rshift(nextU32(self), 6)
	local r = (high * 67108864 + low) / 9007199254740992
	if min == nil then
		return r
	end
	local lo = min :: number
	local hi = if max == nil then 1 else max :: number
	return lo + r * (hi - lo)
end

function RandomClass.NextInteger(self: any, min: number, max: number): number
	if max < min then
		error("invalid argument #2 to 'NextInteger' (interval is empty)", 2)
	end
	return min + math.floor(self:NextNumber() * (max - min + 1))
end

function RandomClass.NextUnitVector(self: any): any
	local Vector3 = RobloxPure.Vector3
	if not Vector3 then
		error("Random:NextUnitVector needs Vector3, which this host level doesn't provide", 2)
	end
	-- Uniform on the sphere
	local z = self:NextNumber(-1, 1)
	local theta = self:NextNumber(0, 2 * math.pi)
	local r = math.sqrt(1 - z * z)
	return Vector3.new(r * math.cos(theta), r * math.sin(theta), z)
end

function RandomClass.Shuffle(self: any, t: { any })
	for i = #t, 2, -1 do
		local j = self:NextInteger(1, i)
		t[i], t[j] = t[j], t[i]
	end
end

function RandomClass.Clone(self: any): any
	local copy = setmetatable({}, RandomClass)
	copy._x, copy._y, copy._z, copy._w = self._x, self._y, self._z, self._w
	return copy
end

RobloxPure.Random = table.freeze({ new = RobloxPure.Random_new })

-- DateTime

local DateTimeClass = {}
DateTimeClass.__index = function(self, key)
	if key == "UnixTimestamp" then
		return math.floor((rawget(self, "UnixTimestampMillis") :: number) / 1000)
	end
	return DateTimeClass[key]
end
DateTimeClass.__type = "DateTime"
DateTimeClass.__eq = function(a, b)
	return rawget(a, "UnixTimestampMillis") == rawget(b, "UnixTimestampMillis")
end
DateTimeClass.__lt = function(a, b)
	return rawget(a, "UnixTimestampMillis") < rawget(b, "UnixTimestampMillis")
end
DateTimeClass.__le = function(a, b)
	return rawget(a, "UnixTimestampMillis") <= rawget(b, "UnixTimestampMillis")
end

local function fromMillis(ms: number): any
	return setmetatable({ UnixTimestampMillis = math.floor(ms) }, DateTimeClass)
end

function DateTimeClass.ToIsoDate(self: any): string
	return DateTimeLib.fromUnixTimestamp((rawget(self, "UnixTimestampMillis") :: number) / 1000):toIsoDate()
end

local function toParts(self: any, universal: boolean): { [string]: number }
	local dt = DateTimeLib.fromUnixTimestamp((rawget(self, "UnixTimestampMillis") :: number) / 1000)
	local v = if universal then dt:toUniversalTime() else dt:toLocalTime()
	return {
		Year = v.year,
		Month = v.month,
		Day = v.day,
		Hour = v.hour,
		Minute = v.minute,
		Second = v.second,
		Millisecond = v.millisecond,
	}
end

function DateTimeClass.ToUniversalTime(self: any)
	return toParts(self, true)
end

function DateTimeClass.ToLocalTime(self: any)
	return toParts(self, false)
end

-- `nowSeconds` lets fake timers drive DateTime.now().
function RobloxPure.makeDateTime(nowSeconds: () -> number): any
	return table.freeze({
		now = function()
			return fromMillis(nowSeconds() * 1000)
		end,
		fromUnixTimestamp = function(seconds: number)
			return fromMillis(seconds * 1000)
		end,
		fromUnixTimestampMillis = function(ms: number)
			return fromMillis(ms)
		end,
		fromIsoDate = function(iso: string)
			local ok, dt = pcall(DateTimeLib.fromIsoDate, iso)
			return if ok then fromMillis(dt.unixTimestampMillis) else nil
		end,
		fromUniversalTime = function(year, month, day, hour, minute, second, millisecond)
			local dt = DateTimeLib.fromUniversalTime({
				year = year or 1970,
				month = month or 1,
				day = day or 1,
				hour = hour or 0,
				minute = minute or 0,
				second = second or 0,
				millisecond = millisecond or 0,
			})
			return fromMillis(dt.unixTimestampMillis)
		end,
	})
end

-- TweenInfo

RobloxPure.TweenInfo = table.freeze({
	new = function(time, easingStyle, easingDirection, repeatCount, reverses, delayTime)
		return table.freeze({
			Time = time or 1,
			EasingStyle = easingStyle,
			EasingDirection = easingDirection,
			RepeatCount = repeatCount or 0,
			Reverses = reverses or false,
			DelayTime = delayTime or 0,
		})
	end,
})

-- JSON with Roblox's quirks: an empty table encodes as "[]".

local function isArray(t: { [any]: any }): boolean
	local count = 0
	for key in t do
		if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
			return false
		end
		count += 1
	end
	return count == #t
end

local ESCAPES = {
	['"'] = '\\"',
	["\\"] = "\\\\",
	["\b"] = "\\b",
	["\f"] = "\\f",
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
}

local function encodeString(s: string): string
	return '"'
		.. string.gsub(s, '[%c"\\]', function(c)
			return ESCAPES[c] or string.format("\\u%04x", string.byte(c))
		end)
		.. '"'
end

local function encodeValue(value: any, stack: { [any]: boolean }): string
	local kind = type(value)
	if kind == "nil" then
		return "null"
	elseif kind == "boolean" then
		return tostring(value)
	elseif kind == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			return "null"
		end
		if value % 1 == 0 and math.abs(value) < 2 ^ 53 then
			return string.format("%d", value)
		end
		return tostring(value)
	elseif kind == "string" then
		return encodeString(value)
	elseif kind == "table" then
		if stack[value] then
			error("Cannot convert a cyclic table to JSON", 0)
		end
		stack[value] = true
		local parts = {}
		if next(value) == nil then
			stack[value] = nil
			return "[]"
		elseif isArray(value) then
			for _, item in value do
				table.insert(parts, encodeValue(item, stack))
			end
			stack[value] = nil
			return "[" .. table.concat(parts, ",") .. "]"
		else
			local keys = {}
			for key in value do
				table.insert(keys, key)
			end
			table.sort(keys, function(a, b)
				return tostring(a) < tostring(b)
			end)
			for _, key in keys do
				table.insert(parts, encodeString(tostring(key)) .. ":" .. encodeValue(value[key], stack))
			end
			stack[value] = nil
			return "{" .. table.concat(parts, ",") .. "}"
		end
	end
	error(`Can't convert {typeof(value)} to JSON`, 0)
end

local function generateGuid(wrapInCurlyBraces: boolean?): string
	local hex = "0123456789ABCDEF"
	local out = {}
	for i = 1, 32 do
		local n = math.random(1, 16)
		if i == 13 then
			n = 5 -- version 4
		elseif i == 17 then
			n = 9 + (n % 4) -- variant 10xx
		end
		table.insert(out, string.sub(hex, n, n))
		if i == 8 or i == 12 or i == 16 or i == 20 then
			table.insert(out, "-")
		end
	end
	local guid = table.concat(out)
	if wrapInCurlyBraces == false then
		return guid
	end
	return "{" .. guid .. "}"
end

RobloxPure.HttpService = {
	Name = "HttpService",
	ClassName = "HttpService",
	JSONEncode = function(_self, value: any): string
		return encodeValue(value, {})
	end,
	JSONDecode = function(_self, text: string): any
		local ok, result = pcall(serde.decode, "json" :: any, text)
		if not ok then
			error("Can't parse JSON", 2)
		end
		return result
	end,
	GenerateGUID = function(_self, wrapInCurlyBraces: boolean?): string
		return generateGuid(wrapInCurlyBraces)
	end,
	UrlEncode = function(_self, text: string): string
		return (string.gsub(text, "[^%w%-%._~]", function(c)
			return string.format("%%%02X", string.byte(c))
		end))
	end,
}

return RobloxPure
