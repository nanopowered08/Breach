--!nonstrict
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
