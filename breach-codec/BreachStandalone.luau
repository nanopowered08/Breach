--!nonstrict
--[[
	BreachStandalone — the BreachEngine Standalone on-disk map format (BreachEngine M3).

	Pure Luau, no requires, no file I/O. It converts between an instance tree and a LIST OF FILES
	({ path = "a/b/Instance.metadata", text = "..." }); the host reads and writes the actual files.

	    local files = Standalone.encode(mission.Root)          -- tree -> files
	    local root, err = Standalone.decode(files)             -- files -> tree

	LAYOUT (main doc §5.5)
	    <rootDir>/<DebugMission>/Instance.metadata         one directory per instance
	    <rootDir>/<DebugMission>/<Child>/Instance.metadata
	    <dir>/Contents                                      StringValue text (raw), when non-empty

	DESIGN DECISIONS (§5.5 / D2, D5)
	  * Child ORDER is stored explicitly (`Order`), not derived from the filesystem, so it survives any OS.
	  * Every instance carries a stable `Id`; instance references are stored as {"RefId": "n42"}, not as
	    fragile child-index paths, and are converted back to index paths on decode.
	  * Directory names are only for humans: sanitised, made unique case-insensitively, never trusted
	    (the real name is in the metadata).
	  * Values are JSON; an explicit `false` is stored as false (no exporter-style dropping).

	Instance.metadata (Markdown; one value per line):
	    # Instance
	    - ClassName: "Part"
	    - Name: "Floor"
	    - Id: "n12"
	    - Order: 3
	    ## Properties
	    - Size: {"X":10,"Y":1,"Z":10}
	    ## Attributes
	    - Tag: "x"
]]

local Standalone = {}
Standalone.VERSION = "0.1.0"

local find, match, sub, gsub, concat = string.find, string.match, string.sub, string.gsub, table.concat
local char = string.char

local function fail(msg)
	error("BreachStandalone: " .. msg, 0)
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

local META = "Instance.metadata"
local CONTENTS = "Contents"
local DEFAULT_ROOT_DIR = "DataModel/game/Workspace"

-------------------------------------------------------------------------------
-- Names
-------------------------------------------------------------------------------
local RESERVED = { [string.lower(META)] = true, ["instance.property"] = true, [string.lower(CONTENTS)] = true }

