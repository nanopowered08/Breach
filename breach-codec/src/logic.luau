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
--@@RANDOM@@
end)()

local Expr = (function()
--@@EXPR@@
end)()

local CF = (function()
--@@CFRAME@@
end)()

local Script = (function()
--@@SCRIPT@@
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
