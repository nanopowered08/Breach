--!nonstrict
--[[ BreachScript standalone: the StateScript VM with BreachExpr, BreachCFrame and BreachRandom embedded. See the header below. ]]

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

local Expr = (function()
--[[
	BreachExpr — the mission expression language (BreachEngine M5; main doc §7.2).

	Pure Luau, no requires, no Roblox APIs. Written from the documentation and from the ~700 real expressions in
	the two Operators maps; contains no game code.

	    local program, err = Expr.compile("(Mission_Difficulty == 1 && 6) || 10")   -- nil, "BreachExpr: ..." on a syntax error
	    program.Deps        { "Mission_Difficulty" }      every variable the expression can read (first-use order)
	    program.Constant    true when it reads nothing, calls nothing and cannot fail (Value is then precomputed)
	    local v = Expr.evaluate(program, ctx)             -- number | string; never throws
	    Expr.interpolate("Found {Files} of {Total}", ctx) -- {expr} inside a string-context attribute

	ctx (all optional):
	    get(name) -> number | string | boolean | table | nil   variable lookup (nil = undeclared -> 0, reported;
	                                                      a table is an opaque object such as a CFrame)
	    arith(op, a, b) -> value | nil, reason            operators when an operand is a table (BreachCFrame.arith)
	    rng(seed, min, max) -> number                     the `RNG` prefix function
	    report(kind, detail)                              kinds: "undeclared" "div-zero" "mod-zero" "type-mismatch" "nan" "no-rng"

	Language (verified against real maps unless marked):
	    values        numbers and strings; no boolean type. 0 and "" are false, everything else true.
	    literals      12  3.5  .5   [text]  [[text with ] inside]
	    variables     [A-Za-z_][A-Za-z0-9_]*          unset/undeclared reads give 0
	    operators     !  - (unary)   * / %   + -   < <= > >=   == ~= !=   &&   ||           (high -> low precedence)
	    && and ||     short-circuit and return an OPERAND, like Lua:  `a && 4 || b` is "4 if a else b"  (used all over real maps)
	    comparisons   give 1 or 0
	    RNG s lo hi   prefix call with space-separated arguments: `RNG 5342 1 8`   (real maps)
	    FLOOR x       the other function in the real maps, written `FLOOR (a / b)` or `FLOOR(a / b)`; its argument is
	                  one parenthesised group / literal / variable, so `FLOOR 7 / 2` is `(FLOOR 7) / 2`
	    names         may start with a digit (`!1Searched`) as long as they contain a letter or underscore
	    #Name         a StateScript local or parameter (only meaningful with a host that resolves it, see BreachScript)
	    % is floored (Lua) modulo: -1 % 8 = 7       (used: `((GuardInfo + 4) % 8) + 1`)
	    [P] unverified choices are listed in main doc §7.2.1.
]]

local Expr = {}
Expr.VERSION = "0.1.0"

local MAX_SOURCE = 100000 -- characters
local MAX_DEPTH = 200 -- parenthesis / prefix-argument nesting
local MAX_AST_DEPTH = 1000 -- longest operator chain; keeps the recursive evaluator well inside Luau's stack
local FUNCTIONS = { RNG = 3, FLOOR = 1 } -- name -> argument count (the only two that appear in the real maps)
Expr.FUNCTIONS = FUNCTIONS

--------------------------------------------------------------------------------------------------- values

local function truthy(v)
	return v ~= 0 and v ~= ""
end
Expr.truthy = truthy

-- number | string | boolean | nil -> number | string | nil (booleans become 1/0)
local function normalize(v)
	local t = type(v)
	if t == "number" then
		if v ~= v or v == math.huge or v == -math.huge then
			return 0
		end
		return v
	elseif t == "string" then
		return v
	elseif t == "boolean" then
		return v and 1 or 0
	end
	return nil
end
Expr.normalize = normalize

-- Numeric view of a value: numbers as is, numeric strings parsed, anything else 0. Second result: was it really numeric?
local function toNumber(v: any)
	if type(v) == "number" then
		return v, true
	end
	if type(v) == "string" then
		local n = tonumber(v)
		if n and n == n and n ~= math.huge and n ~= -math.huge and string.match(v, "%S") then
			return n, true
		end
	end
	return 0, false
end
Expr.toNumber = toNumber

local function formatNumber(n)
	if n == math.floor(n) and math.abs(n) < 1e15 then
		return string.format("%d", n)
	end
	return string.format("%.14g", n)
end
Expr.formatNumber = formatNumber

local function toString(v)
	if type(v) == "number" then
		return formatNumber(v)
	end
	return tostring(v)
end
Expr.toString = toString

--------------------------------------------------------------------------------------------------- tokenizer

local TWO_CHAR = { ["||"] = true, ["&&"] = true, ["=="] = true, ["~="] = true, ["!="] = true, [">="] = true, ["<="] = true }
local ONE_CHAR = { ["!"] = true, ["+"] = true, ["-"] = true, ["*"] = true, ["/"] = true, ["%"] = true, ["<"] = true, [">"] = true, ["("] = true, [")"] = true }

local function fail(msg, pos)
	error({ expr = true, msg = msg, pos = pos }, 0)
end

local function tokenize(src: string)
	local toks, n, i, len = {}, 0, 1, #src
	while i <= len do
		local c = src:sub(i, i)
		if c:match("%s") then
			i += 1
		else
			local start = i
			local word = c:match("%d") and src:match("^%d[%w_]*", i)
			if word and word:find("[%a_]") then -- a name that starts with a digit: 1Searched (real maps have them)
				i += #word
				n += 1
				toks[n] = { k = "id", v = word, pos = start }
			elseif c:match("%d") or (c == "." and src:sub(i + 1, i + 1):match("%d")) then
				local text = src:match("^%d*%.?%d*", i)
				i += #text
				if src:sub(i, i):match("[%a_%.]") then
					fail("malformed number", start)
				end
				n += 1
				toks[n] = { k = "num", v = tonumber(text), pos = start }
			elseif c:match("[%a_]") then
				local text = src:match("^[%a_][%w_]*", i)
				i += #text
				n += 1
				toks[n] = { k = "id", v = text, pos = start }
			elseif c == "#" and src:sub(i + 1, i + 1):match("[%w_]") then -- StateScript local / parameter: #Name
				local text = src:match("^#[%w_]+", i)
				i += #text
				n += 1
				toks[n] = { k = "id", v = text, pos = start }
			elseif c == "[" then
				local text
				if src:sub(i, i + 1) == "[[" then
					local j = src:find("]]", i + 2, true)
					if not j then
						fail("unterminated string literal", start)
					end
					text = src:sub(i + 2, j - 1)
					i = j + 2
				else
					local j = src:find("]", i + 1, true)
					if not j then
						fail("unterminated string literal", start)
					end
					text = src:sub(i + 1, j - 1)
					i = j + 1
				end
				n += 1
				toks[n] = { k = "str", v = text, pos = start }
			else
				local two = src:sub(i, i + 1)
				if TWO_CHAR[two] then
					n += 1
					toks[n] = { k = "op", v = two, pos = start }
					i += 2
				elseif ONE_CHAR[c] then
					n += 1
					toks[n] = { k = "op", v = c, pos = start }
					i += 1
				elseif c == "=" then
					fail("'=' is not an operator; use '==' to compare", start)
				elseif c == "&" or c == "|" then
					fail("'" .. c .. "' alone is not an operator; use '" .. c .. c .. "'", start)
				else
					fail("unexpected character '" .. c .. "'", start)
				end
			end
		end
	end
	n += 1
	toks[n] = { k = "eof", pos = len + 1 }
	return toks
end

--------------------------------------------------------------------------------------------------- parser (Pratt)

local PREC = {
	["||"] = 1,
	["&&"] = 2,
	["=="] = 3, ["~="] = 3, ["!="] = 3,
	["<"] = 4, ["<="] = 4, [">"] = 4, [">="] = 4,
	["+"] = 5, ["-"] = 5,
	["*"] = 6, ["/"] = 6, ["%"] = 6,
}

local function describe(t)
	if t.k == "eof" then
		return "end of expression"
	elseif t.k == "str" then
		return "string literal"
	end
	return "'" .. tostring(t.v) .. "'"
end

local function parse(src)
	local toks = tokenize(src)
	local p = 1
	local deps, depSet = {}, {}
	local hasCall = false
	local parseExpr, parseUnary

	local function parsePrimary(depth)
		local t = toks[p]
		if depth > MAX_DEPTH then
			fail("expression is nested too deeply", t.pos)
		end
		if t.k == "num" then
			p += 1
			return { t = "num", v = t.v, d = 1 }
		elseif t.k == "str" then
			p += 1
			return { t = "str", v = t.v, d = 1 }
		elseif t.k == "id" then
			p += 1
			local arity = FUNCTIONS[t.v]
			if arity then
				hasCall = true
				local args, d = {}, 1
				for i = 1, arity do
					local nt = toks[p]
					if nt.k == "eof" or (nt.k == "op" and nt.v ~= "(" and nt.v ~= "!" and nt.v ~= "-") then
						fail(t.v .. " expects " .. arity .. (arity == 1 and " argument" or " arguments") .. " but got " .. (i - 1), nt.pos)
					end
					args[i] = parseUnary(depth + 1)
					d = math.max(d, args[i].d + 1)
				end
				return { t = "call", name = t.v, args = args, d = d }
			end
			if not depSet[t.v] then
				depSet[t.v] = true
				deps[#deps + 1] = t.v
			end
			return { t = "var", name = t.v, d = 1 }
		elseif t.k == "op" and t.v == "(" then
			p += 1
			local e = parseExpr(1, depth + 1)
			local close = toks[p]
			if close.k ~= "op" or close.v ~= ")" then
				fail("expected ')' but found " .. describe(close), close.pos)
			end
			p += 1
			return e
		end
		fail("unexpected " .. describe(t), t.pos)
		return nil
	end

	function parseUnary(depth)
		local t = toks[p]
		if depth > MAX_DEPTH then
			fail("expression is nested too deeply", t.pos)
		end
		if t.k == "op" and (t.v == "!" or t.v == "-") then
			p += 1
			local a = parseUnary(depth + 1)
			return { t = "un", op = t.v, a = a, d = a.d + 1 }
		end
		return parsePrimary(depth)
	end

	function parseExpr(minPrec, depth)
		local left = parseUnary(depth)
		while true do
			local t = toks[p]
			if t.k ~= "op" then
				break
			end
			local prec = PREC[t.v]
			if not prec or prec < minPrec then
				break
			end
			p += 1
			local right = parseExpr(prec + 1, depth + 1)
			left = { t = "bin", op = t.v, a = left, b = right, d = math.max(left.d, right.d) + 1 }
			if left.d > MAX_AST_DEPTH then
				fail("expression chain is too long", t.pos)
			end
		end
		return left
	end

	local ast = parseExpr(1, 1)
	local last = toks[p]
	if last.k ~= "eof" then
		fail("unexpected " .. describe(last), last.pos)
	end
	return ast, deps, hasCall
end

--------------------------------------------------------------------------------------------------- evaluator

local function floorMod(a, b)
	return a - math.floor(a / b) * b
end

local function evalNode(node: any, ctx: any): any
	local t = node.t
	if t == "num" or t == "str" then
		return node.v
	elseif t == "var" then
		local get = ctx and ctx.get
		local raw = get and get(node.name)
		if type(raw) == "table" then -- an opaque value (a CFrame); only ctx.arith knows what to do with it
			return raw
		end
		local v = normalize(raw)
		if v == nil then
			if ctx and ctx.report then
				ctx.report("undeclared", node.name)
			end
			return 0
		end
		return v
	elseif t == "un" then
		local v = evalNode(node.a, ctx)
		if node.op == "!" then
			return truthy(v) and 0 or 1
		end
		local n, ok = toNumber(v)
		if not ok and ctx and ctx.report then
			ctx.report("type-mismatch", "unary '-' on a non-number")
		end
		return -n
	elseif t == "call" then
		local args = {}
		for i, a in ipairs(node.args) do
			args[i] = toNumber(evalNode(a, ctx))
		end
		if node.name == "FLOOR" then
			return math.floor(args[1])
		end
		local rng = ctx and ctx.rng
		if not rng then
			if ctx and ctx.report then
				ctx.report("no-rng", node.name)
			end
			return args[2]
		end
		return normalize(rng(args[1], args[2], args[3])) or args[2]
	end

	-- binary
	local op = node.op
	if op == "&&" then -- operand-returning, short-circuit
		local l = evalNode(node.a, ctx)
		if not truthy(l) then
			return l
		end
		return evalNode(node.b, ctx)
	elseif op == "||" then
		local l = evalNode(node.a, ctx)
		if truthy(l) then
			return l
		end
		return evalNode(node.b, ctx)
	end

	local l, r = evalNode(node.a, ctx), evalNode(node.b, ctx)
	if type(l) == "table" or type(r) == "table" then
		local res, why
		if ctx and ctx.arith then
			res, why = ctx.arith(op, l, r)
		end
		if res == nil then
			if ctx and ctx.report then
				ctx.report("type-mismatch", why or ("'" .. op .. "' on an object value"))
			end
			return 0
		end
		return normalize(res) or res
	end
	if op == "==" then
		return l == r and 1 or 0
	elseif op == "~=" or op == "!=" then
		return l ~= r and 1 or 0
	end

	if op == "<" or op == "<=" or op == ">" or op == ">=" then
		local a, b = l, r
		if type(l) ~= type(r) then
			local ln, lok = toNumber(l)
			local rn, rok = toNumber(r)
			if (not lok or not rok) and ctx and ctx.report then
				ctx.report("type-mismatch", "ordering a string against a number")
			end
			a, b = ln, rn
		end
		local res
		if op == "<" then
			res = a < b
		elseif op == "<=" then
			res = a <= b
		elseif op == ">" then
			res = a > b
		else
			res = a >= b
		end
		return res and 1 or 0
	end

	-- arithmetic
	local a, aok = toNumber(l)
	local b, bok = toNumber(r)
	if (not aok or not bok) and ctx and ctx.report then
		ctx.report("type-mismatch", "arithmetic '" .. op .. "' on a non-number")
	end
	local res
	if op == "+" then
		res = a + b
	elseif op == "-" then
		res = a - b
	elseif op == "*" then
		res = a * b
	elseif op == "/" then
		if b == 0 then
			if ctx and ctx.report then
				ctx.report("div-zero", "division by zero")
			end
			return 0
		end
		res = a / b
	else -- %
		if b == 0 then
			if ctx and ctx.report then
				ctx.report("mod-zero", "modulo by zero")
			end
			return 0
		end
		res = floorMod(a, b)
	end
	if res ~= res or res == math.huge or res == -math.huge then
		if ctx and ctx.report then
			ctx.report("nan", "arithmetic overflow")
		end
		return 0
	end
	return res
end

--------------------------------------------------------------------------------------------------- public API

local cache, cacheSize = {}, 0
local CACHE_MAX = 4096

local function build(src)
	local ok, ast, deps, hasCall = pcall(parse, src)
	if not ok then
		local e = ast
		if type(e) == "table" and e.expr then
			return nil, ("BreachExpr: %s at column %d in `%s`"):format(e.msg, e.pos, #src > 120 and (src:sub(1, 117) .. "...") or src)
		end
		return nil, "BreachExpr: internal error: " .. tostring(e)
	end
	local program = { Source = src, Ast = ast, Deps = deps, Constant = (#deps == 0 and not hasCall) }
	if program.Constant then
		-- Fold now, but an expression that hits a runtime problem (5 / 0, "a" + 1) stays unfolded so the
		-- problem is reported at evaluation time instead of vanishing.
		local issues = 0
		program.Value = evalNode(ast, { report = function() issues += 1 end })
		if issues > 0 then
			program.Constant, program.Value = false, nil
		end
	end
	return program
end

-- src may be a string, a number or a boolean (attributes hold any of the three). "" compiles to the constant "".
function Expr.compile(src)
	local t = type(src)
	if t == "number" or t == "boolean" then
		local v = normalize(src)
		return { Source = tostring(src), Ast = { t = "num", v = v, d = 1 }, Deps = {}, Constant = true, Value = v }
	elseif t ~= "string" then
		return nil, "BreachExpr: expected a string, number or boolean, got " .. t
	end
	if #src > MAX_SOURCE then
		return nil, "BreachExpr: expression is longer than " .. MAX_SOURCE .. " characters"
	end
	local hit = cache[src]
	if hit then
		return hit.program, hit.err
	end
	local program, err
	if not src:match("%S") then
		program = { Source = src, Ast = { t = "str", v = "", d = 1 }, Deps = {}, Constant = true, Value = "" }
	else
		program, err = build(src)
	end
	if cacheSize >= CACHE_MAX then
		cache, cacheSize = {}, 0
	end
	cache[src] = { program = program, err = err }
	cacheSize += 1
	return program, err
end

function Expr.evaluate(program, ctx)
	if program.Constant then
		return program.Value
	end
	return evalNode(program.Ast, ctx)
end

-- Compile + evaluate in one go. Returns value, or nil + error message.
function Expr.eval(src, ctx)
	local program, err = Expr.compile(src)
	if not program then
		return nil, err
	end
	return Expr.evaluate(program, ctx)
end

-- String-context attributes may contain {expression} parts. Returns the text and a list of problems
-- ({ message = ... }); a part that fails to compile is left in the text as written.
function Expr.interpolate(template, ctx)
	if type(template) ~= "string" or not template:find("{", 1, true) then
		return template, {}
	end
	local out, problems, i, len = {}, {}, 1, #template
	while i <= len do
		local open = template:find("{", i, true)
		if not open then
			out[#out + 1] = template:sub(i)
			break
		end
		out[#out + 1] = template:sub(i, open - 1)
		local close = template:find("}", open + 1, true)
		if not close then
			problems[#problems + 1] = { message = "unterminated '{' at column " .. open }
			out[#out + 1] = template:sub(open)
			break
		end
		local inner = template:sub(open + 1, close - 1)
		local program, err = Expr.compile(inner)
		if program and inner:match("%S") then
			out[#out + 1] = toString(Expr.evaluate(program, ctx))
		else
			problems[#problems + 1] = { message = err or "empty {} part" }
			out[#out + 1] = template:sub(open, close)
		end
		i = close + 1
	end
	return table.concat(out), problems
end

return Expr
end)()

local CF = (function()
--[[
	BreachCFrame — just enough CFrame math for StateScript (BreachEngine M6). Pure Luau, no Roblox APIs, so scripts
	run the same headless and in-game. A host that has real CFrames converts at the edge (see BreachScript's `host`).

	A CFrame is an array of 12 numbers in Roblox's component order: x, y, z, R00 R01 R02, R10 R11 R12, R20 R21 R22
	(row-major rotation). Euler angles follow Roblox's CFrame.Angles: R = Rx · Ry · Rz (main doc §6.5).

	    CF.new(x, y, z)   CF.identity()   CF.angles(rx, ry, rz)   CF.fromQuat(x, y, z, w)   CF.fromString("1, 2, 3")
	    CF.mul(a, b)      CF.inverse(a)   CF.lerp(a, b, t)         CF.position(a)   CF.toQuat(a)   CF.equals(a, b)
	    CF.isCF(v)        CF.arith(op, a, b)   -- the hook BreachExpr uses for `[#Pos * #Rot]`
]]

local CF = {}
local MT = {}
MT.__index = MT

local function make(t)
	return setmetatable(t, MT)
end

-- Structural, not identity: every build of this module (standalone, or the copy embedded in BreachScript/BreachLogic)
-- has its own metatable, and a CFrame made by one must be recognised by another.
MT.__breachCFrame = true
function CF.isCF(v)
	if type(v) ~= "table" then
		return false
	end
	local mt = getmetatable(v)
	return mt ~= nil and mt.__breachCFrame == true and #v == 12
end

function CF.new(x, y, z)
	return make({ x or 0, y or 0, z or 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 })
end

function CF.identity()
	return CF.new(0, 0, 0)
end

function CF.position(c: any)
	return c[1], c[2], c[3]
end

-- 12 numbers in Roblox order.
function CF.fromComponents(list)
	if #list ~= 12 then
		return nil, "a CFrame needs 12 components, got " .. #list
	end
	local t = {}
	for i = 1, 12 do
		t[i] = list[i]
	end
	return make(t)
end

function CF.fromQuat(x, y, z, w, px, py, pz)
	local n = math.sqrt(x * x + y * y + z * z + w * w)
	if n == 0 then
		return CF.new(px, py, pz)
	end
	x, y, z, w = x / n, y / n, z / n, w / n
	return make({
		px or 0, py or 0, pz or 0,
		1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w),
		2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w),
		2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y),
	})
end

function CF.toQuat(c: any)
	local m00, m01, m02, m10, m11, m12, m20, m21, m22 = c[4], c[5], c[6], c[7], c[8], c[9], c[10], c[11], c[12]
	local tr = m00 + m11 + m22
	local x, y, z, w
	if tr > 0 then
		local s = math.sqrt(tr + 1) * 2
		w, x, y, z = 0.25 * s, (m21 - m12) / s, (m02 - m20) / s, (m10 - m01) / s
	elseif m00 > m11 and m00 > m22 then
		local s = math.sqrt(1 + m00 - m11 - m22) * 2
		w, x, y, z = (m21 - m12) / s, 0.25 * s, (m01 + m10) / s, (m02 + m20) / s
	elseif m11 > m22 then
		local s = math.sqrt(1 + m11 - m00 - m22) * 2
		w, x, y, z = (m02 - m20) / s, (m01 + m10) / s, 0.25 * s, (m12 + m21) / s
	else
		local s = math.sqrt(1 + m22 - m00 - m11) * 2
		w, x, y, z = (m10 - m01) / s, (m02 + m20) / s, (m12 + m21) / s, 0.25 * s
	end
	return x, y, z, w
end

-- Roblox CFrame.Angles: R = Rx * Ry * Rz (radians).
function CF.angles(rx, ry, rz)
	local cx, sx, cy, sy, cz, sz = math.cos(rx), math.sin(rx), math.cos(ry), math.sin(ry), math.cos(rz), math.sin(rz)
	return make({
		0, 0, 0,
		cy * cz, -cy * sz, sy,
		cx * sz + sx * sy * cz, cx * cz - sx * sy * sz, -sx * cy,
		sx * sz - cx * sy * cz, sx * cz + cx * sy * sz, cx * cy,
	})
end

function CF.mul(a: any, b: any)
	local ax, ay, az = a[1], a[2], a[3]
	local a00, a01, a02, a10, a11, a12, a20, a21, a22 = a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11], a[12]
	local bx, by, bz = b[1], b[2], b[3]
	local b00, b01, b02, b10, b11, b12, b20, b21, b22 = b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12]
	return make({
		ax + a00 * bx + a01 * by + a02 * bz,
		ay + a10 * bx + a11 * by + a12 * bz,
		az + a20 * bx + a21 * by + a22 * bz,
		a00 * b00 + a01 * b10 + a02 * b20, a00 * b01 + a01 * b11 + a02 * b21, a00 * b02 + a01 * b12 + a02 * b22,
		a10 * b00 + a11 * b10 + a12 * b20, a10 * b01 + a11 * b11 + a12 * b21, a10 * b02 + a11 * b12 + a12 * b22,
		a20 * b00 + a21 * b10 + a22 * b20, a20 * b01 + a21 * b11 + a22 * b21, a20 * b02 + a21 * b12 + a22 * b22,
	})
end

function CF.inverse(c: any)
	local x, y, z = c[1], c[2], c[3]
	local r00, r01, r02, r10, r11, r12, r20, r21, r22 = c[4], c[5], c[6], c[7], c[8], c[9], c[10], c[11], c[12]
	return make({
		-(r00 * x + r10 * y + r20 * z), -(r01 * x + r11 * y + r21 * z), -(r02 * x + r12 * y + r22 * z),
		r00, r10, r20,
		r01, r11, r21,
		r02, r12, r22,
	})
end

-- Position lerps linearly; rotation slerps (nlerp when nearly parallel).
function CF.lerp(a: any, b: any, t: number)
	local x, y, z = a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t
	local ax, ay, az, aw = CF.toQuat(a)
	local bx, by, bz, bw = CF.toQuat(b)
	local dot = ax * bx + ay * by + az * bz + aw * bw
	if dot < 0 then
		bx, by, bz, bw, dot = -bx, -by, -bz, -bw, -dot
	end
	local ka, kb
	if dot > 0.9995 then
		ka, kb = 1 - t, t
	else
		local theta = math.acos(dot)
		local s = math.sin(theta)
		ka, kb = math.sin((1 - t) * theta) / s, math.sin(t * theta) / s
	end
	return CF.fromQuat(ka * ax + kb * bx, ka * ay + kb * by, ka * az + kb * bz, ka * aw + kb * bw, x, y, z)
end

function CF.equals(a: any, b: any, tol: number)
	tol = tol or 1e-9
	for i = 1, 12 do
		if math.abs(a[i] - b[i]) > tol then
			return false
		end
	end
	return true
end

-- "x, y, z" (position) | 7 numbers (position + quaternion x y z w) | 12 numbers (Roblox order).
function CF.fromString(s)
	local nums = {}
	for tok in string.gmatch((s:gsub(",", " ")), "%S+") do
		local n = tonumber(tok)
		if n == nil then
			return nil, "not a number: '" .. tok .. "'"
		end
		nums[#nums + 1] = n
	end
	if #nums == 3 then
		return CF.new(nums[1], nums[2], nums[3])
	elseif #nums == 7 then
		return CF.fromQuat(nums[4], nums[5], nums[6], nums[7], nums[1], nums[2], nums[3])
	elseif #nums == 12 then
		return CF.fromComponents(nums)
	end
	return nil, "expected 3, 7 or 12 numbers, got " .. #nums
end

-- The expression-language hook: arithmetic and equality when an operand is a CFrame. Returns value, or nil + reason.
function CF.arith(op: string, a: any, b: any)
	if CF.isCF(a) and CF.isCF(b) then
		if op == "*" then
			return CF.mul(a, b)
		elseif op == "==" then
			return CF.equals(a, b) and 1 or 0
		elseif op == "~=" or op == "!=" then
			return CF.equals(a, b) and 0 or 1
		end
		return nil, "'" .. op .. "' is not defined for two CFrames"
	end
	if op == "==" then
		return 0
	elseif op == "~=" or op == "!=" then
		return 1
	end
	return nil, "'" .. op .. "' mixes a CFrame with a non-CFrame"
end

function MT.__tostring(c)
	local rotated = not (c[4] == 1 and c[5] == 0 and c[6] == 0 and c[7] == 0 and c[8] == 1 and c[9] == 0 and c[10] == 0 and c[11] == 0 and c[12] == 1)
	return ("CFrame(%g, %g, %g%s)"):format(c[1], c[2], c[3], rotated and ", rotated" or "")
end

return CF
end)()

--[=[
	BreachScript — the StateScript VM (BreachEngine M6; main doc §7.4).

	Written from the instruction list in the Mission Exporter docs and from the 26 real scripts in the two Operators
	maps. Pure Luau; embeds BreachExpr, BreachCFrame and BreachRandom (also usable through BreachLogic).

	    local program = Script.compile(source, "TruckRun")      -- program.Problems = lint findings { Line, Message }
	    local inst = Script.new(program, host, { Name = "TruckRun", Params = { GuardCount = 18 } })
	    inst:spawn()                                              -- start a thread (runs until it first waits)
	    inst:kill(thread)  inst:killAll()

	Compiled once to a flat instruction array (labels -> indices). Every thread has its own program counter, value
	stack, call stack and `#locals`; waits (WAIT, WAITHEARTBEAT, WAITFOR, WAITFORCHANGE) suspend it via the host. A
	thread that runs more than `Budget` instructions without waiting is killed and reported (no script can freeze a server).

	Syntax (verified on real scripts unless marked [P]):
	    CMD arg arg ...      lines are space-separated; blank lines ignored; `:label` defines a label
	    *CMD ...             a leading * means: substitute {x} in the line every time it runs. Without *, braces are left alone [P]
	    word                 a number if it looks like one, else a string; `#Name` reads a local, else a script parameter
	    [ expr ]             evaluates an expression (BreachExpr; may use #locals and CFrames: [#Pos * #Rot])
	    [[ text ]]           a literal string (spaces allowed): CFR #p [[1, 2, 3]]
	    {x}                  text substitution of a variable's value (nested: {Guard{#i}}), on * lines
	    names                in variable positions: `#x` is a thread-local, anything else is a global mission variable
	    CFrame positions     accept a #local, a global variable holding a CFrame, [ expr ], or [[ "x, y, z" ]]

	host (all required unless marked optional):
	    Get(name) -> value|nil          Set(name, value)           global mission variables (value: number|string|CFrame)
	    Now() -> seconds                Schedule(at, fn) -> task   Cancel(task)
	    Watch(deps, evalFn, onValue) -> handle     re-run evalFn when any dep changes and call onValue(value); handle.Dead = true stops it
	    Emit(event)                     world commands arrive as { Kind = "ScriptCommand", Command, Args, Script, Thread }
	    Report(kind, detail)            soft problems (undeclared variable, missing prop, ...)
	    Error(where, message)           a thread died
	    Guid() -> string                Seed (number, for RNG/SHUFFLE)
	    CFrameOf(tag) -> CFrame|nil     (optional) the world's CFrame for a prop tag, for CFRCOPY
]=]

local Script = {}
Script.VERSION = "0.1.0"

local HEARTBEAT = 1 / 60
local DEFAULT_BUDGET = 10000
local MAX_CALL_DEPTH = 256
local MAX_STACK = 10000
local truthy, toNumber = Expr.truthy, Expr.toNumber

-- Attributes on a StateScript instance that are NOT parameters.
Script.Reserved = { ScriptSource = true, Run = true, TriggerEvent = true, DebugVariable = true, DebugLineVariable = true, ScriptMove = true, Type = true }

local function scriptError(msg)
	error({ script = true, msg = msg }, 0)
end

local function isNumber(text)
	return text:match("^[-+]?%d*%.?%d+$") ~= nil or text:match("^[-+]?%d+%.$") ~= nil
end

local function sameValue(a, b)
	if CF.isCF(a) and CF.isCF(b) then
		return CF.equals(a, b)
	end
	return a == b
end

--------------------------------------------------------------------------------------------------- tokenizer

local function tokenizeLine(text: string)
	local toks, i, len = {}, 1, #text
	while i <= len do
		local c = text:sub(i, i)
		if c:match("%s") then
			i += 1
		elseif text:sub(i, i + 1) == "[[" then
			local j = text:find("]]", i + 2, true)
			if not j then
				return nil, "unterminated [[ ]] literal"
			end
			toks[#toks + 1] = { k = "lit", text = text:sub(i + 2, j - 1) }
			i = j + 2
		elseif c == "[" then
			local depth, j = 1, i + 1
			while j <= len and depth > 0 do
				local d = text:sub(j, j)
				if d == "[" then
					depth += 1
				elseif d == "]" then
					depth -= 1
				end
				j += 1
			end
			if depth > 0 then
				return nil, "unterminated [ ] expression"
			end
			toks[#toks + 1] = { k = "expr", text = text:sub(i + 1, j - 2) }
			i = j
		else
			local word: string = text:match("^%S+", i)
			toks[#toks + 1] = { k = "word", text = word }
			i += #word
		end
	end
	return toks
end

--------------------------------------------------------------------------------------------------- threads

local Thread = {}
Thread.__index = Thread

function Thread:localValue(name)
	local v = self.Locals[name]
	if v ~= nil then
		return v
	end
	return self.Inst.Params[name]
end

function Thread:getVar(name)
	if name:sub(1, 1) == "#" then
		return self:localValue(name:sub(2))
	end
	return self.Inst.Host.Get(name)
end

function Thread:setVar(name, value)
	if name:sub(1, 1) == "#" then
		self.Locals[name:sub(2)] = value
	else
		self.Inst.Host.Set(name, value)
	end
end

function Thread:ctx()
	if not self.Ctx then
		local host = self.Inst.Host
		self.Ctx = {
			get = function(name)
				if name:sub(1, 1) == "#" then
					return self:localValue(name:sub(2))
				end
				return host.Get(name)
			end,
			rng = function(seed, min, max)
				return Random.derive(host.Seed or 0, seed, min, max)
			end,
			arith = CF.arith,
			report = function(kind, detail)
				host.Report(kind, detail)
			end,
		}
	end
	return self.Ctx
end

function Thread:eval(text)
	local program, err = Expr.compile(text)
	if not program then
		scriptError("bad expression [" .. text .. "]: " .. err)
	end
	return Expr.evaluate(program, self:ctx())
end

-- Any value: literal text, number, #local, [expr].
function Thread:val(tok)
	if tok.k == "lit" then
		return tok.text
	elseif tok.k == "expr" then
		return self:eval(tok.text)
	end
	local t = tok.text
	if t:sub(1, 1) == "#" then
		local v = self:localValue(t:sub(2))
		if v == nil then
			self.Inst.Host.Report("undeclared", t)
			return 0
		end
		return v
	end
	if isNumber(t) then
		return tonumber(t)
	end
	return t
end

function Thread:str(tok)
	return Expr.toString(self:val(tok))
end

function Thread:num(tok)
	local v = self:val(tok)
	local n, ok = toNumber(v)
	if not ok then
		scriptError("expected a number but got '" .. Expr.toString(v) .. "'")
	end
	return n
end

-- A variable NAME (keeps the '#' of a local).
function Thread:nameOf(tok)
	if tok.k == "word" then
		return tok.text
	end
	return self:str(tok)
end

function Thread:cf(tok)
	local v
	if tok.k == "word" and tok.text:sub(1, 1) ~= "#" and not isNumber(tok.text) then
		v = self.Inst.Host.Get(tok.text) -- a global variable that holds a CFrame (CFRCOPY SecurityRoom SecurityRoom)
		if v == nil then
			scriptError("no CFrame variable named '" .. tok.text .. "'")
		end
	elseif tok.k == "lit" then
		local c, err = CF.fromString(tok.text)
		if not c then
			scriptError("bad CFrame literal: " .. err)
		end
		v = c
	else
		v = self:val(tok)
	end
	if not CF.isCF(v) then
		scriptError("expected a CFrame but got '" .. Expr.toString(v) .. "'")
	end
	return v
end

-- A value that is a number or a CFrame (a bare word may name a global CFrame variable).
function Thread:numOrCf(tok)
	local v = self:val(tok)
	if type(v) == "string" then
		local g = self.Inst.Host.Get(v)
		if type(g) == "table" then
			return g
		end
	end
	return v
end

function Thread:labelName(tok)
	local name = (self:str(tok):gsub("^:", ""))
	if not self.Inst.Program.Labels[name] then
		scriptError("label '" .. name .. "' not found")
	end
	return name
end

function Thread:label(tok)
	return self.Inst.Program.Labels[self:labelName(tok)]
end

function Thread:substitute(text)
	local guard = 0
	while guard < 64 do
		local s, e, name = text:find("{([^{}]*)}")
		if not s then
			break
		end
		guard += 1
		name = name:match("^%s*(.-)%s*$")
		local v = self:getVar(name)
		if v == nil then
			self.Inst.Host.Report("undeclared", name)
			v = 0
		end
		text = text:sub(1, s - 1) .. Expr.toString(v) .. text:sub(e + 1)
	end
	return text
end

-- The expression text of a WAITFOR's arguments: bare words as written, [..] groups parenthesised.
local function joinExpr(args)
	local parts = {}
	for _, tok in ipairs(args) do
		if tok.k == "expr" then
			parts[#parts + 1] = "(" .. tok.text .. ")"
		elseif tok.k == "lit" then
			parts[#parts + 1] = "[" .. tok.text .. "]"
		else
			parts[#parts + 1] = tok.text
		end
	end
	return table.concat(parts, " ")
end

--------------------------------------------------------------------------------------------------- instructions

local C = {}
Script.Commands = C

local function declare(th, name, value)
	if th:getVar(name) == nil then
		th:setVar(name, value)
	end
end

C.INIT = { min = 1, run = function(th, a)
	declare(th, th:nameOf(a[1]), a[2] and th:val(a[2]) or 0) -- once: an existing variable is left alone
end }
C.SET = { min = 2, run = function(th, a)
	th:setVar(th:nameOf(a[1]), th:val(a[2]))
end }

local function step(delta)
	return function(th, a)
		local name = th:nameOf(a[1])
		local cur = th:getVar(name)
		if cur == nil then
			th.Inst.Host.Report("undeclared", name)
			cur = 0
		end
		local n = toNumber(cur)
		th:setVar(name, n + delta)
	end
end
C.INC = { min = 1, run = step(1) }
C.INCREMENT = C.INC
C.DEC = { min = 1, run = step(-1) }
C.DECREMENT = C.DEC

C.ALLOC = { min = 1, run = function(th, a)
	declare(th, th:nameOf(a[1]), 0)
end }
C.ALLOCARRAY = { min = 2, run = function(th, a)
	local name, n = th:nameOf(a[1]), th:num(a[2])
	for i = 0, n - 1 do
		declare(th, name .. i, 0)
	end
end }
C.GUID = { min = 1, run = function(th, a)
	th:setVar(th:nameOf(a[1]), th.Inst.Host.Guid())
end }

-- flow
C.GOTO = { min = 1, run = function(th, a)
	if a[2] == nil or truthy(th:val(a[2])) then
		th.PC = th:label(a[1])
	end
end }

local function pushArgs(th, a, from)
	for i = from, #a do
		if #th.Stack >= MAX_STACK then
			scriptError("value stack overflow")
		end
		th.Stack[#th.Stack + 1] = th:val(a[i])
	end
end

local function call(th, labelTok, a, argsFrom)
	if #th.Calls >= MAX_CALL_DEPTH then
		scriptError("call stack overflow (" .. MAX_CALL_DEPTH .. " nested CALLs)")
	end
	local target = th:label(labelTok)
	pushArgs(th, a, argsFrom)
	th.Calls[#th.Calls + 1] = th.PC
	th.PC = target
end

C.CALL = { min = 1, run = function(th, a)
	call(th, a[1], a, 2)
end }
-- Real scripts write the condition FIRST: CALLIF [RevealSkipped == 1] :KILLLABEL (the old doc had label first).
C.CALLIF = { min = 2, run = function(th, a)
	if truthy(th:val(a[1])) then
		call(th, a[2], a, 3)
	end
end }
C.RETURN = { min = 0, run = function(th)
	if #th.Calls == 0 then
		th.Inst:kill(th)
	else
		th.PC = table.remove(th.Calls)
	end
end }
C.KILL = { min = 0, run = function(th)
	th.Inst:kill(th)
end }
C.THREAD = { min = 1, run = function(th, a)
	local args = {}
	for i = 2, #a do
		args[#args + 1] = th:val(a[i])
	end
	th.Inst:spawn(th:labelName(a[1]), args)
end }

-- stack
C.PUSH = { min = 1, run = function(th, a)
	pushArgs(th, a, 1)
end }
local function pull(remove)
	return function(th, a)
		local name = th:nameOf(a[1])
		local n = #th.Stack
		if n == 0 then
			th.Inst.Host.Report("stack-empty", th.Inst.Name)
			th:setVar(name, 0)
			return
		end
		th:setVar(name, th.Stack[n])
		if remove then
			th.Stack[n] = nil
		end
	end
end
C.POP = { min = 1, run = pull(true) }
C.PEEK = { min = 1, run = pull(false) }

-- waiting
local function sleep(th, seconds, varName)
	local inst, host = th.Inst, th.Inst.Host
	if seconds <= 0 then
		seconds = HEARTBEAT
	end
	th.Task = host.Schedule(host.Now() + seconds, function()
		th.Task = nil
		if varName then
			th:setVar(varName, seconds)
		end
		inst:_run(th)
	end)
	return "wait"
end
C.WAIT = { min = 1, run = function(th, a)
	return sleep(th, th:num(a[1]), a[2] and th:nameOf(a[2]) or nil)
end }
C.WAITHEARTBEAT = { min = 0, run = function(th, a)
	return sleep(th, HEARTBEAT, a[1] and th:nameOf(a[1]) or nil)
end }

local function compileWait(th, a)
	local text = joinExpr(a)
	local program, err = Expr.compile(text)
	if not program then
		scriptError("bad expression [" .. text .. "]: " .. err)
	end
	local deps = {}
	for _, d in ipairs(program.Deps) do
		if d:sub(1, 1) ~= "#" then
			deps[#deps + 1] = d
		end
	end
	local ctx = th:ctx()
	return program, deps, function()
		return Expr.evaluate(program, ctx)
	end
end

local function suspendOn(th, deps, evalFn, ready)
	local inst, host = th.Inst, th.Inst.Host
	if #deps == 0 then
		host.Report("script-hang", inst.Name .. ": a wait on an expression with no mission variables never wakes")
	end
	local handle
	handle = host.Watch(deps, evalFn, function(v)
		if th.Alive and th.Watch == handle and ready(v) then
			handle.Dead = true
			th.Watch = nil
			inst:_run(th)
		end
	end)
	th.Watch = handle
	return "wait"
end

C.WAITFOR = { min = 1, run = function(th, a)
	local _, deps, evalFn = compileWait(th, a)
	if truthy(evalFn()) then
		return
	end
	return suspendOn(th, deps, evalFn, truthy)
end }
C.WAITFORCHANGE = { min = 1, run = function(th, a)
	local _, deps, evalFn = compileWait(th, a)
	local start = evalFn()
	return suspendOn(th, deps, evalFn, function(v)
		return not sameValue(v, start)
	end)
end }

-- math / data
C.LERP = { min = 4, run = function(th, a)
	local x, y, t = th:numOrCf(a[1]), th:numOrCf(a[2]), th:num(a[3])
	local out
	if type(x) == "number" and type(y) == "number" then
		out = x + (y - x) * t
	elseif CF.isCF(x) and CF.isCF(y) then
		out = CF.lerp(x, y, t)
	else
		scriptError("LERP needs two numbers or two CFrames")
	end
	th:setVar(th:nameOf(a[4]), out)
end }

local function parseNumbers(s)
	local nums = {}
	for tok in string.gmatch((s:gsub(",", " ")), "%S+") do
		local n = tonumber(tok)
		if not n then
			scriptError("not a number: '" .. tok .. "'")
		end
		nums[#nums + 1] = n
	end
	return nums
end

C.CFR = { min = 1, run = function(th, a)
	local name = th:nameOf(a[1])
	if a[2] == nil then
		th:setVar(name, CF.identity())
		return
	end
	local v = a[2].k == "lit" and a[2].text or th:val(a[2])
	if CF.isCF(v) then
		th:setVar(name, v)
		return
	end
	local c, err = CF.fromString(Expr.toString(v))
	if not c then
		scriptError("CFR: " .. err)
	end
	th:setVar(name, c)
end }

local function eulerCommand(scale)
	return { min = 2, run = function(th, a)
		local nums
		if #a >= 4 then
			nums = { th:num(a[2]), th:num(a[3]), th:num(a[4]) }
		else
			nums = parseNumbers(th:str(a[2]))
		end
		if #nums ~= 3 then
			scriptError("expected three angles, got " .. #nums)
		end
		th:setVar(th:nameOf(a[1]), CF.angles(nums[1] * scale, nums[2] * scale, nums[3] * scale))
	end }
end
C.CFRANGLES = eulerCommand(1)
C.CFRDEGREES = eulerCommand(math.pi / 180)

C.CFRINV = { min = 1, run = function(th, a)
	local name = th:nameOf(a[1])
	local src = a[2] and th:cf(a[2]) or th:cf({ k = "word", text = name })
	th:setVar(name, CF.inverse(src))
end }

C.CFRCOPY = { min = 2, run = function(th, a)
	local host = th.Inst.Host
	local tag = th:str(a[2])
	local c = host.CFrameOf and host.CFrameOf(tag)
	if not CF.isCF(c) then
		host.Report("missing-prop", tag)
		c = CF.identity()
	end
	th:setVar(th:nameOf(a[1]), c)
end }

-- [P] SHUFFLE out seed items... : writes the shuffled items to out0..out(n-1) and the count to `out`.
C.SHUFFLE = { min = 3, run = function(th, a)
	local host = th.Inst.Host
	local items = {}
	for i = 3, #a do
		items[#items + 1] = th:val(a[i])
	end
	local stream = Random.new(Random.derive(host.Seed or 0, Random.toSeed(th:val(a[2])), 0, 4294967295))
	for i = #items, 2, -1 do
		local j = stream:nextInt(1, i)
		items[i], items[j] = items[j], items[i]
	end
	local name = th:nameOf(a[1])
	for i, v in ipairs(items) do
		th:setVar(name .. (i - 1), v)
	end
	th:setVar(name, #items)
end }

-- world commands: evaluated, then handed to the host as an event. Letters: s string, c CFrame, n number, * the rest.
local WORLD = {
	MOVETO = "sc*", ANIMATE = "scn", ANIMATECUBIC = "scn", COPYTO = "scs*",
	DELETE = "s", DELETEALL = "s", SPAWNBOT = "sc*", INITSTATECOMP = "s*",
}
local function worldArgs(th, a, pattern: string)
	local args, i = {}, 1
	for p = 1, #pattern do
		local kind = pattern:sub(p, p)
		if kind == "*" then
			break
		end
		if kind == "s" then
			args[i] = th:str(a[i])
		elseif kind == "c" then
			args[i] = th:cf(a[i])
		else
			args[i] = th:num(a[i])
		end
		i += 1
	end
	for j = i, #a do
		args[j] = th:val(a[j])
	end
	return args
end

for name, pat in pairs(WORLD) do
	local pattern: string = pat
	local needed = #pattern:gsub("%*", "")
	C[name] = { min = needed, run = function(th, a)
		local ok, args = pcall(worldArgs, th, a, pattern)
		if not ok then
			-- An argument that cannot be resolved (a CFrame variable another script or component has not set yet)
			-- skips THIS command and is reported; it does not kill the thread. [P]
			if type(args) == "table" and args.script then
				th.Inst.Host.Report("command-skipped", th.Inst.Name .. ": " .. name .. ": " .. args.msg)
				return
			end
			error(args, 0)
		end
		th.Inst.Host.Emit({ Kind = "ScriptCommand", Command = name, Args = args, Script = th.Inst.Name, Thread = th.Id })
	end }
end

Script.Instructions = {}
for name in pairs(C) do
	Script.Instructions[#Script.Instructions + 1] = name
end
table.sort(Script.Instructions)

--------------------------------------------------------------------------------------------------- compile

local LABEL_ARG = { GOTO = 1, CALL = 1, THREAD = 1, CALLIF = 2 }

function Script.compile(source, name)
	local program = { Name = name, Code = {}, Labels = {}, Problems = {} }
	local function problem(line, msg)
		program.Problems[#program.Problems + 1] = { Line = line, Message = msg }
	end
	local text = tostring(source or ""):gsub("\r\n", "\n")
	text = text:gsub("\r", "\n")
	local lineNo = 0
	for raw in (text .. "\n"):gmatch("([^\n]*)\n") do
		lineNo += 1
		local line = raw:match("^%s*(.-)%s*$")
		if line ~= "" then
			if line:sub(1, 1) == ":" then
				local label = line:match("^:%s*(%S+)")
				if not label then
					problem(lineNo, "empty label")
				elseif program.Labels[label] then
					problem(lineNo, "duplicate label '" .. label .. "'")
				else
					program.Labels[label] = #program.Code + 1
				end
			else
				local dynamic = false
				if line:sub(1, 1) == "*" then
					dynamic = true
					line = line:sub(2):match("^%s*(.*)$")
				end
				local cmd, rest = line:match("^(%S+)%s*(.*)$")
				cmd = (cmd or ""):upper()
				local ins = { Cmd = cmd, Line = lineNo, Dynamic = dynamic, Rest = rest or "" }
				local spec = C[cmd]
				if not spec then
					problem(lineNo, "unknown instruction '" .. cmd .. "'")
				elseif not dynamic then
					local toks, err = tokenizeLine(ins.Rest)
					if not toks then
						ins.Error = err
						problem(lineNo, err)
					else
						ins.Args = toks
						if #toks < spec.min then
							problem(lineNo, cmd .. " needs " .. spec.min .. " argument(s), found " .. #toks)
						end
					end
				end
				program.Code[#program.Code + 1] = ins
			end
		end
	end
	-- second pass: static label references
	for _, ins in ipairs(program.Code) do
		local at = LABEL_ARG[ins.Cmd]
		local tok = at and ins.Args and ins.Args[at]
		if tok and tok.k == "word" and tok.text:sub(1, 1) ~= "#" then
			if not program.Labels[(tok.text:gsub("^:", ""))] then
				problem(ins.Line, ins.Cmd .. ": label '" .. tok.text:gsub("^:", "") .. "' not found")
			end
		end
		if ins.Cmd == "INIT" and ins.Args and #ins.Args == 1 then
			problem(ins.Line, "INIT without a value (treated as 0)")
		end
	end
	return program
end

--------------------------------------------------------------------------------------------------- instances

local Inst = {}
Inst.__index = Inst

function Script.new(program, host, opts)
	opts = opts or {}
	return setmetatable({
		Program = program,
		Host = host,
		Name = opts.Name or program.Name or "script",
		Path = opts.Path,
		Params = opts.Params or {},
		DebugVariable = opts.DebugVariable,
		DebugLineVariable = opts.DebugLineVariable,
		Budget = opts.Budget or DEFAULT_BUDGET,
		Threads = {},
		LiveCount = 0,
		NextId = 0,
		Instructions = 0,
	}, Inst)
end

function Inst:spawn(label, args)
	local pc = 1
	if label then
		pc = self.Program.Labels[label]
		if not pc then
			self.Host.Error(self.Path or self.Name, "THREAD: label '" .. tostring(label) .. "' not found")
			return nil
		end
	end
	self.NextId += 1
	local th = setmetatable({ Inst = self, Id = self.NextId, PC = pc, Locals = {}, Stack = args or {}, Calls = {}, Alive = true, Line = 0 }, Thread)
	self.Threads[th.Id] = th
	self.LiveCount += 1
	self:_run(th)
	return th
end

function Inst:kill(th)
	if not th.Alive then
		return
	end
	th.Alive = false
	if th.Task then
		self.Host.Cancel(th.Task)
		th.Task = nil
	end
	if th.Watch then
		th.Watch.Dead = true
		th.Watch = nil
	end
	self.Threads[th.Id] = nil
	self.LiveCount -= 1
end

function Inst:killAll()
	for _, th in pairs(self.Threads) do
		self:kill(th)
	end
end

function Inst:_debug(th)
	local host = self.Host
	if self.DebugLineVariable and self.DebugLineVariable ~= "" then
		host.Set(self.DebugLineVariable, th.Line)
	end
	if self.DebugVariable and self.DebugVariable ~= "" then
		host.Set(self.DebugVariable, self.LiveCount)
	end
end

function Inst:_exec(th, ins)
	local spec = C[ins.Cmd]
	if not spec then
		scriptError("unknown instruction '" .. ins.Cmd .. "'")
	end
	local args = ins.Args
	if ins.Dynamic then
		local toks, err = tokenizeLine(th:substitute(ins.Rest))
		if not toks then
			scriptError(err)
		end
		args = toks
	elseif ins.Error then
		scriptError(ins.Error)
	end
	if #args < spec.min then
		scriptError(ins.Cmd .. " needs " .. spec.min .. " argument(s), found " .. #args)
	end
	return spec.run(th, args, ins)
end

function Inst:_run(th)
	if not th.Alive then
		return
	end
	local code, steps = self.Program.Code, 0
	local ok, err = pcall(function()
		while th.Alive do
			local ins = code[th.PC]
			if not ins then
				self:kill(th) -- ran off the end
				return
			end
			th.PC += 1
			steps += 1
			if steps > self.Budget then
				scriptError("instruction budget exceeded (" .. self.Budget .. " instructions without waiting; an endless loop?)")
			end
			th.Line = ins.Line
			if self:_exec(th, ins) == "wait" then
				return
			end
		end
	end)
	self.Instructions += steps
	if not ok then
		self:kill(th)
		local msg = (type(err) == "table" and err.script) and err.msg or ("internal error: " .. tostring(err))
		self.Host.Error((self.Path or self.Name) .. ":" .. th.Line, msg)
	end
	self:_debug(th)
end

return Script
