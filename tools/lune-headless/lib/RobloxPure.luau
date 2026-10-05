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

-- Roblox's ISO form: UTC with a Z and no fractional seconds.
function DateTimeClass.ToIsoDate(self: any): string
	local t = toParts(self, true)
	return string.format("%04d-%02d-%02dT%02d:%02d:%02dZ", t.Year, t.Month, t.Day, t.Hour, t.Minute, t.Second)
end

function DateTimeClass.ToLocalTime(self: any)
	return toParts(self, false)
end

-- Formatting: the tokens Roblox documents for DateTime:FormatUniversalTime, English names only.

local MONTH_NAMES = {
	"January",
	"February",
	"March",
	"April",
	"May",
	"June",
	"July",
	"August",
	"September",
	"October",
	"November",
	"December",
}
local DAY_NAMES = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }

-- en-us localized composites.
local COMPOSITES: { [string]: string } = {
	LTS = "h:mm:ss A",
	LT = "h:mm A",
	LLLL = "dddd, MMMM D, YYYY h:mm A",
	llll = "ddd, MMM D, YYYY h:mm A",
	LLL = "MMMM D, YYYY h:mm A",
	lll = "MMM D, YYYY h:mm A",
	LL = "MMMM D, YYYY",
	ll = "MMM D, YYYY",
	L = "MM/DD/YYYY",
	l = "M/D/YYYY",
}
local COMPOSITE_ORDER = { "LLLL", "llll", "LTS", "LLL", "lll", "LL", "ll", "LT", "L", "l" }

-- Tokens that print names, which only English is emulated for.
local NAME_TOKENS = { MMMM = true, MMM = true, dddd = true, ddd = true, A = true, a = true }

local TOKEN_ORDER = {
	"YYYY",
	"YY",
	"MMMM",
	"MMM",
	"MM",
	"M",
	"DDDD",
	"DDD",
	"DD",
	"D",
	"dddd",
	"ddd",
	"d",
	"HH",
	"H",
	"hh",
	"h",
	"mm",
	"m",
	"ss",
	"s",
	"SSS",
	"SS",
	"S",
	"A",
	"a",
}

-- Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's days_from_civil).
local function daysFromCivil(year: number, month: number, day: number): number
	local y = if month <= 2 then year - 1 else year
	local era = (if y >= 0 then y else y - 399) // 400
	local yoe = y - era * 400
	local mp = (month + 9) % 12
	local doy = (153 * mp + 2) // 5 + day - 1
	local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	return era * 146097 + doe - 719468
end

local function pad(n: number, width: number): string
	return string.format(`%0{width}d`, n)
end

