--!nonstrict
--[[
	BreachCodec — portable decoder for InfiltrationEngine-style mission codes
	(code versions 0, 1 and 2). Part of BreachEngine, milestone M1.

	PORTABILITY CONTRACT
	  * Pure Luau. No Roblox APIs, no `require`, no globals besides the standard
	    Luau libraries (string, table, math). One file; embed it anywhere.
	  * It never touches the network, the filesystem or the clock.
	  * Version-2 codes are Zstd-compressed. Zstd is NOT implemented here; the
	    host supplies `host.zstdDecompress(bytes: string) -> string`
	    (Roblox: EncodingService; C++: libzstd bound into Luau; or a pure-Luau
	    decoder module). Versions 0 and 1 need nothing from the host.
	  * Output is plain tables (see "Output shapes"), never engine objects.

	Written from BreachEngine_Documentation.md section 4 (the wire-format spec).
	It contains no code from the SerializationTools plugin.

	PUBLIC API
	  Codec.decode(input, host?)        -> mission | nil, err
	  Codec.decodeStream(raw, version?) -> mission | nil, err   (already-decompressed stream)
	  Codec.assemble(pieces)            -> {Version, MapId, Total, Payload} | nil, err
	  Codec.parsePiece(text)            -> {Version, MapId, Current, Total, Payload} | nil, err
	  Codec.normalizeGistUrl(url)       -> rawUrl | nil, err
	  Codec.resolveRef(root, path)      -> node | nil
	  Codec.base64Decode(str)           -> string | nil, err
	  Codec.jsonDecode(str)             -> value | nil, err
	  Codec.jsonEncode(value)           -> string | nil, err   (deterministic: sorted keys, exact numbers)

	  `input` is a string (one piece, or a gist's raw text) or an array of strings (pieces).
	  `host` (all optional): { zstdDecompress, base64Decode, jsonDecode, maxDepth, maxRawSize }

	OUTPUT SHAPES
	  mission = {
	    Version, MapId,            -- from the header (nil for decodeStream)
	    Root,                      -- node (usually named "DebugMission")
	    Setup,                     -- decoded TableMissionSetup JSON (Colors converted to {R,G,B}) or nil
	    SetupSource,               -- MissionSetup source text, or nil
	    SetupModules,              -- { [moduleName] = source } from StringMissionSetup children
	    Settings,                  -- { [childName] = value } from CustomMissionSettings, or nil
	    Warnings,                  -- array of strings
	  }
	  node  = { ClassName, Name, Props = {}, Attrs = {}, Children = {}, Parent? }
	  Props only hold properties that were WRITTEN (differ from the engine default),
	  except Name (always filled), and Value for BoolValue/StringValue.
	  Value shapes:  Vector2 {X,Y}   Vector3 {X,Y,Z}   Color3 {R,G,B}   UDim {Scale,Offset}
	    UDim2 {X=UDim,Y=UDim}   NumberRange {Min,Max}
	    CFrame {Position={X,Y,Z}, EulerXYZ={X,Y,Z}}   -- radians, Roblox ToEulerAnglesXYZ convention
	    NumberSequence {{Time,Value,Envelope},...}   ColorSequence {{Time,Color={R,G,B}},...}
	    Enums -> their string name ("Plastic", "Block", ...)
	    InstanceReference -> {Ref = "3.12.2"}  (resolve with Codec.resolveRef)
]]

local Codec = {}
Codec.VERSION = "0.1.0"

local byte, sub, char, gsub, find, match, concat =
	string.byte, string.sub, string.char, string.gsub, string.find, string.match, table.concat

-------------------------------------------------------------------------------
-- Generated data tables (type ids, property tables, enums). See tools/gen_tables.py
-------------------------------------------------------------------------------
--@@TABLES@@

-------------------------------------------------------------------------------
-- Errors: internal code throws strings; public functions pcall and return nil, err
-------------------------------------------------------------------------------
local function fail(msg)
	error("BreachCodec: " .. msg, 0)
end

-------------------------------------------------------------------------------
-- Alphabet and reader
-------------------------------------------------------------------------------
local ALPHABET = "bcdfghjkmpqrtvwxy346789!\"#$%&'()*+,-./:;<=>?@BCDFGHJKMPQRTVWXY[\\]^_`{|}~"
local BASE = 72
local VAL = {} -- byte -> 0..71
for i = 1, #ALPHABET do
	VAL[byte(ALPHABET, i)] = i - 1
end

local MAX2 = BASE ^ 2 - 1 -- 5183
local MAX3 = BASE ^ 3 - 1 -- 373247
local SIGNED_BIAS = math.floor(MAX3 / 2) -- 186623
local TWO_PI = math.pi * 2

local DEFAULT_MAX_DEPTH = 512
local DEFAULT_MAX_RAW = 512 * 1024 * 1024

local function newReader(s, version, maxDepth)
	return { s = s, p = 1, n = #s, escapes = (version or 2) >= 1, maxDepth = maxDepth or DEFAULT_MAX_DEPTH }
end

local function num(r, w)
	local p = r.p
	if p + w - 1 > r.n then
		fail("unexpected end of data at symbol " .. p)
	end
	local s, t = r.s, 0
	for i = p, p + w - 1 do
		local v = VAL[byte(s, i)]
		if v == nil then
			fail("invalid symbol at " .. i)
		end
		t = t * BASE + v
	end
	r.p = p + w
	return t
end

local function readBool(r)
	local c = num(r, 1)
	if c == 0 then
		return true
	elseif c == 1 then
		return false
	end
	fail("invalid Bool symbol at " .. (r.p - 1))
	return false
end

local function readSigned(r)
	return num(r, 3) - SIGNED_BIAS
end

local function readFloat(r)
	local before = readSigned(r)
	return before + num(r, 2) / MAX2
end

local function readBounded(r) -- 3 symbols, 0..1
	return num(r, 3) / MAX3
end

local function readShortBounded(r) -- 2 symbols, 0..1
	return num(r, 2) / MAX2
end

local ESC = { n = "\n", r = "\r", t = "\t" }
local function unescapeOne(c)
	return ESC[c] or "&"
end

local function readString(r)
	local len = num(r, 4)
	local p = r.p
	if p + len - 1 > r.n then
		fail("string length " .. len .. " runs past end of data")
	end
	r.p = p + len
	local v = sub(r.s, p, p + len - 1)
	if r.escapes then
		v = gsub(v, "&(.)", unescapeOne)
	end
	return v
end

-------------------------------------------------------------------------------
-- Value readers (by property value type name)
-------------------------------------------------------------------------------
local function readVector2(r)
	local x = readFloat(r)
	return { X = x, Y = readFloat(r) }
end

local function readVector3(r)
	local x = readFloat(r)
	local y = readFloat(r)
	return { X = x, Y = y, Z = readFloat(r) }
end

local function readUDim(r)
	local s = readFloat(r)
	return { Scale = s, Offset = readFloat(r) }
end

local function readSequenceCount(r)
	local k = num(r, 2)
	-- every keypoint is at least 7 symbols; reject absurd counts before looping
	if k * 7 > r.n - r.p + 1 then
		fail("sequence keypoint count " .. k .. " runs past end of data")
	end
	return k
end

local READ = {
	Bool = readBool,
	ShortestInt = function(r) return num(r, 1) end,
	ShortInt = function(r) return num(r, 2) end,
	Int = function(r) return num(r, 4) end,
	LongInt = function(r) return num(r, 6) end,
	SignedInt = readSigned,
	Float = readFloat,
	BoundedFloat = readBounded,
	ShortBoundedFloat = readShortBounded,
	Vector2 = readVector2,
	Vector3 = readVector3,
	UDim = readUDim,
	UDim2 = function(r)
		local x = readUDim(r)
		return { X = x, Y = readUDim(r) }
	end,
	FloatRange = function(r)
		local a = readFloat(r)
		return { Min = a, Max = readFloat(r) }
	end,
	FloatSequence = function(r)
		local k = readSequenceCount(r)
		local out = {}
		for i = 1, k do
			local t = readShortBounded(r)
			local v = readFloat(r)
			out[i] = { Time = t, Value = v, Envelope = readFloat(r) }
		end
		return out
	end,
	ColorSequence = function(r)
		local k = readSequenceCount(r)
		local out = {}
		for i = 1, k do
			local t = readShortBounded(r)
			local R = readShortBounded(r)
			local G = readShortBounded(r)
			out[i] = { Time = t, Color = { R = R, G = G, B = readShortBounded(r) } }
		end
		return out
	end,
	CFrame = function(r)
		local x = readFloat(r)
		local y = readFloat(r)
		local z = readFloat(r)
		local rx = readBounded(r) * TWO_PI - math.pi
		local ry = readBounded(r) * TWO_PI - math.pi
		local rz = readBounded(r) * TWO_PI - math.pi
		return { Position = { X = x, Y = y, Z = z }, EulerXYZ = { X = rx, Y = ry, Z = rz } }
	end,
	InstanceReference = function(r)
		return { Ref = readString(r) }
	end,
}

-- enum readers: one symbol -> name
for enumName, byValue in pairs(ENUMS) do
	READ[enumName] = function(r)
		local v = num(r, 1)
		local name = byValue[v]
		if name == nil then
			fail("value " .. v .. " is not a valid " .. enumName)
		end
		return name
	end
end

-------------------------------------------------------------------------------
-- Maps
-------------------------------------------------------------------------------
local function readColorMap(r)
	local n = num(r, 2)
	if n * 6 > r.n - r.p + 1 then
		fail("colour map count " .. n .. " runs past end of data")
	end
	local m = table.create and table.create(n) or {}
	for i = 1, n do
		local R = readShortBounded(r)
		local G = readShortBounded(r)
		m[i] = { R = R, G = G, B = readShortBounded(r) }
	end
	return m
end

local function readStringMap(r)
	local n = num(r, 2)
	if n * 4 > r.n - r.p + 1 then
		fail("string map count " .. n .. " runs past end of data")
	end
	local m = {}
	for i = 1, n do
		m[i] = readString(r)
	end
	return m
end

-------------------------------------------------------------------------------
-- Instances
-------------------------------------------------------------------------------
-- Map index 0 means "nil" (the writer emits it for an absent value, e.g. a UnionOperation with no MeshId
-- attribute). Real exports contain it, so it must decode to nil rather than error.
local function mapString(r, strings, allowNil)
	local i = num(r, 2)
	if i == 0 and allowNil then
		return nil
	end
	local v = strings[i]
	if v == nil then
		fail("string map index " .. i .. " out of range (map has " .. #strings .. ")")
	end
	return v
end

local function mapColor(r, colors)
	local i = num(r, 2)
	if i == 0 then
		return nil
	end
	local c = colors[i]
	if c == nil then
		fail("colour map index " .. i .. " out of range (map has " .. #colors .. ")")
	end
	return { R = c.R, G = c.G, B = c.B }
end

local function readInstance(r, colors, strings, depth, warnings)
	if depth > r.maxDepth then
		fail("instance tree deeper than " .. r.maxDepth)
	end
	local typeId = num(r, 1)
	if typeId == 1 then
		return nil -- Nil: skipped class, no body, no children
	end
	local className = TYPE_BY_ID[typeId]
	if className == nil then
		fail("unknown instance type id " .. typeId .. " at symbol " .. (r.p - 1))
	end
	local plist = PROPS[className]
	local node = {
		ClassName = className == "PartNoAttributes" and "Part" or className,
		Name = DEFAULT_NAME[className],
		Props = {},
		Attrs = {},
		Children = {},
	}
	local props = node.Props
	if className == "BoolValue" then
		props.Value = false
	elseif className == "StringValue" then
		props.Value = ""
	end

	-- properties: (propId value)* then terminator 0
	while true do
		local pid = num(r, 1)
		if pid == 0 then
			break
		end
		local entry = plist[pid]
		if entry == nil then
			fail("class " .. className .. " has no property id " .. pid)
		end
		local pname, ptype = entry[1], entry[2]
		local value
		if ptype == "String" then
			value = mapString(r, strings, true)
		elseif ptype == "Color3" then
			value = mapColor(r, colors)
		else
			local rd = READ[ptype]
			if rd == nil then
				fail("no reader for value type " .. tostring(ptype))
			end
			value = rd(r)
		end
		if value ~= nil then
			if pname == "Name" then
				node.Name = value
			else
				props[pname] = value
			end
		end
	end

	-- attributes: (attrTypeId nameIdx value)* then terminator 0 (only some classes)
	if HAS_ATTRS[className] then
		local attrs = node.Attrs
		while true do
			local tid = num(r, 1)
			if tid == 0 then
				break
			end
			local tname = ATTR_BY_ID[tid]
			if tname == nil then
				fail("unknown attribute type id " .. tid)
			end
			local aname = mapString(r, strings)
			local value
			if tname == "String" then
				value = mapString(r, strings, true)
			elseif tname == "Color3" then
				value = mapColor(r, colors)
			else
				value = READ[tname](r)
			end
			attrs[aname] = value -- nil (map index 0) simply leaves the attribute absent
		end
	end

	-- children until terminator 0
	local children = node.Children
	while true do
		if r.p > r.n then
			fail("unexpected end of data inside children of " .. node.ClassName .. " '" .. tostring(node.Name) .. "'")
		end
		if VAL[byte(r.s, r.p)] == 0 then
			r.p = r.p + 1
			break
		end
		local child = readInstance(r, colors, strings, depth + 1, warnings)
		if child ~= nil then
			child.Parent = node
			children[#children + 1] = child
		end
	end
	return node
end

-------------------------------------------------------------------------------
-- JSON (pure Luau, for TableMissionSetup). null becomes nil (absent).
-------------------------------------------------------------------------------
--@@JSON@@

function Codec.jsonEncode(value)
	local ok, res = pcall(jsonEncode, value)
	if ok then
		return res
	end
	return nil, res
end

function Codec.jsonDecode(text)
	local ok, res = pcall(jsonDecode, text)
	if ok then
		return res
	end
	return nil, res
end

-------------------------------------------------------------------------------
-- Base64 (standard alphabet; also accepts URL-safe; ignores whitespace and padding)
-------------------------------------------------------------------------------
local B64 = {}
do
	local a = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	for i = 1, 64 do
		B64[byte(a, i)] = i - 1
	end
	B64[byte("-")] = 62
	B64[byte("_")] = 63
end

local function base64Decode(text)
	local out, k, chunk = {}, 0, {}
	local acc, bits, nchunk = 0, 0, 0
	for i = 1, #text do
		local c = byte(text, i)
		local v = B64[c]
		if v ~= nil then
			acc = acc * 64 + v
			bits = bits + 6
			if bits >= 8 then
				bits = bits - 8
				local div = 2 ^ bits
				local b = math.floor(acc / div)
				acc = acc - b * div
				nchunk = nchunk + 1
				chunk[nchunk] = b
				if nchunk == 2048 then
					k = k + 1
					out[k] = char(table.unpack(chunk, 1, nchunk))
					nchunk = 0
				end
			end
		elseif c ~= 61 and c ~= 32 and c ~= 10 and c ~= 13 and c ~= 9 then
			fail("invalid Base64 character at " .. i)
		end
	end
	if nchunk > 0 then
		k = k + 1
		out[k] = char(table.unpack(chunk, 1, nchunk))
	end
	return concat(out)
end

function Codec.base64Decode(text)
	local ok, res = pcall(base64Decode, text)
	if ok then
		return res
	end
	return nil, res
end

-------------------------------------------------------------------------------
-- Pieces, headers, gist wrapper
-------------------------------------------------------------------------------
local function trim(s)
	return (gsub(gsub(s, "^%s+", ""), "%s+$", ""))
end

local function parsePiece(text)
	if type(text) ~= "string" then
		fail("piece must be a string")
	end
	text = trim(text)
	if sub(text, 1, 3) == "!!!" then
		local rest = match(text, "^!!!.-!!!(.+)$")
		if rest == nil then
			fail("malformed opening comment (no closing !!!)")
		end
		text = rest
	end
	if #text < 7 then
		fail("piece shorter than the 7-symbol header")
	end
	local r = { s = text, p = 1, n = #text }
	local version = num(r, 1)
	local mapId = num(r, 2)
	local current = num(r, 2)
	local total = num(r, 2)
	if version > 2 then
		fail("unsupported code version " .. version .. " (this decoder knows 0, 1, 2)")
	end
	if total < 1 or current < 1 or current > total then
		fail("bad piece numbering " .. current .. "/" .. total)
	end
	return { Version = version, MapId = mapId, Current = current, Total = total, Payload = sub(text, 8) }
end

function Codec.parsePiece(text)
	local ok, res = pcall(parsePiece, text)
	if ok then
		return res
	end
	return nil, res
end

local function assemble(pieces)
	if type(pieces) == "string" then
		pieces = { pieces }
	end
	if #pieces == 0 then
		fail("no pieces given")
	end
	local first
	local slots = {}
	for _, text in ipairs(pieces) do
		local p = parsePiece(text)
		if first == nil then
			first = p
		elseif p.Version ~= first.Version then
			fail("code version mismatch between pieces")
		elseif p.MapId ~= first.MapId then
			fail("map id mismatch between pieces (pieces belong to different missions)")
		elseif p.Total ~= first.Total then
			fail("piece count mismatch between pieces")
		end
		if slots[p.Current] ~= nil and slots[p.Current] ~= p.Payload then
			fail("piece " .. p.Current .. " was given twice with different contents")
		end
		slots[p.Current] = p.Payload
	end
	local parts = {}
	for i = 1, first.Total do
		if slots[i] == nil then
			fail("missing piece " .. i .. " of " .. first.Total)
		end
		parts[i] = slots[i]
	end
	return { Version = first.Version, MapId = first.MapId, Total = first.Total, Payload = concat(parts) }
end

function Codec.assemble(pieces)
	local ok, res = pcall(assemble, pieces)
	if ok then
		return res
	end
	return nil, res
end

function Codec.normalizeGistUrl(url)
	url = trim(url)
	if not find(url, "^https?://") then
		return nil, "BreachCodec: not an http(s) URL"
	end
	local user, id = match(url, "^https?://gist%.github%.com/([^/]+)/([^/?#]+)")
	if user then
		return "https://gist.githubusercontent.com/" .. user .. "/" .. id .. "/raw"
	end
	if find(url, "^https?://gist%.githubusercontent%.com/[^/]+/[^/]+/raw") then
		return url
	end
	return nil, "BreachCodec: not a recognised gist URL"
end

-------------------------------------------------------------------------------
-- Mission assembly
-------------------------------------------------------------------------------
function Codec.resolveRef(root, path)
	local cur = root
	for idx in string.gmatch(path, "%d+") do
		cur = cur and cur.Children[tonumber(idx)]
		if cur == nil then
			return nil
		end
	end
	return cur
end

local function childNamed(node, name)
	for _, c in ipairs(node.Children) do
		if c.Name == name then
			return c
		end
	end
	return nil
end

local function buildMission(root, host, warnings)
	local mission = { Root = root, Warnings = warnings, SetupModules = {} }
	local jd = (host and host.jsonDecode) or jsonDecode

	local tableSetup = childNamed(root, "TableMissionSetup")
	if tableSetup and tableSetup.Props.Value ~= "" then
		local ok, res = pcall(jd, tableSetup.Props.Value)
		if ok and type(res) == "table" then
			if type(res.Colors) == "table" then
				for k, v in pairs(res.Colors) do
					if type(v) == "table" then
						res.Colors[k] = { R = v[1], G = v[2], B = v[3] }
					end
				end
			end
			mission.Setup = res
		else
			warnings[#warnings + 1] = "TableMissionSetup could not be decoded: " .. tostring(res)
		end
	else
		warnings[#warnings + 1] = "mission has no TableMissionSetup"
	end

	local strSetup = childNamed(root, "StringMissionSetup")
	if strSetup then
		mission.SetupSource = strSetup.Props.Value
		for _, c in ipairs(strSetup.Children) do
			mission.SetupModules[c.Name] = c.Props.Value
		end
	end

	local cms = childNamed(root, "CustomMissionSettings")
	if cms then
		mission.Settings = {}
		for _, c in ipairs(cms.Children) do
			mission.Settings[c.Name] = c.Props.Value
		end
	end
	return mission
end

local function decodeStream(raw, version, host)
	local r = newReader(raw, version, host and host.maxDepth)
	local warnings = {}
	local colors = readColorMap(r)
	local strings = readStringMap(r)
	local root = readInstance(r, colors, strings, 1, warnings)
	if root == nil then
		fail("stream's root instance is Nil (unsupported class)")
	end
	if r.p <= r.n then
		warnings[#warnings + 1] = "trailing data after the instance tree (" .. (r.n - r.p + 1) .. " symbols)"
	end
	return buildMission(root, host, warnings)
end

function Codec.decodeStream(raw, version, host)
	local ok, res = pcall(decodeStream, raw, version, host)
	if ok then
		return res
	end
	return nil, res
end

local function decode(input, host)
	host = host or {}
	if type(input) == "string" and find(trim(input), "^https?://") then
		fail("input is a URL; fetch it in the host and pass the text (see Codec.normalizeGistUrl)")
	end
	local asm = assemble(input)
	local raw = asm.Payload
	if asm.Version >= 2 then
		local b64 = host.base64Decode or base64Decode
		local bytes = b64(raw)
		local z = host.zstdDecompress
		if z == nil then
			fail("version-2 codes are Zstd-compressed: provide host.zstdDecompress(bytes) -> string")
		end
		local zerr
		raw, zerr = z(bytes)
		if type(raw) ~= "string" then
			fail(zerr and tostring(zerr) or "host.zstdDecompress must return a string")
		end
		if #raw > (host.maxRawSize or DEFAULT_MAX_RAW) then
			fail("decompressed stream larger than the allowed maximum")
		end
	end
	local mission = decodeStream(raw, asm.Version, host)
	mission.Version = asm.Version
	mission.MapId = asm.MapId
	return mission
end

function Codec.decode(input, host)
	local ok, res = pcall(decode, input, host)
	if ok then
		return res
	end
	return nil, res
end

return Codec
