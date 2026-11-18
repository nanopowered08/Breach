--!nonstrict
--[[
	BreachEncode: the mission-code ENCODER (BreachEngine M12, first half: encode to an InfiltrationEngine code).
	Pure Luau, no Roblox APIs, no requires, deterministic. The mirror of BreachCodec's decoder (docs section 4 and Appendix B):
	an instance tree (what Codec.decode returns in mission.Root: { ClassName, Name, Props, Attrs, Children }) goes in, one or more
	code pieces come out, and Codec.decode(pieces, host) reads them back.

	    local pieces, info = Encode.encode(mission, { MapId = 1234 })        -- mission = Codec.decode result, or a bare root node
	    local code = pieces[1]                                               -- "d:..." style text: version, map id, piece n/total, payload
	    Encode.encodeString(mission)                                         -- one string (errors if it needs several pieces)

	opts: Version (2 default, Zstd+Base64; 1 = plain symbols), MapId (0..5183, default 0), MaxPieceLength (payload characters per
	piece; default: one piece), Comment (text written between "!!!" markers before the first piece).

	What is [verified] and what is not: decode(encode(tree)) equals the tree up to the format's own precision (floats keep 1/5183 of
	their fractional part, colours and transparencies are 1/5183 steps, rotations are three Euler angles), and encode(decode(encode(t)))
	== encode(t) exactly (a fixed point), both tested. The compressed layer is a standards-compliant Zstd frame made of STORED blocks
	(no compression, 128 KiB window), which every Zstd decoder reads; a real game import of an encoded code has NOT been tried.
	Attribute number types are not kept by the decoded tree, so a whole number >= 0 is written as Int (or LongInt above 72^4), a
	negative whole number as SignedInt and everything else as Float; the values read back the same.
]]
local Encode = {}
Encode.VERSION = "0.1.0"

local byte, sub, char, gsub, concat = string.byte, string.sub, string.char, string.gsub, table.concat
local floor = math.floor

--@@TABLES@@

local function fail(msg)
	error("BreachEncode: " .. msg, 0)
end

local ALPHABET = "bcdfghjkmpqrtvwxy346789!\"#$%&'()*+,-./:;<=>?@BCDFGHJKMPQRTVWXY[\\]^_`{|}~"
local BASE = 72
local DIGIT = {}
for i = 1, #ALPHABET do
	DIGIT[i - 1] = sub(ALPHABET, i, i)
end
local MAX2 = BASE ^ 2 - 1 -- 5183
local MAX3 = BASE ^ 3 - 1 -- 373247
local SIGNED_BIAS = floor(MAX3 / 2) -- 186623
local TWO_PI = math.pi * 2

-- reverse tables
local ID_BY_TYPE = {}
for id, name in pairs(TYPE_BY_ID) do
	ID_BY_TYPE[name] = id
end
local ATTR_ID = {}
for id, name in pairs(ATTR_BY_ID) do
	ATTR_ID[name] = id
end
local ENUM_VALUE = {}
for enumName, byValue in pairs(ENUMS) do
	local rev = {}
	for v, name in pairs(byValue) do
		rev[name] = v
	end
	ENUM_VALUE[enumName] = rev
end

-------------------------------------------------------------------------------
-- Writer
-------------------------------------------------------------------------------
local function newWriter()
	return { n = 0, buf = {} }
end

local function put(w, s)
	local n = w.n + 1
	w.n = n
	w.buf[n] = s
end

local function putNum(w, v, width)
	if v ~= floor(v) or v < 0 or v >= BASE ^ width then
		fail("value " .. tostring(v) .. " does not fit in " .. width .. " symbols")
	end
	local digits = {}
	for i = width, 1, -1 do
		local d = v % BASE
		digits[i] = DIGIT[d]
		v = (v - d) / BASE
	end
	put(w, concat(digits))
end

local function round(x)
	return floor(x + 0.5)
end

local function putBool(w, v)
	putNum(w, v and 0 or 1, 1) -- the format writes true as 0 and false as 1
