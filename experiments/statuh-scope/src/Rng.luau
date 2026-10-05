--!strict
--[[
	A small seeded PRNG (xorshift32), so randomized tests replay exactly from a printed seed on any
	machine. Not for anything that needs good randomness.
]]

local Rng = {}
Rng.__index = Rng

export type Rng = typeof(setmetatable({} :: { state: number, seed: number }, Rng))

function Rng.new(seed: number): Rng
	local state = bit32.band(seed * 2654435761 + 1, 0xFFFFFFFF)
	if state == 0 then
		state = 0x9E3779B9
	end
	return setmetatable({ state = state, seed = seed }, Rng)
end

function Rng.nextU32(self: Rng): number
	local x = self.state
	x = bit32.bxor(x, bit32.lshift(x, 13))
	x = bit32.bxor(x, bit32.rshift(x, 17))
	x = bit32.bxor(x, bit32.lshift(x, 5))
	self.state = x
	return x
end

-- Integer in [min, max].
function Rng.int(self: Rng, min: number, max: number): number
	return min + (self:nextU32() % (max - min + 1))
end

-- True with probability p.
function Rng.chance(self: Rng, p: number): boolean
	return self:nextU32() / 4294967296 < p
end

function Rng.pick<T>(self: Rng, list: { T }): T?
	if #list == 0 then
		return nil
	end
	return list[self:int(1, #list)]
end

return Rng
