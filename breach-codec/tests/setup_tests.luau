--!nonstrict
-- M8.0 tests: BreachSetup (MissionSetup data parser). Run via tests/run.luau or `luau tests/setup.luau`
local Setup = require("../BreachSetup")

return function(check)
	local function ok(src)
		local t, err, w = Setup.parse(src)
		return t, err, w
	end
	local function eq(name, src, expected)
		local t, err = ok(src)
		check("setup: " .. name, err == nil and t == expected, tostring(t) .. (err and (" / " .. err) or ""))
	end

	----------------------------------------------------------------------------------------------- scalars and strings
	eq("integer", "return 42", 42)
	eq("negative", "return -7", -7)
	eq("float", "return 3.25", 3.25)
	eq("leading dot float", "return .5", 0.5)
	eq("exponent", "return 1.5e3", 1500)
	eq("negative exponent", "return 2E-2", 0.02)
	eq("hex", "return 0xFF", 255)
	eq("true", "return true", true)
	eq("false", "return false", false)
	eq("double-quoted string", 'return "hi"', "hi")
	eq("single-quoted string", "return 'hi'", "hi")
	eq("escapes", [[return "a\nb\tc\\d\"e\'f"]], 'a\nb\tc\\d"e\'f')
	eq("decimal escape", [[return "\65\066"]], "AB")
	eq("hex escape", [[return "\x41\x42"]], "AB")
	eq("unicode escape", [[return "\u{48}\u{49}"]], "HI")
	eq("\\z skips whitespace", 'return "a\\z\n    b"', "ab")
	eq("long string", "return [[one\ntwo]]", "one\ntwo")
	eq("long string drops a first newline", "return [[\nabc]]", "abc")
	eq("levelled long string", "return [==[a]]b]==]", "a]]b")
	eq("empty string", 'return ""', "")
	check("setup: nil returns nil without error", (function() local t, err = ok("return nil") return t == nil and err == nil end)())

	----------------------------------------------------------------------------------------------- tables
	do
		local t = ok('return { 10, 20, x = 1, ["y z"] = 2, [3] = "three", nested = { a = { b = true } }, }')
		check("setup: array part", t[1] == 10 and t[2] == 20)
		check("setup: named and bracketed keys", t.x == 1 and t["y z"] == 2 and t[3] == "three")
		check("setup: nested tables", t.nested.a.b == true)
		local s = ok("return { a = 1; b = 2; 3 }")
		check("setup: semicolons separate like commas", s.a == 1 and s.b == 2 and s[1] == 3)
		local e = ok("return {}")
		check("setup: an empty table", type(e) == "table" and next(e) == nil)
		local pos = ok("return { {1, 2}, {3, 4}, }")
		check("setup: arrays of arrays, trailing comma", pos[2][2] == 4 and #pos == 2)
		local eqsign = ok('return { a = "==", b = 1 }')
		check("setup: '=' inside a value is not a field", eqsign.a == "==" and eqsign.b == 1)
		local key = ok('return { ["Operator.Any.X"] = "I better search", ["Other"] = "q" }')
		check("setup: dotted string keys (CustomStrings shape)", key["Operator.Any.X"] == "I better search")
		local kw = ok("return { Allow = { Chef = true }, Trespass = true, None = {} }")
		check("setup: the Cells shape", kw.Allow.Chef == true and kw.Trespass == true and next(kw.None) == nil)
		local exprcell = ok('return { Cell = "{A && [B] || [C]}" }')
		check("setup: a {expression} string is just a string here (BreachExpr evaluates it later)", exprcell.Cell == "{A && [B] || [C]}")
	end

	----------------------------------------------------------------------------------------------- locals and references
	do
		local t = ok("local A = { Sec = true, Emp = true }\nlocal B = { Sec = true }\nreturn { One = A, Two = B, Again = A }")
		check("setup: a local constant can be referenced", t.One.Sec == true and t.One.Emp == true and t.Two.Emp == nil)
		check("setup: a reference shares the table (like Lua)", t.One == t.Again)
		local n = ok("local N = 5\nreturn { v = N, w = -N }")
		check("setup: referencing a number", n.v == 5)
		local idx = ok('local T = { a = { b = 3 }, list = { 7, 8 } }\nreturn { x = T.a.b, y = T["a"]["b"], z = T.list[2], w = T.list[1] }')
		check("setup: .field, [\"key\"] and [n] indexing of constants", idx.x == 3 and idx.y == 3 and idx.z == 8 and idx.w == 7)
		local re = ok("local X = 1\nlocal X = 2\nreturn X")
		check("setup: a later local redefines", re == 2)
		local lnil = ok("local X = nil\nreturn { a = X }")
		check("setup: a constant may be nil", lnil.a == nil)
	end

	----------------------------------------------------------------------------------------------- comments and layout
	do
		local t = ok("-- licence line\nlocal A = 1 -- trailing\n--[[ block\ncomment ]]\nreturn { x = A, --[==[ inner ]==] y = 2, -- end\n }")
		check("setup: line, block and levelled comments", t.x == 1 and t.y == 2)
		local sc = ok("local A = 1;\nreturn { x = A };")
		check("setup: optional semicolons after statements", sc.x == 1)
		local c = ok("return {\n\ta = 1,\n\t--[[ForcedLoadout = {\n\t\tGuns = {},\n\t},\n\tBlockArmor = true,]]\n\tb = 2,\n}")
		check("setup: a commented-out block (the Peacemaker has one) vanishes", c.a == 1 and c.b == 2 and c.ForcedLoadout == nil)
		local crlf = ok("local A = 1\r\nreturn {\r\n\tx = A,\r\n}\r\n")
		check("setup: CRLF line endings", crlf.x == 1)
	end

	----------------------------------------------------------------------------------------------- Color3
	do
		local t = ok("return { a = Color3.fromRGB(255, 128, 0), b = Color3.new(1, 0.5, 0), c = Color3.fromRGB(0,0,0) }")
		check("setup: Color3.fromRGB", t.a.Type == "Color3" and t.a.R == 255 and t.a.G == 128 and t.a.B == 0)
		check("setup: Color3.new scales to 0-255", t.b.R == 255 and t.b.G == 127.5 and t.b.B == 0)
		check("setup: a Color3 inside a constant", ok("local C = Color3.fromRGB(1,2,3)\nreturn { x = C }").x.G == 2)
	end

	----------------------------------------------------------------------------------------------- escape warnings
	do
		local t, err, w = ok('return { s = "...\\ARE YOU KIDDING ME?!" }')
		check("setup: an unknown escape is read as the character (Lua/Luau), not an error", err == nil and t.s == "...ARE YOU KIDDING ME?!")
		check("setup: ... and is reported as a warning with a position", #w == 1 and w[1]:find("'\\A'", 1, true) ~= nil and w[1]:find("line 1, column", 1, true) ~= nil, w[1])
		local _, _, none = ok('return "fine"')
		check("setup: a clean chunk has no warnings", #none == 0)
	end

	----------------------------------------------------------------------------------------------- errors: always clean, with a position
	do
		local bad = {
			{ "return", "reached the end" },
			{ "", "no `return`" },
			{ "local A = 1", "no `return`" },
			{ "return {", "unterminated table" },
			{ "return { a = 1", "unterminated table" },
			{ "return { a = }", "unexpected '}'" },
			{ 'return "abc', "unterminated string" },
			{ 'return "abc\ndef"', "newline in string" },
			{ "return [[abc", "unterminated long string" },
			{ "--[[ never closed\nreturn 1", "unterminated block comment" },
			{ "return Foo", "unknown name 'Foo'" },
			{ "return { a = B }\nlocal B = 1", "unknown name 'B'" },
			{ "return print('x')", "unknown name 'print'" },
			{ "return Color3.fromHSV(1,1,1)", "only Color3.fromRGB and Color3.new" },
			{ "return Color3.fromRGB(1, 2)", "takes 3 numbers" },
			{ "return Color3.fromRGB(1, 2, 'x')", "takes numbers" },
			{ "return 1 + 2", "unexpected content after `return`" },
			{ 'return "a" .. "b"', "unexpected content after `return`" },
			{ "return function() end", "not allowed" },
			{ "return { x = if true then 1 else 2 }", "not allowed" },
			{ "local function f() end\nreturn 1", "expected a constant name" },
			{ "local a, b = 1, 2\nreturn a", "expected '='" },
			{ "local A == 1\nreturn A", "expected '='" },
			{ "for i = 1, 2 do end", "expected `local` or `return`" },
			{ "x = 1\nreturn x", "expected `local` or `return`" },
			{ "return 1\nreturn 2", "unexpected content after `return`" },
			{ "return 0x", "malformed number" },
			{ "return 12abc", "malformed number" },
			{ "return -'x'", "unary '-' needs a number" },
			{ "return { [nil] = 1 }", "a table key cannot be nil" },
			{ "local T = 5\nreturn T.x", "cannot index" },
			{ 'return "\\xZ"', "bad \\x escape" },
			{ 'return "\\u{}"', "bad \\u escape" },
			{ 'return "\\400"', "decimal escape too large" },
			{ "return @", "unexpected '@'" },
			{ "return { a = 1 b = 2 }", "expected ',' or '}'" },
		}
		local allClean, shown = true, 0
		for _, c in ipairs(bad) do
			local okp, t, err = pcall(Setup.parse, c[1])
			local good = okp and t == nil and type(err) == "string" and err:find("^BreachSetup: ") ~= nil and err:find(c[2], 1, true) ~= nil and err:find("line %d+, column %d+") ~= nil
			if not good then
				allClean = false
				if shown < 6 then shown += 1 print("  not rejected as expected: " .. c[1]:gsub("\n", "\\n") .. " -> " .. tostring(err)) end
			end
		end
		check("setup: " .. #bad .. " malformed chunks are rejected with a message naming the problem and a line/column", allClean)
		local _, e = Setup.parse("local A = 1\nlocal B = {\n  x = A,\n  y = Nope,\n}\nreturn B")
		check("setup: errors carry the right line and column", e:find("line 4, column 7", 1, true) ~= nil, e)
		check("setup: a non-string is a clean error", select(2, Setup.parse(nil)) ~= nil and select(2, Setup.parse({})) ~= nil)
		check("setup: nesting bombs are refused, not a stack overflow", select(2, Setup.parse("return " .. string.rep("{", 500) .. string.rep("}", 500))) ~= nil)
		check("setup: a deep chain of unary minus is refused", select(2, Setup.parse("return " .. string.rep("-", 500) .. "1")) ~= nil)
		local big = {}
		for i = 1, 20000 do big[i] = "{ id = " .. i .. ", name = \"n" .. i .. "\" }" end
		local t0 = os.clock()
		local bigT = ok("return { " .. table.concat(big, ", ") .. " }")
		check("setup: 20,000 entries parse quickly", bigT ~= nil and #bigT == 20000 and os.clock() - t0 < 2, os.clock() - t0)
	end

	----------------------------------------------------------------------------------------------- fuzz
	do
		local seed = 4242
		local function rnd(n) seed = (seed * 1103515245 + 12345) % 2147483648 return seed % n end
		local pieces = { "return", "local", "A", "B", "=", "{", "}", "[", "]", "(", ")", ",", ";", "1", "2.5", "-", "\"s\"", "'t'", "true", "nil", "Color3.fromRGB", "--", "--[[", "]]", "[[", "..", "+", "function", "\n", " ", "\\", "0x", "e" }
		local threw, parsed, rejected = 0, 0, 0
		for _ = 1, 4000 do
			local parts = {}
			if rnd(2) == 0 then parts[1] = "return" end
			for i = #parts + 1, #parts + 1 + rnd(8) do parts[i] = pieces[1 + rnd(#pieces)] end
			local okp, t, err = pcall(Setup.parse, table.concat(parts, " "))
			if not okp then threw += 1 elseif t ~= nil or err == nil then parsed += 1 else rejected += 1 end
		end
		check("setup fuzz: 4000 random token soups, none threw", threw == 0, threw)
		check("setup fuzz: both outcomes occurred", parsed > 5 and rejected > 100, parsed .. "/" .. rejected)
	end

	----------------------------------------------------------------------------------------------- the real maps
	local okE, emb = pcall(require, "./_embedded")
	if not okE then
		print("(real-map setup tests skipped: tests/_embedded.luau not found)")
		return
	end
	local Codec = require("../BreachCodec")
	local Zstd = require("../BreachZstd")
	local host = { zstdDecompress = Zstd.decompress }
	local okP, embP = pcall(require, "./_embedded_project")
	local maps = { { "TheDiplomat", emb["TheDiplomat.base64"] }, { "thepeacemaker", emb["thepeacemaker.txt"] } }
	if okP then maps[#maps + 1] = { "TheProject", embP["theproject.txt"] } end

	local function same(a, b)
		if type(a) ~= type(b) then return false end
		if type(a) ~= "table" then return a == b end
		for k, v in pairs(a) do if not same(v, b[k]) then return false end end
		for k in pairs(b) do if a[k] == nil then return false end end
		return true
	end

	local parsed = {}
	for _, entry in ipairs(maps) do
		local label = entry[1]
		local d = Codec.decode(entry[2], host)
		local t0 = os.clock()
		local t, err, warns = Setup.parse(d.SetupSource)
		local dt = os.clock() - t0
		check(label .. " [setup]: the MissionSetup chunk (" .. #d.SetupSource .. " bytes) parses", t ~= nil, err)
		if t then
			parsed[label] = t
			check(label .. " [setup]: it overlaps the decoder's Setup exactly (Globals, Internals, ClientState, CustomStrings)", same(t.Globals or {}, d.Setup.Globals or {}) and same(t.Internals or {}, d.Setup.Internals or {}) and same(t.ClientState or {}, d.Setup.ClientState or {}) and same(t.CustomStrings or {}, d.Setup.CustomStrings or {}))
			check(label .. " [setup]: it has the trespass/disguise tables (Cells, EnforceClass)", type(t.Cells) == "table" and next(t.Cells) ~= nil and type(t.EnforceClass) == "table" and type(t.EnforceClass.None) == "table")
			check(label .. " [setup]: the colour constants are Color3 tables", (function() local n = 0 for _, c in pairs(t.Colors or {}) do if type(c) == "table" and c.Type == "Color3" then n += 1 end end return n > 0 end)())
			local n = 0
			for _ in pairs(t.Cells) do n += 1 end
			print(("  %s: parsed in %.3fs; %d cells, %d CustomStrings, %d warnings%s"):format(label, dt, n, (function() local c = 0 for _ in pairs(t.CustomStrings or {}) do c += 1 end return c end)(), #warns, #warns > 0 and (": " .. warns[1]) or ""))
		end
	end
	check("thepeacemaker [setup]: exactly one warning, the invalid \\A escape in a line of dialogue", (function()
		local d = Codec.decode(emb["thepeacemaker.txt"], host)
		local _, _, w = Setup.parse(d.SetupSource)
		return #w == 1 and w[1]:find("'\\A'", 1, true) ~= nil
	end)())
	if parsed.TheDiplomat then
		local c = parsed.TheDiplomat.Cells
		check("The Diplomat [setup]: a cell can be a {expression} string that chooses another cell's rules", type(c.SecurityCenter) == "string" and c.SecurityCenter:sub(1, 1) == "{" and c.SecurityCenter:find("IntercomBluffComplete && [InsideHighlyRestricted] || [Roof]", 1, true) ~= nil, tostring(c.SecurityCenter))
		check("The Diplomat [setup]: and a plain cell lists Allow / Enforce / EnforceMinor / Trespass", c.EmployeesAreaOutside.Allow.Chef == true and c.EmployeesAreaOutside.Enforce.Sec == true and c.EmployeesAreaOutside.EnforceMinor.Sec == true and c.EmployeesAreaOutside.Trespass == true)
		check("The Diplomat [setup]: the shared constants were resolved (ENFORCE_TRESPASS_CLASSES)", (function() for _, cell in pairs(c) do if type(cell) == "table" and cell.Enforce and cell.Enforce.Emp == true and cell.Enforce.Sec == true then return true end end end)() == true)
		check("The Diplomat [setup]: EnforceClass has an entry per alert level and per disguise level", parsed.TheDiplomat.EnforceClass.Alert3.ProSecurity == 5 and parsed.TheDiplomat.EnforceClass.Chef2.Chef == 3)
	end
	if parsed.TheProject then
		local r = parsed.TheProject.Cells.ServerRoomAwesome
		check("The Project [setup]: the server room is only MINOR trespassing for the workshop disguise (the V1.3 changelog)", r ~= nil and r.MinorTrespass ~= nil and r.MinorTrespass.Workshop == true and r.Trespass == true)
		check("The Project [setup]: the vault is enforced by Emp, Sec and Workshops and allows ProSecurity/Workshop", (function() local v = parsed.TheProject.Cells.Vault return v.Enforce.Emp and v.Enforce.Sec and v.Enforce.Workshops and v.Allow.ProSecurity and v.Allow.Workshop and not v.Allow.Technician end)())
	end
end
