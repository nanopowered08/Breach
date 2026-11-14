--!nonstrict
--[==[
	BreachShuffle — randomisation of the physical layout (BreachEngine M11; plan: docs/BreachEngine_M11_Randomisation_Plan.md).

	M11.0 (this file so far): the SURVEY. It reads what a mission declares about shuffling and changes nothing: no behaviour, no moves.
	Pure Luau, no requires, no Roblox APIs.

	    local survey = Shuffle.survey(mission)      -- mission.Nodes is walked (any class, anywhere in the tree)
	    survey.Collections   list of {Id, Path, Class, Name, Attrs, Position, Size}   nodes named "PartCollection" or carrying the attribute PartCollection
	    survey.Targets       the same for nodes named "ShuffleTarget" (or, unnamed, carrying a ShuffleTag)
	    survey.Movers        every OTHER node with a `ShuffleTarget` attribute: something that asks to be moved to a target
	    survey.Folders       Folder/Model nodes with folder-level options (Condition, PickCount, PickSeed, ShuffleContents, ResolvePriority)
	    survey.AttrCounts    { Collection = {attr = n}, Target = {attr = n}, Mover = {attr = n}, Folder = {attr = n} }   which attributes exist, and how often
	    survey.Values        { ShuffleTag = {value = n}, Index, MatchVariable, ResolvePriority, Move, Open, Path, Location, Sound, OnProp, ... }
	    survey.Tags          { [tag] = {Collections, Movers, Targets, Indexes = {index = n}, AskSizes = {"AxBxC" = n}, TargetSizes = {...}} }
	    survey.MoverKinds    { ["Class:Name"] = n }
	    survey.Totals        {Collections, Targets, Movers, Folders}

	What the Blacksite data showed (docs 7.5): every PartCollection carries `ShuffleTarget = <tag>` (the tag it wants, NOT a target itself),
	the tags (`ShuffleTag`) live on the targets, `MatchVariable` is empty on every target and `ResolvePriority` is 2 everywhere.
	    Shuffle.report(survey, maxLines)            -- the survey as lines of text (the adapter prints it)

	M11.1a, the LAYOUT: which target each PartCollection goes to. It only decides; M11.1b (Shuffle.apply, below) moves things.

	    local layout = Shuffle.layout(mission, seed)
	    layout.Placements   list of {Collection, Path, Tag, Target, TargetPath, Index, Steps, Yaw, From, To}  From/To = the collection's centre before and after
	    layout.Unplaced     list of {Collection, Path, Tag, Why}      "no target" | "not enough targets" | "no tag" | "no position"
	    layout.Stats        {Collections, Placed, Unplaced}
	    Shuffle.moved(placement, x, y, z) -> x, y, z       where a point that was inside the collection ends up
	    Shuffle.inside(collection, x, y, z) -> bool        is the point inside the collection volume (a box, turned by its yaw)
	    Shuffle.layoutReport(layout, maxLines)             the layout as text

	Rules, from the Blacksite data [O] and the plan [P]: a collection asks for the tag in its own `ShuffleTarget` attribute; it is given ONE
	target with that tag, never shared (every tag has more targets than collections there); which one comes from the seed (Fisher-Yates over
	the tag's targets, tags in alphabetical order, collections in mission order: same seed, same layout). The collection ends up with its
	FLOOR on the target's floor and its centre above the target's centre (the target is the floor footprint, e.g. 24x12x24 for a 32x28x32
	collection) [P], turned by (target yaw - collection yaw) [P]; a collection with `ShuffleTargetRotation = n` is also turned by a random
	multiple of 360/n degrees [P: the meaning of n]. A collection whose tag has no target, or fewer targets than collections, is left
	unplaced. `CollectionEnabled` (a variable expression) is not evaluated yet; movers are not moved yet.

	What `MatchVariable` and `ResolvePriority` mean is not documented anywhere (see the plan): the survey exists so the real data can say.
]==]

local Random = (function()
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
end)()

local sub, find, match, concat = string.sub, string.find, string.match, table.concat
local char = string.char
local function fail(msg)
	error("BreachShuffle: " .. msg, 0)
end

-- >>> shared JSON (spliced by tools/build.py) <<<
-------------------------------------------------------------------------------
local function jsonDecode(text)
	local pos, n = 1, #text

	local function skip()
		pos = find(text, "[^ \t\r\n]", pos) or (n + 1)
	end
	local function jfail(msg)
		fail("JSON: " .. msg .. " at " .. pos)
	end

	local parseValue

	local function utf8Encode(cp)
		if cp < 0x80 then
			return char(cp)
		elseif cp < 0x800 then
			return char(0xC0 + cp // 64, 0x80 + cp % 64)
		elseif cp < 0x10000 then
			return char(0xE0 + cp // 4096, 0x80 + (cp // 64) % 64, 0x80 + cp % 64)
		end
		return char(0xF0 + cp // 262144, 0x80 + (cp // 4096) % 64, 0x80 + (cp // 64) % 64, 0x80 + cp % 64)
	end

	local SIMPLE = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

	local function parseString()
		pos = pos + 1 -- opening quote
		local parts = {}
		while true do
			local s, e = find(text, '["\\]', pos)
			if not s then
				jfail("unterminated string")
			end
			if s > pos then
				parts[#parts + 1] = sub(text, pos, s - 1)
			end
			if sub(text, s, s) == '"' then
				pos = e + 1
				return concat(parts)
			end
			local esc = sub(text, s + 1, s + 1)
			if esc == "u" then
				local hex = match(text, "^%x%x%x%x", s + 2)
				if not hex then
					jfail("bad \\u escape")
				end
				local cp = tonumber(hex, 16)
				pos = s + 6
				if cp >= 0xD800 and cp <= 0xDBFF then
					local lo = match(text, "^\\u(%x%x%x%x)", pos)
					if lo then
						local l = tonumber(lo, 16)
						if l >= 0xDC00 and l <= 0xDFFF then
							cp = 0x10000 + (cp - 0xD800) * 1024 + (l - 0xDC00)
							pos = pos + 6
						end
					end
				end
				parts[#parts + 1] = utf8Encode(cp)
			else
				local rep = SIMPLE[esc]
				if rep == nil then
					jfail("bad escape \\" .. esc)
				end
				parts[#parts + 1] = rep
				pos = s + 2
			end
		end
	end

	local function parseNumber()
		local s, e = find(text, "^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
		if not s then
			jfail("bad number")
		end
		local v = tonumber(sub(text, s, e))
		if v == nil then
			jfail("bad number")
		end
		pos = e + 1
		return v
	end

	local function parseObject(depth)
		pos = pos + 1
		local obj = {}
		skip()
		if sub(text, pos, pos) == "}" then
			pos = pos + 1
			return obj
		end
		while true do
			skip()
			if sub(text, pos, pos) ~= '"' then
				jfail("expected object key")
			end
			local key = parseString()
			skip()
			if sub(text, pos, pos) ~= ":" then
				jfail("expected ':'")
			end
			pos = pos + 1
			obj[key] = parseValue(depth + 1)
			skip()
			local c = sub(text, pos, pos)
			pos = pos + 1
			if c == "}" then
				return obj
			elseif c ~= "," then
				jfail("expected ',' or '}'")
			end
		end
	end

	local function parseArray(depth)
		pos = pos + 1
		local arr, k = {}, 0
		skip()
		if sub(text, pos, pos) == "]" then
			pos = pos + 1
			return arr
		end
		while true do
			k = k + 1
			arr[k] = parseValue(depth + 1) -- a null leaves a hole, as in most embedders
			skip()
			local c = sub(text, pos, pos)
			pos = pos + 1
			if c == "]" then
				return arr
			elseif c ~= "," then
				jfail("expected ',' or ']'")
			end
		end
	end

	function parseValue(depth)
		if depth > 200 then
			jfail("nesting too deep")
		end
		skip()
		local c = sub(text, pos, pos)
		if c == "{" then
			return parseObject(depth)
		elseif c == "[" then
			return parseArray(depth)
		elseif c == '"' then
			return parseString()
		elseif c == "t" and sub(text, pos, pos + 3) == "true" then
			pos = pos + 4
			return true
		elseif c == "f" and sub(text, pos, pos + 4) == "false" then
			pos = pos + 5
			return false
		elseif c == "n" and sub(text, pos, pos + 3) == "null" then
			pos = pos + 4
			return nil
		elseif c == "-" or find(c, "^%d") then
			return parseNumber()
		end
		jfail("unexpected character '" .. c .. "'")
		return nil
	end

	local v = parseValue(0)
	skip()
	if pos <= n then
		jfail("trailing data")
	end
	return v
end


-- Deterministic JSON encoder: object keys sorted, numbers round-trip exactly (%.17g), arrays = 1..n sequences.
local function jsonEncode(value)
	local parts, n = {}, 0
	local function put(x)
		n = n + 1
		parts[n] = x
	end
	local ESCAPES = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t", ["\b"] = "\\b", ["\f"] = "\\f" }
	local function encString(str)
		put('"')
		put((string.gsub(str, '[%c"\\]', function(c)
			return ESCAPES[c] or string.format("\\u%04x", string.byte(c))
		end)))
		put('"')
	end
	local function enc(v, depth)
		if depth > 200 then
			fail("JSON encode: nesting too deep")
		end
		local t = type(v)
		if t == "string" then
			encString(v)
		elseif t == "number" then
			if v ~= v or v == math.huge or v == -math.huge then
				fail("JSON encode: cannot encode NaN or infinity")
			end
			if v == math.floor(v) and math.abs(v) < 2 ^ 53 then
				put(string.format("%d", v))
			else
				put(string.format("%.17g", v))
			end
		elseif t == "boolean" then
			put(v and "true" or "false")
		elseif t == "table" then
			local len = #v
			local isArray = len > 0 or next(v) == nil
			if isArray then
				for k in pairs(v) do
					if type(k) ~= "number" or k < 1 or k > len or k ~= math.floor(k) then
						isArray = false
						break
					end
				end
			end
			if isArray then
				put("[")
				for i = 1, len do
					if i > 1 then
						put(",")
					end
					enc(v[i], depth + 1)
				end
				put("]")
			else
				local keys = {}
				for k in pairs(v) do
					if type(k) ~= "string" then
						fail("JSON encode: object keys must be strings")
					end
					keys[#keys + 1] = k
				end
				table.sort(keys)
				put("{")
				for i, k in ipairs(keys) do
					if i > 1 then
						put(",")
					end
					encString(k)
					put(":")
					enc(v[k], depth + 1)
				end
				put("}")
			end
		else
			fail("JSON encode: unsupported value type " .. t)
		end
	end
	enc(value, 0)
	return concat(parts)
end

-- <<< END shared JSON <<<

local Shuffle = {}
Shuffle.VERSION = "0.4.0"

local FOLDER_ATTRS = { "Condition", "PickCount", "PickSeed", "ShuffleContents", "ResolvePriority" }
local VALUE_ATTRS = { "ShuffleTag", "Index", "MatchVariable", "ResolvePriority", "ShuffleTargetRotation", "Move", "Open", "Path", "Location", "Sound", "OnProp", "CollectionEnabled", "RemovedVariable", "InstantOpenDoorDetection", "LockOutPlayers" }
local MAX_DISTINCT = 60 -- distinct values kept per attribute; the rest are counted under "(others)"

local function bump(t, key, n)
	t[key] = (t[key] or 0) + (n or 1)
end

-- a stable text for an attribute value (never a table address)
local function show(v)
	local t = type(v)
	if t == "string" then
		return v
	elseif t == "number" or t == "boolean" then
		return tostring(v)
	elseif t == "table" then
		if type(v.X) == "number" and type(v.Y) == "number" and type(v.Z) == "number" then
			return "(" .. tostring(v.X) .. "," .. tostring(v.Y) .. "," .. tostring(v.Z) .. ")"
		end
		return "{" .. tostring(v.Type or "table") .. "}"
	end
	return t
end

local function sizeKey(size)
	if size then
		return tostring(size.X) .. "x" .. tostring(size.Y) .. "x" .. tostring(size.Z)
	end
	return nil
end

local function xyz(v)
	if type(v) == "table" and type(v.X) == "number" then
		return { X = v.X, Y = v.Y or 0, Z = v.Z or 0 }
	end
	return nil
end

-- The heading (rotation about Y) of a part from its EulerXYZ angles. The Y angle alone is wrong for a flipped part: Euler (180, 30, 180) is a
-- heading of 150, not 30. R = Rx * Ry * Rz (CFrame.fromEulerAnglesXYZ); heading = atan2(-right.z, right.x).
local function yawOf(e)
	if type(e) ~= "table" then
		return 0
	end
	local rx, ry, rz = e.X or 0, e.Y or 0, e.Z or 0
	return math.atan2(math.cos(rx) * math.sin(ry) * math.cos(rz) - math.sin(rx) * math.sin(rz), math.cos(ry) * math.cos(rz))
end
Shuffle.yawOf = yawOf

local function describe(node, kind)
	local props = node.Props
	local cf = props and props.CFrame
	return {
		Id = node.Id, Path = node.Path, Class = node.ClassName, Name = node.Name, Kind = kind,
		Attrs = node.Attrs or {},
		Position = xyz(cf and cf.Position), Size = xyz(props and props.Size),
		Yaw = yawOf(cf and cf.EulerXYZ),
	}
end

-- the tag a collection or mover asks for: its `ShuffleTarget` attribute (a string) [O: Blacksite], or a ShuffleTag
local function askedTag(attrs)
	if type(attrs.ShuffleTarget) == "string" and attrs.ShuffleTarget ~= "" then
		return attrs.ShuffleTarget
	end
	if attrs.ShuffleTag ~= nil then
		return show(attrs.ShuffleTag)
	end
	return nil
end

function Shuffle.survey(mission)
	local s = {
		Collections = {}, Targets = {}, Movers = {}, Folders = {},
		AttrCounts = { Collection = {}, Target = {}, Mover = {}, Folder = {} },
		Values = {}, Tags = {}, MoverKinds = {},
		Totals = { Collections = 0, Targets = 0, Movers = 0, Folders = 0 },
		Warnings = {},
	}
	for _, a in ipairs(VALUE_ATTRS) do
		s.Values[a] = {}
	end
	local nodes = type(mission) == "table" and mission.Nodes
	if type(nodes) ~= "table" then
		s.Warnings[#s.Warnings + 1] = "the mission has no node list; nothing surveyed"
		return s
	end

	local distinct = {} -- attribute -> how many distinct values are kept so far
	local function addValues(attrs)
		for _, a in ipairs(VALUE_ATTRS) do
			local v = attrs[a]
			if v ~= nil then
				local bucket, key = s.Values[a], show(v)
				if bucket[key] == nil then
					if (distinct[a] or 0) < MAX_DISTINCT then
						distinct[a] = (distinct[a] or 0) + 1
					else
						key = "(others)"
					end
				end
				bump(bucket, key)
			end
		end
	end
	local function tagEntry(tag)
		local t = s.Tags[tag]
		if not t then
			t = { Collections = 0, Movers = 0, Targets = 0, Indexes = {}, AskSizes = {}, TargetSizes = {} }
			s.Tags[tag] = t
		end
		return t
	end
	for _, node in ipairs(nodes) do
		local attrs = node.Attrs or {}
		local isCollection = node.Name == "PartCollection" or attrs.PartCollection ~= nil
		local isTarget = not isCollection and (node.Name == "ShuffleTarget" or attrs.ShuffleTag ~= nil)
		local isMover = not isCollection and not isTarget and attrs.ShuffleTarget ~= nil
		if isCollection then
			local d = describe(node, "Collection")
			s.Collections[#s.Collections + 1] = d
			s.Totals.Collections += 1
			for k in pairs(attrs) do
				bump(s.AttrCounts.Collection, k)
			end
			addValues(attrs)
			local tag = askedTag(attrs)
			if tag then
				local t = tagEntry(tag)
				t.Collections += 1
				if d.Size then
					bump(t.AskSizes, sizeKey(d.Size))
				end
				if attrs.Index ~= nil then
					bump(t.Indexes, show(attrs.Index))
				end
			end
		elseif isTarget then
			local d = describe(node, "Target")
			s.Targets[#s.Targets + 1] = d
			s.Totals.Targets += 1
			for k in pairs(attrs) do
				bump(s.AttrCounts.Target, k)
			end
			addValues(attrs)
			if attrs.ShuffleTag ~= nil then
				local t = tagEntry(show(attrs.ShuffleTag))
				t.Targets += 1
				if d.Size then
					bump(t.TargetSizes, sizeKey(d.Size))
				end
				if attrs.Index ~= nil then
					bump(t.Indexes, show(attrs.Index))
				end
			end
		elseif isMover then
			s.Movers[#s.Movers + 1] = describe(node, "Mover")
			s.Totals.Movers += 1
			bump(s.MoverKinds, node.ClassName .. ":" .. tostring(node.Name))
			for k in pairs(attrs) do
				bump(s.AttrCounts.Mover, k)
			end
			addValues(attrs)
			local tag = askedTag(attrs)
			if tag then
				tagEntry(tag).Movers += 1
			end
		elseif node.ClassName == "Folder" or node.ClassName == "Model" then
			local found = false
			for _, a in ipairs(FOLDER_ATTRS) do
				if attrs[a] ~= nil then
					found = true
					bump(s.AttrCounts.Folder, a)
				end
			end
			if found then
				s.Folders[#s.Folders + 1] = describe(node, "Folder")
				s.Totals.Folders += 1
			end
		end
	end
	if s.Totals.Collections == 0 and s.Totals.Targets == 0 then
		s.Warnings[#s.Warnings + 1] = "no PartCollection or ShuffleTarget found: the mission has no physical shuffle"
	elseif s.Totals.Collections == 0 or s.Totals.Targets == 0 then
		s.Warnings[#s.Warnings + 1] = ("PartCollection %d, ShuffleTarget %d: one side is missing, nothing can be moved"):format(s.Totals.Collections, s.Totals.Targets)
	end
	-- demand against supply, tag by tag (sorted, so the text is deterministic). Only COLLECTIONS need a target: movers ride along with a collection.
	local names = {}
	for tag in pairs(s.Tags) do
		names[#names + 1] = tag
	end
	table.sort(names)
	for _, tag in ipairs(names) do
		local g = s.Tags[tag]
		if g.Collections > 0 and g.Targets == 0 then
			s.Warnings[#s.Warnings + 1] = ("tag %s is asked for by %d collections but has no target"):format(tag, g.Collections)
		elseif g.Collections > g.Targets then
			s.Warnings[#s.Warnings + 1] = ("tag %s is asked for by %d collections but has only %d targets (are targets reused?)"):format(tag, g.Collections, g.Targets)
		elseif g.Collections == 0 and g.Movers > 0 then
			s.Warnings[#s.Warnings + 1] = ("tag %s has %d movers but no collection to move them with"):format(tag, g.Movers)
		end
	end
	return s
end

-- "name=count" pairs, biggest first (ties by name), at most `limit` of them, then "... +N more"
local function top(map, limit, numericKeys)
	local list = {}
	for k, n in pairs(map) do
		list[#list + 1] = { k = k, n = n }
	end
	table.sort(list, function(a, b)
		if a.n ~= b.n then
			return a.n > b.n
		end
		local an, bn = tonumber(a.k), tonumber(b.k)
		if numericKeys and an and bn and an ~= bn then
			return an < bn
		end
		return a.k < b.k
	end)
	local out = {}
	for i = 1, math.min(#list, limit) do
		out[#out + 1] = list[i].k .. "=" .. list[i].n
	end
	if #list > limit then
		out[#out + 1] = ("... +%d more"):format(#list - limit)
	end
	return table.concat(out, ", "), #list
end

function Shuffle.report(survey, maxLines)
	maxLines = maxLines or 40
	local lines = {}
	local function add(text)
		lines[#lines + 1] = text
	end
	local t = survey.Totals
	add(("%d PartCollection, %d ShuffleTarget, %d movers (other nodes with a ShuffleTarget attribute), %d folders with folder-level options"):format(t.Collections, t.Targets, t.Movers or 0, t.Folders))
	for _, kind in ipairs({ "Collection", "Target", "Mover", "Folder" }) do
		local text, n = top(survey.AttrCounts[kind] or {}, 16)
		if n > 0 then
			add(("%s attributes: %s"):format(kind, text))
		end
	end
	local mk, mn = top(survey.MoverKinds or {}, 8)
	if mn > 0 then
		add(("movers by kind: %s"):format(mk))
	end
	for _, a in ipairs(VALUE_ATTRS) do
		local text, n = top(survey.Values[a], 10, true)
		if n > 0 then
			add(("%s (%d distinct): %s"):format(a, n, text))
		end
	end
	local tags = {}
	for tag in pairs(survey.Tags) do
		tags[#tags + 1] = tag
	end
	table.sort(tags)
	for _, tag in ipairs(tags) do
		local g = survey.Tags[tag]
		local idx = top(g.Indexes, 10, true)
		local ask, tgt = top(g.AskSizes or {}, 2), top(g.TargetSizes or {}, 2)
		local line = ("tag %s: %d collections, %d targets"):format(tag, g.Collections, g.Targets)
		if (g.Movers or 0) > 0 then
			line ..= (", %d movers"):format(g.Movers)
		end
		if idx ~= "" then
			line ..= ", indexes " .. idx
		end
		if ask ~= "" or tgt ~= "" then
			line ..= (", sizes: ask [%s] targets [%s]"):format(ask, tgt)
		end
		add(line)
	end
	for _, w in ipairs(survey.Warnings) do
		add("warning: " .. w)
	end
	if #lines > maxLines then
		local extra = #lines - (maxLines - 1)
		for i = #lines, maxLines, -1 do
			lines[i] = nil
		end
		add(("... (%d more lines)"):format(extra))
	end
	return lines
end

---------------------------------------------------------------------------------------------------------- M11.1a: the layout
local function lastName(path)
	return tostring(path or "?"):match("([^/]+)$") or tostring(path)
end

function Shuffle.layout(mission, seed, opts)
	local survey = Shuffle.survey(mission)
	local rng = Random.new(seed or 0)
	local result = { Seed = seed, Placements = {}, Unplaced = {}, Stats = { Collections = #survey.Collections, Placed = 0, Unplaced = 0 } }

	local targetsBy = {}
	for _, t in ipairs(survey.Targets) do
		if t.Attrs.ShuffleTag ~= nil then
			local tag = show(t.Attrs.ShuffleTag)
			targetsBy[tag] = targetsBy[tag] or {}
			table.insert(targetsBy[tag], t)
		end
	end
	local asks, tags = {}, {}
	local function unplace(c, tag, why)
		result.Unplaced[#result.Unplaced + 1] = { Collection = c.Id, Path = c.Path, Tag = tag, Why = why }
		result.Stats.Unplaced += 1
	end
	for _, c in ipairs(survey.Collections) do
		local tag = askedTag(c.Attrs)
		if not tag then
			unplace(c, nil, "no tag")
		elseif not (c.Position and c.Size) then
			unplace(c, tag, "no position")
		else
			if not asks[tag] then
				asks[tag] = {}
				tags[#tags + 1] = tag
			end
			table.insert(asks[tag], c)
		end
	end
	table.sort(tags)

	for _, tag in ipairs(tags) do
		local targets = {}
		for _, t in ipairs(targetsBy[tag] or {}) do
			if t.Position and t.Size then
				targets[#targets + 1] = t
			end
		end
		for i = #targets, 2, -1 do -- Fisher-Yates: the seed decides which targets are used and in which order
			local j = rng:nextInt(1, i)
			targets[i], targets[j] = targets[j], targets[i]
		end
		for i, c in ipairs(asks[tag]) do
			local t = targets[i]
			if not t then
				unplace(c, tag, #targets == 0 and "no target" or "not enough targets")
			else
				local steps, n = 0, tonumber(c.Attrs.ShuffleTargetRotation)
				if n and n >= 2 and n == math.floor(n) then
					steps = rng:nextInt(0, n - 1)
				end
				local yaw = (t.Yaw or 0) - (c.Yaw or 0)
				if steps > 0 then
					yaw += steps * (2 * math.pi / n)
				end
				local floorY = t.Position.Y - t.Size.Y / 2
				result.Placements[#result.Placements + 1] = {
					Collection = c.Id, Path = c.Path, Tag = tag, Target = t.Id, TargetPath = t.Path, Index = i, Steps = steps, Yaw = yaw,
					From = { X = c.Position.X, Y = c.Position.Y, Z = c.Position.Z },
					To = { X = t.Position.X, Y = floorY + c.Size.Y / 2, Z = t.Position.Z }, -- floor on floor, centre over the target's centre [P]
					Size = { X = c.Size.X, Y = c.Size.Y, Z = c.Size.Z },
				}
				result.Stats.Placed += 1
			end
		end
	end
	return result
end

-- where a point that was inside the collection ends up (rotate about the collection's old centre by Yaw, then move to the new centre)
function Shuffle.moved(placement, x, y, z)
	local dx, dz = x - placement.From.X, z - placement.From.Z
	local c, s = math.cos(placement.Yaw), math.sin(placement.Yaw)
	return placement.To.X + dx * c + dz * s, y - placement.From.Y + placement.To.Y, placement.To.Z - dx * s + dz * c
end

-- is the point inside the collection volume (a box turned by the collection's own yaw)?
function Shuffle.inside(collection, x, y, z)
	if not (collection.Position and collection.Size) then
		return false
	end
	local yaw = collection.Yaw or 0
	local dx, dz = x - collection.Position.X, z - collection.Position.Z
	local c, s = math.cos(-yaw), math.sin(-yaw)
	local lx, lz = dx * c + dz * s, -dx * s + dz * c
	return math.abs(lx) <= collection.Size.X / 2 and math.abs(y - collection.Position.Y) <= collection.Size.Y / 2 and math.abs(lz) <= collection.Size.Z / 2
end

---------------------------------------------------------------------------------------------------------- M11.1b: applying the layout
-- Turn an EulerXYZ rotation (R = Rx * Ry * Rz, Roblox's ToEulerAnglesXYZ convention) by `yaw` about the world Y axis: R' = Ry(yaw) * R.
-- Returns the new rx, ry, rz.
local function turnedEuler(e, yaw)
	local rx, ry, rz = 0, 0, 0
	if type(e) == "table" then
		rx, ry, rz = e.X or 0, e.Y or 0, e.Z or 0
	end
	if yaw == 0 then
		return rx, ry, rz
	end
	local cx, sx, cy, sy, cz, sz = math.cos(rx), math.sin(rx), math.cos(ry), math.sin(ry), math.cos(rz), math.sin(rz)
	local r11, r12, r13 = cy * cz, -cy * sz, sy
	local r22, r23 = cx * cz - sx * sy * sz, -sx * cy
	local r31, r32, r33 = sx * sz - cx * sy * cz, sx * cz + cx * sy * sz, cx * cy
	local c, s = math.cos(yaw), math.sin(yaw)
	local n11, n12, n13 = c * r11 + s * r31, c * r12 + s * r32, c * r13 + s * r33
	local n32, n33 = -s * r12 + c * r32, -s * r13 + c * r33
	local ny = math.asin(math.max(-1, math.min(1, n13)))
	if math.abs(n13) < 0.999999 then
		return math.atan2(-r23, n33), ny, math.atan2(-n12, n11)
	end
	return math.atan2(n32, r22), ny, 0 -- gimbal lock: all of the turn goes into rx
end

Shuffle.turnedEuler = turnedEuler

-- Apply a layout to the mission, IN PLACE, once, before anything reads positions (BreachWorld.build, props, bots, logic markers).
-- Rule [P]: every node whose CENTRE lies inside a placed collection's volume (original position) moves rigidly with that collection:
-- its position goes through Shuffle.moved and its rotation is turned by the placement's Yaw. A collection uses its own placement even if its
-- centre lies in another collection. ShuffleTarget markers stay where they are. A string attribute `Path` that holds a navigation table
-- (`Node`/`Placed` point lists, the Meadow map of a cell or of a mover) is moved too: with its own node's placement when the node has a position
-- inside a collection, else point by point. Returns { Nodes = moved nodes, NavPoints = moved nav points, Collections = placed collections }.
function Shuffle.apply(mission, layout)
	local stats = { Nodes = 0, NavPoints = 0, Collections = 0 }
	if type(mission) ~= "table" or type(mission.Nodes) ~= "table" or type(layout) ~= "table" or #layout.Placements == 0 then
		return stats
	end
	if mission.ShuffleLayout ~= nil then
		return stats -- never twice: a second pass would move everything again
	end
	mission.ShuffleLayout = layout
	local survey = Shuffle.survey(mission)
	local byId = {}
	for _, c in ipairs(survey.Collections) do
		byId[c.Id] = c
	end
	local zones, own, isTarget = {}, {}, {}
	for _, t in ipairs(survey.Targets) do
		isTarget[t.Id] = true
	end
	for _, p in ipairs(layout.Placements) do
		local c = byId[p.Collection]
		if c and c.Position and c.Size then
			local zone = { C = c, P = p }
			zones[#zones + 1] = zone
			own[c.Id] = zone
			stats.Collections += 1
		end
	end
	local function zoneAt(x, y, z)
		for _, zone in ipairs(zones) do
			if Shuffle.inside(zone.C, x, y, z) then
				return zone
			end
		end
		return nil
	end
	local function movePoint(zone, pt)
		if type(pt) == "table" and type(pt[1]) == "number" and type(pt[2]) == "number" and type(pt[3]) == "number" then
			pt[1], pt[2], pt[3] = Shuffle.moved(zone.P, pt[1], pt[2], pt[3])
			stats.NavPoints += 1
		end
	end
	-- decide first (original positions), then mutate: nothing is moved twice, and the order of nodes does not matter
	local jobs = {}
	for _, node in ipairs(mission.Nodes) do
		if not isTarget[node.Id] then
			local props = node.Props
			local cf = props and props.CFrame
			local pos = type(cf) == "table" and cf.Position
			local zone = own[node.Id]
			if not zone and type(pos) == "table" and type(pos.X) == "number" then
				zone = zoneAt(pos.X, pos.Y or 0, pos.Z or 0)
			end
			local raw = node.Attrs and node.Attrs.Path
			local nav
			if type(raw) == "string" and string.sub(raw, 1, 1) == "{" then
				local ok, data = pcall(jsonDecode, raw)
				if ok and type(data) == "table" and (type(data.Node) == "table" or type(data.Placed) == "table") then
					nav = data
				end
			end
			if zone or nav then
				jobs[#jobs + 1] = { node = node, zone = zone, nav = nav }
			end
		end
	end
	for _, job in ipairs(jobs) do
		local node, zone = job.node, job.zone
		if zone then
			local cf = node.Props.CFrame
			local pos = cf.Position
			pos.X, pos.Y, pos.Z = Shuffle.moved(zone.P, pos.X, pos.Y or 0, pos.Z or 0)
			if zone.P.Yaw ~= 0 then
				local rx, ry, rz = turnedEuler(cf.EulerXYZ, zone.P.Yaw)
				cf.EulerXYZ = { X = rx, Y = ry, Z = rz }
			end
			stats.Nodes += 1
		end
		if job.nav then
			local before = stats.NavPoints
			for _, key in ipairs({ "Node", "Placed" }) do
				for _, pt in ipairs(job.nav[key] or {}) do
					local z = zone
					if not z and type(pt) == "table" and type(pt[1]) == "number" then
						z = zoneAt(pt[1], pt[2] or 0, pt[3] or 0)
					end
					if z then
						movePoint(z, pt)
					end
				end
			end
			if stats.NavPoints > before then -- re-written only when something moved: other attributes keep their exact text
				node.Attrs.Path = jsonEncode(job.nav)
			end
		end
	end
	return stats
end

function Shuffle.layoutReport(layout, maxLines)
	maxLines = maxLines or 20
	local lines = {}
	local st = layout.Stats
	lines[#lines + 1] = ("layout (seed %s): %d of %d collections placed on targets, %d unplaced"):format(tostring(layout.Seed), st.Placed, st.Collections, st.Unplaced)
	local why = {}
	for _, u in ipairs(layout.Unplaced) do
		local key = u.Why .. (u.Tag and (": " .. u.Tag) or "")
		why[key] = (why[key] or 0) + 1
	end
	local text, n = top(why, 10)
	if n > 0 then
		lines[#lines + 1] = "unplaced: " .. text
	end
	local turned = 0
	for _, p in ipairs(layout.Placements) do
		if p.Steps > 0 then
			turned += 1
		end
	end
	if turned > 0 then
		lines[#lines + 1] = ("%d collections also turned by a random step (ShuffleTargetRotation)"):format(turned)
	end
	local SAMPLE = 12
	for i, p in ipairs(layout.Placements) do
		if i > SAMPLE then
			lines[#lines + 1] = ("... (%d more placements)"):format(#layout.Placements - SAMPLE)
			break
		end
		lines[#lines + 1] = ("%s #%d: %s -> %s (turned %d degrees)"):format(p.Tag, p.Index, lastName(p.Path), lastName(p.TargetPath), math.floor(math.deg(p.Yaw) % 360 + 0.5))
	end
	if #lines > maxLines then
		local extra = #lines - (maxLines - 1)
		for i = #lines, maxLines, -1 do
			lines[i] = nil
		end
		lines[#lines + 1] = ("... (%d more lines)"):format(extra)
	end
	return lines
end

return Shuffle
