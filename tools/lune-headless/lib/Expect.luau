--!strict
--[[
	`expect`, its matchers, asymmetric matchers and `jest.fn`/`jest.spyOn` mocks: the subset of
	jest-lua that Nevermore specs use (counted across src/**/*.spec.lua), with jest-lua's semantics:
	- toBe uses identity, with NaN equal to itself (Object.is).
	- toEqual compares recursively and ignores metatables; toStrictEqual also compares metatables.
	- toThrow(text) passes when the error message contains `text` (plain find).
	- Matchers may be called with `.` or `:`.
]]

local Expect = {}

local ASYMMETRIC = {} -- metatable marking asymmetric matchers
local MOCK = {} -- metatable marking mock functions

-- Forwarding functions handed out by jest.fn/spyOn, mapped back to their mock.
local mockOfFunction: { [any]: any } = setmetatable({}, { __mode = "k" }) :: any
local allMocks: { any } = {}

local function isNaN(v: any): boolean
	return type(v) == "number" and v ~= v
end

local function objectIs(a: any, b: any): boolean
	return rawequal(a, b) or (isNaN(a) and isNaN(b))
end

local function isAsymmetric(v: any): boolean
	return type(v) == "table" and getmetatable(v) == ASYMMETRIC
end

local function toMock(v: any): any?
	if type(v) == "table" and getmetatable(v) == MOCK then
		return v
	end
	return mockOfFunction[v]
end

local function deepEqual(a: any, b: any, strict: boolean, seen: { [any]: { [any]: boolean } }): boolean
	if isAsymmetric(b) then
		return b.matches(a)
	end
	if isAsymmetric(a) then
		return a.matches(b)
	end
	if objectIs(a, b) then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		-- Userdata datatypes (Vector3, CFrame, ...) compare by value through __eq.
		if typeof(a) == typeof(b) and type(a) == "userdata" then
			return a == b
		end
		return false
	end
	if strict and getmetatable(a) ~= getmetatable(b) then
		return false
	end
	local pairsSeen: { [any]: boolean } = seen[a] or {}
	if pairsSeen[b] then
		return true
	end
	seen[a] = pairsSeen
	pairsSeen[b] = true
	for key, value in a do
		if not deepEqual(value, b[key], strict, seen) then
			return false
		end
	end
	for key, value in b do
		if a[key] == nil and value ~= nil then
			return false
		end
	end
	return true
end

function Expect.equals(a: any, b: any, strict: boolean?): boolean
	return deepEqual(a, b, strict == true, {})
end

local function formatKey(key: any): string
	if type(key) == "string" and string.match(key, "^[%a_][%w_]*$") then
		return key
	end
	return "[" .. Expect.format(key, 1) .. "]"
end

-- A short, readable rendering of a value for failure messages.
function Expect.format(value: any, depth: number?): string
	local remaining = depth or 3
	if type(value) == "string" then
		return string.format("%q", value)
	elseif isAsymmetric(value) then
		return value.description
	elseif toMock(value) then
		return "[mock function]"
	elseif type(value) ~= "table" then
		return tostring(value)
	end
	if remaining <= 0 then
		return "{...}"
	end
	local parts = {}
	local count = 0
	local length = #value
	for i = 1, length do
		count += 1
		if count > 12 then
			table.insert(parts, "...")
			break
		end
		table.insert(parts, Expect.format(value[i], remaining - 1))
	end
	if count <= 12 then
		local keys = {}
		for key in value do
			if not (type(key) == "number" and key >= 1 and key <= length and key % 1 == 0) then
				table.insert(keys, key)
			end
		end
		table.sort(keys, function(x, y)
			return tostring(x) < tostring(y)
		end)
		for _, key in keys do
			count += 1
			if count > 12 then
				table.insert(parts, "...")
				break
			end
			table.insert(parts, formatKey(key) .. " = " .. Expect.format(value[key], remaining - 1))
		end
	end
	return "{" .. table.concat(parts, ", ") .. "}"
end

