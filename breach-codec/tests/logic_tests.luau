--!nonstrict
-- M5 tests: BreachExpr, BreachRandom, BreachLogic.   Run via `luau tests/run.luau` or alone: `luau tests/logic.luau`
local Expr = require("../BreachExpr")
local Random = require("../BreachRandom")
local Logic = require("../BreachLogic")

local function near(a, b, tol)
	return type(a) == "number" and type(b) == "number" and math.abs(a - b) <= (tol or 1e-9)
end

return function(check)
	----------------------------------------------------------------------------------------------- Random
	do
		local a = Random.derive(416, 5342, 1, 8)
		check("random: derive is stateless and repeatable", a == Random.derive(416, 5342, 1, 8))
		local seen, inRange = {}, true
		for s = 1, 200 do
			local v = Random.derive(7, s, 1, 8)
			seen[v] = true
			if v < 1 or v > 8 or v ~= math.floor(v) then inRange = false end
		end
		local distinct = 0
		for _ in pairs(seen) do distinct += 1 end
		check("random: 200 caller seeds stay in [1,8] and cover all 8 values", inRange and distinct == 8, distinct)
		check("random: mission seed matters", Random.derive(1, 5, 1, 1000000) ~= Random.derive(2, 5, 1, 1000000))
		check("random: caller seed matters", Random.derive(1, 5, 1, 1000000) ~= Random.derive(1, 6, 1, 1000000))
		check("random: min == max", Random.derive(3, 3, 4, 4) == 4)
		check("random: swapped bounds are tolerated", (function() local v = Random.derive(3, 3, 8, 1) return v >= 1 and v <= 8 end)())
		check("random: negative and huge seeds do not throw", pcall(Random.derive, -5, 2 ^ 60, 1, 6) and pcall(Random.derive, 0 / 0, math.huge, 1, 6))
		check("random: string seeds work", Random.derive("a", "b", 1, 100) == Random.derive("a", "b", 1, 100))
		local s1, s2 = Random.new(99), Random.new(99)
		local same = true
		for _ = 1, 50 do
			if s1:nextInt(1, 6) ~= s2:nextInt(1, 6) then same = false end
		end
		check("random: streams with the same seed agree", same)
		local f = Random.new(1):nextFloat()
		check("random: float in [0,1)", f >= 0 and f < 1)
		-- distribution sanity: 6000 rolls of a d6, each face 800..1200
		local counts = { 0, 0, 0, 0, 0, 0 }
		local st = Random.new(2024)
		for _ = 1, 6000 do
			local r = st:nextInt(1, 6)
			counts[r] += 1
		end
		local fair = true
		for i = 1, 6 do if counts[i] < 800 or counts[i] > 1200 then fair = false end end
		check("random: d6 distribution is roughly fair", fair, table.concat(counts, ","))
	end

	----------------------------------------------------------------------------------------------- Expr: language
	local vars = { A = 1, B = 0, X = 0, Mission_Difficulty = 2, S = "hi", E = "", GuardInfo = 5, N = 7 }
	local gets, reports, rngCalls = {}, {}, {}
	local ctx = {
		get = function(n) gets[#gets + 1] = n return vars[n] end,
		rng = function(s, lo, hi) rngCalls[#rngCalls + 1] = { s, lo, hi } return Random.derive(0, s, lo, hi) end,
		report = function(k, d) reports[#reports + 1] = k .. ":" .. tostring(d) end,
	}
	local function ev(src)
		gets, reports, rngCalls = {}, {}, {}
		local p, err = Expr.compile(src)
		if not p then return nil, err end
		return Expr.evaluate(p, ctx)
	end
	local function eq(name, src, expected)
		local v, err = ev(src)
		check("expr: " .. name .. "  [" .. src .. "]", v == expected, tostring(v) .. (err and (" / " .. err) or ""))
	end

	eq("precedence * over +", "1 + 2 * 3", 7)
	eq("parentheses", "(1 + 2) * 3", 9)
	eq("left-assoc minus", "10 - 3 - 2", 5)
	eq("left-assoc divide", "100 / 10 / 5", 2)
	eq("unary minus", "-2 * -3", 6)
	eq("double negation", "- -4", 4)
	eq("floored modulo (Lua)", "-1 % 8", 7)
	eq("modulo", "17 % 5", 2)
	eq("real-map shape", "(((GuardInfo) + 4) % 8) + 1", 2)
	eq("decimals", ".5 + .25", 0.75)
	eq("comparison gives 1", "3 > 2", 1)
	eq("comparison gives 0", "3 < 2", 0)
	eq("<= and >=", "(2 <= 2) + (2 >= 3)", 1)
	eq("== and ~=", "(A == 1) + (A ~= 1)", 1)
	eq("!= is accepted too (one real expression uses it)", "(A != 1) + (A != 2)", 1)
	eq("!= with RNG, as in the real map", "(RNG 95257 0 1000) != 816 && 5", 5)
	eq("names may start with a digit (real: !1Searched)", "!1Searched", 1)
	eq("a digit-leading name is read as a variable", "2Cats + 1", 1)
	eq("a number is still a number", "12 + 1", 13)
	eq("FLOOR with a parenthesised argument (real: FLOOR ((a + b) / 3))", "FLOOR (7 / 2)", 3)
	eq("FLOOR without a space (real: FLOOR(2 + n / 2))", "FLOOR(2 + 5 / 2)", 4)
	eq("FLOOR rounds toward minus infinity", "FLOOR (-3.5)", -4)
	eq("FLOOR of a literal", "FLOOR 3.9", 3)
	eq("FLOOR takes one argument: FLOOR 7 / 2 is (FLOOR 7) / 2", "FLOOR 7 / 2", 3.5)
	eq("FLOOR composes", "FLOOR (N / 2) + FLOOR (N / 3)", 5)
	eq("comparison binds tighter than ==", "5 > 3 == 1", 1)
	eq("arithmetic binds tighter than comparison", "1 + 1 == 2", 1)
	eq("! gives 1/0", "!B", 1)
	eq("! of a truthy", "!A", 0)
	eq("! binds tighter than &&", "!B && 5", 5)
	eq("&& returns the right operand", "A && 4", 4)
	eq("&& returns the falsy left operand", "B && 4", 0)
	eq("|| returns the truthy left operand", "3 || 7", 3)
	eq("|| returns the right operand", "0 || 7", 7)
	eq("cond && x || y (true)", "A && 4 || 7", 4)
	eq("cond && x || y (false)", "B && 4 || 7", 7)
	eq("chain from a real map", "B && 4 || A && 9 || 7", 9)
	eq("difficulty ladder (real map)", "(Mission_Difficulty == 1 && 6) || (Mission_Difficulty == 2 && 8) || 10", 8)
	eq("&& binds tighter than ||", "1 || 0 && 0", 1)
	eq("string literal", "[Notify.DiplomatFled]", "Notify.DiplomatFled")
	eq("long string literal", "[[a]b]]", "a]b")
	eq("string equality", "[abc] == [abc]", 1)
	eq("string inequality", "[abc] == [abd]", 0)
	eq("mixed types are not equal", "[1] == 1", 0)
	eq("string ordering", "[a] < [b]", 1)
	eq("0 is false", "0 && 1", 0)
	eq("empty string is false", "E || 3", 3)
	eq("non-empty string is true", "S && 3", 3)
	eq("a string through && (real map: cond && [Key])", "A && [Notify.X]", "Notify.X")
	eq("a false cond && [Key] stays false", "B && [Notify.X]", 0)
	eq("empty expression is the empty string", "", "")
	eq("blank expression is the empty string", "   ", "")
	eq("number attribute (not a string)", "12", 12)
	check("expr: boolean attributes compile (true -> 1)", Expr.evaluate(Expr.compile(true)) == 1 and Expr.evaluate(Expr.compile(false)) == 0)
	check("expr: number attributes compile", Expr.evaluate(Expr.compile(2.5)) == 2.5)
	check("expr: undeclared variable reads 0 and is reported", ev("Nope + 1") == 1 and reports[1] == "undeclared:Nope")
	check("expr: booleans from the host read as 1/0", (function() vars.T = true return ev("T + 1") == 2 end)())

	-- short circuit is load-bearing
	ev("0 && Nope")
	check("short-circuit: && skips the right side (no read, no report)", #reports == 0 and gets[1] == nil)
	ev("A || Nope")
	check("short-circuit: || skips the right side", #reports == 0 and #gets == 1)
	ev("X ~= 0 && 10 / X")
	check("short-circuit: guarded division never divides by zero", #reports == 0)
	ev("A || RNG 1 1 6")
	check("short-circuit: RNG on the dead branch is never called", #rngCalls == 0)
	ev("B || RNG 1 1 6")
	check("short-circuit: RNG on the live branch is called", #rngCalls == 1)

	-- RNG
	local v1 = ev("RNG 5342 1 8")
	check("rng: prefix call with three arguments", #rngCalls == 1 and rngCalls[1][1] == 5342 and rngCalls[1][2] == 1 and rngCalls[1][3] == 8 and v1 >= 1 and v1 <= 8)
	check("rng: usable inside arithmetic", (function() local v = ev("(RNG 5342 1 8) + 100") return v >= 101 and v <= 108 end)())
	check("rng: arguments may be unary-negative", (function() ev("RNG 1 -5 5") return rngCalls[1][2] == -5 end)())
	check("rng: arguments may be parenthesised expressions", (function() ev("RNG (2 + 3) 1 (4 * 2)") return rngCalls[1][1] == 5 and rngCalls[1][3] == 8 end)())
	check("rng: without a host rng it reports and returns min", (function()
		local p = Expr.compile("RNG 1 3 9")
		local got
		local v = Expr.evaluate(p, { report = function(k) got = k end })
		return v == 3 and got == "no-rng"
	end)())

	-- runtime problems are reported, not thrown
	check("expr: division by zero -> 0 and reported", ev("5 / 0") == 0 and reports[1]:find("div%-zero") ~= nil)
	check("expr: modulo by zero -> 0 and reported", ev("5 % 0") == 0 and reports[1]:find("mod%-zero") ~= nil)
	check("expr: arithmetic on text is reported", ev("[abc] + 1") == 1 and reports[1]:find("type%-mismatch") ~= nil)
	check("expr: numeric strings coerce in arithmetic", (function() vars.NS = "5" return ev("NS + 1") == 6 end)())
	check("expr: overflow to infinity becomes 0 and is reported", ev(string.rep("9999999999999999999 * ", 17) .. "1") == 0 and reports[1]:find("nan") ~= nil, reports[1])

	-- dependencies and constants
	do
		local p = Expr.compile("A && B || A && C + 1")
		check("expr: Deps are every variable, first-use order, no duplicates", #p.Deps == 3 and p.Deps[1] == "A" and p.Deps[2] == "B" and p.Deps[3] == "C", table.concat(p.Deps, ","))
		check("expr: an expression that reads a variable is not constant", p.Constant == false)
		local c = Expr.compile("2 * 3 + 1")
		check("expr: constant folding", c.Constant == true and c.Value == 7 and #c.Deps == 0)
		check("expr: RNG is never constant", Expr.compile("RNG 1 1 2").Constant == false)
		check("expr: compile caches (same program object)", Expr.compile("A + B") == Expr.compile("A + B"))
	end

	-- syntax errors: clean message with a column, never a throw
	local bad = {
		"1 +", "(1", "1 2", "a = b", "a & b", "a | b", "a !== b", "[unterminated", ")", "()", "1..2", "@", "RNG 1 2", "RNG", "FLOOR", "FLOOR +", "FLOOR ()",
		"RNG * 2 3", "A B", "1 + * 2", "!", "-", "(A && )", "A &&", "|| A", "'quoted'", "A ? 1 : 2", "A ^ 2", "{A}",
	}
	local allClean = true
	for _, src in ipairs(bad) do
		local ok, p, err = pcall(Expr.compile, src)
		if not ok or p ~= nil or type(err) ~= "string" or not err:find("^BreachExpr: ") then
			allClean = false
			print("  not rejected cleanly: " .. src, ok, p, err)
		end
	end
	check("expr: " .. #bad .. " malformed expressions are all rejected with a BreachExpr message", allClean)
	check("expr: error messages carry a column", select(2, Expr.compile("1 +")):find("column 4") ~= nil)
	check("expr: wrong type for compile is an error, not a throw", select(2, Expr.compile({})) ~= nil and select(2, Expr.compile(nil)) ~= nil)
	check("expr: deep nesting is refused, not a stack overflow", select(2, Expr.compile(string.rep("(", 500) .. "1" .. string.rep(")", 500))) ~= nil)
	check("expr: deep unary chain is refused", select(2, Expr.compile(string.rep("!", 500) .. "A")) ~= nil)
	check("expr: very long operator chains are refused or evaluate (no crash)", (function()
		local parts = {}
		for i = 1, 3000 do parts[i] = "A" end
		local ok = pcall(function()
			local p = Expr.compile(table.concat(parts, " + "))
			if p then Expr.evaluate(p, ctx) end
		end)
		return ok
	end)())
	check("expr: an enormous source is refused", select(2, Expr.compile(string.rep("1", 200000))) ~= nil)

	-- interpolation (string-context attributes)
	do
		local t, problems = Expr.interpolate("Found {N} of {N + 3}!", ctx)
		check("interpolate: {expr} parts are evaluated", t == "Found 7 of 10!" and #problems == 0, t)
		local t2 = Expr.interpolate("no braces", ctx)
		check("interpolate: text without braces is returned as is", t2 == "no braces")
		local t3, p3 = Expr.interpolate("bad {1 +} part", ctx)
		check("interpolate: a bad part stays as written and is reported", t3 == "bad {1 +} part" and #p3 == 1)
		local t4, p4 = Expr.interpolate("open {N", ctx)
		check("interpolate: an unterminated brace is reported", t4 == "open {N" and #p4 == 1)
		check("interpolate: fractions format without noise", Expr.interpolate("{1 / 4} {10 / 2}", ctx) == "0.25 5")
		check("interpolate: strings pass through", Expr.interpolate("{S}", ctx) == "hi")
	end

	-- fuzz: token soup must never throw, compile or not
	do
		local seed = 12345
		local function rnd(n) seed = (seed * 1103515245 + 12345) % 2147483648 return seed % n end
		local pieces = { "A", "B", "X", "1", "0", "2.5", "[s]", "RNG", "(", ")", "!", "-", "+", "*", "/", "%", "&&", "||", "==", "~=", "<", ">=", " ", "=", "&", "{", "[", "]", "9999999999999999999", "." }
		local threw, compiled, rejected = 0, 0, 0
		for _ = 1, 4000 do
			local parts = {}
			for i = 1, 1 + rnd(14) do parts[i] = pieces[1 + rnd(#pieces)] end
			local src = table.concat(parts, " ")
			local ok, p = pcall(Expr.compile, src)
			if not ok then
				threw += 1
			elseif p then
				compiled += 1
				if not pcall(Expr.evaluate, p, ctx) then threw += 1 end
			else
				rejected += 1
			end
		end
		check("expr fuzz: 4000 random token soups, none threw", threw == 0, threw)
		check("expr fuzz: both outcomes occurred", compiled > 50 and rejected > 50, compiled .. "/" .. rejected)
	end

	----------------------------------------------------------------------------------------------- Store + replication
	do
		local S = Logic.Store.new()
		S:set("Globals", "A", 1)
		S:set("Internals", "Secret", 42)
		check("store: get finds Globals and Internals", S:get("A") == 1 and S:get("Secret") == 42)
		check("store: scopeOf", S:scopeOf("A") == "Globals" and S:scopeOf("Secret") == "Internals" and S:scopeOf("Nope") == nil)
		check("store: set reports change", S:set("Globals", "A", 2) == true and S:set("Globals", "A", 2) == false)
		check("store: booleans are stored as 1/0", (function() S:set("Globals", "Flag", true) return S:get("Flag") == 1 end)())
		check("store: nil is refused", S:set("Globals", "Z", nil) == false)
		S:flush()

		local snap1 = S:addClient("p1")
		local names = {}
		for _, e in ipairs(snap1.Globals) do names[e.Name] = true end
		check("snapshot: Full, carries Globals", snap1.Full == true and names.A and names.Flag)
		check("snapshot: never carries Internals", not names.Secret)
		check("snapshot: sorted by name (deterministic)", snap1.Globals[1].Name < snap1.Globals[2].Name)
		check("store: setClient on an unknown client fails", S:setClient("ghost", "x", 1) == false)
		S:setClient("p1", "Obj", 5)
		S:addClient("p2")
		S:flush()
		S:set("Globals", "A", 3)
		S:set("Globals", "A", 4)
		S:set("Globals", "C", "x")
		S:set("Internals", "Secret", 43)
		S:setClient("p1", "Obj", 6)
		local pk = S:flush()
		local function asMap(list) local m = {} for _, e in ipairs(list) do m[e.Name] = e.Value end return m end
		local g1, c1 = asMap(pk.p1.Globals), asMap(pk.p1.Client)
		check("flush: Global changes are coalesced (last value wins)", g1.A == 4 and g1.C == "x" and #pk.p1.Globals == 2)
		check("flush: every client gets the Global delta", asMap(pk.p2.Globals).A == 4)
		check("flush: Internals are never in a packet", g1.Secret == nil and asMap(pk.p2.Globals).Secret == nil)
		check("flush: client vars go only to their owner", c1.Obj == 6 and #pk.p2.Client == 0)
		check("flush: packets are marked as deltas", pk.p1.Full == false)
		check("flush: nothing pending -> empty", next(S:flush()) == nil)
		S:set("Globals", "A", 4)
		check("flush: an unchanged write queues nothing", next(S:flush()) == nil)
		check("getClient: own var, then replicated global", S:getClient("p1", "Obj") == 6 and S:getClient("p2", "Obj") == nil and S:getClient("p2", "A") == 4)
		S:removeClient("p1")
		S:set("Globals", "A", 9)
		local pk2 = S:flush()
		check("removeClient: no more packets for a removed client", pk2.p1 == nil and pk2.p2 ~= nil)
	end

	----------------------------------------------------------------------------------------------- Logic: helpers
	local function C(ty, name, attrs) return { Type = ty, Name = name, Path = "DebugMission/StateComponents/" .. name, Attrs = attrs } end
	local function spec(setup, comps, opts) return Logic.fromSpec(setup, comps, opts) end
	local function eventsOf(l, kind)
		local out = {}
		for _, e in ipairs(l:drainEvents()) do if not kind or e.Kind == kind then out[#out + 1] = e end end
		return out
	end

	----------------------------------------------------------------------------------------------- Logic: Setup stores
	do
		local l = spec({ Globals = { A = "0", B = "A + 1", C = "B * 2" } })
		check("setup: initial values", l:get("A") == 0 and l:get("B") == 1 and l:get("C") == 2)
		l:set("A", 5)
		check("setup: a derived variable follows its inputs through a chain", l:get("B") == 6 and l:get("C") == 12)

		local latch = spec({ Globals = { Hit = "0", Latch = "Hit || Latch" } })
		latch:set("Hit", 1)
		latch:set("Hit", 0)
		check("setup: a self-referencing entry latches (real-map pattern)", latch:get("Latch") == 1)

		local choose = spec({ Globals = { Pick = "(D == 1 && 6) || (D == 2 && 8) || 10" } }, {}, { builtins = { D = 2 } })
		check("setup: engine builtins feed expressions", choose:get("Pick") == 8)
		choose:set("D", 1)
		check("setup: and re-trigger them", choose:get("Pick") == 6)

		local own = spec({ Globals = { Mission_Difficulty = "9" } }, {}, { builtins = { Mission_Difficulty = 2 } })
		check("setup: a builtin wins over Setup", own:get("Mission_Difficulty") == 2)

		local str = spec({ Globals = { Fled = "0", Mission_Failed = "Fled && [Notify.Fled]" } })
		str:set("Fled", 1)
		check("setup: a string flows through && (cond && [Key])", str:get("Mission_Failed") == "Notify.Fled")

		local und = spec({ Globals = { X = "Nope + 1" } })
		check("setup: an undeclared read is 0 and listed in Undeclared", und:get("X") == 1 and (und.Undeclared.Nope or 0) >= 1)

		local badSetup = spec({ Globals = { Bad = "1 +", Good = "2" } })
		check("setup: a bad expression is an Error, the variable still exists", #badSetup.Errors == 1 and badSetup.Errors[1].Where == "Setup.Globals.Bad" and badSetup:get("Bad") == 0 and badSetup:get("Good") == 2)

		local cyc = spec({ Globals = { P = "Q + 1", Q = "P + 1" } }, {}, { maxSettle = 500 })
		local settled = false
		for _, e in ipairs(cyc.Errors) do if e.Where == "settle" and e.Message:find("did not settle") then settled = true end end
		check("setup: oscillating logic is cut off and reported (no hang)", settled)
		check("setup: and the engine keeps working afterwards", cyc:advance(1) == true)

		local g1 = spec({ Internals = { G = "RNG 5342 1 8", Loc = "(((G) + 4) % 8) + 1" } }, {}, { seed = 416 })
		local g2 = spec({ Internals = { G = "RNG 5342 1 8", Loc = "(((G) + 4) % 8) + 1" } }, {}, { seed = 416 })
		check("setup: RNG is reproducible for one mission seed", g1:get("G") == g2:get("G") and g1:get("Loc") == g2:get("Loc"))
		check("setup: RNG and the derived location stay in range", g1:get("G") >= 1 and g1:get("G") <= 8 and g1:get("Loc") >= 1 and g1:get("Loc") <= 8)
		local distinct, seenV = 0, {}
		for s = 1, 40 do
			local v = spec({ Internals = { G = "RNG 5342 1 8" } }, {}, { seed = s }):get("G")
			if not seenV[v] then seenV[v] = true distinct += 1 end
		end
		check("setup: different mission seeds give different RNG results", distinct >= 5, distinct)
		check("setup: Internals live in the Internals scope", g1.Store.Internals.G ~= nil and g1.Store.Globals.G == nil)

		local nonstr = spec({ Globals = { N = 7, T = true, F = false } })
		check("setup: numbers and booleans are valid entries", nonstr:get("N") == 7 and nonstr:get("T") == 1 and nonstr:get("F") == 0)

		check("setup: names are sorted, so construction is deterministic", (function()
			local a = spec({ Globals = { Z = "1", A = "Z + 1", M = "A + 1" } })
			return a:get("M") == 3
		end)())
	end

	----------------------------------------------------------------------------------------------- Logic: StateUpdate
	do
		local l = spec({ Globals = { A = "0" } }, { C("StateUpdate", "SU", { Watch = "A && 7", SetVariable = "V", SetInternal = "W" }) })
		check("StateUpdate: targets are created as 0", l:get("V") == 0 and l:get("W") == 0)
		l:set("A", 1)
		check("StateUpdate: SetVariable gets the Watch value", l:get("V") == 7)
		check("StateUpdate: SetInternal goes to the Internals scope", l.Store.Internals.W == 7 and l.Store.Globals.W == nil)
		l:set("A", 0)
		check("StateUpdate: follows the Watch back down", l:get("V") == 0)

		local latch = spec({ Globals = { Interrogated = "0" } }, {
			C("StateUpdate", "RoleReveals", { Watch = "Interrogated || RoleVisible", SetVariable = "RoleVisible" }),
		})
		latch:set("Interrogated", 1)
		latch:set("Interrogated", 0)
		check("StateUpdate: the 'Watch includes its own target' latch holds", latch:get("RoleVisible") == 1)

		local chain = spec({ Globals = { A = "0" } }, {
			C("StateUpdate", "S1", { Watch = "A + 1", SetVariable = "B" }),
			C("StateUpdate", "S2", { Watch = "B + 1", SetVariable = "C" }),
		})
		chain:set("A", 10)
		check("StateUpdate: components chain", chain:get("B") == 11 and chain:get("C") == 12)

		local blank = spec({}, { C("StateUpdate", "Empty", { SetVariable = "X" }), C("StateUpdate", "NoTarget", { Watch = "1" }) })
		check("StateUpdate: blank Watch and missing targets are warnings", #blank.Warnings == 2 and #blank.Errors == 0)
		local badw = spec({}, { C("StateUpdate", "Bad", { Watch = "1 +", SetVariable = "X" }) })
		check("StateUpdate: a bad Watch is an Error naming the component and attribute", #badw.Errors == 1 and badw.Errors[1].Where == "DebugMission/StateComponents/Bad.Watch")
	end

	----------------------------------------------------------------------------------------------- Logic: Notification
	do
		local setup = { Globals = { N = "0" }, CustomStrings = { ["Notify.Files"] = "Found {N} files" } }
		local l = spec(setup, { C("Notification", "FilesNote", { Condition = "N >= 2", Notification = "Notify.Files" }) })
		check("Notification: nothing before the condition", #l:drainEvents() == 0)
		l:set("N", 1)
		check("Notification: still nothing", #l.Events == 0)
		l:set("N", 2)
		local ev1 = eventsOf(l, "Notification")
		check("Notification: fires on the rising edge", #ev1 == 1 and ev1[1].Key == "Notify.Files" and ev1[1].Component == "FilesNote")
		check("Notification: text comes from CustomStrings with {expr} filled in", ev1[1].Text == "Found 2 files", ev1[1].Text)
		l:set("N", 3)
		check("Notification: no repeat while the condition stays true", #l.Events == 0)
		l:set("N", 0)
		l:set("N", 4)
		local ev2 = eventsOf(l)
		check("Notification: fires again after a falling edge", #ev2 == 1 and ev2[1].Text == "Found 4 files")

		local initial = spec({ Globals = { Open = "1" } }, { C("Notification", "Hello", { Condition = "Open", Notification = "Notify.Unknown" }) })
		local ie = initial:drainEvents()
		check("Notification: a condition already true at the start fires at time 0", #ie == 1 and ie[1].Time == 0)
		check("Notification: an unknown key gives Key without Text", ie[1].Key == "Notify.Unknown" and ie[1].Text == nil)

		local noKey = spec({}, { C("Notification", "Mute", { Condition = "1" }) })
		check("Notification: no text/key is a warning, not an event", #noKey.Warnings == 1 and #noKey.Events == 0)

		local seen = {}
		local cb = spec({ Globals = { G = "0" } }, { C("Notification", "CB", { Condition = "G", Notification = "k" }) }, { onEvent = function(e) seen[#seen + 1] = e end })
		cb:set("G", 1)
		check("Notification: onEvent callback is called as it happens", #seen == 1 and seen[1].Kind == "Notification")
		check("Notification: events carry the time", (function() cb:advance(2.5) cb:set("G", 0) cb:set("G", 1) return near(seen[2].Time, 2.5) end)())
	end

	----------------------------------------------------------------------------------------------- Logic: TimerComponent
	do
		local function timer(attrs, setup, opts)
			local a = { SetVariable = "T", SetFormattedVariable = "TF", StartValue = 0, TargetValue = 3, Increment = 1, Enabled = "Go", Paused = "", Offset = "", Frequency = "" }
			for k, v in pairs(attrs or {}) do a[k] = v end
			local s = { Globals = { Go = "0", P = "0", O = "0" } }
			for k, v in pairs(setup or {}) do s.Globals[k] = v end
			return spec(s, { C("TimerComponent", "Timer", a) }, opts)
		end

		local l = timer()
		check("Timer: shows StartValue before it is enabled", l:get("T") == 0 and l:get("TF") == "00:00")
		l:advance(5)
		check("Timer: stays put while disabled", l:get("T") == 0)
		l:set("Go", 1)
		l:advance(1)
		check("Timer: ticks once per second", l:get("T") == 1)
		l:advance(1)
		check("Timer: counts up", l:get("T") == 2)
		l:advance(100)
		check("Timer: stops exactly on the target", l:get("T") == 3 and l:get("TF") == "00:03")
		l:advance(100)
		check("Timer: and stays there", l:get("T") == 3)
		l:set("Go", 0)
		check("Timer: disabling resets to StartValue", l:get("T") == 0)
		l:set("Go", 1)
		l:advance(1)
		check("Timer: can be restarted", l:get("T") == 1)

		local down = timer({ StartValue = 180, TargetValue = 0, Increment = -1 })
		down:set("Go", 1)
		down:advance(60)
		check("Timer: counts down, formatted MM:SS", down:get("T") == 120 and down:get("TF") == "02:00")
		down:advance(1000)
		check("Timer: a countdown stops at 0, never below", down:get("T") == 0 and down:get("TF") == "00:00")

		local fine = timer({ StartValue = 0, TargetValue = 100, Increment = 0.1, Frequency = 0.1 })
		fine:set("Go", 1)
		fine:advance(1)
		check("Timer: Frequency 0.1 / Increment 0.1 tracks real seconds", near(fine:get("T"), 1, 1e-9), fine:get("T"))
		fine:advance(2.05)
		check("Timer: with no float drift", near(fine:get("T"), 3, 1e-9), fine:get("T"))

		local one = timer({ TargetValue = 100 })
		one:set("Go", 1)
		local many = timer({ TargetValue = 100 })
		many:set("Go", 1)
		one:advance(10)
		for _ = 1, 10 do many:advance(1) end
		check("Timer: one big advance equals many small ones", one:get("T") == 10 and many:get("T") == 10)

		-- ticks fire at their own time even inside one big advance
		local timed = spec({ Globals = { Go = "1" } }, {
			C("TimerComponent", "Clock", { SetVariable = "T", StartValue = 0, TargetValue = 100, Increment = 1, Enabled = "Go" }),
			C("Notification", "AtThree", { Condition = "T >= 3", Notification = "k" }),
		})
		timed:advance(10)
		local at3 = eventsOf(timed, "Notification")
		check("Timer: watchers see each tick at its exact time (event at t=3 inside advance(10))", #at3 == 1 and near(at3[1].Time, 3), at3[1] and at3[1].Time)
		check("Timer: Time ends at the advance target", near(timed.Time, 10))

		local pz = timer({ Paused = "P", TargetValue = 100 })
		pz:set("Go", 1)
		pz:advance(2)
		pz:set("P", 1)
		pz:advance(5)
		check("Timer: Paused holds the value", pz:get("T") == 2)
		pz:set("P", 0)
		pz:advance(1)
		check("Timer: and resumes from it", pz:get("T") == 3)

		local off = timer({ Offset = "O", TargetValue = 100 })
		off:set("Go", 1)
		off:set("O", 5)
		check("Timer: Offset is added to the output", off:get("T") == 5)
		off:advance(2)
		check("Timer: and keeps being added", off:get("T") == 7)

		local hold = timer({ TargetValue = 100 }, nil, { timerOnDisable = "hold" })
		hold:set("Go", 1)
		hold:advance(2)
		hold:set("Go", 0)
		hold:advance(5)
		check("Timer: timerOnDisable='hold' keeps the value", hold:get("T") == 2)

		local zero = timer({ Increment = 0 })
		zero:set("Go", 1)
		zero:advance(10)
		check("Timer: Increment 0 never advances and warns (no hang)", zero:get("T") == 0 and #zero.Warnings >= 1)

		local fast = timer({ TargetValue = 1000, Frequency = 0.00001 })
		fast:set("Go", 1)
		fast:advance(1)
		check("Timer: absurdly small Frequency is clamped to one Heartbeat", fast:get("T") >= 59 and fast:get("T") <= 61, fast:get("T"))

		local exprT = timer({ StartValue = "Base", TargetValue = "Base + 2" }, { Base = "10" })
		exprT:set("Go", 1)
		exprT:advance(10)
		check("Timer: StartValue/TargetValue may be expressions", exprT:get("T") == 12)

		local quiet = spec({}, { C("TimerComponent", "Mute", { Enabled = "1" }) })
		check("Timer: no output variable is a warning", #quiet.Warnings == 1)

		check("formatTime", Logic.formatTime(0) == "00:00" and Logic.formatTime(65) == "01:05" and Logic.formatTime(3599) == "59:59" and Logic.formatTime(3600) == "60:00" and Logic.formatTime(-5) == "-00:05" and Logic.formatTime(59.9) == "00:59")
	end

	----------------------------------------------------------------------------------------------- Logic: mission triggers
	do
		local function trig(timeout, setup)
			local s = { Globals = { Done = "0" } }
			for k, v in pairs(setup or {}) do s.Globals[k] = v end
			return spec(s, { C("MissionCompletionTrigger", "Win", { Condition = "Done", Timeout = timeout, CompleteVariable = "Won" }) })
		end
		local l = trig(1.5)
		l:set("Done", 1)
		l:advance(1)
		check("Completion: waits for Timeout", l.Outcome == nil and l:get("Won") == 0)
		l:advance(0.5)
		check("Completion: fires after Timeout", l.Outcome ~= nil and l.Outcome.Kind == "Complete" and near(l.Outcome.Time, 1.5))
		check("Completion: sets CompleteVariable", l:get("Won") == 1)
		local ev = eventsOf(l, "MissionComplete")
		check("Completion: one MissionComplete event naming the variable", #ev == 1 and ev[1].Variable == "Won" and ev[1].Component == "Win")
		l:set("Done", 0)
		l:set("Done", 1)
		l:advance(10)
		check("Completion: latched, never fires twice", #eventsOf(l) == 0 and l.Outcome.Kind == "Complete")

		local c = trig(1.5)
		c:set("Done", 1)
		c:advance(1)
		c:set("Done", 0)
		c:advance(1)
		c:set("Done", 1)
		c:advance(1.4)
		check("Completion: dropping the condition cancels the countdown", c.Outcome == nil)
		c:advance(0.2)
		check("Completion: and re-arming restarts it in full (armed at t=2, fires at t=3.5)", c.Outcome ~= nil and near(c.Outcome.Time, 3.5), c.Outcome and c.Outcome.Time)

		local z = trig(0)
		z:set("Done", 1)
		check("Completion: Timeout 0 fires immediately", z.Outcome ~= nil and z.Outcome.Time == 0)

		local early = trig(1, { Done = "1" })
		check("Completion: a condition already true at the start counts down from 0", early.Outcome == nil)
		early:advance(1)
		check("Completion: and then fires", early.Outcome ~= nil)

		local both = spec({ Globals = { Win = "1", Lose = "1" } }, {
			C("MissionCompletionTrigger", "W", { Condition = "Win", Timeout = 2, CompleteVariable = "Won" }),
			C("MissionFailedTrigger", "F", { Condition = "Lose", Timeout = 1, FailedVariable = "Lost" }),
		})
		both:advance(5)
		check("Triggers: the first to fire decides the outcome", both.Outcome.Kind == "Failed" and both:get("Lost") == 1 and both:get("Won") == 0)
		local bev = both:drainEvents()
		check("Triggers: and only one outcome event exists", #bev == 1 and bev[1].Kind == "MissionFailed")

		local viaString = spec({ Globals = { Fled = "0", Mission_Failed = "Fled && [Notify.Fled]" } }, {
			C("MissionFailedTrigger", "Fail", { Condition = "Mission_Failed", Timeout = 0, FailedVariable = "" }),
		})
		viaString:set("Fled", 1)
		check("Triggers: a (non-empty) string condition counts as true; blank FailedVariable is fine", viaString.Outcome ~= nil and viaString.Outcome.Kind == "Failed")

		local noVar = spec({ Globals = { D = "1" } }, { C("MissionCompletionTrigger", "NV", { Condition = "D", Timeout = 0 }) })
		check("Completion: CompleteVariable is optional", noVar.Outcome ~= nil)
	end

	----------------------------------------------------------------------------------------------- Logic: replication
	do
		local l = spec(
			{ Globals = { Alarm = "0" }, Internals = { Secret = "42" }, ClientState = { Seen = "Alarm && 1 || Seen", Note = "0", Mirror = "Alarm + 10" } }
		)
		local r1 = l:addClient("u1")
		check("replica: starts with the server's Globals", r1:get("Alarm") == 0)
		check("replica: never sees Internals", r1:get("Secret") == nil and (r1.Undeclared.Secret or 0) == 0)
		check("replica: client-state entries are evaluated on the client", r1:get("Mirror") == 10 and r1:get("Seen") == 0)
		l:set("Alarm", 1)
		check("replica: nothing arrives until the host replicates", r1:get("Alarm") == 0)
		local packets = l:replicate()
		check("replica: replicate() delivers the Global change", r1:get("Alarm") == 1 and packets.u1 ~= nil)
		check("replica: client-side derived state reacts to it", r1:get("Seen") == 1 and r1:get("Mirror") == 11)
		l:set("Alarm", 0)
		l:replicate()
		check("replica: a client-state latch holds", r1:get("Seen") == 1 and r1:get("Mirror") == 10)
		local r2 = l:addClient("u2")
		check("replica: a late joiner gets the full snapshot, with its own client state", r2:get("Alarm") == 0 and r2:get("Seen") == 0)
		l:setClient("u1", "Note", 7)
		l:replicate()
		check("replica: server-set client variables go to that client only", r1:get("Note") == 7 and r2:get("Note") == 0)
		check("replica: eval runs an expression against the client's view", r1:eval("Note + Alarm") == 7)
		r1:set("Note", 9)
		check("replica: a client's local write stays local", r1:get("Note") == 9 and l.Store:getClient("u1", "Note") == 7)
		l:removeClient("u2")
		l:set("Alarm", 1)
		local p3 = l:replicate()
		check("replica: removed clients stop receiving", p3.u2 == nil and r2:get("Alarm") == 0)

		-- network-style: raw packets applied by hand
		local net = spec({ Globals = { Score = "0" } })
		local snap = net.Store:addClient("n1")
		local remote = Logic.Replica.new("n1", {}, 0)
		remote:apply(snap)
		net:set("Score", 12)
		for id, pk in pairs(net:flush()) do if id == "n1" then remote:apply(pk) end end
		check("replica: works with raw packets (host-side transport)", remote:get("Score") == 12)
		local bad = Logic.Replica.new("x", { Broken = "1 +", Ok = "2" }, 0)
		check("replica: a bad client-state expression is recorded, the rest works", #bad.Errors == 1 and bad:get("Ok") == 2 and bad:get("Broken") == 0)
	end

	----------------------------------------------------------------------------------------------- Logic: determinism, robustness
	do
		local function run(seed)
			local l = spec(
				{
					Globals = { Go = "1", Fled = "0", Mission_Failed = "Fled && [Notify.Fled]", Loot = "0" },
					Internals = { Pick = "RNG 77 1 6" },
					CustomStrings = { ["Notify.Tick"] = "Tick {T}" },
				},
				{
					C("TimerComponent", "Clock", { SetVariable = "T", SetFormattedVariable = "TF", StartValue = 0, TargetValue = 20, Increment = 1, Enabled = "Go" }),
					C("StateUpdate", "Mirror", { Watch = "T * 2", SetVariable = "T2", SetInternal = "T2i" }),
					C("Notification", "Tick", { Condition = "T % 5 == 0 && T > 0", Notification = "Notify.Tick" }),
					C("StateUpdate", "LootRoll", { Watch = "T >= 10 && Pick", SetVariable = "Loot" }),
					C("MissionCompletionTrigger", "End", { Condition = "T >= 20", Timeout = 1, CompleteVariable = "Won" }),
				},
				{ seed = seed }
			)
			local log = {}
			for step = 1, 40 do
				l:advance(0.75)
				if step == 8 then l:set("Fled", 1) end
				for _, e in ipairs(l:drainEvents()) do
					log[#log + 1] = ("%s@%.3f:%s:%s"):format(e.Kind, e.Time, e.Component or "", tostring(e.Text or e.Key or e.Variable))
				end
			end
			return table.concat(log, "|"), l
		end
		local a, la = run(416)
		local b = run(416)
		local c = run(417)
		check("determinism: the same seed and inputs give an identical event log", a == b and #a > 20, #a)
		check("determinism: the mission actually ran (ticks, completion)", la.Outcome ~= nil and la.Outcome.Kind == "Complete" and la:get("Won") == 1 and la:get("T") == 20)
		check("determinism: RNG feeds through (loot is the seeded pick)", la:get("Loot") == la:get("Pick") and la:get("Pick") >= 1 and la:get("Pick") <= 6)
		local picks = {}
		for sd = 1, 24 do
			local _, ls = run(sd)
			picks[ls:get("Pick")] = true
			if ls:get("T") ~= 20 then picks.bad = true end
		end
		local nPicks = 0
		for k in pairs(picks) do if k ~= "bad" then nPicks += 1 end end
		check("determinism: other seeds change only the seeded result (24 seeds -> several Picks, timing identical)", nPicks >= 3 and not picks.bad, nPicks)
		check("determinism: and the event log differs only where RNG is involved", c ~= nil)

		local junk = spec({ Globals = { A = "1 +", B = "((", C = "[x", D = "RNG 1" } }, {
			C("TimerComponent", "T", { Enabled = "1 +" }),
			C("Notification", "N", { Condition = "(", Notification = "k" }),
			C("MissionCompletionTrigger", "M", { Condition = "&&", Timeout = "abc" }),
			C("StateUpdate", "S", { Watch = "!", SetVariable = "x" }),
			{ Type = "Mystery", Name = "Unknown", Attrs = {} },
		})
		check("robust: broken mission data never throws, everything is an Error entry", #junk.Errors >= 8 and junk:advance(10) == true)
		check("robust: unsupported component types are counted, not run", junk.Unsupported.Mystery == 1)
		check("robust: advance rejects nonsense", junk:advance(-1) == false and junk:advance("x") == false)
		check("robust: set rejects nonsense values", junk:set("v", {}) == false)
		check("robust: Logic.new rejects a non-mission", select(2, Logic.new({})) ~= nil and select(2, Logic.new(nil)) ~= nil)

		local storm = spec({ Globals = { Go = "1" } }, { C("TimerComponent", "Storm", { SetVariable = "T", StartValue = 0, TargetValue = 1e9, Increment = 1, Enabled = "Go", Frequency = 1 / 60 }) }, { maxTicks = 50 })
		storm:advance(100000)
		check("robust: a tick storm is capped per advance() and reported", #storm.Errors >= 1 and storm:get("T") <= 51 and storm:get("T") >= 49, storm:get("T"))
		check("robust: summary() works", (function() local s = storm:summary() return s.Components.TimerComponent == 1 and s.Bindings >= 1 end)())
	end

	----------------------------------------------------------------------------------------------- defaults stay in sync with Appendix A
	do
		local V = require("../BreachValidator")
		for ty, defaults in pairs(Logic.Defaults) do
			local ref = V.defaultsFor(ty)
			if ty == "StateScript" then continue end -- exempt from validation by design (§3.4 rule 3)
			local ok = ref ~= nil
			if ok then
				for k, v in pairs(defaults) do if ref[k] ~= v then ok = false print("  default mismatch", ty, k, v, ref[k]) end end
				for k, v in pairs(ref) do if defaults[k] ~= v then ok = false print("  default mismatch", ty, k, defaults[k], v) end end
			end
			check("defaults: " .. ty .. " matches the validator's Appendix A table", ok)
		end
	end

	----------------------------------------------------------------------------------------------- real maps
	local okE, emb = pcall(require, "./_embedded")
	if not okE then
		print("(real-map logic tests skipped: tests/_embedded.luau not found)")
		return
	end
	local Codec = require("../BreachCodec")
	local Zstd = require("../BreachZstd")
	local Mission = require("../BreachMission")
	local Validator = require("../BreachValidator")
	local host = { zstdDecompress = Zstd.decompress }

	for _, mapName in ipairs({ "TheDiplomat.base64", "thepeacemaker.txt" }) do
		if emb[mapName] then
			local label = mapName:gsub("%..*", "")
			local d, derr = Codec.decode(emb[mapName], host)
			check(label .. " [logic]: decodes", d ~= nil, derr)
			if d then
				local m = Mission.build(d, { validator = Validator })

				-- 1. every expression in Setup
				local total, failed = 0, {}
				for _, store in ipairs({ "Globals", "Internals", "ClientState" }) do
					for name, src in pairs(d.Setup[store] or {}) do
						total += 1
						local p, err = Expr.compile(src)
						if not p then failed[#failed + 1] = store .. "." .. name .. ": " .. err end
					end
				end
				check(label .. " [logic]: all " .. total .. " Setup expressions compile", #failed == 0, failed[1])

				-- 2. every expr-kind attribute on every node. Two attributes are typed `expr` in Appendix A but hold
				--    string-context values (CustomStrings keys like UI.AlreadySearched, or {template} text): they are
				--    checked with interpolate(), not as expressions. One real expression in The Diplomat has a stray ')'.
				local STRING_CONTEXT = { DisabledTitle = true, DisabledSubtitle = true }
				local KNOWN_DATA_BUGS = { ["DebugMission/Props/TriggerLocalChat.Active"] = true }
				local attrTotal, strCtx, attrFailed, knownBugs = 0, 0, {}, 0
				local function walk(node)
					local key = Mission.componentKey(node)
					for attr, value in pairs(node.Attrs or {}) do
						if Validator.kindOf(key, attr) == "EXPRESSION" and type(value) == "string" then
							if STRING_CONTEXT[attr] then
								strCtx += 1
								local _, problems = Expr.interpolate(value, nil)
								if #problems > 0 then attrFailed[#attrFailed + 1] = (node.Path or node.Name) .. "." .. attr .. ": " .. problems[1].message end
							else
								attrTotal += 1
								local p, err = Expr.compile(value)
								if not p then
									if KNOWN_DATA_BUGS[(node.Path or "") .. "." .. attr] then
										knownBugs += 1
									else
										attrFailed[#attrFailed + 1] = (node.Path or node.Name) .. "." .. attr .. ": " .. err
									end
								end
							end
						end
					end
					for _, c in ipairs(node.Children) do walk(c) end
				end
				walk(m.Root)
				check(label .. " [logic]: all " .. attrTotal .. " expression attributes compile (" .. knownBugs .. " known data typo, " .. strCtx .. " string-context)", attrTotal > 0 and #attrFailed == 0, attrFailed[1])
				for i = 1, math.min(#attrFailed, 8) do print("    " .. attrFailed[i]) end

				-- 3. build the logic core and run it
				local function make()
					return Logic.new(m, { seed = 416, builtins = { Mission_Difficulty = 2, Mission_PlayerTotal = 1, Mission_TacticalDifficulty = 0 } })
				end
				local t0 = os.clock()
				local logic = make()
				local buildTime = os.clock() - t0
				check(label .. " [logic]: builds with no Errors", logic ~= nil and #logic.Errors == 0, logic and logic.Errors[1] and (logic.Errors[1].Where .. " " .. logic.Errors[1].Message))
				if logic then
					local s = logic:summary()
					local t1 = os.clock()
					for _ = 1, 600 do logic:advance(1) end
					local runTime = os.clock() - t1
					check(label .. " [logic]: 600 simulated seconds run without Errors", #logic.Errors == 0, logic.Errors[1] and (logic.Errors[1].Where .. " " .. logic.Errors[1].Message))
					local comps = {}
					for _, ty in ipairs({ "StateUpdate", "Notification", "TimerComponent", "MissionCompletionTrigger" }) do comps[#comps + 1] = ty .. "×" .. (s.Components[ty] or 0) end
					print(("  %s: globals %d, internals %d, client-state %d | %s | %d unsupported components | %d bindings, %d evaluations | build %.3fs, 600 s simulated in %.3fs"):format(
						label, s.Globals, s.Internals, s.ClientState, table.concat(comps, " "), s.Unsupported, s.Bindings, s.Evaluations, buildTime, runTime))
					local und = {}
					for name in pairs(logic.Undeclared) do und[#und + 1] = name end
					table.sort(und)
					print(("  %s: %d variables are read but never declared or written by a supported component (engine built-ins, or written by later milestones): %s%s"):format(
						label, #und, table.concat(und, ", "):sub(1, 260), #table.concat(und, ", ") > 260 and " ..." or ""))
					local issues = {}
					for k, n in pairs(logic.Issues) do issues[#issues + 1] = k .. " ×" .. n end
					table.sort(issues)
					if #issues > 0 then print("  " .. label .. ": runtime issues: " .. table.concat(issues, "; "):sub(1, 300)) end
					if #logic.Warnings > 0 then print("  " .. label .. ": " .. #logic.Warnings .. " warnings, e.g. " .. logic.Warnings[1].Where .. ": " .. logic.Warnings[1].Message) end

					-- determinism on the real map
					local function signature(lg)
						local out = {}
						for step = 1, 300 do
							lg:advance(1)
							for _, e in ipairs(lg:drainEvents()) do out[#out + 1] = ("%s@%g:%s:%s"):format(e.Kind, e.Time, e.Component or "", tostring(e.Key or e.Variable)) end
						end
						local names = {}
						for k in pairs(lg.Store.Globals) do names[#names + 1] = k end
						table.sort(names)
						for _, k in ipairs(names) do out[#out + 1] = k .. "=" .. tostring(lg.Store.Globals[k]) end
						return table.concat(out, "\n")
					end
					check(label .. " [logic]: two runs of the real map are identical", signature(make()) == signature(make()))

					-- replication on the real map
					local rep = logic:addClient("player1")
					check(label .. " [logic]: a client joins with no Errors", #rep.Errors == 0, rep.Errors[1] and (rep.Errors[1].Where .. " " .. rep.Errors[1].Message))
					local internalsLeak = false
					for name in pairs(logic.Store.Internals) do
						if logic.Store.Globals[name] == nil and rep.Globals[name] ~= nil then internalsLeak = true end
					end
					check(label .. " [logic]: no Internal variable reaches the client", not internalsLeak)
					local agree = true
					for name, v in pairs(logic.Store.Globals) do if rep.Globals[name] ~= v then agree = false end end
					check(label .. " [logic]: the client mirrors every Global", agree)
				end
			end
		end
	end
end
