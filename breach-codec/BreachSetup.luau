--!nonstrict
--[==[
	BreachSetup — parser for the `MissionSetup` chunk (BreachEngine M8.0; main doc §3 / N10).

	A mission keeps its setup (trespass classes, cells, preplanning, objectives, combat, custom disguises, ...) as a Luau
	chunk. In all three real maps it is pure DATA: `local NAME = {...}` constants followed by `return {...}`, with no
	functions. This is a strict parser for exactly that subset. It never runs code and never guesses: anything outside the
	subset is a clean error with a line and column.

	    local t, err, warnings = Setup.parse(source)   -- t = the returned table; nil, "BreachSetup: ... at line L, column C" on error
	                                                   -- warnings: list of strings (e.g. an invalid escape read as the character itself)

	Supported:  `local Name = <value>`  (later references by name, with `.field` / `["key"]` / `[n]` indexing)
	            `return <value>`        (once, last; an optional `;` after statements)
	            values:  tables ({a, b, k = v, ["k"] = v, [1] = v}, separators , or ;), strings ('..', "..", [[..]], [=[..]=]
	                     with the usual escapes), numbers (decimal, float, exponent, hex, unary minus), true, false, nil,
	                     Color3.fromRGB(r, g, b) and Color3.new(r, g, b)
	            comments: -- line, --[[ block ]], --[=[ levelled ]=]
	A Color3 becomes { Type = "Color3", R = 0..255, G = 0..255, B = 0..255 }.
	Not supported (errors): function calls other than Color3, operators (.., +, ...), `function`, `if`, loops, `local a, b`.
]==]

local Setup = {}
Setup.VERSION = "0.1.0"

local MAX_DEPTH = 200
local MAX_SOURCE = 16 * 1024 * 1024