local function errorMessage(err: any): string
	if type(err) == "table" and err.message ~= nil then
		return tostring(err.message)
	end
	return tostring(err)
end

-- Asymmetric matchers

local function asymmetric(description: string, matches: (any) -> boolean): any
	return setmetatable({ description = description, matches = matches }, ASYMMETRIC)
end

local function isInstanceOf(value: any, class: any): boolean
	if type(value) ~= "table" then
		return false
	end
	local mt = getmetatable(value)
	local guard = 0
	while type(mt) == "table" and guard < 64 do
		if mt == class or mt.__index == class then
			return true
		end
		mt = getmetatable(mt)
		guard += 1
	end
	return false
end

local function anyMatcher(expected: any): any
	if type(expected) == "string" then
		return asymmetric(`Any<{expected}>`, function(v)
			return type(v) == expected or typeof(v) == expected
		end)
	end
	return asymmetric("Any<class>", function(v)
		return isInstanceOf(v, expected)
	end)
end

-- Matchers

type MatcherContext = {
	actual: any,
	negate: boolean,
}

local function fail(ctx: MatcherContext, pass: boolean, message: string)
	if ctx.negate then
		pass = not pass
	end
	if not pass then
		error((if ctx.negate then "expect(received).never: " else "expect(received): ") .. message, 4)
	end
end

local function getMockOrFail(value: any): any
	local mock = toMock(value)
	if not mock then
		error(`expect(received): received value must be a mock function, got {Expect.format(value)}`, 4)
	end
	return mock
end

local MATCHERS: { [string]: (ctx: MatcherContext, ...any) -> () } = {}

function MATCHERS.toBe(ctx, expected)
	fail(ctx, objectIs(ctx.actual, expected), `{Expect.format(ctx.actual)} to be {Expect.format(expected)}`)
end

function MATCHERS.toEqual(ctx, expected)
	fail(
		ctx,
		deepEqual(ctx.actual, expected, false, {}),
		`{Expect.format(ctx.actual)} to equal {Expect.format(expected)}`
	)
end

function MATCHERS.toStrictEqual(ctx, expected)
	fail(
		ctx,
		deepEqual(ctx.actual, expected, true, {}),
		`{Expect.format(ctx.actual)} to strictly equal {Expect.format(expected)}`
	)
end

function MATCHERS.toBeNil(ctx)
	fail(ctx, ctx.actual == nil, `{Expect.format(ctx.actual)} to be nil`)
end
MATCHERS.toBeUndefined = MATCHERS.toBeNil

function MATCHERS.toBeDefined(ctx)
	fail(ctx, ctx.actual ~= nil, `{Expect.format(ctx.actual)} to be defined`)
end

function MATCHERS.toBeTruthy(ctx)
	fail(ctx, not not ctx.actual, `{Expect.format(ctx.actual)} to be truthy`)
end

function MATCHERS.toBeFalsy(ctx)
	fail(ctx, not ctx.actual, `{Expect.format(ctx.actual)} to be falsy`)
end

function MATCHERS.toBeNaN(ctx)
	fail(ctx, isNaN(ctx.actual), `{Expect.format(ctx.actual)} to be NaN`)
end

function MATCHERS.toBeCloseTo(ctx, expected: number, numDigits: number?)
	local digits = numDigits or 2
	local actual = ctx.actual
	local pass
	if actual == math.huge and expected == math.huge or actual == -math.huge and expected == -math.huge then
		pass = true
	else
		pass = type(actual) == "number" and math.abs(expected - actual) < (10 ^ -digits) / 2
	end
	fail(ctx, pass, `{Expect.format(actual)} to be close to {Expect.format(expected)} ({digits} digits)`)
end

local function compareNumbers(name: string, op: (number, number) -> boolean)
	MATCHERS[name] = function(ctx, expected)
		local actual = ctx.actual
		if type(actual) ~= "number" or type(expected) ~= "number" then
			error(`expect(received).{name}: both values must be numbers`, 3)
		end
		fail(ctx, op(actual, expected), `{actual} {name} {expected}`)
	end
