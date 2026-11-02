--!nonstrict
--[==[
	BreachBots — bots and patrols (BreachEngine M8b; plan: BreachEngine_M8_Bots_Plan.md §5).

	Pure Luau, deterministic (one seeded RNG), no Roblox APIs. It owns the BOT MODEL (who a bot is, what it carries, which
	route it walks, when it despawns) and drives movement through a BreachNav. Vision, alert and hostages come later (M8c, M8d).

	    local bots = Bots.new(mission, world, logic, nav, { seed = 416 })
	    -- each frame:  logic:advance(dt)   bots:step(dt)          (bots steps `nav` itself)
	    for _, ev in ipairs(bots:drainEvents()) do ... end         -- BotSpawned BotArrived BotDeparted BotDespawned BotPathFailed BotReached
	    bots:alive()   bots:withTag("Chef")   bots:bot(id)   bots:setFlag(id, "Hostage", true)   Bots.parseInv("A_tag|B=cond")

	What is built from the real maps (7 / 57 / 44 bots) and what is a choice:
	    Bots are BoolValues under Bots/ (folders with a false Condition, or named Disabled, are skipped).
	    `Nodes` / `NodesBreak` name a folder (or a single part) under Nodes/ [O]; a folder's parts, in order, are the route [O].
	                     A value may list several names separated by spaces [O]; the bot walks one of them, chosen from the seed [P].
	    PatrolWalk       walks the route in a loop and pauses PatrolCycleLength seconds at each node;  >= 10000 = a static post [P]
	    WorkWithBreaks   works the `Nodes` route for WorkSeconds, then goes to a `NodesBreak` node for BreakSeconds [P]
	    start            bots that share a route start spread along it (k-th bot starts at node k) [P]
	    Inv              "Item[_tag][=condition]" entries separated by single '|' ('||' inside a condition is not a separator) [R]
	    DespawnCondition removes the bot when `DespawnCondition && !DespawnBlocked` is true [R]
	    BotStateTracker  (a component) keeps Total/Hostage/Incapacitation/Death/ClientKill/Flee count variables per BotServerTag [R]
	[P] values live in Bots.Defaults.
]==]

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

local Bots = {}
Bots.VERSION = "0.1.0"

Bots.Defaults = {
	WalkSpeed = 9, -- studs/s while patrolling
	DefaultDwell = 1.5, -- PatrolCycleLength when a bot sets none (the most common real value)
	StaticDwell = 10000, -- a PatrolCycleLength at or above this means "never leaves its post"
	WorkSeconds = 60,
	BreakSeconds = 20,
	RetrySeconds = 4, -- after a failed path
	MaxPathFailures = 3, -- then the bot skips that node
}

local function isBlank(v)
	return v == nil or v == "" or (type(v) == "string" and not v:match("%S"))
end

local function lower(s)
	return tostring(s):lower()
end

