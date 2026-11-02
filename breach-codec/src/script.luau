--!nonstrict
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
