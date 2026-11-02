--!nonstrict
--[[
	BreachLogic — the logic core of a mission (BreachEngine M5; main doc §7).

	Pure Luau, no requires, no Roblox APIs, no clock of its own: the host calls `advance(dt)` (a Heartbeat, a test
	loop, a C++ tick). Built on BreachMission (it reads Setup and the StateComponents folder). It embeds BreachExpr
	and BreachRandom, so this one file is all you need; they are also exposed as Logic.Expr / Logic.Random.

	    local Logic = require("./BreachLogic")
	    local logic = Logic.new(mission, { seed = 416, builtins = { Mission_Difficulty = 1 } })
	    logic:advance(1/60)                 -- run time forward; timers tick, delays fire, variables settle
	    logic:get("Mission_AlarmRaised")    logic:set("Mission_AlarmRaised", 1)
	    for _, ev in ipairs(logic:drainEvents()) do ... end     -- Notification / MissionComplete / MissionFailed
	    logic.Outcome                       -- nil | { Kind = "Complete" | "Failed", Component, Time }

	Replication (host moves the bytes; see Store and Replica):
	    local replica = logic:addClient(userId)   -- in-process client copy, already holds the full snapshot
	    logic:replicate()                          -- push pending changes to every attached replica
	    logic:flush()                              -- or: raw packets per client id, to send over your own network

	Supported components: StateUpdate, Notification, TimerComponent, MissionCompletionTrigger, MissionFailedTrigger,
	StateScript (M6: BreachScript VM; world commands come out as { Kind = "ScriptCommand" } events),
	DelayedStateUpdate, ConditionalStateUpdate, VariableShuffle (preprocess).
	Components of other types found under StateComponents/ are counted in logic.Unsupported (later milestones).
	Components under Disabled/, StateComponentsPreprocess/ etc. do not run (opts.componentFolders).

	Nothing here throws on bad mission data: problems land in logic.Errors / logic.Warnings / logic.Undeclared / logic.Issues.
]]

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

local Script = (function()
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
end)()

local Logic = {}
Logic.VERSION = "0.2.0"
Logic.Expr = Expr
Logic.Random = Random
Logic.CF = CF
Logic.Script = Script

local truthy, toNumber = Expr.truthy, Expr.toNumber
local EPS = 1e-9
local MIN_FREQUENCY = 1 / 60 -- one Heartbeat

local SUPPORTED = {
	StateUpdate = true,
	Notification = true,
	TimerComponent = true,
	MissionCompletionTrigger = true,
	MissionFailedTrigger = true,
	StateScript = true,
	DelayedStateUpdate = true,
	ConditionalStateUpdate = true,
	VariableShuffle = true, -- a preprocess component: runs once, before Setup
}