local function tagSet(s)
	local set, list = {}, {}
	if type(s) == "string" then
		for t in s:gmatch("%S+") do
			set[lower(t)] = true
			list[#list + 1] = t
		end
	end
	return set, list
end

-- "Item_tag=condition|Item2|Item3_tag3": Item, optional _tag, optional =condition. '||' inside a condition stays together.
function Bots.parseInv(text)
	local out = {}
	if type(text) ~= "string" or isBlank(text) then
		return out
	end
	local protected = text:gsub("||", "\1\1")
	for piece in protected:gmatch("[^|]+") do
		piece = piece:gsub("\1\1", "||"):match("^%s*(.-)%s*$")
		if piece ~= "" then
			local head, cond = piece, nil
			local eq = piece:find("=", 1, true)
			if eq then
				head, cond = piece:sub(1, eq - 1), piece:sub(eq + 1)
				head, cond = head:match("^%s*(.-)%s*$"), cond:match("^%s*(.-)%s*$")
			end
			local item, tag = head, nil
			local us = head:find("_", 1, true)
			if us then
				item, tag = head:sub(1, us - 1), head:sub(us + 1)
			end
			out[#out + 1] = { Item = item, Tag = tag, Condition = (cond ~= "" and cond) or nil }
		end
	end
	return out
end

--------------------------------------------------------------------------------------------------- routes

local function nodeRecord(part)
	local p = part.Props and part.Props.CFrame and part.Props.CFrame.Position
	if not p then
		return nil
	end
	return { X = p.X or 0, Y = p.Y or 0, Z = p.Z or 0, Name = part.Name, Attrs = part.Attrs or {}, Part = part }
end

local function partsOf(node, out)
	for _, ch in ipairs(node.Children or {}) do
		if ch.ClassName == "Part" or ch.ClassName == "MeshPart" then
			local r = nodeRecord(ch)
			if r then
				out[#out + 1] = r
			end
		elseif ch.ClassName == "Folder" then
			partsOf(ch, out)
		end
	end
	return out
end

-- name -> list of node records (the parts of the folder in order, or the single part). Case-insensitive; top level first.
local function resolveRoute(root, name)
	if root == nil or isBlank(name) then
		return nil
	end
	local want = lower(name)
	local found
	for _, ch in ipairs(root.Children or {}) do
		if lower(ch.Name) == want then
			found = ch
			break
		end
	end
	if not found then
		local function search(node)
			for _, ch in ipairs(node.Children or {}) do
				if lower(ch.Name) == want then
					found = ch
					return
				end
				search(ch)
				if found then
					return
				end
			end
		end
		search(root)
	end
	if not found then
		return nil
	end
	if found.ClassName == "Folder" then
		local list = partsOf(found, {})
		return #list > 0 and list or nil
	end
	local r = nodeRecord(found)
	return r and { r } or nil
end

--------------------------------------------------------------------------------------------------- the simulation

local Sim = {}
Sim.__index = Sim

local function emit(self, kind, bot, extra)
	local ev = { Kind = kind, Bot = bot and bot.Id, Time = self.Time }
	for k, v in pairs(extra or {}) do
		ev[k] = v
	end
	self.Events[#self.Events + 1] = ev
end

function Sim:drainEvents()
	local e = self.Events
	self.Events = {}
	return e
end

local function dwellOf(self, bot)
	local v = tonumber(bot.Attrs.PatrolCycleLength)
	if v == nil or v <= 0 then
		return self.Params.DefaultDwell
	end
	return v
end

local function isStatic(self, bot)
	return #bot.Route <= 1 or dwellOf(self, bot) >= self.Params.StaticDwell
end

-- Is a route node in play? (a node with an ActiveVariable only counts while that variable is true)
local function nodeActive(self, node)
	local v = node.Attrs.ActiveVariable
	if isBlank(v) then
		return true
	end
	local r = self.Logic:eval(v)
	return r ~= nil and r ~= 0 and r ~= ""
end

local function goTo(self, bot, node, index)
	bot.Target = index
	bot.State = "Walking"
	self.Nav:goto(bot.Id, node.X, node.Y, node.Z)
	emit(self, "BotDeparted", bot, { Node = index })
end

local function nextIndex(self, bot, route, from)
	local n = #route
	for step = 1, n do
		local i = (from - 1 + step) % n + 1
		if nodeActive(self, route[i]) then
			return i
		end
	end
	return from
end

local function startDwell(self, bot, seconds)
	bot.State = "Dwelling"
	bot.Timer = seconds
end

local function depart(self, bot)
	if bot.Behavior == "WorkWithBreaks" and #bot.BreakRoute > 0 then
		if bot.Phase == "Work" and bot.PhaseTimer <= 0 then
			bot.Phase = "Break"
			bot.PhaseTimer = self.Params.BreakSeconds
			bot.BreakCount += 1
			local i = Random.derive(self.Seed, bot.Seq * 977 + bot.BreakCount, 1, #bot.BreakRoute)
			bot.BreakIndex = i
			goTo(self, bot, bot.BreakRoute[i], i)
			return
		elseif bot.Phase == "Break" and bot.PhaseTimer <= 0 then
			bot.Phase = "Work"
			bot.PhaseTimer = self.Params.WorkSeconds
			local i = nextIndex(self, bot, bot.Route, bot.Index)
			goTo(self, bot, bot.Route[i], i)
			return
		elseif bot.Phase == "Break" then
			startDwell(self, bot, math.max(0.1, bot.PhaseTimer))
			return
		end
	end
	local i = nextIndex(self, bot, bot.Route, bot.Index)
	goTo(self, bot, bot.Route[i], i)
end

local function onArrived(self, bot)
	bot.Failures = 0
	local route = (bot.Phase == "Break") and bot.BreakRoute or bot.Route
	bot.Index = bot.Target or bot.Index
	local node = route[bot.Index]
	emit(self, "BotArrived", bot, { Node = bot.Index, Anim = node and node.Attrs.Anim, Phase = bot.Phase })
	if bot.Behavior == "PassingCivilian" then -- a passer-by walks its route once and is gone at the end
		if bot.Index >= #route then
			self:despawn(bot, "Passed")
		else
			goTo(self, bot, route[bot.Index + 1], bot.Index + 1)
		end
		return
	end
	if bot.Phase == "Break" then
		startDwell(self, bot, math.max(0.1, bot.PhaseTimer))
	elseif isStatic(self, bot) then
		bot.State, bot.Timer = "Dwelling", math.huge
	else
		startDwell(self, bot, dwellOf(self, bot))
	end
end

--------------------------------------------------------------------------------------------------- state trackers and flags

local FLAGS = { Hostage = "HostageCountVariable", Incapacitated = "IncapacitationCountVariable", Dead = "DeathCountVariable", ClientKilled = "ClientKillCountVariable", Fled = "FleeCountVariable" }

function Sim:recount()
	for _, tr in ipairs(self.Trackers) do
		local total, counts = 0, { Hostage = 0, Incapacitated = 0, Dead = 0, ClientKilled = 0, Fled = 0 }
		for _, bot in ipairs(self.List) do
			if bot.State ~= "Despawned" and (tr.TagKey == nil or bot.TagSet[tr.TagKey]) then
				total += 1
				for flag in pairs(counts) do
					if bot.Flags[flag] then
						counts[flag] += 1
					end
				end
			end
		end
		self.Logic:set(tr.Totals, total)
		for flag, var in pairs(FLAGS) do
			if not isBlank(tr.Attrs[var]) then
				self.Logic:set(tr.Attrs[var], counts[flag])
			end
		end
	end
end

function Sim:setFlag(id, flag, value)
	local bot = self.ById[id]
	if not bot or FLAGS[flag] == nil then
		return false
	end
	bot.Flags[flag] = value and true or nil
	if flag == "Dead" and value then
		self.Nav:stop(bot.Id)
		bot.State = "Dead"
	end
	self:recount()
	return true
end

-- Commands from the alert layer [M8c]. A commanded bot leaves its patrol: State becomes `state` (e.g. "Fleeing", "Radioing",
-- "Questioning") and the patrol logic ignores it until resume(). command() walks it to a point and emits BotReached on
-- arrival; hold() stops it where it stands.
function Sim:command(id, state, x, y, z)
	local bot = self.ById[id]
	if not bot or bot.State == "Despawned" or bot.State == "Dead" then
		return false
	end
	bot.Command, bot.State = state, state
	if x then
		self.Nav:goto(bot.Id, x, y, z)
		bot.State = "Going:" .. state
	else
		self.Nav:stop(bot.Id)
	end
	return true
end

function Sim:hold(id, state)
	return self:command(id, state)
end

-- back to the patrol: head for the route node it was heading to
function Sim:resume(id)
	local bot = self.ById[id]
	if not bot or bot.State == "Despawned" or bot.State == "Dead" or not bot.Command then
		return false
	end
	bot.Command = nil
	local route = (bot.Phase == "Break") and bot.BreakRoute or bot.Route
	local idx = bot.Target or bot.Index
	if route[idx] then
		goTo(self, bot, route[idx], idx)
	else
		bot.State, bot.Timer = "Dwelling", 0
	end
	return true
end

function Sim:despawn(bot, reason)
	if bot.State == "Despawned" then
		return
	end
	bot.State = "Despawned"
	self.Nav:removeAgent(bot.Id)
	emit(self, "BotDespawned", bot, { Reason = reason })
	self:recount()
end

--------------------------------------------------------------------------------------------------- step

function Sim:step(dt)
	self.Time += dt
	self.Nav:step(dt)
	for _, ev in ipairs(self.Nav:drainEvents()) do
		local bot = self.ById[ev.Agent]
		if bot and ev.Kind == "Arrived" and bot.State == "Walking" then
			onArrived(self, bot)
		elseif bot and ev.Kind == "Arrived" and bot.Command then
			bot.State = bot.Command
			emit(self, "BotReached", bot, { Command = bot.Command })
		elseif bot and ev.Kind == "PathFailed" and bot.Command then
			bot.State = bot.Command -- a commanded bot that cannot get there stays where it is; the commander polls State
			emit(self, "BotReached", bot, { Command = bot.Command, Failed = true })
		elseif bot and ev.Kind == "PathFailed" then
			bot.Failures += 1
			emit(self, "BotPathFailed", bot, { Node = bot.Target, Failures = bot.Failures })
			bot.State, bot.Timer = "Retry", self.Params.RetrySeconds
		end
	end
	for _, bot in ipairs(self.List) do
		if bot.State ~= "Despawned" and bot.State ~= "Dead" then
			if bot.Behavior == "WorkWithBreaks" and (bot.State == "Dwelling" or bot.State == "Walking") then
				bot.PhaseTimer -= dt
			end
			if bot.State == "Dwelling" then
				bot.Timer -= dt
				if bot.Timer <= 0 then
					depart(self, bot)
				end
			elseif bot.State == "Retry" then
				bot.Timer -= dt
				if bot.Timer <= 0 then
					local route = (bot.Phase == "Break") and bot.BreakRoute or bot.Route
					local idx = bot.Target or bot.Index
					if bot.Failures >= self.Params.MaxPathFailures then
						idx = nextIndex(self, bot, route, idx) -- give up on that node
						bot.Failures = 0
					end
					goTo(self, bot, route[idx], idx)
				end
			end
		end
	end
end

--------------------------------------------------------------------------------------------------- queries

function Sim:bot(id)
	return self.ById[id]
end

function Sim:all()
	return self.List
end

function Sim:alive()
	local out = {}
	for _, b in ipairs(self.List) do
		if b.State ~= "Despawned" and b.State ~= "Dead" then
			out[#out + 1] = b
		end
	end
	return out
end

function Sim:withTag(tag)
	local k, out = lower(tag), {}
	for _, b in ipairs(self.List) do
		if b.TagSet[k] and b.State ~= "Despawned" then
			out[#out + 1] = b
		end
	end
	return out
end

-- The direction a bot faces (x, z): its movement heading while it walks; the look direction of the node it stands at otherwise
-- (a node part's CFrame, LookVector = -Z) [P]; falls back to the last heading, then +X.
function Sim:facing(bot)
	if type(bot) == "string" then
		bot = self.ById[bot]
	end
	if not bot then
		return nil
	end
	local ag = self.Nav:agent(bot.Id)
	if ag and ag.Speed > 0.5 then
		local hx, hz = self.Nav:heading(bot.Id)
		if hx then
			return hx, hz
		end
	end
	local route = (bot.Phase == "Break") and bot.BreakRoute or bot.Route
	local node = route[bot.Index]
	local e = node and node.Part and node.Part.Props and node.Part.Props.CFrame and node.Part.Props.CFrame.EulerXYZ
	if e then
		-- LookVector = R * (0, 0, -1) with R = Rx * Ry * Rz; only the horizontal part matters
		local cx, cy, sy = math.cos(e.X or 0), math.cos(e.Y or 0), math.sin(e.Y or 0)
		local lx, lz = -sy * 1, -(cx * cy)
		local len = math.sqrt(lx * lx + lz * lz)
		if len > 1e-6 then
			return lx / len, lz / len
		end
	end
	local hx, hz = self.Nav:heading(bot.Id)
	if hx then
		return hx, hz
	end
	return 1, 0
end

function Sim:position(id)
	return self.Nav:position(id)
end

function Sim:summary()
	local by, alive = {}, 0
	for _, b in ipairs(self.List) do
		by[b.Behavior] = (by[b.Behavior] or 0) + 1
		if b.State ~= "Despawned" and b.State ~= "Dead" then
			alive += 1
		end
	end
	return { Bots = #self.List, Alive = alive, Behaviors = by, Skipped = #self.Skipped, Warnings = #self.Warnings, Trackers = #self.Trackers }
end

--------------------------------------------------------------------------------------------------- build

local function warn(self, where, msg)
	self.Warnings[#self.Warnings + 1] = { Where = where, Message = msg }
end

local function collectBots(logic, root, warnFn)
	local out = {}
	local function walk(node, ok)
		for _, ch in ipairs(node.Children or {}) do
			local childOk = ok
			if ch.ClassName == "Folder" then
				if ch.Name == "Disabled" then
					childOk = false
				elseif not isBlank(ch.Attrs and ch.Attrs.Condition) then
					local v = logic:eval(ch.Attrs.Condition)
					if v == nil then
						warnFn((ch.Path or ch.Name) .. ".Condition", "could not evaluate; treated as false")
					end
					childOk = ok and v ~= nil and v ~= 0 and v ~= ""
				end
			end
			if childOk and ch.ClassName == "BoolValue" and ch.Attrs then
				out[#out + 1] = ch
			end
			walk(ch, childOk)
		end
	end
	walk(root, true)
	return out
end

-- Creates one bot from a Bots-folder node (or a synthetic node for spawn()). Returns the bot, or nil when it cannot be made.
local function createBot(self, node)
	local params, nav, logic, nodesRoot = self.Params, self.Nav, self.Logic, self.NodesRoot
	local created
	local a = node.Attrs
	local where = node.Path or node.Name
	local behavior = isBlank(a.Behavior) and "PatrolWalk" or a.Behavior
	local seqNext = #self.List + 1
	-- `Nodes` / `NodesBreak` may list several route names separated by spaces (a real Peacemaker bot has "SecPatrol SecQuarter2");
	-- the bot walks ONE of those that exist, chosen once from the seed [P]
	local function choose(value, salt)
		local found = {}
		for name in tostring(value or ""):gmatch("%S+") do
			local r = resolveRoute(nodesRoot, name)
			if r then
				found[#found + 1] = { Name = name, Route = r }
			end
		end
		if #found == 0 then
			return nil, nil, 0
		end
		local pick = found[#found == 1 and 1 or Random.derive(self.Seed, seqNext * 131 + salt, 1, #found)]
		return pick.Route, pick.Name, #found
	end
	local route, routeName, choices = choose(a.Nodes, 1)
	local brk = choose(a.NodesBreak, 2) or {}
	if behavior ~= "PatrolWalk" and behavior ~= "WorkWithBreaks" and behavior ~= "PassingCivilian" then
		self.Skipped[#self.Skipped + 1] = { Where = where, Reason = "behaviour '" .. tostring(behavior) .. "' is not implemented yet" }
	elseif not route then
		self.Skipped[#self.Skipped + 1] = { Where = where, Reason = "route '" .. tostring(a.Nodes) .. "' not found under Nodes/" }
		warn(self, where .. ".Nodes", "route '" .. tostring(a.Nodes) .. "' not found; the bot is not created")
	else
		local seq = #self.List + 1
		local key = lower(routeName)
		self.RouteUse[key] = (self.RouteUse[key] or 0) + 1
		local startIndex = (self.RouteUse[key] - 1) % #route + 1
		local set, list = tagSet(a.ServerTag)
		local bot = {
			Id = node.Id or where, Name = node.Name, Node = node, Attrs = a, Seq = seq, Behavior = behavior, Route = route, BreakRoute = brk, RouteName = routeName, RouteChoices = choices,
			Index = startIndex, Target = startIndex, TagSet = set, Tags = list, Class = a.Class, Profile = a.Profile, Outfit = a.Outfit,
			Weapon = a.Weapon, Inv = Bots.parseInv(a.Inv), HostageDifficulty = tonumber(a.HostageDifficulty) or 0,
			DetectionSpeed = tonumber(a.DetectionSpeed) or 1, SearchArea = a.SearchArea, ClientTag = a.ClientTag, Flags = {},
			State = "Dwelling", Timer = 0, Phase = "Work", PhaseTimer = params.WorkSeconds, BreakCount = 0, Failures = 0,
		}
		local start = route[startIndex]
		nav:addAgent(bot.Id, start.X, start.Y, start.Z, { MaxSpeed = params.WalkSpeed })
		-- spread the first departures so bots on one route do not all leave in the same tick
		local frac = Random.derive(self.Seed, seq * 7919, 0, 1000) / 1000
		if isStatic(self, bot) then
			bot.Timer = math.huge
		else
			bot.Timer = dwellOf(self, bot) * frac
		end
		self.List[#self.List + 1] = bot
		created = bot
		self.ById[bot.Id] = bot
		emit(self, "BotSpawned", bot, { Behavior = behavior, Route = routeName })

		local cond = a.DespawnCondition
		if not isBlank(cond) then
			local src = "(" .. tostring(cond) .. ")"
			if not isBlank(a.DespawnBlocked) then
				src = src .. " && !(" .. tostring(a.DespawnBlocked) .. ")"
			end
			logic:watch(src, function(v)
				if v ~= nil and v ~= 0 and v ~= "" then
					self:despawn(bot, "DespawnCondition")
				end
			end, where .. ".DespawnCondition")
		end
	end

	return created
end

-- A bot made while the mission runs (RandomBotSpawner). `attrs` are bot attributes (Behavior, Nodes, ServerTag, Class ...).
function Sim:spawn(attrs, name)
	self.SpawnCount = (self.SpawnCount or 0) + 1
	local id = "spawn:" .. tostring(name or "bot") .. "#" .. self.SpawnCount
	local node = { Id = id, Name = tostring(name or "bot") .. "#" .. self.SpawnCount, Path = id, Attrs = attrs, Children = {} }
	local bot = createBot(self, node)
	if bot then
		bot.Spawned = true
		self:recount()
	end
	return bot
end

-- deterministic integer in [lo, hi] from the mission seed and a salt (for the layers above)
function Sim:rand(salt, lo, hi)
	return Random.derive(self.Seed, salt, lo, hi)
end

function Bots.new(mission, world, logic, nav, opts)
	opts = opts or {}
	local params = {}
	for k, v in pairs(Bots.Defaults) do
		params[k] = v
	end
	for k, v in pairs(opts.params or {}) do
		params[k] = v
	end
	local self = setmetatable({
		Mission = mission, World = world, Logic = logic, Nav = nav, Params = params, Seed = opts.seed or 0, Time = 0,
		List = {}, ById = {}, Events = {}, Warnings = {}, Skipped = {}, Trackers = {}, RouteUse = {},
	}, Sim)

	local botsRoot = mission:folder("Bots")
	local nodesRoot = mission:folder("Nodes")
	if not botsRoot then
		return nil, "BreachBots: the mission has no Bots folder"
	end

	self.NodesRoot = nodesRoot
	for _, node in ipairs(collectBots(logic, botsRoot, function(where, msg) warn(self, where, msg) end)) do
		createBot(self, node)
	end

	-- BotStateTracker components keep count variables per tag
	for _, comp in ipairs(mission:byComponent("BotStateTracker") or {}) do
		if (comp.Path or ""):find("/StateComponents/", 1, true) then
			local tag = comp.Attrs.BotServerTag
			self.Trackers[#self.Trackers + 1] = { Attrs = comp.Attrs, TagKey = (not isBlank(tag)) and lower(tag) or nil, Totals = comp.Attrs.TotalCountVariable }
			if isBlank(comp.Attrs.TotalCountVariable) then
				self.Trackers[#self.Trackers].Totals = "__BotTotal_" .. tostring(#self.Trackers)
			end
		end
	end
	logic:settle()
	self:recount()
	return self
end

return Bots
