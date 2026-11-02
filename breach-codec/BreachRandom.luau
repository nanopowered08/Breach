--!nonstrict
--[[
	BreachRandom — the one place BreachEngine makes seeded decisions (main doc §7.5).

	Pure Luau, no requires. Only 32-bit integer arithmetic, so the same seed gives the same numbers on every host
	(desktop Luau, Roblox, an embedded C++ runtime). It does NOT reproduce Entry Point's own random numbers —
	nobody outside the game knows that algorithm — it only guarantees that a (mission seed, caller seed) pair
	always yields the same answer.

	    Random.derive(missionSeed, callerSeed, min, max)   -- stateless: integer in [min, max], used by the `RNG` expression
	    local r = Random.new(seed)                          -- stream, for shuffles etc. (later milestones)
	    r:nextFloat()  r:nextInt(min, max)
]]

local Random = {}

local TWO32 = 4294967296

-- 32-bit multiply without losing precision (doubles hold 2^53 exactly; a*b would not).
local function mul32(a, b)
	local ah = a // 65536
	local al = a % 65536
	return (((ah * b) % 65536) * 65536 + al * b) % TWO32
end

-- murmur3 finaliser: every input bit affects every output bit.
local function mix(h)
	h = bit32.bxor(h, bit32.rshift(h, 16))
	h = mul32(h, 0x85EBCA6B)
	h = bit32.bxor(h, bit32.rshift(h, 13))
	h = mul32(h, 0xC2B2AE35)
	h = bit32.bxor(h, bit32.rshift(h, 16))
	return h
end

-- Any seed -> uint32. Numbers: floor, wrap (negatives fine). Strings: FNV-1a. Anything else: 0.
local function toSeed(x)
	if type(x) == "number" then
		if x ~= x or x == math.huge or x == -math.huge then
			return 0
		end
		return math.floor(x) % TWO32
	elseif type(x) == "string" then
		local h = 2166136261
		for i = 1, #x do
			h = mul32(bit32.bxor(h, string.byte(x, i)), 16777619)
		end
		return h
	end
	return 0
end
Random.toSeed = toSeed

-- Uniform float in [0, 1) from a uint32.
local function unit(h)
	return h / TWO32
end

local function intIn(u, min, max)
	min, max = math.floor(min), math.floor(max)
	if max < min then
		min, max = max, min
	end
	return min + math.floor(u * (max - min + 1))
end

function Random.derive(missionSeed, callerSeed, min, max)
	local h = mix((mul32(mix(toSeed(missionSeed)), 0x01000193) + mix((toSeed(callerSeed) + 0x9E3779B9) % TWO32)) % TWO32)
	return intIn(unit(h), min, max)
end

local Stream = {}
Stream.__index = Stream

function Random.new(seed)
	return setmetatable({ State = toSeed(seed) }, Stream)
end

function Stream:nextU32()
	self.State = (self.State + 0x9E3779B9) % TWO32
	return mix(self.State)
end

function Stream:nextFloat()
	return unit(self:nextU32())
end

function Stream:nextInt(min, max)
	return intIn(self:nextFloat(), min, max)
end

return Random