end
compareNumbers("toBeGreaterThan", function(a, b)
	return a > b
end)
compareNumbers("toBeGreaterThanOrEqual", function(a, b)
	return a >= b
end)
compareNumbers("toBeLessThan", function(a, b)
	return a < b
end)
compareNumbers("toBeLessThanOrEqual", function(a, b)
	return a <= b
end)

function MATCHERS.toContain(ctx, item)
	local actual = ctx.actual
	local pass = false
	if type(actual) == "string" then
		pass = type(item) == "string" and string.find(actual, item, 1, true) ~= nil
	elseif type(actual) == "table" then
		for _, value in actual do
			if objectIs(value, item) then
				pass = true
				break
			end
		end
	end
	fail(ctx, pass, `{Expect.format(actual)} to contain {Expect.format(item)}`)
end

function MATCHERS.toContainEqual(ctx, item)
	local pass = false
	if type(ctx.actual) == "table" then
		for _, value in ctx.actual do
			if deepEqual(value, item, false, {}) then
				pass = true
				break
			end
		end
	end
	fail(ctx, pass, `{Expect.format(ctx.actual)} to contain equal {Expect.format(item)}`)
end

function MATCHERS.toHaveLength(ctx, length: number)
	local actual = ctx.actual
	local actualLength = if type(actual) == "string" or type(actual) == "table" then #actual else nil
	fail(ctx, actualLength == length, `length {tostring(actualLength)} to be {length}`)
end

function MATCHERS.toMatch(ctx, pattern: string)
	local pass = type(ctx.actual) == "string" and string.find(ctx.actual, pattern) ~= nil
	fail(ctx, pass, `{Expect.format(ctx.actual)} to match {Expect.format(pattern)}`)
end

function MATCHERS.toBeInstanceOf(ctx, class)
	fail(ctx, isInstanceOf(ctx.actual, class), `{Expect.format(ctx.actual)} to be an instance of the class`)
end

function MATCHERS.toHaveProperty(ctx, path: any, ...)
	local hasValue = select("#", ...) > 0
	local expected = ...
	local keys = if type(path) == "table" then path else string.split(tostring(path), ".")
	local current = ctx.actual
	local found = true
	for _, key in keys do
		if type(current) ~= "table" or current[key] == nil then
			found = false
			break
		end
		current = current[key]
	end
	local pass = found and (not hasValue or deepEqual(current, expected, false, {}))
	fail(ctx, pass, `{Expect.format(ctx.actual)} to have property {Expect.format(path)}`)
end

function MATCHERS.toThrow(ctx, expected: any?)
	local fn = ctx.actual
	if type(fn) ~= "function" and not toMock(fn) then
		error("expect(received).toThrow: received value must be a function", 3)
	end
	local ok, err = pcall(fn)
	local pass
	local detail
	if ok then
		pass = false
		detail = "did not throw"
	else
		local message = errorMessage(err)
		detail = "threw " .. Expect.format(message)
		if expected == nil then
			pass = true
		elseif type(expected) == "string" then
			pass = string.find(message, expected, 1, true) ~= nil
		elseif isAsymmetric(expected) then
			pass = expected.matches(message)
		elseif type(expected) == "table" and expected.message ~= nil then
			pass = string.find(message, tostring(expected.message), 1, true) ~= nil
		else
			pass = true
		end
	end
	local wanted = if expected == nil then "" else " " .. Expect.format(expected)
	fail(ctx, pass, `function to throw{wanted}, but it {detail}`)
end
MATCHERS.toThrowError = MATCHERS.toThrow

