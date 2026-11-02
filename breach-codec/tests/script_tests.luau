--!nonstrict
-- M6 tests: BreachCFrame, expression extensions, BreachScript (the StateScript VM), StateScript in BreachLogic.
-- Run via `luau tests/run.luau` or alone: `luau tests/script.luau`
local CF = require("../BreachCFrame")
local Expr = require("../BreachExpr")
local Script = require("../BreachScript")
local Logic = require("../BreachLogic")

local function near(a, b, tol)
	return type(a) == "number" and type(b) == "number" and math.abs(a - b) <= (tol or 1e-6)
end

local function rotate(c, x, y, z) -- apply a CFrame's rotation to a vector
	return c[4] * x + c[5] * y + c[6] * z, c[7] * x + c[8] * y + c[9] * z, c[10] * x + c[11] * y + c[12] * z
end

return function(check)
	----------------------------------------------------------------------------------------------- CFrame
	do
		local id = CF.identity()
		check("cframe: isCF", CF.isCF(id) and not CF.isCF({}) and not CF.isCF(5) and not CF.isCF("x"))
		local a = CF.new(1, 2, 3)
		check("cframe: new / position", select(1, CF.position(a)) == 1 and select(3, CF.position(a)) == 3)
		check("cframe: identity is the multiplicative identity", CF.equals(CF.mul(id, a), a) and CF.equals(CF.mul(a, id), a))
		check("cframe: translations compose", CF.equals(CF.mul(CF.new(1, 0, 0), CF.new(0, 2, 0)), CF.new(1, 2, 0)))

		local ry = CF.angles(0, math.pi / 2, 0)
		local x, y, z = rotate(ry, 1, 0, 0)
		check("cframe: Angles(0, 90°, 0) takes +X to -Z (right-handed, Roblox)", near(x, 0) and near(y, 0) and near(z, -1), ("%g %g %g"):format(x, y, z))
		local rx = CF.angles(math.pi / 2, 0, 0)
		x, y, z = rotate(rx, 0, 1, 0)
		check("cframe: Angles(90°, 0, 0) takes +Y to +Z", near(x, 0) and near(y, 0) and near(z, 1))
		local rz = CF.angles(0, 0, math.pi / 2)
		x, y, z = rotate(rz, 1, 0, 0)
		check("cframe: Angles(0, 0, 90°) takes +X to +Y", near(x, 0) and near(y, 1) and near(z, 0))
		check("cframe: Angles(a,b,c) = Rx · Ry · Rz (Roblox order)", CF.equals(CF.angles(0.3, 0.5, 0.7), CF.mul(CF.mul(CF.angles(0.3, 0, 0), CF.angles(0, 0.5, 0)), CF.angles(0, 0, 0.7)), 1e-9))
		check("cframe: rotation then translation order matters (T*R != R*T)", not CF.equals(CF.mul(CF.new(1, 0, 0), ry), CF.mul(ry, CF.new(1, 0, 0))))
		local tr = CF.mul(ry, CF.new(1, 0, 0))
		check("cframe: R * T moves the point through the rotation", near(tr[1], 0) and near(tr[3], -1))

		-- random-ish algebra
		local seed, ok1, ok2, ok3 = 7, true, true, true
		local function rnd() seed = (seed * 1103515245 + 12345) % 2147483648 return (seed / 2147483648) * 6 - 3 end
		for _ = 1, 200 do
			local p = CF.mul(CF.new(rnd(), rnd(), rnd()), CF.angles(rnd(), rnd(), rnd()))
			local q = CF.mul(CF.new(rnd(), rnd(), rnd()), CF.angles(rnd(), rnd(), rnd()))
			local r = CF.mul(CF.new(rnd(), rnd(), rnd()), CF.angles(rnd(), rnd(), rnd()))
			if not CF.equals(CF.mul(p, CF.inverse(p)), id, 1e-9) then ok1 = false end
			if not CF.equals(CF.mul(CF.mul(p, q), r), CF.mul(p, CF.mul(q, r)), 1e-9) then ok2 = false end
			local qx, qy, qz, qw = CF.toQuat(p)
			if not CF.equals(CF.fromQuat(qx, qy, qz, qw, p[1], p[2], p[3]), p, 1e-9) then ok3 = false end
		end
		check("cframe: p * p⁻¹ = identity (200 random)", ok1)
		check("cframe: multiplication is associative (200 random)", ok2)
		check("cframe: quaternion round trip (200 random)", ok3)

		check("cframe: lerp endpoints", CF.equals(CF.lerp(ry, rx, 0), ry, 1e-9) and CF.equals(CF.lerp(ry, rx, 1), rx, 1e-9))
		local half = CF.lerp(id, CF.angles(0, math.pi / 2, 0), 0.5)
		check("cframe: slerp halfway is half the angle", CF.equals(half, CF.angles(0, math.pi / 4, 0), 1e-9))
		local mid = CF.lerp(CF.new(0, 0, 0), CF.new(10, 20, 30), 0.25)
		check("cframe: position lerps linearly", near(mid[1], 2.5) and near(mid[2], 5) and near(mid[3], 7.5))
		check("cframe: lerp takes the short way round (opposite quaternion sign)", CF.equals(CF.lerp(CF.angles(0, 0.1, 0), CF.angles(0, 2 * math.pi - 0.1, 0), 0.5), id, 1e-6))

		local c3 = CF.fromString("-119.696, 36.5, -181")
		check("cframe: fromString 3 numbers = position", c3 and near(c3[1], -119.696) and near(c3[3], -181) and CF.equals(CF.mul(c3, id), c3))
		check("cframe: fromString 7 numbers = position + quaternion", CF.equals(CF.fromString("1 2 3 0 0 0 1"), CF.new(1, 2, 3), 1e-9))
		check("cframe: fromString 12 numbers", CF.equals(CF.fromString("1 2 3 1 0 0 0 1 0 0 0 1"), CF.new(1, 2, 3)))
		check("cframe: fromString rejects 5 numbers", select(2, CF.fromString("1 2 3 4 5")) ~= nil)
		check("cframe: fromString rejects text", select(2, CF.fromString("1, two, 3")) ~= nil)
		check("cframe: fromComponents rejects wrong length", select(2, CF.fromComponents({ 1, 2 })) ~= nil)
		check("cframe: tostring", tostring(a) == "CFrame(1, 2, 3)" and tostring(ry):find("rotated") ~= nil)
		check("cframe: arith * and ==", CF.isCF(CF.arith("*", a, ry)) and CF.arith("==", a, a) == 1 and CF.arith("~=", a, a) == 0 and CF.arith("==", a, 5) == 0)
		check("cframe: arith refuses nonsense", select(2, CF.arith("+", a, a)) ~= nil and select(2, CF.arith("*", a, 2)) ~= nil)
	end

	----------------------------------------------------------------------------------------------- Expr extensions
	do
		local locals = { Pos = CF.new(5, 0, 0), Rot = CF.angles(0, math.pi / 2, 0), n = 3 }
		local reports = {}
		local ctx = {
			get = function(name) if name:sub(1, 1) == "#" then return locals[name:sub(2)] end return nil end,
			arith = CF.arith, report = function(k, d) reports[#reports + 1] = k .. ":" .. tostring(d) end,
		}
		local p = Expr.compile("#n * 2 + 1")
		check("expr: #local names compile and appear in Deps", p and p.Deps[1] == "#n")
		check("expr: #local evaluates through ctx.get", Expr.evaluate(p, ctx) == 7)
		local mulCF = Expr.evaluate(Expr.compile("#Pos * #Rot"), ctx)
		check("expr: CFrame * CFrame goes through ctx.arith", CF.isCF(mulCF) and near(mulCF[1], 5))
		local mulCF2 = Expr.evaluate(Expr.compile("#Rot * #Pos"), ctx)
		check("expr: and order matters", CF.isCF(mulCF2) and near(mulCF2[3], -5))
		check("expr: CFrame == CFrame", Expr.evaluate(Expr.compile("#Pos == #Pos"), ctx) == 1 and Expr.evaluate(Expr.compile("#Pos ~= #Rot"), ctx) == 1)
		check("expr: a CFrame is truthy", Expr.evaluate(Expr.compile("#Pos && 7"), ctx) == 7)
		reports = {}
		check("expr: unsupported CFrame arithmetic is 0 and reported", Expr.evaluate(Expr.compile("#Pos + 1"), ctx) == 0 and reports[1]:find("type%-mismatch") ~= nil)
		check("expr: without an arith hook a table operand is also just reported", Expr.evaluate(Expr.compile("#Pos * #Rot"), { get = ctx.get, report = function() end }) == 0)
		check("expr: a lone '#' is still a clean error", select(2, Expr.compile("# + 1")) ~= nil and select(2, Expr.compile("#")) ~= nil)
		check("expr: '#' names do not break ordinary expressions", Expr.compile("A + B").Deps[1] == "A")
	end

	----------------------------------------------------------------------------------------------- VM harness
	local function mockHost(opts)
		opts = opts or {}
		local h = { vars = opts.vars or {}, events = {}, reports = {}, errors = {}, tasks = {}, watches = {}, now = 0, Seed = opts.seed or 7, guids = 0 }
		h.Get = function(n) return h.vars[n] end
		h.Set = function(n, v) h.vars[n] = v end
		h.Now = function() return h.now end
		h.Schedule = function(at, fn) local t = { At = at, Fn = fn } h.tasks[#h.tasks + 1] = t return t end
		h.Cancel = function(t) t.Cancelled = true end
		h.Watch = function(deps, evalFn, onValue) local w = { Deps = deps, Eval = evalFn, On = onValue } h.watches[#h.watches + 1] = w return w end
		h.Emit = function(e) e.Time = h.now h.events[#h.events + 1] = e end
		h.Report = function(k, d) h.reports[#h.reports + 1] = k .. ":" .. tostring(d) end
		h.Error = function(w, m) h.errors[#h.errors + 1] = w .. ": " .. m end
		h.Guid = function() h.guids += 1 return ("%08x-%08x"):format(h.guids * 2654435761 % 4294967296, h.guids) end
		h.CFrameOf = opts.props and function(tag) return opts.props[tag] end or nil
		function h.poke()
			for _ = 1, 10 do
				local woke = false
				for _, w in ipairs(h.watches) do
					if not w.Dead then
						local before = w.Dead
						w.On(w.Eval())
						if w.Dead and not before then woke = true end
					end
				end
				if not woke then break end
			end
		end
		function h.advance(dt)
			local target = h.now + dt
			while true do
				local best
				for _, t in ipairs(h.tasks) do
					if not t.Done and not t.Cancelled and t.At <= target + 1e-9 and (not best or t.At < best.At) then best = t end
				end
				if not best then break end
				best.Done = true
				h.now = math.max(h.now, best.At)
				best.Fn()
				h.poke()
			end
			h.now = target
		end
		return h
	end
	-- Compile + start a script; returns host, instance, first thread.
	local function run(src, opts)
		opts = opts or {}
		local h = mockHost(opts)
		local program = Script.compile(src, opts.name or "t")
		local inst = Script.new(program, h, { Name = opts.name or "t", Params = opts.params, Budget = opts.budget, DebugVariable = opts.debugVar, DebugLineVariable = opts.debugLine })
		local th = inst:spawn()
		h.poke()
		return h, inst, th, program
	end

	----------------------------------------------------------------------------------------------- VM: the documented instruction set
	do
		local want = {
			"INIT", "SET", "INC", "INCREMENT", "DEC", "DECREMENT", "ALLOC", "ALLOCARRAY", "GUID", "GOTO", "CALL", "CALLIF", "RETURN", "KILL", "THREAD",
			"PUSH", "POP", "PEEK", "WAIT", "WAITHEARTBEAT", "WAITFOR", "WAITFORCHANGE", "LERP", "CFR", "CFRANGLES", "CFRDEGREES", "CFRINV", "CFRCOPY", "SHUFFLE",
			"MOVETO", "ANIMATE", "ANIMATECUBIC", "COPYTO", "DELETE", "DELETEALL", "SPAWNBOT", "INITSTATECOMP",
		}
		local have, missing = {}, {}
		for _, n in ipairs(Script.Instructions) do have[n] = true end
		for _, n in ipairs(want) do if not have[n] then missing[#missing + 1] = n end end
		check("script: all " .. #want .. " documented instructions exist", #missing == 0, table.concat(missing, ","))
	end

	-- variables
	do
		local h = run("INIT A 5\nINIT A 9\nSET B [A * 2]\nINC A\nDEC B\nINIT #l 3\nSET C #l\nSET N -2\nSET S hello\nSET L [[two words]]\nSET F .5")
		check("vars: INIT sets once (a second INIT is ignored)", h.vars.A == 6)
		check("vars: SET with an expression, INC, DEC", h.vars.B == 9)
		check("vars: #locals are thread-local, not mission variables", h.vars.C == 3 and h.vars["#l"] == nil and h.vars.l == nil)
		check("vars: negative and decimal words are numbers", h.vars.N == -2 and h.vars.F == 0.5)
		check("vars: plain words are strings, [[..]] keeps spaces", h.vars.S == "hello" and h.vars.L == "two words")
		local h2 = run("INC Missing")
		check("vars: INC of an undeclared variable reports and counts from 0", h2.vars.Missing == 1 and h2.reports[1] == "undeclared:Missing")
		local h3 = run("INIT Mine 1\nINIT Mine 2", { vars = { Mine = 77 } })
		check("vars: INIT leaves a variable that already exists (Setup wins)", h3.vars.Mine == 77)
		local h4 = run("INCREMENT A\nINCREMENT A\nDECREMENT A\nset b 4\ninc b", { vars = { A = 0 } })
		check("vars: INCREMENT/DECREMENT aliases and lower-case instructions", h4.vars.A == 1 and h4.vars.b == 5)
		local h5 = run("INIT WingEntrancePatrol\nSET X [WingEntrancePatrol + 1]")
		check("vars: INIT with no value gives 0 (a real script does this)", h5.vars.WingEntrancePatrol == 0 and h5.vars.X == 1)
	end

	-- ALLOC / ALLOCARRAY / GUID
	do
		local h = run("ALLOC X\nALLOCARRAY Arr 3\nGUID G1\nGUID G2\nGUID #g\nSET Lg #g")
		check("alloc: ALLOC creates a variable at 0", h.vars.X == 0)
		check("alloc: ALLOCARRAY makes var0..var(n-1)", h.vars.Arr0 == 0 and h.vars.Arr1 == 0 and h.vars.Arr2 == 0 and h.vars.Arr3 == nil)
		check("alloc: GUID gives distinct ids", type(h.vars.G1) == "string" and h.vars.G1 ~= h.vars.G2 and h.vars.Lg ~= h.vars.G1)
		local h2 = run("ALLOC Keep\nINC Keep\nALLOC Keep\nALLOCARRAY Keep 1")
		check("alloc: ALLOC does not reset an existing variable", h2.vars.Keep == 1 and h2.vars.Keep0 == 0)
	end

	-- flow
	do
		local h = run("INIT #i 0\n:loop\nINC #i\nGOTO loop [#i < 5]\nSET R #i")
		check("flow: GOTO with a condition loops", h.vars.R == 5)
		local h2 = run("INIT #i 0\n:top\nINC #i\nGOTO :top [#i < 3]\nSET R #i")
		check("flow: a label may be written with its colon", h2.vars.R == 3)
		local h3 = run("GOTO end\nSET Skipped 1\n:end\nSET Done 1")
		check("flow: unconditional GOTO", h3.vars.Skipped == nil and h3.vars.Done == 1)
		local h4 = run("GOTO end [0]\nSET Ran 1\n:end")
		check("flow: a false condition falls through; a label at the end is valid", h4.vars.Ran == 1)
		local h5 = run("CALL sub 21\nSET After 1\nKILL\n:sub\nPOP #v\nSET R [#v * 2]\nRETURN")
		check("flow: CALL pushes its arguments, RETURN comes back", h5.vars.R == 42 and h5.vars.After == 1)
		local h6 = run("CALL a 1 2 3\nKILL\n:a\nPOP #x\nPOP #y\nPOP #z\nSET X #x\nSET Y #y\nSET Z #z\nRETURN")
		check("flow: arguments pop in reverse (last pushed first)", h6.vars.X == 3 and h6.vars.Y == 2 and h6.vars.Z == 1)
		local h7 = run("CALLIF [Go == 1] :KILLLABEL\nSET After 1\nKILL\n:KILLLABEL\nKILL", { vars = { Go = 0 } })
		check("flow: CALLIF takes the condition FIRST (real scripts); false = no call", h7.vars.After == 1)
		local h8 = run("CALLIF [Go == 1] :KILLLABEL\nSET After 1\nKILL\n:KILLLABEL\nKILL", { vars = { Go = 1 } })
		check("flow: CALLIF true calls the label (the real script kills itself this way)", h8.vars.After == nil)
		local h9 = run("CALLIF 1 sub 5\nKILL\n:sub\nPOP #a\nSET R #a\nRETURN")
		check("flow: CALLIF passes arguments after the label", h9.vars.R == 5)
		local h10 = run("RETURN\nSET Never 1")
		check("flow: RETURN with an empty call stack is KILL", h10.vars.Never == nil)
		local h11 = run("SET A 1\nKILL\nSET B 1")
		check("flow: KILL ends the thread", h11.vars.A == 1 and h11.vars.B == nil)
		local h12 = run("SET A 1")
		check("flow: running off the end ends the thread", h12.vars.A == 1 and #h12.errors == 0)
		local h13, inst13 = run("THREAD worker 7\nSET Main 1\nKILL\n:worker\nPOP #n\nWAIT 1\nSET W #n")
		check("flow: THREAD starts another thread immediately and the parent carries on", h13.vars.Main == 1 and h13.vars.W == nil)
		h13.advance(1)
		check("flow: THREAD passes arguments; the thread runs independently", h13.vars.W == 7 and inst13.LiveCount == 0)
	end

	-- stack
	do
		local h = run("PUSH 10\nPUSH 20\nPEEK #a\nPOP #b\nPOP #c\nSET A #a\nSET B #b\nSET C #c")
		check("stack: PEEK keeps the top, POP removes it", h.vars.A == 20 and h.vars.B == 20 and h.vars.C == 10)
		local h2 = run("POP #x\nSET X #x\nSET After 1")
		check("stack: POP on an empty stack reports, gives 0 and carries on", h2.vars.X == 0 and h2.vars.After == 1 and h2.reports[1]:find("^stack%-empty") ~= nil)
		local h3 = run("PUSH 1 2 3\nPOP #a\nSET A #a")
		check("stack: PUSH takes several values", h3.vars.A == 3)
	end

	-- waiting
	do
		local h = run("WAIT 2.5\nSET T 1")
		h.advance(2.4)
		check("wait: WAIT holds the thread", h.vars.T == nil)
		h.advance(0.1)
		check("wait: and releases it on time", h.vars.T == 1)
		local h2 = run("WAIT 1 #e\nSET E #e")
		h2.advance(1)
		check("wait: WAIT's optional variable receives the time waited", h2.vars.E == 1)
		local h3 = run("WAIT 0\nSET T 1")
		check("wait: WAIT 0 still yields (one heartbeat)", h3.vars.T == nil)
		h3.advance(1 / 60)
		check("wait: and resumes a heartbeat later", h3.vars.T == 1)
		local h4 = run("WAITHEARTBEAT #dt\nSET D #dt")
		h4.advance(1 / 60)
		check("wait: WAITHEARTBEAT is 1/60 s and reports it", near(h4.vars.D, 1 / 60, 1e-12))
		local h5 = run("WAIT 1\nSET A 1\nWAIT 2\nSET B 1")
		h5.advance(2.9)
		check("wait: sequential waits add up", h5.vars.A == 1 and h5.vars.B == nil)
		h5.advance(0.1)
		check("wait: ... exactly", h5.vars.B == 1)

		local hf, instf = run("WAITFOR Flag\nSET Done 1", { vars = { Flag = 0 } })
		check("waitfor: blocks while the condition is false", hf.vars.Done == nil and instf.LiveCount == 1)
		hf.vars.Flag = 1
		hf.poke()
		check("waitfor: wakes when a variable it reads changes", hf.vars.Done == 1 and instf.LiveCount == 0)
		local hf2 = run("WAITFOR Flag\nSET Done 1", { vars = { Flag = 1 } })
		check("waitfor: an already-true condition does not block", hf2.vars.Done == 1)
		local hf3 = run("WAITFOR [Flag > 2]\nSET Done 1", { vars = { Flag = 0 } })
		hf3.vars.Flag = 3
		hf3.poke()
		check("waitfor: [expression] form", hf3.vars.Done == 1)
		local hf4 = run("WAITFOR Flag > 2 && Other\nSET Done 1", { vars = { Flag = 0, Other = 1 } })
		hf4.vars.Flag = 5
		hf4.poke()
		check("waitfor: an unbracketed multi-word expression works too", hf4.vars.Done == 1)
		-- the documented pitfall: *WAITFOR {cond} freezes the condition into a constant
		local hp = run("*WAITFOR {Flag}\nSET Done 1", { vars = { Flag = 0 } })
		hp.vars.Flag = 1
		hp.poke()
		check("waitfor pitfall (faithful): *WAITFOR {cond} becomes WAITFOR 0 and hangs forever", hp.vars.Done == nil)
		check("waitfor pitfall: ... and is reported as a hang", (function() for _, r in ipairs(hp.reports) do if r:find("^script%-hang") then return true end end end)() == true)
		local hp2 = run("*WAITFOR {Flag}\nSET Done 1", { vars = { Flag = 1 } })
		check("waitfor pitfall (faithful): ... or returns instantly when it was already 1", hp2.vars.Done == 1)

		local hc, instc = run("WAITFORCHANGE V\nSET Done 1", { vars = { V = 5 } })
		hc.poke()
		check("waitforchange: an unchanged value keeps waiting", hc.vars.Done == nil)
		hc.vars.V = 6
		hc.poke()
		check("waitforchange: wakes on any change", hc.vars.Done == 1)
		local hc2 = run("WAITFORCHANGE [A + B]\nSET Done 1", { vars = { A = 1, B = 1 } })
		hc2.vars.A = 0
		hc2.vars.B = 2
		hc2.poke()
		check("waitforchange: compares the expression's value, not its parts", hc2.vars.Done == nil)
		hc2.vars.B = 3
		hc2.poke()
		check("waitforchange: ... and wakes when that changes", hc2.vars.Done == 1)

		-- kill cancels pending waits
		local hk, instk, thk = run("WAIT 5\nSET Late 1")
		instk:kill(thk)
		hk.advance(10)
		check("kill: a killed thread's WAIT never fires", hk.vars.Late == nil and instk.LiveCount == 0)
		local hk2, instk2, thk2 = run("WAITFOR Flag\nSET Late 1", { vars = { Flag = 0 } })
		instk2:kill(thk2)
		hk2.vars.Flag = 1
		hk2.poke()
		check("kill: a killed thread's WAITFOR never wakes", hk2.vars.Late == nil)
		local hk3, instk3 = run("THREAD a\nTHREAD a\nKILL\n:a\nWAIT 100")
		check("kill: killAll stops every thread", instk3.LiveCount == 2 and (function() instk3:killAll() return instk3.LiveCount == 0 end)())
	end

	-- math / data
	do
		local h = run("LERP 10 20 .25 R")
		check("math: LERP on numbers", near(h.vars.R, 12.5))
		local h2 = run("CFR #a [[0, 0, 0]]\nCFR #b [[10, 0, 0]]\nLERP #a #b .5 #m\nMOVETO t #m")
		check("math: LERP on CFrames", h2.events[1] and near(h2.events[1].Args[2][1], 5))
		local h3 = run("LERP 1 [[x]] 0 R")
		check("math: LERP of mismatched things is an error", #h3.errors == 1)
		local h4 = run("CFR #p\nMOVETO t #p")
		check("math: CFR with no value is the identity", CF.equals(h4.events[1].Args[2], CF.identity()))
		local h5 = run("CFR #p [[1 2 3 0 0 0 1]]\nMOVETO t #p")
		check("math: CFR with 7 numbers", CF.equals(h5.events[1].Args[2], CF.new(1, 2, 3), 1e-9))
		local h6 = run("CFR #p [[1, two, 3]]\nSET After 1")
		check("math: a bad CFR literal kills the thread with a message", #h6.errors == 1 and h6.errors[1]:find("not a number") ~= nil and h6.vars.After == nil)
		local h7 = run("CFR #q [[1, 0, 0]]\nCFRDEGREES #r [[0, 90, 0]]\nMOVETO t [#r * #q]")
		local m = h7.events[1].Args[2]
		check("math: CFRDEGREES then [#r * #q] rotates the point (+X -> -Z)", near(m[1], 0) and near(m[3], -1))
		local h8 = run("CFRANGLES #r [[0, " .. math.pi / 2 .. ", 0]]\nCFRDEGREES #d [[0, 90, 0]]\nMOVETO a #r\nMOVETO b #d")
		check("math: CFRANGLES (radians) and CFRDEGREES agree", CF.equals(h8.events[1].Args[2], h8.events[2].Args[2], 1e-9))
		local h9 = run("CFRDEGREES #r 0 90 0\nMOVETO a #r")
		check("math: angles may be three separate numbers", near(h9.events[1].Args[2][6], 1))
		local h10 = run("CFR #a [[3, 4, 5]]\nCFRDEGREES #r [[10, 20, 30]]\nCFR #p [[3, 4, 5]]\nMOVETO t [#a * #r]\nCFRINV #inv #a\nMOVETO u [#a * #inv]")
		check("math: CFRINV x gives the inverse", CF.equals(h10.events[2].Args[2], CF.identity(), 1e-9))
		local h11 = run("CFR #a [[3, 4, 5]]\nCFR #o [[3, 4, 5]]\nCFRINV #a\nMOVETO u [#a * #o]\nMOVETO v #a")
		check("math: CFRINV with one argument inverts in place", CF.equals(h11.events[1].Args[2], CF.identity(), 1e-9) and near(h11.events[2].Args[2][1], -3))

		local props = { PropA = CF.new(1, 2, 3) }
		local h12 = run("CFRCOPY #c PropA\nMOVETO t #c\nCFRCOPY #d Missing\nMOVETO u #d", { props = props })
		check("math: CFRCOPY reads a prop's CFrame from the host", CF.equals(h12.events[1].Args[2], CF.new(1, 2, 3)))
		check("math: ... a missing prop is reported and gives the identity (no crash)", CF.equals(h12.events[2].Args[2], CF.identity()) and h12.reports[1] == "missing-prop:Missing")
		local h13 = run("CFRCOPY Global PropA\nMOVETO t Global", { props = props })
		check("math: CFRCOPY into a GLOBAL name makes a CFrame variable (real: CFRCOPY SecurityRoom SecurityRoom)", CF.isCF(h13.vars.Global) and #h13.events == 1)

		local function shuffled(seed)
			local h = run("SHUFFLE out 99 a b c d e f", { seed = seed })
			local items = {}
			for i = 0, 5 do items[#items + 1] = h.vars["out" .. i] end
			return table.concat(items), h.vars.out
		end
		local s1, n1 = shuffled(1)
		local sorted = {}
		for ch in s1:gmatch(".") do sorted[#sorted + 1] = ch end
		table.sort(sorted)
		check("math: SHUFFLE is a permutation and stores the count", table.concat(sorted) == "abcdef" and n1 == 6)
		check("math: SHUFFLE is reproducible per seed", shuffled(1) == shuffled(1))
		local differ = false
		for sd = 2, 12 do if shuffled(sd) ~= s1 then differ = true end end
		check("math: ... and differs between mission seeds", differ)
	end

	-- world commands
	do
		local h = run("MOVETO LoudTruck [[1, 2, 3]] 0\nANIMATE Tag [[4, 5, 6]] 0.5\nANIMATECUBIC Tag2 [[7, 8, 9]] 2\nCOPYTO Orig [[0, 0, 0]] NewTag Attr 5\nDELETE Gone\nDELETEALL Tagged\nSPAWNBOT Guard [[1, 1, 1]] Nodes Foo\nINITSTATECOMP Tmpl Attr 1\nSET After 1")
		local names = {}
		for _, e in ipairs(h.events) do names[#names + 1] = e.Command end
		check("world: every world instruction emits a ScriptCommand, in order, without blocking", table.concat(names, " ") == "MOVETO ANIMATE ANIMATECUBIC COPYTO DELETE DELETEALL SPAWNBOT INITSTATECOMP" and h.vars.After == 1)
		check("world: MOVETO keeps its extra argument (real scripts pass 0)", h.events[1].Args[3] == 0 and h.events[1].Args[1] == "LoudTruck" and CF.isCF(h.events[1].Args[2]))
		check("world: ANIMATE args are (tag, CFrame, seconds)", h.events[2].Args[1] == "Tag" and near(h.events[2].Args[3], 0.5))
		check("world: COPYTO / SPAWNBOT pass the rest through", h.events[4].Args[3] == "NewTag" and h.events[4].Args[5] == 5 and h.events[7].Args[3] == "Nodes" and h.events[7].Args[4] == "Foo")
		check("world: events say which script and thread", h.events[1].Script == "t" and h.events[1].Thread == 1 and h.events[1].Kind == "ScriptCommand")
		local h2 = run("MOVETO t Nope\nSET After 1")
		check("world: an unresolved CFrame skips that command (reported), the thread carries on", #h2.events == 0 and h2.vars.After == 1 and #h2.errors == 0 and h2.reports[1]:find("^command%-skipped") ~= nil)
		local h3 = run("ANIMATE t [[1,2,3]] soon\nSET After 1")
		check("world: a bad number skips the command too", #h3.events == 0 and h3.vars.After == 1)
		local h4 = run("DELETE")
		check("world: too few arguments kill the thread (a real syntax error)", #h4.errors == 1 and h4.errors[1]:find("needs 1") ~= nil)
	end

	-- dynamic lines and substitution
	do
		local h = run("INIT #i 1\n*SET V{#i} 5\nSET W {#i}")
		check("subst: a * line substitutes {#local}", h.vars.V1 == 5)
		check("subst: a line WITHOUT * leaves braces alone", h.vars.W == "{#i}")
		local h2 = run("INIT #i 2\n*SET Out {Idx{#i}}", { vars = { Idx1 = "one", Idx2 = "two" } })
		check("subst: nested braces resolve inside-out (real: {Guard{#Iteration}})", h2.vars.Out == "two")
		local h3 = run("*SET R [{#GuardCount} + 1]", { params = { GuardCount = 18 } })
		check("subst: {#Param} reads a script parameter, inside [..] too", h3.vars.R == 19)
		local h4 = run("*SET R {Missing}")
		check("subst: an unknown variable substitutes 0 and is reported", h4.vars.R == 0 and h4.reports[1] == "undeclared:Missing")
		local h5 = run("INIT #i 0\n:loop\nINC #i\n*SET Item{#i} [#i * 10]\n*GOTO loop [#i < ({#N} + 1)]", { params = { N = 3 } })
		check("subst: the real spawn-loop shape works", h5.vars.Item1 == 10 and h5.vars.Item2 == 20 and h5.vars.Item3 == 30 and h5.vars.Item4 == 40 and h5.vars.Item5 == nil)
		local h6 = run("SET R [#Missing + 1]")
		check("subst: an unknown #local in an expression reads 0", h6.vars.R == 1)
		local h7 = run("INIT #i 1\n*SET {#i} x")
		check("subst: a substituted name may be a number", h7.vars["1"] == "x")
	end

	-- instance parameters
	do
		local h = run("SET A #Speed\nSET B #Run", { params = { Speed = 4 } })
		check("params: #Name reads an instance attribute", h.vars.A == 4 and h.vars.B == 0)
		local h2 = run("INIT #Speed 9\nSET A #Speed", { params = { Speed = 4 } })
		check("params: INIT sees a parameter as already existing, so it does not override it", h2.vars.A == 4)
	end

	-- errors, lint, budget
	do
		local p = Script.compile("SET A 1\nBOGUS 1 2\n:a\n:a\nGOTO nowhere\nCALL :alsonowhere\nINIT X\nSET\n[unterminated\nWAITFOR [x", "lint")
		local msgs = {}
		for _, pr in ipairs(p.Problems) do msgs[#msgs + 1] = pr.Line .. ":" .. pr.Message end
		local text = table.concat(msgs, " | ")
		check("lint: unknown instruction", text:find("2:unknown instruction 'BOGUS'", 1, true) ~= nil, text)
		check("lint: duplicate label", text:find("duplicate label 'a'", 1, true) ~= nil)
		check("lint: label not found (with and without colon)", text:find("5:GOTO: label 'nowhere' not found", 1, true) ~= nil and text:find("6:CALL: label 'alsonowhere' not found", 1, true) ~= nil)
		check("lint: INIT without a value", text:find("7:INIT without a value", 1, true) ~= nil)
		check("lint: too few arguments", text:find("8:SET needs 2 argument(s), found 0", 1, true) ~= nil)
		check("lint: unterminated bracket", text:find("unterminated", 1, true) ~= nil)
		check("lint: clean scripts have no problems", #Script.compile("SET A 1\n:x\nGOTO x [0]").Problems == 0)
		check("lint: CRLF line endings and blank lines are fine", #Script.compile("SET A 1\r\n\r\n  \r\nSET B 2\r\n").Problems == 0 and #Script.compile("SET A 1\r\nSET B 2").Code == 2)

		local h = run("SET A 1\nBOGUS\nSET B 1")
		check("errors: an unknown instruction kills the thread when REACHED", h.vars.A == 1 and h.vars.B == nil and h.errors[1]:find("2: unknown instruction 'BOGUS'", 1, true) ~= nil)
		local h2 = run("SET A 1\nGOTO nowhere")
		check("errors: a missing label is a runtime error naming the line", h2.errors[1]:find("2: label 'nowhere' not found", 1, true) ~= nil)
		local h3 = run("SET A [1 +]")
		check("errors: a bad expression is a runtime error", h3.errors[1]:find("bad expression", 1, true) ~= nil)
		local h4 = run("SET A [1 / 0]\nSET B 1")
		check("errors: a soft runtime problem (1 / 0) is 0, not a death", h4.vars.A == 0 and h4.vars.B == 1 and #h4.errors == 0)
		local h5 = run(":f\nCALL f")
		check("errors: runaway recursion is cut off", #h5.errors == 1 and h5.errors[1]:find("call stack overflow", 1, true) ~= nil)
		local h6 = run("SET A 1\n*SET B [unterminated")
		check("errors: an unterminated bracket on a * line is a runtime error", h6.errors[1] ~= nil and h6.errors[1]:find("unterminated", 1, true) ~= nil)

		local hb, instb = run(":loop\nINC N\nGOTO loop", { vars = { N = 0 }, budget = 500 })
		check("budget: an endless loop with no wait is killed after the budget", #hb.errors == 1 and hb.errors[1]:find("instruction budget exceeded (500", 1, true) ~= nil and instb.LiveCount == 0)
		check("budget: ... having really run about that many instructions", hb.vars.N >= 150 and hb.vars.N <= 260, hb.vars.N)
		local hb2, instb2 = run(":loop\nINC N\nWAITHEARTBEAT\nGOTO loop", { vars = { N = 0 }, budget = 50 })
		hb2.advance(1)
		check("budget: a loop that waits is legitimate and is never killed", #hb2.errors == 0 and instb2.LiveCount == 1 and hb2.vars.N >= 59)
		local hb3 = run(":loop\nINC N\nGOTO loop", { vars = { N = 0 } })
		check("budget: the default budget is 10,000", #hb3.errors == 1 and hb3.errors[1]:find("(10000", 1, true) ~= nil)
		local hb4 = run("INIT #i 0\n:l\nINC #i\nGOTO l [#i < 2000]\nSET Done 1")
		check("budget: a long but finite loop within the budget completes", hb4.vars.Done == 1)
	end

	-- debug variables
	do
		local h, inst = run("SET A 1\nWAIT 1\nSET B 1\nWAIT 1", { debugVar = "dbg", debugLine = "dbgLine" })
		check("debug: DebugLineVariable holds the line the thread stopped at (the WAIT on line 2)", h.vars.dbgLine == 2)
		check("debug: DebugVariable counts live threads", h.vars.dbg == 1)
		h.advance(1)
		check("debug: ... and follows the thread along", h.vars.dbgLine == 4)
		h.advance(1)
		check("debug: ... down to 0 when it ends", h.vars.dbg == 0 and inst.LiveCount == 0)
	end

	-- expressions inside scripts use the mission RNG
	do
		local h = run("SET R [RNG 5 1 6]", { seed = 11 })
		local h2 = run("SET R [RNG 5 1 6]", { seed = 11 })
		check("rng: scripts draw from the mission seed", h.vars.R == h2.vars.R and h.vars.R >= 1 and h.vars.R <= 6)
	end

	----------------------------------------------------------------------------------------------- Logic: StateScript component
	local function C(ty, name, attrs) return { Type = ty, Name = name, Path = "DebugMission/StateComponents/" .. name, Attrs = attrs } end
	local function spec(setup, comps, opts) return Logic.fromSpec(setup, comps, opts) end
	local function commands(l)
		local out = {}
		for _, e in ipairs(l:drainEvents()) do if e.Kind == "ScriptCommand" then out[#out + 1] = e end end
		return out
	end

	do
		-- Run mode
		local l = spec({ Globals = { Open = "0" } }, { C("StateScript", "Door", { Run = "Open", ScriptSource = "SET Started 1\nWAIT 5\nSET Late 1\nKILL" }) })
		check("StateScript Run: does not start while the condition is false", l:get("Started") == nil and #l.Scripts == 1)
		l:set("Open", 1)
		check("StateScript Run: starts on the rising edge", l:get("Started") == 1 and l:get("Late") == nil)
		l:advance(5)
		check("StateScript Run: runs to its end", l:get("Late") == 1)
		l:set("Late", 0)
		l:set("Open", 0)
		l:set("Open", 1)
		l:advance(5)
		check("StateScript Run: a new rising edge starts it again", l:get("Late") == 1)

		local l2 = spec({ Globals = { Open = "0" } }, { C("StateScript", "Door", { Run = "Open", ScriptSource = "WAIT 5\nSET Late 1\nKILL" }) })
		l2:set("Open", 1)
		l2:advance(2)
		l2:set("Open", 0)
		l2:advance(10)
		check("StateScript Run: the thread is killed when the condition falls", l2:get("Late") == nil and l2.Scripts[1].LiveCount == 0)

		local l3 = spec({ Globals = { Open = "0" } }, { C("StateScript", "Once", { Run = "Open", ScriptSource = "INC Count\nKILL" }) })
		l3:set("Open", 1)
		l3:advance(10)
		check("StateScript Run: a finished script does not restart while Run stays true", l3:get("Count") == 1)

		local l4 = spec({}, { C("StateScript", "Boot", { Run = "1", ScriptSource = "SET Booted 1" }) })
		check("StateScript Run: Run=1 starts at time 0", l4:get("Booted") == 1)

		-- TriggerEvent mode
		local e = spec({ Globals = { Ev = "0" } }, { C("StateScript", "Evt", { TriggerEvent = "Ev", ScriptSource = "INC Runs\nWAIT 5\nINC Finished\nKILL" }) })
		check("StateScript TriggerEvent: nothing at zero", e:get("Runs") == nil)
		e:set("Ev", 1)
		e:set("Ev", 2)
		check("StateScript TriggerEvent: a fresh thread on every non-zero change", e:get("Runs") == 2 and e.Scripts[1].LiveCount == 2)
		e:set("Ev", 0)
		e:advance(5)
		check("StateScript TriggerEvent: not halted at zero (both threads finish)", e:get("Finished") == 2)
		e:set("Ev", 0)
		check("StateScript TriggerEvent: no change, no thread", e:get("Runs") == 2)

		local ex = spec({ Globals = { Cond = "0", T = "0" } }, { C("StateScript", "ExprEvt", { TriggerEvent = "T == 80 && Cond == 0", ScriptSource = "INC Runs" }) })
		ex:set("T", 80)
		ex:set("T", 81)
		ex:set("T", 80)
		check("StateScript TriggerEvent: may be an expression (real: TruckSpawnTimer == 80 && ...)", ex:get("Runs") == 2)

		local both = spec({ Globals = { Run = "0", Ev = "0" } }, { C("StateScript", "Both", { Run = "Run", TriggerEvent = "Ev", ScriptSource = "INC Runs\nWAIT 100" }) })
		both:set("Run", 1)
		both:set("Ev", 1)
		check("StateScript: Run and TriggerEvent work side by side", both:get("Runs") == 2)
		both:set("Run", 0)
		check("StateScript: Run falling kills only the Run thread", both.Scripts[1].LiveCount == 1)

		local w = spec({}, { C("StateScript", "None", { ScriptSource = "SET A 1" }), C("StateScript", "Empty", { Run = "1" }) })
		check("StateScript: neither Run/TriggerEvent, or no source, is a warning", #w.Warnings == 2 and #w.Errors == 0)

		-- parameters, reserved attributes
		local p = spec({}, { C("StateScript", "Params", { Run = "1", GuardCount = 3, ScriptMove = true, ScriptSource = "SET Count #GuardCount\nSET Move #ScriptMove\nSET R #Run" }) })
		check("StateScript: other attributes are parameters (#GuardCount)", p:get("Count") == 3)
		check("StateScript: reserved attributes (ScriptMove, Run) are not", p:get("Move") == 0 and p:get("R") == 0 and (p.Undeclared["#Run"] or 0) >= 1)

		-- script <-> declarative logic
		local m = spec({ Globals = { Go = "0" } }, {
			C("TimerComponent", "Clock", { SetVariable = "T", StartValue = 0, TargetValue = 100, Increment = 1, Enabled = "Go" }),
			C("StateScript", "Waiter", { Run = "1", ScriptSource = "WAITFOR T >= 3\nSET Hit 1\nKILL" }),
			C("StateUpdate", "Follow", { Watch = "Hit * 10", SetVariable = "Mirror" }),
		})
		m:set("Go", 1)
		m:advance(2.9)
		check("integration: WAITFOR sleeps until a Timer's value arrives", m:get("Hit") == nil and m.Scripts[1].LiveCount == 1)
		m:advance(0.1)
		check("integration: ... wakes at exactly t=3 and a StateUpdate reacts to what the script set", m:get("Hit") == 1 and m:get("Mirror") == 10 and m.Scripts[1].LiveCount == 0)

		local s = spec({ Globals = { Pre = "42" }, Internals = { Hidden = "1" } }, { C("StateScript", "Writer", { Run = "1", ScriptSource = "INIT Pre 7\nINIT Fresh 7\nSET Hidden 5" }) })
		check("integration: INIT leaves Setup variables alone; SET respects a variable's scope", s:get("Pre") == 42 and s:get("Fresh") == 7 and s.Store.Internals.Hidden == 5 and s.Store.Globals.Hidden == nil)
		check("integration: script-made variables replicate like any Global", (function()
			local r = s:addClient("u1")
			return r:get("Fresh") == 7 and r:get("Hidden") == nil
		end)())

		local dbg = spec({}, { C("StateScript", "Dbg", { Run = "1", DebugVariable = "dv", DebugLineVariable = "dl", ScriptSource = "WAIT 1\nSET A 1" }) })
		check("integration: debug variables are declared and updated", dbg:get("dv") == 1 and dbg:get("dl") == 1)

		-- CFrame variables are shared between scripts but are not replicated
		local objs = spec({ Globals = { Which = "0" } }, {
			C("StateScript", "Remember", { Run = "Which", ScriptSource = "CFRCOPY Prev Thing" }),
			C("StateScript", "Use", { Run = "!Which", ScriptSource = "MOVETO Thing Prev" }),
		}, { world = { cframeOf = function(tag) return CF.new(9, 8, 7) end } })
		check("objects: a script that runs before the CFrame exists skips the command and reports it", #commands(objs) == 0 and (objs.Issues["command-skipped: Use: MOVETO: no CFrame variable named 'Prev'"] or 0) == 1, next(objs.Issues))
		objs:set("Which", 1)
		objs:set("Which", 0)
		local cmds = commands(objs)
		check("objects: CFRCOPY into a global makes a CFrame another script can read", #cmds == 1 and cmds[1].Command == "MOVETO" and near(cmds[1].Args[2][1], 9))
		local r = objs:addClient("u1")
		check("objects: CFrame variables are not replicated", r:get("Prev") == nil and objs.Store.Globals.Prev == nil)
		objs:set("Prev", 5)
		check("objects: a number written over a CFrame variable replaces it", objs.Objects.prev == nil and objs:get("Prev") == 5)

		-- errors and lint reach Logic
		local bad = spec({}, { C("StateScript", "Bad", { Run = "1", ScriptSource = "SET A 1\nBOGUS\nGOTO nowhere" }) })
		check("integration: lint findings become Warnings with the line", #bad.Warnings >= 2 and bad.Warnings[1].Where:find("ScriptSource line 2", 1, true) ~= nil)
		check("integration: a runtime script error becomes an Error with path:line", #bad.Errors == 1 and bad.Errors[1].Where == "DebugMission/StateComponents/Bad:2", bad.Errors[1] and bad.Errors[1].Where)
		local budgeted = spec({}, { C("StateScript", "Loop", { Run = "1", ScriptSource = ":l\nGOTO l" }) }, { scriptBudget = 100 })
		check("integration: scriptBudget is honoured and the engine keeps running", #budgeted.Errors == 1 and budgeted:advance(1) == true)

		-- determinism
		local function log(seed)
			local lg = spec({ Globals = { Go = "1" } }, {
				C("StateScript", "Roll", { Run = "Go", ScriptSource = "SHUFFLE s 1 a b c d e\nGUID g\nSET Roll [RNG 3 1 1000]\n*MOVETO P{#i} [[1,2,3]]\nWAIT 1.5\nSET Pick s0" }),
			}, { seed = seed })
			lg:advance(3)
			return table.concat({ tostring(lg:get("s0")), tostring(lg:get("s1")), tostring(lg:get("g")), tostring(lg:get("Roll")), tostring(lg:get("Pick")) }, ",")
		end
		check("determinism: scripts replay identically for one seed", log(5) == log(5))
		check("determinism: and differ across seeds", log(5) ~= log(6))
	end

	----------------------------------------------------------------------------------------------- the real scripts
	local okE, emb = pcall(require, "./_embedded")
	if not okE then
		print("(real-map script tests skipped: tests/_embedded.luau not found)")
		return
	end
	local Codec = require("../BreachCodec")
	local Zstd = require("../BreachZstd")
	local Mission = require("../BreachMission")
	local Validator = require("../BreachValidator")
	local host = { zstdDecompress = Zstd.decompress }

	local totalScripts, totalLint, lintKinds = 0, 0, {}
	for _, mapName in ipairs({ "TheDiplomat.base64", "thepeacemaker.txt" }) do
		local label = mapName:gsub("%..*", "")
		local d = Codec.decode(emb[mapName], host)
		local m = Mission.build(d, { validator = Validator })
		local nodes = m:byComponent("StateScript") or {}
		local active = 0
		local unknownInstr, labels, syntax, initNoVal, instrUsed = 0, 0, 0, 0, {}
		for _, node in ipairs(nodes) do
			local program = Script.compile(node.Attrs.ScriptSource or "", node.Name)
			if node.Path:find("/StateComponents/", 1, true) then active += 1 end
			totalScripts += 1
			for _, ins in ipairs(program.Code) do instrUsed[ins.Cmd] = true end
			for _, pr in ipairs(program.Problems) do
				totalLint += 1
				if pr.Message:find("unknown instruction", 1, true) then unknownInstr += 1
				elseif pr.Message:find("label", 1, true) then labels += 1
				elseif pr.Message:find("INIT without a value", 1, true) then initNoVal += 1
				else syntax += 1 print("    lint: " .. node.Name .. ":" .. pr.Line .. " " .. pr.Message) end
			end
		end
		check(label .. " [script]: " .. #nodes .. " real StateScripts compile with no unknown instructions, missing labels or syntax problems", unknownInstr == 0 and labels == 0 and syntax == 0)
		local used = {}
		for k in pairs(instrUsed) do used[#used + 1] = k end
		table.sort(used)
		print(("  %s: %d StateScripts (%d run), instructions used: %s | INIT without a value: %d"):format(label, #nodes, active, table.concat(used, " "), initNoVal))
	end

	-- run a whole real map with the scripts live
	local Diplomat = Mission.build(Codec.decode(emb["TheDiplomat.base64"], host), { validator = Validator })
	local props = function(tag) return CF.new(#tag, 1, 2) end
	local function makeDiplomat() return Logic.new(Diplomat, { seed = 416, builtins = { Mission_Difficulty = 2, Mission_PlayerTotal = 1 }, world = { cframeOf = props } }) end
	local dl = makeDiplomat()
	check("The Diplomat [script]: builds with the scripts live, no Errors", #dl.Errors == 0, dl.Errors[1] and (dl.Errors[1].Where .. " " .. dl.Errors[1].Message))
	check("The Diplomat [script]: its 4 active StateScripts are instantiated", #dl.Scripts == 4, #dl.Scripts)
	dl:drainEvents()
	dl:set("DriveTruck", 1) -- the TruckRun script's TriggerEvent
	dl:advance(10)
	local seq = {}
	for _, ev in ipairs(commands(dl)) do
		if ev.Script == "TruckRun" then seq[#seq + 1] = ("%s %s @%.2f"):format(ev.Command, ev.Args[1], ev.Time) end
	end
	check("The Diplomat [script]: TruckRun plays its timed sequence exactly (WAIT 2, 1.5, .2, .5, .2)", table.concat(seq, " | ") == "ANIMATECUBIC BollardTag0 @2.00 | ANIMATECUBIC BollardTag1 @2.00 | ANIMATE TruckTag @3.50 | ANIMATE TruckTag @3.70 | ANIMATE TruckTag @4.20 | ANIMATE TruckTag @4.40 | ANIMATE GarageCarTag @4.40", table.concat(seq, " | "))
	check("The Diplomat [script]: ... and sets TruckFinish at the end", dl:get("TruckFinish") == 1)
	local ev1 = nil
	local dl2 = makeDiplomat()
	dl2:drainEvents()
	dl2:set("PoolTableFlip", 1)
	for _, ev in ipairs(commands(dl2)) do if ev.Script == "PoolTableFlip" then ev1 = ev end end
	check("The Diplomat [script]: PoolTableFlip fires from its TriggerEvent with the copied prop CFrame", ev1 ~= nil and ev1.Command == "ANIMATECUBIC" and ev1.Args[1] == "PoolTable" and near(ev1.Args[3], 0.7) and near(ev1.Args[2][1], #"TableCfrRef"))
	check("The Diplomat [script]: SpawnBots runs at start (Run=1) and does not kill the engine", (function()
		local c = makeDiplomat()
		c:advance(5)
		return #c.Errors == 0
	end)())
	local spawnIssues = {}
	for k in pairs(dl.Issues) do spawnIssues[#spawnIssues + 1] = k end
	print(("  The Diplomat: the bot-spawn script resolves {Guard1} etc. from variables a VariableShuffle component would set (not implemented yet): %d issues, e.g. %s"):format(#spawnIssues, (spawnIssues[1] or "-"):sub(1, 110)))

	local Peace = Mission.build(Codec.decode(emb["thepeacemaker.txt"], host), { validator = Validator })
	local function makePeace() return Logic.new(Peace, { seed = 416, builtins = { Mission_Difficulty = 2, Mission_PlayerTotal = 1, Mission_TacticalDifficulty = 0 }, world = { cframeOf = props } }) end
	local pl = makePeace()
	check("The Peacemaker [script]: builds with all its StateScripts live, no Errors", #pl.Errors == 0, pl.Errors[1] and (pl.Errors[1].Where .. " " .. pl.Errors[1].Message))
	print(("  The Peacemaker: %d StateScripts instantiated"):format(#pl.Scripts))
	pl:drainEvents()
	pl:set("BlastDoorOutOpen", 1)
	local doorCmds = {}
	for _, ev in ipairs(commands(pl)) do if ev.Script == "OutOpen" then doorCmds[#doorCmds + 1] = ev end end
	check("The Peacemaker [script]: OutOpen animates both blast doors", #doorCmds == 2 and doorCmds[1].Args[1] == "BlastDoorRightOut" and doorCmds[2].Args[1] == "BlastDoorLeftOut" and near(doorCmds[1].Args[3], 5))
	local rightDoor = doorCmds[1] and doorCmds[1].Args[2]
	check("The Peacemaker [script]: the door CFrame is position * Rot(0, 90°, 0), straight from the script's numbers", rightDoor ~= nil and near(rightDoor[1], 10.499) and near(rightDoor[2], -6.6) and near(rightDoor[3], -97.425) and near(rightDoor[6], 1) and near(rightDoor[10], -1))
	pl:advance(300)
	check("The Peacemaker [script]: 300 s with scripts live, still no Errors", #pl.Errors == 0, pl.Errors[1] and (pl.Errors[1].Where .. " " .. pl.Errors[1].Message))
	local issueKinds = {}
	for k, n in pairs(pl.Issues) do issueKinds[#issueKinds + 1] = k:sub(1, 70) .. " x" .. n end
	table.sort(issueKinds)
	if #issueKinds > 0 then print("  The Peacemaker: soft script issues: " .. table.concat(issueKinds, "; "):sub(1, 400)) end

	local function sig(make)
		local lg = make()
		lg:set("BlastDoorOutOpen", 1)
		local out = {}
		for _ = 1, 120 do
			lg:advance(1)
			for _, ev in ipairs(lg:drainEvents()) do
				if ev.Kind == "ScriptCommand" then out[#out + 1] = ("%s@%g:%s:%s"):format(ev.Command, ev.Time, ev.Script, tostring(ev.Args[1])) end
			end
		end
		return table.concat(out, "\n")
	end
	check("The Peacemaker [script]: two runs produce the same script commands", sig(makePeace) == sig(makePeace))
end
