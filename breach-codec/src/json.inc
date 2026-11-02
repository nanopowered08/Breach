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