-- Attribute defaults, copied from Appendix A (tests compare them with BreachValidator's table).
local DEFAULTS = {
	StateUpdate = { Watch = "", SetVariable = "", SetInternal = "" },
	Notification = { Condition = "", Notification = "" },
	TimerComponent = {
		SetVariable = "", SetFormattedVariable = "", StartValue = 0, TargetValue = 60, Increment = 1,
		Offset = "", Enabled = "", Paused = "", Frequency = "",
	},
	MissionCompletionTrigger = { Condition = "", Timeout = 1, CompleteVariable = "" },
	MissionFailedTrigger = { Condition = "", Timeout = 1, FailedVariable = "" },
	StateScript = { ScriptSource = "", Run = "", TriggerEvent = "", DebugVariable = "", DebugLineVariable = "" }, -- no validator entry
	DelayedStateUpdate = { Watch = "", DelayTime = 5, SetVariable = "", OnlyMatch = false },
	ConditionalStateUpdate = { Watch = "", Condition = "", InactiveVariable = "", ActiveVariable = "" },
	VariableShuffle = { Prefix0 = "", Prefix1 = "", Set0 = "", Set1 = "", Seed = "", InternalOnly = false },
}
Logic.Defaults = DEFAULTS

--[[ Variables the ENGINE provides (the three real maps read exactly these). Defaults describe a one-player mission that has
	just started and is calm; a host overrides any of them with opts.builtins, or passes opts.defaultBuiltins = false.
	Without them an undeclared read is 0, and `PlayersInCombatExit == Mission_PlayersInGame` is `0 == 0`: true, which in
	The Project completed the mission at t = 1 s. [P] values, [O] names. ]]
Logic.Builtins = {
	Mission_Difficulty = 1,
	Mission_TacticalDifficulty = 0,
	Mission_PlayerTotal = 1,
	Mission_PlayersInGame = 1,
	Mission_AlarmRaised = 0,
	Mission_AlertLevel = 0,
	Mission_Started = 1,
}

local function sortedKeys(t)
	local ks = {}
	if type(t) == "table" then
		for k in pairs(t) do
			ks[#ks + 1] = k
		end
		table.sort(ks, function(a, b)
			return tostring(a) < tostring(b)
		end)
	end
	return ks
end

local function clean(x) -- strip float noise (0.30000000000000004 -> 0.3)
	return tonumber(string.format("%.12g", x)) or x
end

local function formatTime(seconds) -- "MM:SS"
	local s = math.floor(math.abs(seconds) + EPS)
	return (seconds < 0 and "-" or "") .. string.format("%02d:%02d", s // 60, s % 60)
end
Logic.formatTime = formatTime

--------------------------------------------------------------------------------------------------- Store

--[[ Three scopes (§7.1):
	Globals      replicated to every client automatically
	Internals    server only, never in a packet
	Client vars  one table per client; only that client receives them
	Packets are plain tables: { Full = bool, Globals = { {Name=,Value=}, ... }, Client = { {Name=,Value=}, ... } } ]]
local Store = {}
Store.__index = Store

local function newPending()
	return { List = {}, Set = {} }
end

local function markPending(p, name)
	if not p.Set[name] then
		p.Set[name] = true
		p.List[#p.List + 1] = name
	end
end

function Store.new()
	return setmetatable({
		Canon = {}, -- lower-case name -> the spelling first used (variable names are case-insensitive, see main doc §7.1)
		Globals = {},
		Internals = {},
		Pending = newPending(),
		Clients = {},
		ClientOrder = {},
		Listeners = {}, -- function(scope, name, old, new, clientId)
	}, Store)
end

-- The canonical spelling of a name, registering it on first use.
function Store:key(name)
	local lo = name:lower()
	local c = self.Canon[lo]
	if c == nil then
		c = name
		self.Canon[lo] = name
	end
	return c
end

function Store:scopeOf(name)
	local c = self.Canon[name:lower()]
	if c == nil then
		return nil
	elseif self.Globals[c] ~= nil then
		return "Globals"
	elseif self.Internals[c] ~= nil then
		return "Internals"
	end
	return nil
end

function Store:get(name)
	local c = self.Canon[name:lower()]
	if c == nil then
		return nil
	end
	local v = self.Globals[c]
	if v == nil then
		v = self.Internals[c]
	end
	return v
end

-- scope: "Globals" | "Internals". Returns true when the value changed.
function Store:set(scope, name, value)
	value = Expr.normalize(value)
	if value == nil or type(name) ~= "string" then
		return false
	end
	name = self:key(name)
	local t = self[scope]
	local old = t[name]
	if old == value then
		return false
	end
	t[name] = value
	if scope == "Globals" then
		markPending(self.Pending, name)
	end
	for _, fn in ipairs(self.Listeners) do
		fn(scope, name, old, value, nil)
	end
	return true
end

function Store:addClient(id)
	if self.Clients[id] then
		return self:snapshot(id)
	end
	self.Clients[id] = { Vars = {}, Pending = newPending() }
	self.ClientOrder[#self.ClientOrder + 1] = id
	return self:snapshot(id)
end

function Store:removeClient(id)
	if not self.Clients[id] then
		return
	end
	self.Clients[id] = nil
	for i, v in ipairs(self.ClientOrder) do
		if v == id then
			table.remove(self.ClientOrder, i)
			break
		end
	end
end

function Store:setClient(id, name, value)
	local c = self.Clients[id]
	value = Expr.normalize(value)
	if not c or value == nil or type(name) ~= "string" then
		return false
	end
	name = self:key(name)
	local old = c.Vars[name]
	if old == value then
		return false
	end
	c.Vars[name] = value
	markPending(c.Pending, name)
	for _, fn in ipairs(self.Listeners) do
		fn("Client", name, old, value, id)
	end
	return true
end

function Store:getClient(id, name)
	local k = self.Canon[name:lower()]
	if k == nil then
		return nil
	end
	local c = self.Clients[id]
	if c and c.Vars[k] ~= nil then
		return c.Vars[k]
	end
	return self.Globals[k]
end

local function pairsOf(map)
	local list = {}
	for _, name in ipairs(sortedKeys(map)) do
		list[#list + 1] = { Name = name, Value = map[name] }
	end
	return list
end

-- Everything a client needs when it joins (sorted, so identical state gives identical packets).
function Store:snapshot(id)
	local c = self.Clients[id]
	return { Full = true, Globals = pairsOf(self.Globals), Client = pairsOf(c and c.Vars or {}) }
end

-- Changes since the last flush, coalesced (last value wins), as { [clientId] = packet }. Clients with nothing new are absent.
function Store:flush()
	local packets = {}
	local globals
	if #self.Pending.List > 0 then
		globals = {}
		for _, name in ipairs(self.Pending.List) do
			globals[#globals + 1] = { Name = name, Value = self.Globals[name] }
		end
	end
	for _, id in ipairs(self.ClientOrder) do
		local c = self.Clients[id]
		local own
		if #c.Pending.List > 0 then
			own = {}
			for _, name in ipairs(c.Pending.List) do
				own[#own + 1] = { Name = name, Value = c.Vars[name] }
			end
		end
		if globals or own then
			packets[id] = { Full = false, Globals = globals or {}, Client = own or {} }
		end
		c.Pending = newPending()
	end
	self.Pending = newPending()
	return packets
end

Logic.Store = Store

--------------------------------------------------------------------------------------------------- Reactor

--[[ Re-evaluates an expression whenever a variable it mentions changes (static dependency list: every identifier
	in the expression, a safe superset of what one evaluation reads). `apply(value)` runs on EVERY evaluation —
	assignment is idempotent (Store ignores unchanged values), and an edge detector needs to see each result.
	FIFO queue, registration order: the same mission always settles the same way. A budget stops oscillating logic. ]]
local Reactor = {}
Reactor.__index = Reactor

function Reactor.new(ctx, budget)
	return setmetatable({ Ctx = ctx, Watch = {}, Queue = {}, Head = 1, Tail = 0, Budget = budget or 100000, Evaluations = 0, Settling = false, Count = 0 }, Reactor)
end

function Reactor:mark(b)
	if not b.Dirty then
		b.Dirty = true
		self.Tail += 1
		self.Queue[self.Tail] = b
	end
end

function Reactor:bind(program, apply, label, evalFn)
	local b = { Program = program, Apply = apply, Label = label, Dirty = false, Eval = evalFn }
	for _, name in ipairs(program.Deps) do
		local key = name:lower()
		local list = self.Watch[key]
		if not list then
			list = {}
			self.Watch[key] = list
		end
		list[#list + 1] = b
	end
	self.Count += 1
	self:mark(b)
	return b
end

function Reactor:changed(name)
	local list = self.Watch[name:lower()]
	if list then
		local keep = 0
		for i = 1, #list do
			local b = list[i]
			if not b.Dead then -- a finished wait: drop it from the list as we go
				keep += 1
				list[keep] = b
				self:mark(b)
			end
		end
		for i = #list, keep + 1, -1 do
			list[i] = nil
		end
	end
end

-- true, or false + message when the logic did not settle (the queue is dropped so the host keeps running)
function Reactor:settle()
	if self.Settling then
		return true
	end
	self.Settling = true
	local n, recent = 0, {}
	while self.Head <= self.Tail do
		local b = self.Queue[self.Head]
		self.Queue[self.Head] = nil
		self.Head += 1
		b.Dirty = false
		n += 1
		if n > self.Budget then
			local seen, labels = {}, {}
			for _, l in ipairs(recent) do
				if not seen[l] and #labels < 8 then
					seen[l] = true
					labels[#labels + 1] = l
				end
			end
			for i = self.Head, self.Tail do
				self.Queue[i].Dirty = false
			end
			self.Queue, self.Head, self.Tail = {}, 1, 0
			self.Settling = false
			return false, "logic did not settle after " .. self.Budget .. " evaluations; still changing: " .. table.concat(labels, ", ")
		end
		recent[(n % 32) + 1] = b.Label
		if not b.Dead then
			self.Evaluations += 1
			if b.Eval then
				b.Apply(b.Eval(), b)
			else
				b.Apply(Expr.evaluate(b.Program, self.Ctx), b)
			end
		end
	end
	self.Queue, self.Head, self.Tail = {}, 1, 0
	self.Settling = false
	return true
end

--------------------------------------------------------------------------------------------------- Replica

--[[ The client's copy: replicated Globals + its own client variables. Client-side expression bindings
	(Setup.ClientState) are evaluated HERE, against that view, exactly like the real game does on the client. ]]
local Replica = {}
Replica.__index = Replica

function Replica.new(id, clientSetup, seed, budget)
	local self = setmetatable({ Id = id, Globals = {}, Vars = {}, Errors = {}, Undeclared = {}, Applied = 0, Canon = {} }, Replica)
	self.Ctx = {
		get = function(name)
			local c = self.Canon[name:lower()]
			if c == nil then
				return nil
			end
			local v = self.Vars[c]
			if v == nil then
				v = self.Globals[c]
			end
			return v
		end,
		rng = function(s, min, max)
			return Random.derive(seed or 0, s, min, max)
		end,
		report = function(kind, detail)
			if kind == "undeclared" then
				self.Undeclared[detail] = (self.Undeclared[detail] or 0) + 1
			end
		end,
	}
	self.Reactor = Reactor.new(self.Ctx, budget)
	for _, name in ipairs(sortedKeys(clientSetup)) do
		local program, err = Expr.compile(clientSetup[name])
		self.Vars[self:_key(name)] = 0
		if not program then
			self.Errors[#self.Errors + 1] = { Where = "Setup.ClientState." .. name, Message = err }
		else
			self.Reactor:bind(program, function(v)
				self:_setVar(name, v)
			end, "ClientState." .. name)
		end
	end
	self:settle()
	return self
end

function Replica:_key(name)
	local lo = name:lower()
	local c = self.Canon[lo]
	if c == nil then
		c = name
		self.Canon[lo] = name
	end
	return c
end

function Replica:_setVar(name, v)
	v = Expr.normalize(v)
	name = self:_key(name)
	if v ~= nil and self.Vars[name] ~= v then
		self.Vars[name] = v
		self.Reactor:changed(name)
	end
end

function Replica:settle()
	local ok, err = self.Reactor:settle()
	if not ok then
		self.Errors[#self.Errors + 1] = { Where = "settle", Message = err }
	end
	return ok
end

function Replica:get(name)
	return self.Ctx.get(name)
end

-- Local client-state write (a client's own variable; the server is not told).
function Replica:set(name, value)
	self:_setVar(name, value)
	return self:settle()
end

function Replica:eval(src)
	return Expr.eval(src, self.Ctx)
end

function Replica:apply(packet)
	for _, e in ipairs(packet.Globals or {}) do
		local k = self:_key(e.Name)
		if self.Globals[k] ~= e.Value then
			self.Globals[k] = e.Value
			self.Reactor:changed(k)
		end
	end
	for _, e in ipairs(packet.Client or {}) do
		self:_setVar(e.Name, e.Value)
	end
	self.Applied += 1
	return self:settle()
end

Logic.Replica = Replica

--------------------------------------------------------------------------------------------------- Logic

local L = {}
L.__index = L

local function attrOf(comp, key)
	local v = comp.Attrs and comp.Attrs[key]
	if v == nil then
		return DEFAULTS[comp.Type][key]
	end
	return v
end

local function isBlank(v)
	return v == nil or (type(v) == "string" and not v:match("%S"))
end

function L:_error(where, message)
	self.Errors[#self.Errors + 1] = { Where = where, Message = message }
end

function L:_warn(where, message)
	self.Warnings[#self.Warnings + 1] = { Where = where, Message = message }
end

function L:_compile(src, where)
	local program, err = Expr.compile(src)
	if not program then
		self:_error(where, err)
	end
	return program
end

function L:_emit(ev)
	ev.Time = self.Time
	self.Events[#self.Events + 1] = ev
	if self.OnEvent then
		self.OnEvent(ev)
	end
end

function L:_schedule(at, fn)
	self.Seq += 1
	local task = { At = at, Seq = self.Seq, Fn = fn }
	local tl = self.Timeline
	local lo, hi = 1, #tl + 1
	while lo < hi do -- first index whose (At, Seq) is greater
		local mid = (lo + hi) // 2
		local m = tl[mid]
		if m.At < at or (m.At == at and m.Seq < task.Seq) then
			lo = mid + 1
		else
			hi = mid
		end
	end
	table.insert(tl, lo, task)
	return task
end

function L:_cancel(task)
	task.Cancelled = true
end

--- components: list of { Type, Name, Attrs, Path } — already filtered to the ones that should run.
function Logic.fromSpec(setup, components, opts)
	opts = opts or {}
	local self = setmetatable({}, L)
	self.Setup = setup or {}
	self.Seed = opts.seed or 0
	self.Time = 0
	self.Seq = 0
	self.Timeline = {}
	self.Events = {}
	self.Errors, self.Warnings, self.Undeclared, self.Issues, self.Unsupported = {}, {}, {}, {}, {}
	self.OnEvent = opts.onEvent
	self.MaxTicks = opts.maxTicks or 100000
	self.TimerOnDisable = opts.timerOnDisable or "reset" -- [P] "reset" | "hold"
	self.Counts = { Globals = 0, Internals = 0, ClientState = 0, Components = {} }
	self.Replicas = {}

	local store = Store.new()
	self.Store = store
	self.Objects = {} -- non-replicated object variables (CFrames written by scripts), keyed by lower-case name; they win over Store values
	self.Scripts = {}
	self.GuidCount = 0
	self.ScriptBudget = opts.scriptBudget
	self.Ctx = {
		get = function(name)
			local o = self.Objects[name:lower()]
			if o ~= nil then
				return o
			end
			return store:get(name)
		end,
		arith = CF.arith,
		rng = function(s, min, max)
			return Random.derive(self.Seed, s, min, max)
		end,
		report = function(kind, detail)
			if kind == "undeclared" then
				self.Undeclared[detail] = (self.Undeclared[detail] or 0) + 1
			else
				local key = kind .. ": " .. tostring(detail)
				self.Issues[key] = (self.Issues[key] or 0) + 1
			end
		end,
	}
	local reactor = Reactor.new(self.Ctx, opts.maxSettle)
	self.Reactor = reactor
	store.Listeners[1] = function(scope, name)
		if scope ~= "Client" then
			reactor:changed(name)
		end
	end

	self.ScriptHost = {
		Seed = self.Seed,
		Get = function(name)
			return self.Ctx.get(name)
		end,
		Set = function(name, value)
			self:_scriptSet(name, value)
		end,
		Now = function()
			return self.Time
		end,
		Schedule = function(at, fn)
			return self:_schedule(at, fn)
		end,
		Cancel = function(task)
			self:_cancel(task)
		end,
		Watch = function(deps, evalFn, onValue)
			return reactor:bind({ Deps = deps }, onValue, "script wait", evalFn)
		end,
		Emit = function(ev)
			self:_emit(ev)
		end,
		Report = function(kind, detail)
			self.Ctx.report(kind, detail)
		end,
		Error = function(where, message)
			self:_error(where, message)
		end,
		Guid = function()
			self.GuidCount += 1
			return string.format("%08x-%08x", Random.derive(self.Seed, self.GuidCount * 2, 0, 4294967295), Random.derive(self.Seed, self.GuidCount * 2 + 1, 0, 4294967295))
		end,
		CFrameOf = opts.world and opts.world.cframeOf,
	}

	-- 1. engine-provided variables (Mission_Difficulty, ...) belong to the host and win over Setup
	local builtin, provided = {}, {}
	if opts.defaultBuiltins ~= false then
		for k, v in pairs(Logic.Builtins) do
			provided[k] = v
		end
	end
	for k, v in pairs(opts.builtins or {}) do
		provided[k] = v
	end
	for _, name in ipairs(sortedKeys(provided)) do
		builtin[name] = true
		store:set("Globals", name, provided[name])
	end

	-- 1b. preprocess components (VariableShuffle) run once, before Setup, so Setup and components can read what they assign
	for _, comp in ipairs(components or {}) do
		if comp.Type == "VariableShuffle" then
			self.Counts.Components.VariableShuffle = (self.Counts.Components.VariableShuffle or 0) + 1
			self:_runShuffle(comp, (comp.Path or comp.Name or comp.Type) .. ".")
		end
	end

	-- 2. every Setup entry is a binding `var := expression`: a constant runs once (initial value), an expression
	--    re-runs when what it reads changes, and a self-reference (`X = X || cond`) reads the variable's previous value.
	local pending = {}
	for _, scope in ipairs({ "Globals", "Internals" }) do
		local entries = self.Setup[scope]
		for _, name in ipairs(sortedKeys(entries)) do
			self.Counts[scope] += 1
			if not builtin[name] then
				if store:scopeOf(name) == nil then -- (a preprocess shuffle may already have assigned it)
					store:set(scope, name, 0)
				end
				local program = self:_compile(entries[name], "Setup." .. scope .. "." .. name)
				if program then
					pending[#pending + 1] = { scope = scope, name = name, program = program }
				end
			end
		end
	end
	for _, name in ipairs(sortedKeys(self.Setup.ClientState)) do
		self.Counts.ClientState += 1
		local _, err = Expr.compile(self.Setup.ClientState[name])
		if err then
			self:_error("Setup.ClientState." .. name, err)
		end
	end

	-- 3. a component's output variables exist (as 0) from the start
	local function declare(scope, name)
		if type(name) == "string" and name:match("%S") and store:scopeOf(name) == nil then
			store:set(scope, name, 0)
		end
	end
	for _, comp in ipairs(components or {}) do
		if SUPPORTED[comp.Type] then
			declare("Globals", attrOf(comp, "SetVariable"))
			declare("Internals", attrOf(comp, "SetInternal"))
			declare("Globals", attrOf(comp, "SetFormattedVariable"))
			declare("Globals", attrOf(comp, "CompleteVariable"))
			declare("Globals", attrOf(comp, "FailedVariable"))
			declare("Globals", attrOf(comp, "ActiveVariable"))
			declare("Globals", attrOf(comp, "InactiveVariable"))
			declare("Globals", attrOf(comp, "DebugVariable"))
			declare("Globals", attrOf(comp, "DebugLineVariable"))
		end
	end

	for _, p in ipairs(pending) do
		reactor:bind(p.program, function(v)
			store:set(p.scope, p.name, v)
		end, p.scope .. "." .. p.name)
	end

	-- Setup values (initial constants, derived entries) settle BEFORE any component is built, so a component that
	-- reads one at construction (a timer's StartValue, say) sees its real value.
	self:settle()

	-- 4. components, in document order
	for _, comp in ipairs(components or {}) do
		if SUPPORTED[comp.Type] then
			if comp.Type ~= "VariableShuffle" then
				self.Counts.Components[comp.Type] = (self.Counts.Components[comp.Type] or 0) + 1
			end
			local where = (comp.Path or comp.Name or comp.Type) .. "."
			if comp.Type == "StateUpdate" then
				self:_addStateUpdate(comp, where)
			elseif comp.Type == "Notification" then
				self:_addNotification(comp, where)
			elseif comp.Type == "TimerComponent" then
				self:_addTimer(comp, where)
			elseif comp.Type == "StateScript" then
				self:_addStateScript(comp, where)
			elseif comp.Type == "DelayedStateUpdate" then
				self:_addDelayed(comp, where)
			elseif comp.Type == "ConditionalStateUpdate" then
				self:_addConditional(comp, where)
			elseif comp.Type == "VariableShuffle" then
				-- already run in the preprocess pass
			elseif comp.Type == "MissionCompletionTrigger" then
				self:_addTrigger(comp, where, "Complete", "CompleteVariable")
			else
				self:_addTrigger(comp, where, "Failed", "FailedVariable")
			end
		else
			self.Unsupported[comp.Type] = (self.Unsupported[comp.Type] or 0) + 1
		end
	end

	self:settle()
	return self
end

--------------------------------------------------------------------------------------------------- components

function L:_addStateUpdate(comp, where)
	local watch = attrOf(comp, "Watch")
	if isBlank(watch) then
		self:_warn(where .. "Watch", "StateUpdate has no Watch expression; it does nothing")
		return
	end
	local program = self:_compile(watch, where .. "Watch")
	if not program then
		return
	end
	local targets = {}
	local setVar, setInt = attrOf(comp, "SetVariable"), attrOf(comp, "SetInternal")
	if not isBlank(setVar) then
		targets[#targets + 1] = { "Globals", setVar }
	end
	if not isBlank(setInt) then
		targets[#targets + 1] = { "Internals", setInt }
	end
	if #targets == 0 then
		self:_warn(where, "StateUpdate has neither SetVariable nor SetInternal; it does nothing")
		return
	end
	self.Reactor:bind(program, function(v)
		for _, t in ipairs(targets) do
			self.Store:set(t[1], t[2], v)
		end
	end, comp.Name or "StateUpdate")
end

function L:_addNotification(comp, where)
	local key = attrOf(comp, "Notification")
	if isBlank(key) then
		self:_warn(where .. "Notification", "Notification has no text/key; it does nothing")
		return
	end
	local program = self:_compile(attrOf(comp, "Condition"), where .. "Condition")
	if not program then
		return
	end
	local active = false
	self.Reactor:bind(program, function(v)
		local on = truthy(v)
		if on and not active then -- [P] fires on every rising edge
			local k = Expr.interpolate(key, self.Ctx)
			local strings = self.Setup.CustomStrings
			local text = type(strings) == "table" and strings[k] or nil
			if type(text) == "string" then
				text = Expr.interpolate(text, self.Ctx)
			else
				text = nil
			end
			self:_emit({ Kind = "Notification", Component = comp.Name, Path = comp.Path, Key = k, Text = text })
		end
		active = on
	end, comp.Name or "Notification")
end

function L:_addTrigger(comp, where, kind, varAttr)
	local program = self:_compile(attrOf(comp, "Condition"), where .. "Condition")
	if not program then
		return
	end
	local timeout = toNumber(attrOf(comp, "Timeout"))
	local varName = attrOf(comp, varAttr)
	local task
	local function fire()
		task = nil
		if self.Outcome then
			return
		end
		self.Outcome = { Kind = kind, Component = comp.Name, Path = comp.Path, Time = self.Time }
		if not isBlank(varName) then
			self.Store:set("Globals", varName, 1)
		end
		self:_emit({ Kind = "Mission" .. kind, Component = comp.Name, Path = comp.Path, Variable = (not isBlank(varName)) and varName or nil })
	end
	self.Reactor:bind(program, function(v)
		if truthy(v) then -- [P] the condition must HOLD for Timeout seconds
			if self.Outcome or task then
				return
			end
			if timeout <= 0 then
				fire()
			else
				task = self:_schedule(self.Time + timeout, fire)
			end
		elseif task then
			self:_cancel(task)
			task = nil
		end
	end, comp.Name or kind)
end

function L:_addTimer(comp, where)
	local function compileAttr(name)
		return self:_compile(attrOf(comp, name), where .. name)
	end
	local pEnabled, pPaused, pOffset = compileAttr("Enabled"), compileAttr("Paused"), compileAttr("Offset")
	local pStart, pTarget, pInc, pFreq = compileAttr("StartValue"), compileAttr("TargetValue"), compileAttr("Increment"), compileAttr("Frequency")
	if not (pEnabled and pPaused and pOffset and pStart and pTarget and pInc and pFreq) then
		return
	end
	local setVar, setFmt = attrOf(comp, "SetVariable"), attrOf(comp, "SetFormattedVariable")
	if isBlank(setVar) and isBlank(setFmt) then
		self:_warn(where, "TimerComponent has neither SetVariable nor SetFormattedVariable; its value is invisible")
	end
	local t = { Enabled = false, Paused = false, Offset = 0, Done = false, Base = 0, Task = nil }
	local function num(program)
		return (toNumber(Expr.evaluate(program, self.Ctx)))
	end

	local function publish()
		local out = clean(t.Base + t.Offset)
		if not isBlank(setVar) then
			self.Store:set("Globals", setVar, out)
		end
		if not isBlank(setFmt) then
			self.Store:set("Globals", setFmt, formatTime(out))
		end
	end
	local function cancel()
		if t.Task then
			self:_cancel(t.Task)
			t.Task = nil
		end
	end

	local schedule
	local function tick()
		t.Task = nil
		if not t.Enabled or t.Paused or t.Done then
			return
		end
		local inc, target = num(pInc), num(pTarget)
		t.Base = clean(t.Base + inc)
		local out = clean(t.Base + t.Offset)
		if (inc > 0 and out >= target) or (inc < 0 and out <= target) then
			t.Base = clean(target - t.Offset) -- stop exactly on the target
			t.Done = true
		end
		publish()
		schedule()
	end
	function schedule()
		cancel()
		if not t.Enabled or t.Paused or t.Done then
			return
		end
		if num(pInc) == 0 then
			if not t.WarnedZero then
				t.WarnedZero = true
				self:_warn(where, "TimerComponent Increment is 0; it never advances")
			end
			return
		end
		local f = Expr.evaluate(pFreq, self.Ctx)
		local freq = (f == "" or f == nil) and 1 or math.max(num(pFreq), MIN_FREQUENCY) -- [P] blank = every second
		t.Task = self:_schedule(self.Time + freq, tick)
	end
	local function reset()
		cancel()
		t.Done = false
		t.Base = num(pStart)
		publish()
	end

	reset()
	-- order matters for the first settle: Offset, Paused, then Enabled (whose apply starts the clock)
	self.Reactor:bind(pOffset, function(v)
		local o = (toNumber(v))
		if o ~= t.Offset then
			t.Offset = o
			publish()
		end
	end, (comp.Name or "Timer") .. ".Offset")
	self.Reactor:bind(pPaused, function(v)
		local p = truthy(v)
		if p ~= t.Paused then
			t.Paused = p
			if p then
				cancel()
			else
				schedule()
			end
		end
	end, (comp.Name or "Timer") .. ".Paused")
	self.Reactor:bind(pEnabled, function(v)
		local e = truthy(v)
		if e == t.Enabled then
			return
		end
		t.Enabled = e
		if e then
			-- StartValue is read when the clock starts (always in "reset" mode; the first time in "hold" mode)
			if self.TimerOnDisable == "reset" or not t.Started then
				t.Done = false
				t.Base = num(pStart)
				publish()
			end
			t.Started = true
			schedule()
		elseif self.TimerOnDisable == "reset" then
			reset()
		else
			cancel()
		end
	end, (comp.Name or "Timer") .. ".Enabled")
end

-- Assign a variable in the scope it already lives in (else Globals).
function L:_write(name, value)
	self.Store:set(self.Store:scopeOf(name) or "Globals", name, value)
end

--[[ ConditionalStateUpdate [P]: while Condition is true, ActiveVariable := Watch; while it is false, InactiveVariable := Watch
	(if set). Re-evaluated when Watch or Condition changes. Real use: DiplomatDeadInStealth := DiplomatKilled while
	!Mission_AlarmRaised — so it stops following once the alarm is up. ]]
function L:_addConditional(comp, where)
	local active, inactive = attrOf(comp, "ActiveVariable"), attrOf(comp, "InactiveVariable")
	if isBlank(attrOf(comp, "Watch")) or (isBlank(active) and isBlank(inactive)) then
		self:_warn(where, "ConditionalStateUpdate needs a Watch and an ActiveVariable or InactiveVariable; it does nothing")
		return
	end
	local pWatch = self:_compile(attrOf(comp, "Watch"), where .. "Watch")
	local pCond = self:_compile(attrOf(comp, "Condition"), where .. "Condition")
	if not (pWatch and pCond) then
		return
	end
	local deps, seen = {}, {}
	for _, p in ipairs({ pWatch, pCond }) do
		for _, d in ipairs(p.Deps) do
			if not seen[d] then
				seen[d] = true
				deps[#deps + 1] = d
			end
		end
	end
	self.Reactor:bind({ Deps = deps }, function(r)
		if truthy(r.Condition) then
			if not isBlank(active) then
				self:_write(active, r.Watch)
			end
		elseif not isBlank(inactive) then
			self:_write(inactive, r.Watch)
		end
	end, comp.Name or "ConditionalStateUpdate", function()
		return { Condition = Expr.evaluate(pCond, self.Ctx), Watch = Expr.evaluate(pWatch, self.Ctx) }
	end)
end

--[[ DelayedStateUpdate [P]: SetVariable := Watch, DelayTime seconds after Watch last changed to that value.
	OnlyMatch = false is a pure delay line (every change arrives, in order: the Diplomat's 1 s "ForgeDelay" staircase);
	OnlyMatch = true applies the value only if Watch STILL has it when the delay ends (a change in between cancels it). ]]
function L:_addDelayed(comp, where)
	local var = attrOf(comp, "SetVariable")
	if isBlank(attrOf(comp, "Watch")) or isBlank(var) then
		self:_warn(where, "DelayedStateUpdate needs a Watch and a SetVariable; it does nothing")
		return
	end
	local pWatch = self:_compile(attrOf(comp, "Watch"), where .. "Watch")
	local pDelay = self:_compile(attrOf(comp, "DelayTime"), where .. "DelayTime")
	if not (pWatch and pDelay) then
		return
	end
	local onlyMatch = truthy(Expr.normalize(attrOf(comp, "OnlyMatch")) or 0)
	local seen, last = false, nil
	self.Reactor:bind(pWatch, function(v)
		if seen and v == last then
			return -- re-evaluated, but not a change
		end
		seen, last = true, v
		local delay = (toNumber(Expr.evaluate(pDelay, self.Ctx)))
		if delay <= 0 then
			self:_write(var, v)
			return
		end
		self:_schedule(self.Time + delay, function()
			if onlyMatch and Expr.evaluate(pWatch, self.Ctx) ~= v then
				return
			end
			self:_write(var, v)
		end)
	end, comp.Name or "DelayedStateUpdate")
end

--[[ VariableShuffle [P, shape confirmed by real maps]: Set0 and Set1 are `|` lists. A seeded shuffle of Set1 is dealt
	round-robin over Set0 (so every Set0 key gets a value, and with |Set1| >= |Set0| it is a permutation).
	Prefix0 .. key := value     (Diplomat: Guard7 := "WingPatrol", read as {Guard7} by a script)
	Prefix1 .. value := key     if Prefix1 is set (Peacemaker: RoleTechLead := "Sci3", read as RoleTechLead == [SciINDEX])
	Numeric strings are stored as numbers. InternalOnly puts the results in Internals (not replicated). ]]
function L:_runShuffle(comp, where)
	local function split(text)
		local out = {}
		if type(text) == "number" then
			text = tostring(text)
		end
		for piece in tostring(text or ""):gmatch("[^|]+") do
			out[#out + 1] = piece:match("^%s*(.-)%s*$")
		end
		return out
	end
	local set0, set1 = split(attrOf(comp, "Set0")), split(attrOf(comp, "Set1"))
	if #set0 == 0 or #set1 == 0 then
		self:_warn(where, "VariableShuffle needs Set0 and Set1; it does nothing")
		return
	end
	local pSeed = self:_compile(attrOf(comp, "Seed"), where .. "Seed")
	if not pSeed then
		return
	end
	local stream = Random.new(Random.derive(self.Seed, Random.toSeed(Expr.evaluate(pSeed, self.Ctx)), 0, 4294967295))
	local deck = table.clone(set1)
	for i = #deck, 2, -1 do
		local j = stream:nextInt(1, i)
		deck[i], deck[j] = deck[j], deck[i]
	end
	local scope = truthy(Expr.normalize(attrOf(comp, "InternalOnly")) or 0) and "Internals" or "Globals"
	local prefix0, prefix1 = tostring(attrOf(comp, "Prefix0") or ""), tostring(attrOf(comp, "Prefix1") or "")
	local function typed(x)
		local n = tonumber(x)
		return n ~= nil and n or x
	end
	for i, key in ipairs(set0) do
		local value = deck[(i - 1) % #deck + 1]
		self.Store:set(scope, prefix0 .. key, typed(value))
		if prefix1 ~= "" then
			self.Store:set(scope, prefix1 .. value, typed(key))
		end
	end
end

function L:_scriptSet(name, value)
	local lo = name:lower()
	if type(value) == "table" then
		self.Objects[lo] = value
		self.Reactor:changed(name)
		return
	end
	if self.Objects[lo] ~= nil then
		self.Objects[lo] = nil
		self.Reactor:changed(name)
	end
	self.Store:set(self.Store:scopeOf(name) or "Globals", name, value)
end

--[[ StateScript. Two independent start modes (main doc §7.4):
	Run           runs a thread while the expression is non-zero: starts on the rising edge, is killed when it falls
	TriggerEvent  a fresh thread on every change to a non-zero value
	Both may be set (all four real scripts do); they then work side by side [P]. Every other attribute is a parameter (#Name). ]]
function L:_addStateScript(comp, where)
	local source = attrOf(comp, "ScriptSource")
	if isBlank(source) then
		self:_warn(where .. "ScriptSource", "StateScript has no source; it does nothing")
		return
	end
	local program = Script.compile(source, comp.Name)
	for _, p in ipairs(program.Problems) do
		self:_warn(where .. "ScriptSource line " .. p.Line, p.Message)
	end
	local params = {}
	for k, v in pairs(comp.Attrs or {}) do
		if not Script.Reserved[k] then
			params[k] = Expr.normalize(v) or v
		end
	end
	local inst = Script.new(program, self.ScriptHost, {
		Name = comp.Name, Path = comp.Path, Params = params, Budget = self.ScriptBudget,
		DebugVariable = attrOf(comp, "DebugVariable"), DebugLineVariable = attrOf(comp, "DebugLineVariable"),
	})
	self.Scripts[#self.Scripts + 1] = inst
	local runSrc, evSrc = attrOf(comp, "Run"), attrOf(comp, "TriggerEvent")
	if isBlank(runSrc) and isBlank(evSrc) then
		self:_warn(where, "StateScript has neither Run nor TriggerEvent; it never starts")
		return
	end
	if not isBlank(runSrc) then
		local pRun = self:_compile(runSrc, where .. "Run")
		if pRun then
			local active, thread = false, nil
			self.Reactor:bind(pRun, function(v)
				local on = truthy(v)
				if on and not active then
					active = true
					thread = inst:spawn()
				elseif not on and active then
					active = false
					if thread then
						inst:kill(thread)
						thread = nil
					end
				end
			end, (comp.Name or "StateScript") .. ".Run")
		end
	end
	if not isBlank(evSrc) then
		local pEv = self:_compile(evSrc, where .. "TriggerEvent")
		if pEv then
			local last
			self.Reactor:bind(pEv, function(v)
				if truthy(v) and v ~= last then
					inst:spawn()
				end
				last = v
			end, (comp.Name or "StateScript") .. ".TriggerEvent")
		end
	end
end

--------------------------------------------------------------------------------------------------- public API

local function collect(mission, folderNames)
	local active, unsupported = {}, {}
	for _, fname in ipairs(folderNames) do
		local folder = mission:folder(fname)
		if folder then
			local function walk(node)
				for _, ch in ipairs(node.Children) do
					if ch.ClassName == "BoolValue" and ch.Attrs and ch.Attrs.Type then
						local ty = ch.Attrs.Type
						if SUPPORTED[ty] then
							active[#active + 1] = { Type = ty, Name = ch.Name, Attrs = ch.Attrs, Path = ch.Path, Id = ch.Id }
						else
							unsupported[ty] = (unsupported[ty] or 0) + 1
						end
					end
					walk(ch)
				end
			end
			walk(folder)
		end
	end
	return active, unsupported
end

--[[ opts:
	seed              mission seed for RNG (default 0)
	builtins          { Mission_Difficulty = 1, ... } engine-provided variables; they win over Setup. Logic.Builtins holds
	                  defaults for the seven the real maps read; opts.defaultBuiltins = false turns those off
	componentFolders  top-level folders whose components run (default { "StateComponents" })
	preprocessFolders folders searched for preprocess components, VariableShuffle (default { "StateComponentsPreprocess" })
	onEvent           function(event), called as events happen (they are also queued for drainEvents)
	timerOnDisable    "reset" (default) | "hold" — what a TimerComponent does when Enabled turns false  [P]
	world             { cframeOf = function(tag) -> CFrame | nil }  lets CFRCOPY read prop positions (a Logic.CF value)
	scriptBudget      instructions a StateScript thread may run without waiting (default 10000)
	maxSettle         evaluation budget per settle (default 100000)
	maxTicks          scheduled actions per advance() (default 100000) ]]
function Logic.new(mission, opts)
	opts = opts or {}
	if type(mission) ~= "table" or type(mission.folder) ~= "function" then
		return nil, "BreachLogic: expected a BreachMission model (Mission.build(...))"
	end
	local pre, preUnsupported = collect(mission, opts.preprocessFolders or { "StateComponentsPreprocess" })
	local active, unsupported = collect(mission, opts.componentFolders or { "StateComponents" })
	for ty, n in pairs(preUnsupported) do
		unsupported[ty] = (unsupported[ty] or 0) + n
	end
	local all = {}
	for _, c in ipairs(pre) do
		if c.Type == "VariableShuffle" then all[#all + 1] = c end -- the only preprocess type implemented
	end
	for _, c in ipairs(active) do
		all[#all + 1] = c
	end
	local self = Logic.fromSpec(mission.Setup, all, opts)
	for ty, n in pairs(unsupported) do
		self.Unsupported[ty] = n
	end
	return self
end

function L:settle()
	local ok, err = self.Reactor:settle()
	if not ok then
		self:_error("settle", err)
	end
	return ok
end

function L:get(name)
	return self.Store:get(name)
end

-- Host/gameplay write; settles so everything that reads the variable updates. Unknown names become Globals.
function L:set(name, value)
	if Expr.normalize(value) == nil then
		return false
	end
	if self.Objects[name:lower()] ~= nil then -- a host write replaces a CFrame variable
		self.Objects[name:lower()] = nil
	end
	self.Store:set(self.Store:scopeOf(name) or "Globals", name, value)
	return self:settle()
end

function L:eval(src)
	return Expr.eval(src, self.Ctx)
end

-- Run time forward. Scheduled actions fire in time order, each at its own exact time, and the variables settle after each.
function L:advance(dt)
	if type(dt) ~= "number" or dt < 0 then
		return false
	end
	self:settle()
	local target = self.Time + dt
	local ran = 0
	while true do
		local task = self.Timeline[1]
		while task and task.Cancelled do
			table.remove(self.Timeline, 1)
			task = self.Timeline[1]
		end
		if not task or task.At > target + EPS then
			break
		end
		table.remove(self.Timeline, 1)
		if task.At > self.Time then
			self.Time = task.At
		end
		task.Fn()
		self:settle()
		ran += 1
		if ran >= self.MaxTicks then
			self:_error("advance", "more than " .. self.MaxTicks .. " scheduled actions in one advance(); the rest are deferred")
			break
		end
	end
	if target > self.Time then
		self.Time = target
	end
	return true
end

-- Hooks for layers built on top of the logic core (BreachProps):
-- watch: call onValue(value) whenever the expression's value is (re)evaluated, i.e. at the next settle and whenever a variable it reads changes
function L:watch(src, onValue, label)
	local program = self:_compile(src, label or "watch")
	if not program then
		return nil
	end
	return self.Reactor:bind(program, onValue, label or "watch")
end

-- after: run fn after `seconds` of simulated time (cancellable: returns a task for Logic's scheduler)
function L:after(seconds, fn)
	return self:_schedule(self.Time + seconds, fn)
end

-- emit: queue an event for drainEvents() / onEvent
function L:emit(ev)
	self:_emit(ev)
end

function L:drainEvents()
	local ev = self.Events
	self.Events = {}
	return ev
end

--- Replication. addClient attaches an in-process Replica that already holds the full snapshot.
function L:addClient(id)
	local replica = Replica.new(id, self.Setup.ClientState, self.Seed, self.Reactor.Budget)
	local snapshot = self.Store:addClient(id)
	self.Replicas[id] = replica
	replica:apply(snapshot)
	return replica
end

function L:removeClient(id)
	self.Store:removeClient(id)
	self.Replicas[id] = nil
end

function L:setClient(id, name, value)
	return self.Store:setClient(id, name, value)
end

-- Raw packets { [clientId] = packet } for hosts that send them over a network.
function L:flush()
	return self.Store:flush()
end

-- Flush and deliver to every attached Replica; returns the packets too.
function L:replicate()
	local packets = self.Store:flush()
	for id, packet in pairs(packets) do
		local r = self.Replicas[id]
		if r then
			r:apply(packet)
		end
	end
	return packets
end

-- Counts for reports and tests.
function L:summary()
	local unsupported = 0
	for _, n in pairs(self.Unsupported) do
		unsupported += n
	end
	local undeclared = 0
	for _ in pairs(self.Undeclared) do
		undeclared += 1
	end
	return {
		Globals = self.Counts.Globals, Internals = self.Counts.Internals, ClientState = self.Counts.ClientState,
		Components = self.Counts.Components, Unsupported = unsupported, UndeclaredNames = undeclared,
		Bindings = self.Reactor.Count, Evaluations = self.Reactor.Evaluations,
		Errors = #self.Errors, Warnings = #self.Warnings, Time = self.Time,
	}
end

return Logic