end

local function putSigned(w, v)
	putNum(w, v + SIGNED_BIAS, 3)
end

local function putFloat(w, v)
	if type(v) ~= "number" or v ~= v then
		fail("a Float must be a number, got " .. tostring(v))
	end
	local before = floor(v)
	local k = round((v - before) * MAX2)
	if k > MAX2 then
		k = MAX2
	end
	if before < -SIGNED_BIAS or before > SIGNED_BIAS + 1 then
		fail("Float " .. tostring(v) .. " is outside the representable range (about +-186,623)")
	end
	putSigned(w, before)
	putNum(w, k, 2)
end

local function clamp01(v)
	if v ~= v then
		fail("a bounded value must be a number")
	end
	return v < 0 and 0 or (v > 1 and 1 or v)
end

local function putBounded(w, v)
	putNum(w, round(clamp01(v) * MAX3), 3)
end

local function putShortBounded(w, v)
	putNum(w, round(clamp01(v) * MAX2), 2)
end

local function putAngle(w, a) -- an Euler angle in radians, stored as 0..1 over [-pi, pi]
	a = (a + math.pi) % TWO_PI
	putBounded(w, a / TWO_PI)
end

-- strings are length-prefixed (4 symbols) with &-escapes (version >= 1): & -> &&, newline -> &n, CR -> &r, tab -> &t
local ESCAPE = { ["&"] = "&&", ["\n"] = "&n", ["\r"] = "&r", ["\t"] = "&t" }
local function escapeString(s)
	return (gsub(s, "[&\n\r\t]", ESCAPE))
end