local function sanitize(name)
	local s = gsub(tostring(name), "[^%w_%.%-]", "_")
	if #s > 80 then
		s = sub(s, 1, 80)
	end
	s = gsub(s, "%.+$", function(d) return string.rep("_", #d) end)
	if s == "" then
		s = "_"
	end
	if RESERVED[string.lower(s)] then
		s = s .. "_"
	end
	return s
end

-------------------------------------------------------------------------------
-- Encode
-------------------------------------------------------------------------------
local PLAIN_KEY = "^[A-Za-z_][A-Za-z0-9_]*$"

local function keyText(k)
	if find(k, PLAIN_KEY) then
		return k
	end
	return "[" .. jsonEncode(k) .. "]"
end

local function sortedKeys(t)
	local ks = {}
	for k in pairs(t) do
		ks[#ks + 1] = k
	end
	table.sort(ks)
	return ks
end

function Standalone.encode(root, opts)
	opts = opts or {}
	local rootDir = opts.rootDir or DEFAULT_ROOT_DIR

	-- pass 1: ids and ref-path -> id map
	local used, refPathToId, ordered = {}, {}, {}
	local function collect(node, refPath)
		ordered[#ordered + 1] = { node = node, refPath = refPath }
		if node.Id ~= nil then
			if used[node.Id] then
				fail("duplicate node id " .. tostring(node.Id))
			end
			used[node.Id] = true
		end
		for i, c in ipairs(node.Children) do
			collect(c, refPath == "" and tostring(i) or (refPath .. "." .. i))
		end
	end
	collect(root, "")
	local counter = 0
	local function freshId()
		repeat
			counter = counter + 1
		until not used["n" .. counter]
		used["n" .. counter] = true
		return "n" .. counter
	end
	local ids = {}
	for _, e in ipairs(ordered) do
		local id = e.node.Id or freshId()
		ids[e.node] = id
		refPathToId[e.refPath] = id
	end

	local files = {}
	local function emit(node, dir, order)
		local lines = { "# Instance" }
		lines[#lines + 1] = "- ClassName: " .. jsonEncode(node.ClassName)
		lines[#lines + 1] = "- Name: " .. jsonEncode(node.Name)
		lines[#lines + 1] = "- Id: " .. jsonEncode(ids[node])
		lines[#lines + 1] = "- Order: " .. order
		local contents
		local propLines = {}
		for _, k in ipairs(sortedKeys(node.Props)) do
			local v = node.Props[k]
			if node.ClassName == "StringValue" and k == "Value" and type(v) == "string" then
				if v ~= "" then
					contents = v
				end
			else
				if type(v) == "table" and type(v.Ref) == "string" then
					local id = refPathToId[v.Ref]
					if id == nil then
						fail("instance reference '" .. v.Ref .. "' on " .. tostring(node.Name) .. " points at nothing")
					end
					v = { RefId = id }
				end
				propLines[#propLines + 1] = "- " .. keyText(k) .. ": " .. jsonEncode(v)
			end
		end
		if #propLines > 0 then
			lines[#lines + 1] = "## Properties"
			for _, l in ipairs(propLines) do
				lines[#lines + 1] = l
			end
		end
		if next(node.Attrs) ~= nil then
			lines[#lines + 1] = "## Attributes"
			for _, k in ipairs(sortedKeys(node.Attrs)) do
				lines[#lines + 1] = "- " .. keyText(k) .. ": " .. jsonEncode(node.Attrs[k])
			end
		end
		files[#files + 1] = { path = dir .. "/" .. META, text = concat(lines, "\n") .. "\n" }
		if contents ~= nil then
			files[#files + 1] = { path = dir .. "/" .. CONTENTS, text = contents }
		end
		local taken = {}
		for i, c in ipairs(node.Children) do
			local base = sanitize(c.Name)
			local name, n = base, 1
			while taken[string.lower(name)] do
				n = n + 1
				name = base .. "~" .. n
			end
			taken[string.lower(name)] = true
			emit(c, dir .. "/" .. name, i)
		end
	end
	emit(root, rootDir .. "/" .. sanitize(root.Name), 1)
	return files
end

-------------------------------------------------------------------------------
-- Decode
-------------------------------------------------------------------------------
local function parseKey(raw)
	if sub(raw, 1, 1) == "[" then
		local k = jsonDecode(sub(raw, 2, #raw - 1))
		if type(k) ~= "string" then
			fail("bad bracketed key " .. raw)
		end
		return k
	end
	return raw
end

local function parseMetadata(text, where)
	local meta, props, attrs = {}, {}, {}
	local section
	for line in string.gmatch(text, "[^\r\n]+") do
		if line == "# Instance" then
			section = meta
		elseif line == "## Properties" then
			section = props
		elseif line == "## Attributes" then
			section = attrs
		elseif sub(line, 1, 2) == "- " then
			if section == nil then
				fail(where .. ": value before any section")
			end
			local rest = sub(line, 3)
			local key, value
			if sub(rest, 1, 1) == "[" then
				-- bracketed key: [ "json string" ]: value
				local close = find(rest, '"%]: ')
				if not close then
					fail(where .. ": malformed key in line: " .. line)
				end
				key = parseKey(sub(rest, 1, close + 1))
				value = sub(rest, close + 4)
			else
				local k, v = match(rest, "^([^:]+): (.*)$")
				if not k then
					fail(where .. ": malformed line: " .. line)
				end
				key, value = k, v
			end
			section[key] = jsonDecode(value)
		else
			fail(where .. ": unexpected line: " .. line)
		end
	end
	return meta, props, attrs
end

local function dirname(p)
	return match(p, "^(.*)/[^/]*$") or ""
end

function Standalone.decode(files, opts)
	local ok, res = pcall(function()
		opts = opts or {}
		local rootDir = opts.rootDir or DEFAULT_ROOT_DIR
		local text = {}
		for _, f in ipairs(files) do
			text[f.path] = f.text
		end
		local byDir, dirs = {}, {}
		for path in pairs(text) do
			local dir = match(path, "^(.*)/" .. gsub(META, "%.", "%%.") .. "$")
			if dir ~= nil then
				dirs[#dirs + 1] = dir
			end
		end
		table.sort(dirs)
		local ids = {}
		for _, dir in ipairs(dirs) do
			local meta, props, attrs = parseMetadata(text[dir .. "/" .. META], dir)
			if type(meta.ClassName) ~= "string" or meta.Name == nil or type(meta.Id) ~= "string" or type(meta.Order) ~= "number" then
				fail(dir .. ": metadata is missing ClassName, Name, Id or Order")
			end
			if ids[meta.Id] then
				fail("duplicate id " .. meta.Id .. " (" .. dir .. " and " .. ids[meta.Id].dir .. ")")
			end
			local node = { ClassName = meta.ClassName, Name = meta.Name, Id = meta.Id, Props = props, Attrs = attrs, Children = {}, dir = dir, order = meta.Order }
			local contents = text[dir .. "/" .. CONTENTS]
			if contents ~= nil then
				node.Props.Value = contents
			elseif node.ClassName == "StringValue" and node.Props.Value == nil then
				node.Props.Value = ""
			end
			ids[meta.Id] = node
			byDir[dir] = node
		end
		local root
		for _, dir in ipairs(dirs) do
			local node = byDir[dir]
			local parentDir = dirname(dir)
			local parent = byDir[parentDir]
			if parent then
				parent.Children[#parent.Children + 1] = node
				node.Parent = parent
			elseif parentDir == rootDir then
				if root then
					fail("more than one root instance under " .. rootDir)
				end
				root = node
			else
				fail(dir .. ": parent directory has no " .. META)
			end
		end
		if not root then
			fail("no root instance found under " .. rootDir)
		end
		-- order, then strip bookkeeping, then references
		local function finish(node, refPath)
			table.sort(node.Children, function(a, b)
				if a.order ~= b.order then
					return a.order < b.order
				end
				return a.dir < b.dir
			end)
			for i = 2, #node.Children do
				if node.Children[i].order == node.Children[i - 1].order then
					fail(node.dir .. ": two children share Order " .. node.Children[i].order)
				end
			end
			node.dir, node.order = nil, nil
			node.RefPath = refPath
			for i, c in ipairs(node.Children) do
				finish(c, refPath == "" and tostring(i) or (refPath .. "." .. i))
			end
		end
		finish(root, "")
		for _, node in pairs(ids) do
			for k, v in pairs(node.Props) do
				if type(v) == "table" and type(v.RefId) == "string" then
					local target = ids[v.RefId]
					if target == nil then
						fail("reference to unknown id " .. v.RefId .. " on " .. tostring(node.Name))
					end
					node.Props[k] = { Ref = target.RefPath }
				end
			end
		end
		return root
	end)
	if ok then
		return res
	end
	return nil, tostring(res)
end

return Standalone
