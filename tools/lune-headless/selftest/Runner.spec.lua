--[[
	Self-test for the runner itself. Tests named "[fails] ..." must be reported as failed and every
	other test must pass; selftest/check.luau enforces that.
]]
local require = require(script.Parent.loader).load(script)

local Jest = require("Jest")

local describe = Jest.Globals.describe
local expect = Jest.Globals.expect
local it = Jest.Globals.it
local jest = Jest.Globals.jest
local beforeEach = Jest.Globals.beforeEach
local afterEach = Jest.Globals.afterEach
local beforeAll = Jest.Globals.beforeAll
local afterAll = Jest.Globals.afterAll

describe("async results", function()
	it("[fails] a test that yields and then fails is a failure", function()
		task.wait(0.01)
		error("failed after yielding")
	end)

	it("a test that yields and then passes is a pass", function()
		local waited = task.wait(0.01)
		expect(waited >= 0.01).toBe(true)
	end)

	it("[fails] a test that never finishes times out", function()
		coroutine.yield()
	end, 0.2)

	it("a done-style test waits for done()", function(done)
		task.delay(0.01, function()
			done()
		end)
	end)

	it("[fails] a done-style test fails when done gets an error", function(done)
		task.delay(0.01, function()
			done("bad")
		end)
	end)
end)

describe("hooks are scoped to their block", function()
	local log = {}

	beforeAll(function()
		table.insert(log, "beforeAll")
	end)
	beforeEach(function()
		table.insert(log, "outer beforeEach")
	end)
	afterEach(function()
		table.insert(log, "outer afterEach")
	end)

	it("runs outer hooks only", function()
		expect(log).toEqual({ "beforeAll", "outer beforeEach" })
	end)

	describe("inner", function()
		beforeEach(function()
			table.insert(log, "inner beforeEach")
		end)

		it("runs outer then inner beforeEach", function()
			expect(log[#log - 1]).toBe("outer beforeEach")
			expect(log[#log]).toBe("inner beforeEach")
		end)
	end)

	it("doesn't run the inner hook for a later sibling test", function()
		expect(log[#log]).toBe("outer beforeEach")
		expect(log[#log - 1]).toBe("outer afterEach")
	end)

	afterAll(function()
		expect(log[#log]).toBe("outer afterEach")
	end)
end)

describe("[fails] describe body", function()
	error("describe bodies that throw are reported")
end)

describe("matchers", function()
	it("compares deeply and by identity", function()
		local t = { a = { 1, 2 } }
		expect(t).toEqual({ a = { 1, 2 } })
		expect(t).never.toBe({ a = { 1, 2 } })
		expect(t).toBe(t)
		expect(0 / 0).toBe(0 / 0)
		expect({ x = 1 }).toEqual({ x = expect.any("number") })
		expect(1.005).toBeCloseTo(1, 1)
		expect("hello world").toContain("o w")
		expect({ 1, 2, 3 }).toHaveLength(3)
		expect(nil).toBeNil()
		expect(3).toBeGreaterThan(2)
	end)

	it("matches thrown messages by substring", function()
		expect(function()
			error("Bad thing happened")
		end).toThrow("thing happen")
		expect(function() end).never.toThrow()
	end)

	it("[fails] reports a failed matcher", function()
		expect(1).toBe(2)
	end)

	it("supports jest.fn and spyOn", function()
		local mock, fn = jest.fn(function(x)
			return x * 2
		end)
		expect(fn(2)).toBe(4)
		expect(mock).toHaveBeenCalledTimes(1)
		expect(mock).toHaveBeenCalledWith(2)

		local object = {
			method = function(_self, x)
				return x + 1
			end,
		}
		local spy = jest.spyOn(object, "method")
		expect(object:method(1)).toBe(2)
		expect(spy).toHaveBeenCalled()
		spy.mockReturnValue(10)
		expect(object:method(1)).toBe(10)
	end)
end)

describe("fake timers", function()
	afterEach(function()
		jest.useRealTimers()
	end)

	it("advances task.delay and os.clock", function()
		jest.useFakeTimers()
		local fired = {}
		local start = os.clock()
		task.delay(1, function()
			table.insert(fired, "a")
		end)
		task.delay(0.5, function()
			table.insert(fired, "b")
		end)
		jest.advanceTimersByTime(600)
		expect(fired).toEqual({ "b" })
		expect(os.clock() - start).toBeCloseTo(0.6, 5)
		jest.advanceTimersByTime(600)
		expect(fired).toEqual({ "b", "a" })
	end)

	it("cancels a fake delay", function()
		jest.useFakeTimers()
		local fired = false
		local thread = task.delay(1, function()
			fired = true
		end)
		task.cancel(thread)
		jest.advanceTimersByTime(2000)
		expect(fired).toBe(false)
	end)

	it("resumes a fake task.wait", function()
		jest.useFakeTimers()
		local resumed = nil
		task.spawn(function()
			resumed = task.wait(2)
		end)
		jest.advanceTimersByTime(1000)
		expect(resumed).toBeNil()
		jest.advanceTimersByTime(1000)
		expect(resumed).toBeCloseTo(2, 5)
	end)

	it("[fails] rethrows an error from a timer callback", function()
		jest.useFakeTimers()
		task.delay(1, function()
			error("timer callback failed")
		end)
		jest.advanceTimersByTime(1000)
	end)
end)

describe("stray errors", function()
	it("an error in a spawned thread doesn't fail the test", function()
		task.spawn(function()
			error("stray")
		end)
		expect(true).toBe(true)
	end)
end)

describe("skipping", function()
	it.skip("[skipped] is not run", function()
		error("should not run")
	end)
end)