local function putString(w, s, escapes)
	if type(s) ~= "string" then
		fail("a String must be a string, got " .. type(s))
	end
	if escapes then
		s = escapeString(s)
	end
	putNum(w, #s, 4)
	put(w, s)
end

-------------------------------------------------------------------------------
-- Value writers (by property value type name), the mirror of the decoder's READ
-------------------------------------------------------------------------------
local function need(v, name, ...)
	if type(v) ~= "table" then
		fail(name .. " must be a table")
	end
	local out = {}
	for i = 1, select("#", ...) do
		local key = select(i, ...)
		local x = v[key]
		if type(x) ~= "number" then
			fail(name .. "." .. key .. " must be a number")
		end
		out[i] = x
	end
	return table.unpack(out)
end

local function putVector2(w, v)
	local x, y = need(v, "Vector2", "X", "Y")
	putFloat(w, x)
	putFloat(w, y)
end

local function putVector3(w, v)
	local x, y, z = need(v, "Vector3", "X", "Y", "Z")
	putFloat(w, x)
	putFloat(w, y)
	putFloat(w, z)
end

local function putUDim(w, v)
	local s, o = need(v, "UDim", "Scale", "Offset")
	putFloat(w, s)
	putFloat(w, o)
end

local function putSequenceCount(w, t)
	if type(t) ~= "table" then
		fail("a sequence must be a table")
	end
	putNum(w, #t, 2)
end

local WRITE = {
	ShortestInt = function(w, v) putNum(w, v, 1) end,
	ShortInt = function(w, v) putNum(w, v, 2) end,
	Int = function(w, v) putNum(w, v, 4) end,
	LongInt = function(w, v) putNum(w, v, 6) end,
	SignedInt = function(w, v) putSigned(w, v) end,
	Float = putFloat,
	BoundedFloat = putBounded,
	ShortBoundedFloat = putShortBounded,
	Vector2 = putVector2,
	Vector3 = putVector3,
	UDim = putUDim,
	UDim2 = function(w, v)
		if type(v) ~= "table" then
			fail("UDim2 must be a table")
		end
		putUDim(w, v.X)
		putUDim(w, v.Y)
	end,
	FloatRange = function(w, v)
		local a, b = need(v, "FloatRange", "Min", "Max")
		putFloat(w, a)
		putFloat(w, b)
	end,
	FloatSequence = function(w, seq)
		putSequenceCount(w, seq)
		for _, k in ipairs(seq) do
			local t, val, env = need(k, "FloatSequence keypoint", "Time", "Value", "Envelope")
			putShortBounded(w, t)
			putFloat(w, val)
			putFloat(w, env)
		end
	end,
	ColorSequence = function(w, seq)
		putSequenceCount(w, seq)
		for _, k in ipairs(seq) do
			local t = need(k, "ColorSequence keypoint", "Time")
			local r, g, b = need(k.Color, "ColorSequence colour", "R", "G", "B")
			putShortBounded(w, t)
			putShortBounded(w, r)
			putShortBounded(w, g)
			putShortBounded(w, b)
		end
	end,
	CFrame = function(w, v)
		if type(v) ~= "table" then
			fail("CFrame must be a table")
		end
		local x, y, z = need(v.Position, "CFrame.Position", "X", "Y", "Z")
		local rx, ry, rz = 0, 0, 0
		if v.EulerXYZ ~= nil then
			rx, ry, rz = need(v.EulerXYZ, "CFrame.EulerXYZ", "X", "Y", "Z")
		end
		putFloat(w, x)
		putFloat(w, y)
		putFloat(w, z)
		putAngle(w, rx)
		putAngle(w, ry)
		putAngle(w, rz)
	end,
}

-------------------------------------------------------------------------------
-- One encoding run: interning maps + the instance tree
-------------------------------------------------------------------------------
local function newRun(escapes)
	return {
		escapes = escapes,
		strings = {}, stringIndex = {}, -- 1-based, first use order
		colors = {}, colorIndex = {},
		warnings = {},
	}
end

local function internString(run, s)
	if type(s) ~= "string" then
		fail("expected a string, got " .. type(s))
	end
	local i = run.stringIndex[s]
	if i == nil then
		i = #run.strings + 1
		run.strings[i] = s
		run.stringIndex[s] = i
	end
	return i
end

local function internColor(run, c)
	local r, g, b = need(c, "Color3", "R", "G", "B")
	local kr, kg, kb = round(clamp01(r) * MAX2), round(clamp01(g) * MAX2), round(clamp01(b) * MAX2)
	local key = kr .. "," .. kg .. "," .. kb
	local i = run.colorIndex[key]
	if i == nil then
		i = #run.colors + 1
		run.colors[i] = { kr, kg, kb }
		run.colorIndex[key] = i
	end
	return i
end

local function putValue(run, w, vtype, value, where)
	if vtype == "String" then
		putNum(w, internString(run, value), 2)
	elseif vtype == "Color3" then
		putNum(w, internColor(run, value), 2)
	elseif vtype == "Bool" then
		if type(value) ~= "boolean" then
			fail(where .. " must be a boolean")
		end
		putBool(w, value)
	elseif vtype == "InstanceReference" then
		if type(value) ~= "table" or type(value.Ref) ~= "string" then
			fail(where .. " must be { Ref = string }")
		end
		putString(w, value.Ref, run.escapes)
	elseif ENUM_VALUE[vtype] then
		local n = ENUM_VALUE[vtype][value]
		if n == nil then
			fail(where .. ": '" .. tostring(value) .. "' is not a valid " .. vtype)
		end
		putNum(w, n, 1)
	else
		local wr = WRITE[vtype]
		if wr == nil then
			fail("no writer for value type " .. tostring(vtype))
		end
		wr(w, value)
	end
end

-- attribute type chosen from the Lua value (the decoded tree does not keep the wire type)
local function attrType(value, name)
	local t = type(value)
	if t == "boolean" then
		return "Bool"
	elseif t == "string" then
		return "String"
	elseif t == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			fail("attribute '" .. name .. "' is not a finite number")
		end
		if value == floor(value) then
			if value >= 0 and value < BASE ^ 4 then
				return "Int"
			elseif value >= 0 and value < BASE ^ 6 then
				return "LongInt"
			elseif value < 0 and value >= -SIGNED_BIAS then
				return "SignedInt"
			end
		end
		return "Float"
	elseif t == "table" then
		if value.Position ~= nil then
			return "CFrame"
		elseif value.R ~= nil then
			return "Color3"
		elseif value.X ~= nil then
			return "Vector3"
		end
	end
	fail("attribute '" .. name .. "' has a value the format cannot store (" .. t .. ")")
	return nil
end

local function writeInstance(run, w, node, depth, path)
	if type(node) ~= "table" or type(node.ClassName) ~= "string" then
		fail("an instance needs a ClassName (at " .. path .. ")")
	end
	if depth > 512 then
		fail("instance tree deeper than 512 (at " .. path .. ")")
	end
	local className = node.ClassName
	local typeName = className
	local typeId = ID_BY_TYPE[typeName]
	if typeId == nil or typeId == 1 then
		fail("class '" .. className .. "' is not a class the format can store (at " .. path .. ")")
	end
	local plist = PROPS[typeName]
	putNum(w, typeId, 1)
	local here = path .. "/" .. tostring(node.Name)

	-- properties: (propId value)* then 0. Name only when it differs from the class default.
	local props = node.Props or {}
	for pid, entry in ipairs(plist) do
		local pname, ptype = entry[1], entry[2]
		local value
		if pname == "Name" then
			if node.Name ~= nil and node.Name ~= DEFAULT_NAME[typeName] then
				value = node.Name
			end
		else
			value = props[pname]
			if typeName == "BoolValue" and pname == "Value" and value == false then
				value = nil -- the decoder starts a BoolValue at false
			elseif typeName == "StringValue" and pname == "Value" and value == "" then
				value = nil -- and a StringValue at ""
			end
		end
		if value ~= nil then
			putNum(w, pid, 1)
			putValue(run, w, ptype, value, here .. "." .. pname)
		end
	end
	for pname in pairs(props) do
		local known = false
		for _, entry in ipairs(plist) do
			if entry[1] == pname then
				known = true
				break
			end
		end
		if not known then
			run.warnings[#run.warnings + 1] = here .. ": property '" .. tostring(pname) .. "' is not part of the format and was not written"
		end
	end
	putNum(w, 0, 1)

	-- attributes: (attrTypeId nameIdx value)* then 0, only for some classes
	if HAS_ATTRS[typeName] then
		local names = {}
		for k in pairs(node.Attrs or {}) do
			names[#names + 1] = k
		end
		table.sort(names)
		for _, name in ipairs(names) do
			local value = node.Attrs[name]
			local at = attrType(value, name)
			putNum(w, ATTR_ID[at], 1)
			putNum(w, internString(run, name), 2)
			putValue(run, w, at, value, here .. "[" .. name .. "]")
		end
		putNum(w, 0, 1)
	elseif node.Attrs ~= nil and next(node.Attrs) ~= nil then
		run.warnings[#run.warnings + 1] = here .. ": a " .. className .. " cannot carry attributes; they were not written"
	end

	-- children until 0
	for _, child in ipairs(node.Children or {}) do
		writeInstance(run, w, child, depth + 1, here)
	end
	putNum(w, 0, 1)
end

-- the symbol stream: colour map, string map, instance tree
function Encode.encodeStream(root, version)
	local run = newRun((version or 2) >= 1)
	local body = newWriter()
	writeInstance(run, body, root, 1, "")
	local out = newWriter()
	putNum(out, #run.colors, 2)
	for _, c in ipairs(run.colors) do
		putNum(out, c[1], 2)
		putNum(out, c[2], 2)
		putNum(out, c[3], 2)
	end
	putNum(out, #run.strings, 2)
	for _, s in ipairs(run.strings) do
		putString(out, s, run.escapes)
	end
	put(out, concat(body.buf, "", 1, body.n))
	return concat(out.buf, "", 1, out.n), run.warnings
end

-------------------------------------------------------------------------------
-- Zstd (stored blocks) and Base64
-------------------------------------------------------------------------------
-- A valid Zstd frame with no compression: magic, descriptor 0 (no checksum, no dictionary, content size unknown),
-- window descriptor 0x38 (128 KiB), then raw blocks of at most 128 KiB, the last one flagged.
function Encode.zstdStore(data)
	local out = { "\40\181\47\253", "\0", "\56" }
	local n, pos = #data, 1
	if n == 0 then
		out[#out + 1] = "\1\0\0"
	end
	while pos <= n do
		local len = math.min(131072, n - pos + 1)
		local last = (pos + len > n) and 1 or 0
		local h = len * 8 + last -- block type 0 = Raw
		out[#out + 1] = char(h % 256, floor(h / 256) % 256, floor(h / 65536) % 256)
		out[#out + 1] = sub(data, pos, pos + len - 1)
		pos = pos + len
	end
	return concat(out)
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
function Encode.base64Encode(data)
	local out, k = {}, 0
	for i = 1, #data, 3 do
		local a, b, c = byte(data, i, i + 2)
		local n = a * 65536 + (b or 0) * 256 + (c or 0)
		local c1, c2, c3, c4 = floor(n / 262144) % 64, floor(n / 4096) % 64, floor(n / 64) % 64, n % 64
		k = k + 1
		out[k] = sub(B64, c1 + 1, c1 + 1) .. sub(B64, c2 + 1, c2 + 1)
			.. (b and sub(B64, c3 + 1, c3 + 1) or "=") .. (c and sub(B64, c4 + 1, c4 + 1) or "=")
	end
	return concat(out)
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------
local function encode(mission, opts)
	opts = opts or {}
	local root = mission
	if type(mission) == "table" and mission.Root ~= nil then
		root = mission.Root
	end
	local version = opts.Version or 2
	if version ~= 1 and version ~= 2 then
		fail("this encoder writes code versions 1 and 2 (got " .. tostring(version) .. ")")
	end
	local mapId = opts.MapId or (type(mission) == "table" and mission.MapId) or 0
	if type(mapId) ~= "number" or mapId ~= floor(mapId) or mapId < 0 or mapId > MAX2 then
		fail("MapId must be a whole number 0..5183")
	end
	local raw, warnings = Encode.encodeStream(root, version)
	local payload = raw
	if version == 2 then
		payload = Encode.base64Encode(Encode.zstdStore(raw))
	end
	local per = opts.MaxPieceLength
	local chunks = {}
	if per == nil or #payload <= per then
		chunks[1] = payload
	else
		if type(per) ~= "number" or per < 1 then
			fail("MaxPieceLength must be a positive number")
		end
		for i = 1, #payload, per do
			chunks[#chunks + 1] = sub(payload, i, i + per - 1)
		end
	end
	local total = #chunks
	if total > MAX2 then
		fail("more than 5183 pieces")
	end
	local pieces = {}
	for i, chunk in ipairs(chunks) do
		local h = newWriter()
		putNum(h, version, 1)
		putNum(h, mapId, 2)
		putNum(h, i, 2)
		putNum(h, total, 2)
		local text = concat(h.buf, "", 1, h.n) .. chunk
		if i == 1 and opts.Comment ~= nil then
			text = "!!!" .. tostring(opts.Comment) .. "!!!" .. text
		end
		pieces[i] = text
	end
	return pieces, { Warnings = warnings, RawSymbols = #raw, PayloadLength = #payload, Version = version, MapId = mapId }
end

function Encode.encode(mission, opts)
	local ok, a, b = pcall(encode, mission, opts)
	if ok then
		return a, b
	end
	return nil, a
end

function Encode.encodeString(mission, opts)
	local pieces, info = Encode.encode(mission, opts)
	if pieces == nil then
		return nil, info
	end
	if #pieces ~= 1 then
		return nil, "BreachEncode: the code needs " .. #pieces .. " pieces; use Encode.encode"
	end
	return pieces[1], info
end

return Encode