local function formatParts(parts: { [string]: number }, format: string, locale: string): string
	local english = string.lower(string.sub(locale, 1, 2)) == "en"
	local days = daysFromCivil(parts.Year, parts.Month, parts.Day)
	local weekDay = (days + 4) % 7 -- 1970-01-01 was a Thursday; Sunday is 0
	local yearDay = days - daysFromCivil(parts.Year, 1, 1) + 1
	local hour12 = if parts.Hour % 12 == 0 then 12 else parts.Hour % 12

	local function token(name: string): string
		if NAME_TOKENS[name] and not english then
			error(`[lune-headless] DateTime formatting only emulates English names (locale "{locale}")`, 0)
		end
		if name == "YYYY" then
			return pad(parts.Year, 4)
		elseif name == "YY" then
			return pad(parts.Year % 100, 2)
		elseif name == "MMMM" then
			return MONTH_NAMES[parts.Month]
		elseif name == "MMM" then
			return string.sub(MONTH_NAMES[parts.Month], 1, 3)
		elseif name == "MM" then
			return pad(parts.Month, 2)
		elseif name == "M" then
			return tostring(parts.Month)
		elseif name == "DDDD" then
			return pad(yearDay, 3)
		elseif name == "DDD" then
			return tostring(yearDay)
		elseif name == "DD" then
			return pad(parts.Day, 2)
		elseif name == "D" then
			return tostring(parts.Day)
		elseif name == "dddd" then
			return DAY_NAMES[weekDay + 1]
		elseif name == "ddd" then
			return string.sub(DAY_NAMES[weekDay + 1], 1, 3)
		elseif name == "d" then
			return tostring(weekDay)
		elseif name == "HH" then
			return pad(parts.Hour, 2)
		elseif name == "H" then
			return tostring(parts.Hour)
		elseif name == "hh" then
			return pad(hour12, 2)
		elseif name == "h" then
			return tostring(hour12)
		elseif name == "mm" then
			return pad(parts.Minute, 2)
		elseif name == "m" then
			return tostring(parts.Minute)
		elseif name == "ss" then
			return pad(parts.Second, 2)
		elseif name == "s" then
			return tostring(parts.Second)
		elseif name == "SSS" then
			return pad(parts.Millisecond, 3)
		elseif name == "SS" then
			return pad(parts.Millisecond // 10, 2)
		elseif name == "S" then
			return tostring(parts.Millisecond // 100)
		elseif name == "A" then
			return if parts.Hour < 12 then "AM" else "PM"
		else -- "a"
			return if parts.Hour < 12 then "am" else "pm"
		end
	end

	local out = {}
	local index = 1
	while index <= #format do
		local char = string.sub(format, index, index)
		if char == "[" then
			local close = string.find(format, "]", index + 1, true)
			if close then
				table.insert(out, string.sub(format, index + 1, close - 1))
				index = close + 1
				continue
			end
		end
		local matched = false
		for _, name in COMPOSITE_ORDER do
			if string.sub(format, index, index + #name - 1) == name then
				if not english then
					error(`[lune-headless] DateTime formatting only emulates English (locale "{locale}")`, 0)
				end
				table.insert(out, formatParts(parts, COMPOSITES[name], locale))
				index += #name
				matched = true
				break
			end
		end
		if not matched then
			for _, name in TOKEN_ORDER do
				if string.sub(format, index, index + #name - 1) == name then
					table.insert(out, token(name))
					index += #name
					matched = true
					break
				end
			end
		end
		if not matched then
			table.insert(out, char)
			index += 1
		end
	end
	return table.concat(out)
end

function DateTimeClass.FormatUniversalTime(self: any, format: string, locale: string): string
	if type(locale) ~= "string" then
		error("Argument 2 missing or nil", 2)
	end
	return formatParts(toParts(self, true), format, locale)
end

function DateTimeClass.FormatLocalTime(self: any, format: string, locale: string): string
	if type(locale) ~= "string" then
		error("Argument 2 missing or nil", 2)
	end
	return formatParts(toParts(self, false), format, locale)
end

-- "DateTime" for this module's DateTime objects, nil for anything else.
function RobloxPure.typeName(value: any): string?
	if type(value) == "table" and getmetatable(value) == DateTimeClass then
		return "DateTime"
	end
	return nil
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
			local y, mo, d = year or 1970, month or 1, day or 1
			if mo < 1 or mo > 12 or d < 1 or d > 31 then
				-- Out-of-range calendar fields: let Lune reject them (Roblox's handling is unverified).
				local dt = DateTimeLib.fromUniversalTime({
					year = y,
					month = mo,
					day = d,
					hour = 0,
					minute = 0,
					second = 0,
					millisecond = 0,
				})
				return fromMillis(dt.unixTimestampMillis)
			end
			-- Clock fields roll over (hour 25 is 01:00 the next day), as on Roblox.
			local seconds = daysFromCivil(y, mo, d) * 86400 + (hour or 0) * 3600 + (minute or 0) * 60 + (second or 0)
			return fromMillis(seconds * 1000 + (millisecond or 0))
		end,
		fromLocalTime = function(year, month, day, hour, minute, second, millisecond)
			local dt = DateTimeLib.fromLocalTime({
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