local ESCAPES = { a = "\a", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", v = "\v", ["\\"] = "\\", ['"'] = '"', ["'"] = "'", ["\n"] = "\n" }

local function parse(src: string)
	local pos, len = 1, #src
	local locals, declared, warnings = {}, {}, {}

	local function fail(msg, at)
		error({ setup = true, msg = msg, pos = at or pos }, 0)
	end

	local function skip()
		while true do
			local _, e = src:find("^[ \t\r\n]+", pos)
			if e then
				pos = e + 1
			end
			if src:sub(pos, pos + 1) == "--" then
				local level = src:match("^%-%-%[(=*)%[", pos)
				if level then
					local close = "]" .. level .. "]"
					local _, e2 = src:find(close, pos + 4 + #level, true)
					if not e2 then
						fail("unterminated block comment", pos)
					end
					pos = e2 + 1
				else
					local nl = src:find("\n", pos, true)
					pos = nl and nl + 1 or len + 1
				end
			else
				return
			end
		end
	end

	local function peek(n)
		return src:sub(pos, pos + (n or 1) - 1)
	end

	local function expect(ch)
		skip()
		if src:sub(pos, pos + #ch - 1) ~= ch then
			fail("expected '" .. ch .. "'" .. (pos > len and " but reached the end" or (" but found '" .. peek() .. "'")))
		end
		pos += #ch
	end

	local function readString()
		local q = src:sub(pos, pos)
		local start = pos
		pos += 1
		local parts = {}
		while true do
			local i = src:find("[\\\n" .. q .. "]", pos)
			if not i then
				fail("unterminated string", start)
			end
			parts[#parts + 1] = src:sub(pos, i - 1)
			local c = src:sub(i, i)
			if c == q then
				pos = i + 1
				break
			elseif c == "\n" then
				fail("unterminated string (newline in string)", start)
			end
			local e = src:sub(i + 1, i + 1)
			if ESCAPES[e] then
				parts[#parts + 1] = ESCAPES[e]
				pos = i + 2
			elseif e:match("%d") then
				local digits = src:match("^%d%d?%d?", i + 1)
				local n = tonumber(digits)
				if n > 255 then
					fail("decimal escape too large", i)
				end
				parts[#parts + 1] = string.char(n)
				pos = i + 1 + #digits
			elseif e == "x" then
				local hex = src:match("^%x%x", i + 2)
				if not hex then
					fail("bad \\x escape", i)
				end
				parts[#parts + 1] = string.char(tonumber(hex, 16))
				pos = i + 4
			elseif e == "z" then
				local _, ze = src:find("^%s*", i + 2)
				pos = ze + 1
			elseif e == "u" then
				local hex = src:match("^{(%x+)}", i + 2)
				if not hex then
					fail("bad \\u escape", i)
				end
				parts[#parts + 1] = utf8.char(tonumber(hex, 16))
				pos = i + 4 + #hex
			elseif e == "" then
				fail("unterminated string", start)
			else
				-- Lua and Luau read an unknown escape as the character itself (the Peacemaker has "\ARE YOU KIDDING ME"):
				-- keep it, and report it as a warning
				warnings[#warnings + 1] = { pos = i, msg = "invalid escape sequence '\\" .. e .. "' (read as '" .. e .. "')" }
				parts[#parts + 1] = e
				pos = i + 2
			end
		end
		return table.concat(parts)
	end

	local function readLongString()
		local level = src:match("^%[(=*)%[", pos)
		local close = "]" .. level .. "]"
		local s, e = src:find(close, pos + 2 + #level, true)
		if not s then
			fail("unterminated long string", pos)
		end
		local text = src:sub(pos + 2 + #level, s - 1)
		pos = e + 1
		if text:sub(1, 1) == "\n" then
			text = text:sub(2)
		end
		return text
	end

	local function readNumber()
		local hex = src:match("^0[xX]%x+", pos)
		local text = hex
			or src:match("^%d+%.?%d*[eE][%+%-]?%d+", pos)
			or src:match("^%.%d+[eE][%+%-]?%d+", pos)
			or src:match("^%d+%.?%d*", pos)
			or src:match("^%.%d+", pos)
		if not text then
			fail("bad number")
		end
		if src:sub(pos + #text, pos + #text):match("[%w_]") then
			fail("malformed number", pos)
		end
		local n = tonumber(text)
		if n == nil then
			fail("bad number '" .. text .. "'")
		end
		pos += #text
		return n
	end

	local value

	local function readTable(depth)
		local start = pos
		pos += 1
		local t, n = {}, 0
		while true do
			skip()
			if pos > len then
				fail("unterminated table (opened here)", start)
			end
			local c = src:sub(pos, pos)
			if c == "}" then
				pos += 1
				return t
			end
			if c == "[" and not src:find("^%[=*%[", pos) then
				pos += 1
				local k = value(depth + 1)
				expect("]")
				expect("=")
				local v = value(depth + 1)
				if k == nil then
					fail("a table key cannot be nil", pos)
				end
				t[k] = v
			else
				local name = src:match("^[%a_][%w_]*", pos)
				local nameEnd = name and pos + #name
				local isField = false
				if name then
					local _, e = src:find("^%s*=[^=]", nameEnd)
					isField = e ~= nil
				end
				if isField then
					pos = nameEnd
					expect("=")
					t[name] = value(depth + 1)
				else
					n += 1
					t[n] = value(depth + 1)
				end
			end
			skip()
			local sep = src:sub(pos, pos)
			if sep == "," or sep == ";" then
				pos += 1
			elseif sep ~= "}" then
				if pos > len then
					fail("unterminated table (opened here)", start)
				end
				fail("expected ',' or '}' in a table" .. (pos > len and " but reached the end" or (" but found '" .. peek() .. "'")))
			end
		end
	end

	local function readCall(name, depth)
		-- only Color3.fromRGB / Color3.new
		expect("(")
		local args = {}
		skip()
		if peek() ~= ")" then
			while true do
				args[#args + 1] = value(depth + 1)
				skip()
				if peek() == "," then
					pos += 1
				else
					break
				end
			end
		end
		expect(")")
		if #args ~= 3 then
			fail(name .. " takes 3 numbers, found " .. #args)
		end
		for _, a in ipairs(args) do
			if type(a) ~= "number" then
				fail(name .. " takes numbers")
			end
		end
		if name == "Color3.new" then
			return { Type = "Color3", R = args[1] * 255, G = args[2] * 255, B = args[3] * 255 }
		end
		return { Type = "Color3", R = args[1], G = args[2], B = args[3] }
	end

	function value(depth)
		if depth > MAX_DEPTH then
			fail("nested too deeply")
		end
		skip()
		if pos > len then
			fail("expected a value but reached the end")
		end
		local c = src:sub(pos, pos)
		if c == "{" then
			return readTable(depth)
		elseif c == '"' or c == "'" then
			return readString()
		elseif c == "[" and src:find("^%[=*%[", pos) then
			return readLongString()
		elseif c == "-" then
			pos += 1
			skip()
			local v = value(depth + 1)
			if type(v) ~= "number" then
				fail("unary '-' needs a number", pos)
			end
			return -v
		elseif c:match("[%d%.]") then
			return readNumber()
		elseif c:match("[%a_]") then
			local start = pos
			local name = src:match("^[%a_][%w_]*", pos)
			pos += #name
			if name == "true" then
				return true
			elseif name == "false" then
				return false
			elseif name == "nil" then
				return nil
			elseif name == "function" or name == "if" or name == "for" or name == "while" or name == "not" then
				fail("'" .. name .. "' is not allowed: a setup chunk is data only", start)
			end
			if name == "Color3" then
				local m = src:match("^%.(%a+)", pos)
				if m == "fromRGB" or m == "new" then
					pos += 1 + #m
					return readCall("Color3." .. m, depth)
				end
				fail("only Color3.fromRGB and Color3.new are allowed", start)
			end
			if not declared[name] then
				fail("unknown name '" .. name .. "' (only earlier `local` constants can be referenced)", start)
			end
			local v = locals[name]
			-- indexing: .field and [key]
			while true do
				local dot = src:match("^%.([%a_][%w_]*)", pos)
				if dot then
					if type(v) ~= "table" then
						fail("cannot index a " .. type(v) .. " value", pos)
					end
					v = v[dot]
					pos += 1 + #dot
				elseif peek() == "[" and not src:find("^%[=*%[", pos) then
					pos += 1
					local k = value(depth + 1)
					expect("]")
					if type(v) ~= "table" then
						fail("cannot index a " .. type(v) .. " value", pos)
					end
					v = v[k]
				else
					break
				end
			end
			return v
		end
		fail("unexpected '" .. c .. "'")
		return nil
	end

	local result, returned = nil, false
	while true do
		skip()
		if pos > len then
			break
		end
		if peek() == ";" then
			pos += 1
		elseif returned then
			fail("unexpected content after `return`")
		else
			local word = src:match("^[%a_][%w_]*", pos)
			if word == "local" then
				pos += 5
				skip()
				local name = src:match("^[%a_][%w_]*", pos)
				if not name or name == "function" then
					fail("expected a constant name after `local`")
				end
				pos += #name
				skip()
				if peek() ~= "=" or peek(2) == "==" then
					fail("expected '=' after `local " .. name .. "` (only `local Name = value` is allowed)")
				end
				pos += 1
				locals[name] = value(1)
				declared[name] = true
			elseif word == "return" then
				pos += 6
				result = value(1)
				returned = true
			else
				fail("expected `local` or `return`" .. (word and (", found '" .. word .. "'") or (", found '" .. peek() .. "'")))
			end
		end
	end
	if not returned then
		fail("the chunk has no `return`", len + 1)
	end
	return result, warnings
end

local function lineCol(src: string, at: number)
	local line, col = 1, 1
	local i = 1
	while true do
		local nl = src:find("\n", i, true)
		if not nl or nl >= at then
			col = at - i + 1
			break
		end
		line += 1
		i = nl + 1
	end
	return line, col
end

function Setup.parse(source)
	if type(source) ~= "string" then
		return nil, "BreachSetup: expected a string, got " .. type(source)
	end
	if #source > MAX_SOURCE then
		return nil, "BreachSetup: the chunk is larger than " .. MAX_SOURCE .. " bytes"
	end
	local ok, res, warns = pcall(parse, source)
	if ok then
		local out = {}
		for _, w in ipairs(warns) do
			local line, col = lineCol(source, w.pos)
			out[#out + 1] = ("%s at line %d, column %d"):format(w.msg, line, col)
		end
		return res, nil, out
	end
	if type(res) == "table" and res.setup then
		local line, col = lineCol(source, math.min(res.pos, #source + 1))
		return nil, ("BreachSetup: %s at line %d, column %d"):format(res.msg, line, col)
	end
	return nil, "BreachSetup: internal error: " .. tostring(res)
end

return Setup