function MATCHERS.toHaveBeenCalled(ctx)
	local mock = getMockOrFail(ctx.actual)
	fail(ctx, #mock.mock.calls > 0, `mock to have been called, called {#mock.mock.calls} times`)
end
MATCHERS.toBeCalled = MATCHERS.toHaveBeenCalled

function MATCHERS.toHaveBeenCalledTimes(ctx, times: number)
	local mock = getMockOrFail(ctx.actual)
	fail(ctx, #mock.mock.calls == times, `mock to have been called {times} times, called {#mock.mock.calls} times`)
end
MATCHERS.toBeCalledTimes = MATCHERS.toHaveBeenCalledTimes

local function callMatches(call: any, expected: any): boolean
	if (call.n or #call) ~= (expected.n or #expected) then
		return false
	end
	for i = 1, expected.n or #expected do
		if not deepEqual(call[i], expected[i], false, {}) then
			return false
		end
	end
	return true
end

function MATCHERS.toHaveBeenCalledWith(ctx, ...)
	local mock = getMockOrFail(ctx.actual)
	local expected = table.pack(...)
	local pass = false
	for _, call in mock.mock.calls do
		if callMatches(call, expected) then
			pass = true
			break
		end
	end
	fail(ctx, pass, `mock to have been called with {Expect.format(expected)}`)
end
MATCHERS.toBeCalledWith = MATCHERS.toHaveBeenCalledWith

function MATCHERS.toHaveBeenLastCalledWith(ctx, ...)
	local mock = getMockOrFail(ctx.actual)
	local calls = mock.mock.calls
	local last = calls[#calls]
	fail(
		ctx,
		last ~= nil and callMatches(last, table.pack(...)),
		`mock to have been last called with {Expect.format(table.pack(...))}`
	)
end
MATCHERS.lastCalledWith = MATCHERS.toHaveBeenLastCalledWith

function MATCHERS.toHaveBeenNthCalledWith(ctx, n: number, ...)
	local mock = getMockOrFail(ctx.actual)
	local call = mock.mock.calls[n]
	fail(
		ctx,
		call ~= nil and callMatches(call, table.pack(...)),
		`mock call #{n} to have been called with {Expect.format(table.pack(...))}`
	)
end

-- expect(actual)

local function buildMatchers(actual: any, negate: boolean): any
	local ctx: MatcherContext = { actual = actual, negate = negate }
	local matchers = {}
	for name, matcher in MATCHERS do
		matchers[name] = function(...)
			-- Support both `expect(x).toBe(y)` and `expect(x):toBe(y)`.
			if rawequal((...), matchers) then
				return matcher(ctx, select(2, ...))
			end
			return matcher(ctx, ...)
		end
	end
	return matchers
end

local expect = setmetatable({
	any = anyMatcher,
	anything = function()
		return asymmetric("Anything", function(v)
			return v ~= nil
		end)
	end,
	stringContaining = function(text: string)
		return asymmetric(`StringContaining<{text}>`, function(v)
			return type(v) == "string" and string.find(v, text, 1, true) ~= nil
		end)
	end,
	stringMatching = function(pattern: string)
		return asymmetric(`StringMatching<{pattern}>`, function(v)
			return type(v) == "string" and string.find(v, pattern) ~= nil
		end)
	end,
	objectContaining = function(subset: { [any]: any })
		return asymmetric("ObjectContaining", function(v)
			if type(v) ~= "table" then
				return false
			end
			for key, value in subset do
				if not deepEqual(v[key], value, false, {}) then
					return false
				end
			end
			return true
		end)
	end,
	arrayContaining = function(items: { any })
		return asymmetric("ArrayContaining", function(v)
			if type(v) ~= "table" then
				return false
			end
			for _, item in items do
				local found = false
				for _, value in v do
					if deepEqual(value, item, false, {}) then
						found = true
						break
					end
				end
				if not found then
					return false
				end
			end
			return true
		end)
	end,
}, {
	__call = function(_, actual: any)
		local matchers = buildMatchers(actual, false)
		matchers.never = buildMatchers(actual, true)
		matchers.never_ = matchers.never
		return matchers
	end,
})

Expect.expect = expect

-- Mocks

local function newMock(implementation: ((...any) -> ...any)?): (any, (...any) -> ...any)
	local state = {
		calls = {} :: { any },
		results = {} :: { { type: string, value: any } },
		instances = {} :: { any },
		lastCall = nil :: any,
	}
	local mock: any
	local impl = implementation
	local onceImpls: { (...any) -> ...any } = {}
	local name = "jest.fn()"

	local function invoke(...: any): ...any
		local args = table.pack(...)
		table.insert(state.calls, args)
		state.lastCall = args
		local fn = table.remove(onceImpls, 1) or impl
		if not fn then
			table.insert(state.results, { type = "return", value = nil })
			return nil
		end
		local results = table.pack(pcall(fn, ...))
		if not results[1] then
			table.insert(state.results, { type = "throw", value = results[2] })
			error(results[2], 0)
		end
		table.insert(state.results, { type = "return", value = results[2] })
		return table.unpack(results, 2, results.n)
	end

	local methods = {}
	function methods.mockImplementation(fn)
		impl = fn
		return mock
	end
	function methods.mockImplementationOnce(fn)
		table.insert(onceImpls, fn)
		return mock
	end
	function methods.mockReturnValue(value)
		impl = function()
			return value
		end
		return mock
	end
	function methods.mockReturnValueOnce(value)
		table.insert(onceImpls, function()
			return value
		end)
		return mock
	end
	function methods.mockClear()
		table.clear(state.calls)
		table.clear(state.results)
		table.clear(state.instances)
		state.lastCall = nil
		return mock
	end
	function methods.mockReset()
		methods.mockClear()
		impl = nil
		table.clear(onceImpls)
		return mock
	end
	function methods.mockRestore()
		methods.mockReset()
		if mock._restore then
			mock._restore()
		end
	end
	function methods.getMockName()
		return name
	end
	function methods.mockName(newName)
		name = newName
		return mock
	end
	function methods.getMockImplementation()
		return impl
	end

	mock = setmetatable({ mock = state, _isMockFunction = true, _methods = methods, _invoke = invoke }, MOCK)

	local function forward(...: any): ...any
		return invoke(...)
	end
	mockOfFunction[forward] = mock
	table.insert(allMocks, mock)
	return mock, forward
end

MOCK.__index = function(self: any, key: any): any
	local methods = rawget(self, "_methods")
	local method = methods and methods[key]
	if method then
		return function(...)
			if rawequal((...), self) then
				return method(select(2, ...))
			end
			return method(...)
		end
	end
	return nil
end
MOCK.__call = function(self: any, ...: any): ...any
	local invoke: any = rawget(self, "_invoke")
	return invoke(...)
end

function Expect.fn(implementation: ((...any) -> ...any)?): (any, (...any) -> ...any)
	return newMock(implementation)
end

-- jest-lua keeps one spy per (object, key) even after restoreAllMocks, and a second spyOn hands
-- back the cached mock without reinstalling it. Nevermore specs work around that quirk (see
-- TeleportServiceUtils.spec.lua), so mirror it.
local spies: { [any]: { [any]: any } } = setmetatable({}, { __mode = "k" }) :: any

function Expect.spyOn(object: any, key: any): any
	spies[object] = spies[object] or {}
	local existing = spies[object][key]
	if existing then
		return existing
	end
	local original = object[key]
	if type(original) ~= "function" and not toMock(original) then
		error(`Cannot spy on the {tostring(key)} property because it is not a function`, 2)
	end
	local mock, forward = newMock(original)
	rawset(mock, "_restore", function()
		object[key] = original
	end)
	object[key] = forward
	spies[object][key] = mock
	return mock
end

function Expect.clearAllMocks()
	for _, mock in allMocks do
		mock.mockClear()
	end
end

function Expect.resetAllMocks()
	for _, mock in allMocks do
		mock.mockReset()
	end
end

function Expect.restoreAllMocks()
	for _, mock in allMocks do
		local restore = rawget(mock, "_restore")
		if restore then
			restore()
		end
	end
end

function Expect.isMock(value: any): boolean
	return toMock(value) ~= nil
end

return Expect
