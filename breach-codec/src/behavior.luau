--!nonstrict
--[==[
	BreachBehavior — CustomBehavior scripts, their conditions, and the bot spawners (BreachEngine M8e; plan §3).

	Pure Luau, deterministic. Built on a logic core, BreachBots (the bots; spawn/command/hold/resume) and BreachNav; optionally
	BreachAlert (ENTERCOMBAT sets the Fighting flag).

	    local bh = Behavior.new(logic, { mission = mission, bots = bots, nav = nav, alert = alert, players = playersFn })
	    bh:step(dt)                         -- after bots:step
	    bh:isRunning(botId)  bh:sourceOf(botId)
	    bh:drainEvents()
	    -- BehaviorStarted {Bot, Source, Priority}  BehaviorFinished {Bot, Source, Why}  BotSay {Bot, Line, Text}  BotPose {Bot, Pose, On}
	    -- BotCheckpoint {Bot}  BotEnterCombat {Bot}  SpawnerSpawned {Bot, Spawner}

	Components [O = attributes from the real maps and Appendix A, R = observed, P = my reading]:
	  * CustomBehaviorCondition {BotServerTag, Condition, CustomBehavior, Priority = Custom1..5, LoopApply}: while Condition holds,
	    every bot with the tag runs the script; of several true conditions the HIGHEST priority number wins [P]; LoopApply restarts the
	    script when it ends [O: 16 of 20 real ones loop]. When the condition ends (or a higher one takes over) the script stops and the
	    bot goes back to its patrol [P]. A bot that is a hostage, a body, dead, fled, or commanded by something else (an alert
	    reaction) is left alone.
	  * AlarmedBehaviorOverride {BotServerTag, CustomBehavior}: once Mission_AlarmRaised is up, the tagged bots run the script instead,
	    once, above every custom condition [O: the Diplomat's flees to a saferoom and sets PanicRoomTrigger]. The ones under Disabled/
	    are ignored.
	  * RandomBotSpawner {SpawningActive, SpawnTimeMin, SpawnTimeMax, Behavior, Class, Profile, Outfit, Nodes, Tag ...}: while active, a
	    bot is spawned every random SpawnTimeMin..SpawnTimeMax seconds (seeded), tagged with `ServerTag` or `Tag` [O: real spawners
	    make PassingCivilian bots that walk their route once and are gone].

	The script language [O: all commands found in the three real maps; semantics P]:
	  WAIT s | WAITFOR expr | MOVETODYNAMIC node | SET var [value=1] | CHAT key | SETFASTWALK | SETRUNNING | PHONE n | CROSSARMS n | RADIO n
	  | CHECKPOINT | ENTERCOMBAT | TAKEDOWNIMMUNE | FOLLOW target [tag] | GOTO label [var] | :label | END | AUTOCLEANUP
	  AUTOCLEANUP also resets speed and poses when the script stops. Unknown commands are skipped and listed in `bh.Unknown`.
]==]

local Behavior = {}
Behavior.VERSION = "0.1.0"

Behavior.Defaults = {
	FastWalkMul = 1.6, -- SETFASTWALK: speed x this [P]
	RunMul = 2.2, -- SETRUNNING [P]
	OpsPerStep = 64, -- a script cannot spin forever inside one step
	FollowRefresh = 1, -- FOLLOW <tag>: re-aim at the followed bot this often [P]
	MoveTimeout = 120, -- a MOVETODYNAMIC that never arrives is given up after this long [P]
	Alarm = "Mission_AlarmRaised",
}

local function lower(s)
	return tostring(s):lower()
end

local function isBlank(v)
	return v == nil or v == "" or (type(v) == "string" and not v:match("%S"))
end

local function truthy(v)
	return v ~= nil and v ~= false and v ~= 0 and v ~= ""
end

--------------------------------------------------------------------------------------------------- the script language

local KNOWN = {
	WAIT = true, WAITFOR = true, MOVETODYNAMIC = true, SET = true, CHAT = true, SETFASTWALK = true, SETRUNNING = true, PHONE = true,
	CROSSARMS = true, RADIO = true, CHECKPOINT = true, ENTERCOMBAT = true, TAKEDOWNIMMUNE = true, FOLLOW = true, GOTO = true, END = true,
	AUTOCLEANUP = true,
}

-- text -> { Ops = { {Cmd, Args, Rest} }, Labels = { name = op index }, Cleanup = bool, Unknown = { cmd } }
function Behavior.parse(src)
	local prog = { Ops = {}, Labels = {}, Cleanup = false, Unknown = {} }
	for raw in tostring(src or ""):gmatch("[^\r\n]+") do
		local line = raw:match("^%s*(.-)%s*$")
		if line ~= "" then
			local label = line:match("^:(%S+)")
			if label then
				prog.Labels[lower(label)] = #prog.Ops + 1
			else
				local cmd, rest = line:match("^(%S+)%s*(.*)$")
				cmd = cmd:upper()
				if cmd == "AUTOCLEANUP" then
					prog.Cleanup = true
				elseif KNOWN[cmd] then
					local args = {}
					for w in rest:gmatch("%S+") do
						args[#args + 1] = w
					end
					prog.Ops[#prog.Ops + 1] = { Cmd = cmd, Args = args, Rest = rest }
				else
					prog.Unknown[#prog.Unknown + 1] = cmd
				end
			end
		end
	end
	return prog
end

--------------------------------------------------------------------------------------------------- construction

local Sim = {}
Sim.__index = Sim

local function emit(self, kind, extra)
	local ev = { Kind = kind, Time = self.Time }
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

local function activeComp(c)
	local path = c.Path or ""
	return path:find("/StateComponents/", 1, true) ~= nil and not path:find("/Disabled/", 1, true)
end

-- MOVETODYNAMIC targets: a Part whose `Id` attribute is the name (the maps' `DynamicNode` parts), a Part by its own name, or a
-- Folder (the position of its first part, e.g. Nodes/LeadSecurityStart).
local function firstPart(node)
	for _, ch in ipairs(node.Children or {}) do
		local p = ch.Props and ch.Props.CFrame and ch.Props.CFrame.Position
		if p and (ch.ClassName == "Part" or ch.ClassName == "MeshPart") then
			return p
		end
		local deeper = ch.ClassName == "Folder" and firstPart(ch)
		if deeper then
			return deeper
		end
	end
	return nil
end

local function collectNodes(root, out)
	for _, ch in ipairs(root.Children or {}) do
		local p = ch.Props and ch.Props.CFrame and ch.Props.CFrame.Position
		if p and (ch.ClassName == "Part" or ch.ClassName == "MeshPart") then
			local rec = { X = p.X or 0, Y = p.Y or 0, Z = p.Z or 0 }
			local id = ch.Attrs and ch.Attrs.Id
			if not isBlank(id) and not out[lower(id)] then
				out[lower(id)] = rec
			end
			if not out[lower(ch.Name)] then
				out[lower(ch.Name)] = rec
			end
		elseif ch.ClassName == "Folder" then
			local fp = firstPart(ch)
			if fp and not out[lower(ch.Name)] then
				out[lower(ch.Name)] = { X = fp.X or 0, Y = fp.Y or 0, Z = fp.Z or 0 }
			end
		end
		collectNodes(ch, out)
	end
	return out
end

function Behavior.new(logic, opts)
	opts = opts or {}
	local params = {}
	for k, v in pairs(Behavior.Defaults) do
		params[k] = v
	end
	for k, v in pairs(opts.params or {}) do
		params[k] = v
	end
	local self = setmetatable({
		Logic = logic, Mission = opts.mission, Bots = opts.bots, Nav = opts.nav, Alert = opts.alert, PlayersFn = opts.players, Params = params,
		Time = 0, Events = {}, Conds = {}, Alarmed = {}, Spawners = {}, Runners = {}, Unknown = {}, Nodes = {}, Errors = {},
	}, Sim)
	local mission = opts.mission
	if mission and mission.Root then
		collectNodes(mission.Root, self.Nodes)
	end
	local function readScript(comp)
		local prog = Behavior.parse(comp.Attrs.CustomBehavior)
		for _, u in ipairs(prog.Unknown) do
			self.Unknown[#self.Unknown + 1] = u
		end
		return prog
	end
	for _, comp in ipairs(mission and mission:byComponent("CustomBehaviorCondition") or {}) do
		if activeComp(comp) and not isBlank(comp.Attrs.BotServerTag) and not isBlank(comp.Attrs.Condition) then
			local c = {
				Src = comp.Path or comp.Name, Name = comp.Name, Tag = lower(comp.Attrs.BotServerTag), Prio = tonumber(tostring(comp.Attrs.Priority or ""):match("%d+")) or 1,
				Prog = readScript(comp), Loop = truthy(comp.Attrs.LoopApply), Value = false,
			}
			self.Conds[#self.Conds + 1] = c
			logic:watch(comp.Attrs.Condition, function(v)
				c.Value = truthy(v)
			end, "CustomBehaviorCondition " .. tostring(comp.Name))
		end
	end
	for _, comp in ipairs(mission and mission:byComponent("AlarmedBehaviorOverride") or {}) do
		if activeComp(comp) and not isBlank(comp.Attrs.BotServerTag) then
			self.Alarmed[#self.Alarmed + 1] = { Src = comp.Path or comp.Name, Name = comp.Name, Tag = lower(comp.Attrs.BotServerTag), Prio = 99, Prog = readScript(comp), Loop = false }
		end
	end
	for _, comp in ipairs(mission and mission:byComponent("RandomBotSpawner") or {}) do
		if activeComp(comp) then
			local sp = { Name = comp.Name, Attrs = comp.Attrs, Active = isBlank(comp.Attrs.SpawningActive), Timer = nil, Count = 0 }
			self.Spawners[#self.Spawners + 1] = sp
			if not sp.Active then
				logic:watch(comp.Attrs.SpawningActive, function(v)
					sp.Active = truthy(v)
				end, "RandomBotSpawner " .. tostring(comp.Name))
			end
		end
	end
	return self
end

--------------------------------------------------------------------------------------------------- runners

local function out(bot)
	return bot == nil or bot.State == "Despawned" or bot.State == "Dead" or bot.Flags.Dead or bot.Flags.Incapacitated or bot.Flags.Hostage or bot.Flags.Fled
end

function Sim:isRunning(botId)
	return self.Runners[botId] ~= nil
end

function Sim:sourceOf(botId)
	local r = self.Runners[botId]
	return r and r.Src.Name or nil
end

function Sim:_setSpeed(botId, mul)
	local ag = self.Nav.Agents and self.Nav.Agents[botId]
	if ag then
		ag.MaxSpeed = (self.Bots.Params.WalkSpeed or 9) * mul
	end
end

function Sim:_stop(botId, why)
	local r = self.Runners[botId]
	if not r then
		return
	end
	self.Runners[botId] = nil
	local bot = self.Bots:bot(botId)
	if r.Follow and self.Nav.stopFollow then
		self.Nav:stopFollow(botId)
	end
	if r.Prog.Cleanup then
		self:_setSpeed(botId, 1)
		for pose in pairs(r.Poses) do
			emit(self, "BotPose", { Bot = botId, Pose = pose, On = false })
		end
	end
	if bot and bot.Command == "Custom" and not out(bot) then
		self.Bots:resume(botId)
	end
	emit(self, "BehaviorFinished", { Bot = botId, Source = r.Src.Name, Why = why })
end

function Sim:_start(bot, src)
	self.Bots:hold(bot.Id, "Custom")
	self.Runners[bot.Id] = { Src = src, Prog = src.Prog, PC = 1, Wait = 0, Moving = false, Poses = {}, Loop = src.Loop }
	emit(self, "BehaviorStarted", { Bot = bot.Id, Source = src.Name, Priority = src.Prio })
end

function Sim:_value(arg)
	local n = tonumber(arg)
	if n ~= nil then
		return n
	end
	local v = self.Logic:eval(arg)
	return v ~= nil and v or arg
end

-- one op; returns "block" when the runner must wait, "end" when the script is over, nil to carry on
function Sim:_exec(bot, r, op)
	local id = bot.Id
	local c = op.Cmd
	if c == "WAIT" then
		r.Wait = tonumber(op.Args[1]) or 0
		return "block"
	elseif c == "WAITFOR" then
		r.WaitFor = op.Rest
		return "block"
	elseif c == "MOVETODYNAMIC" then
		local node = self.Nodes[lower(op.Args[1] or "")]
		if not node then
			self.Errors[#self.Errors + 1] = "MOVETODYNAMIC: node '" .. tostring(op.Args[1]) .. "' not found"
			return nil
		end
		self.Bots:command(id, "Custom", node.X, node.Y, node.Z)
		r.Moving, r.MoveTimer = true, self.Params.MoveTimeout
		return "block"
	elseif c == "SET" then
		local var = op.Args[1]
		if var then
			self.Logic:set(var, op.Args[2] ~= nil and self:_value(op.Args[2]) or 1)
		end
	elseif c == "CHAT" then
		local key = op.Args[1]
		if key then
			emit(self, "BotSay", { Bot = id, Line = key, Text = key })
		end
	elseif c == "SETFASTWALK" then
		self:_setSpeed(id, self.Params.FastWalkMul)
	elseif c == "SETRUNNING" then
		self:_setSpeed(id, self.Params.RunMul)
	elseif c == "PHONE" or c == "CROSSARMS" or c == "RADIO" then
		local on = (tonumber(op.Args[1]) or 1) ~= 0
		local pose = c:sub(1, 1) .. c:sub(2):lower()
		r.Poses[pose] = on or nil
		emit(self, "BotPose", { Bot = id, Pose = pose, On = on })
	elseif c == "CHECKPOINT" then
		emit(self, "BotCheckpoint", { Bot = id })
	elseif c == "ENTERCOMBAT" then
		emit(self, "BotEnterCombat", { Bot = id })
		if self.Alert then
			self.Alert:setFighting(id, true, "Script")
		end
	elseif c == "TAKEDOWNIMMUNE" then
		bot.Flags.TakedownImmune = true
	elseif c == "FOLLOW" then
		local target = op.Args[1]
		if target and self.Nav.Actors[target] then
			self.Nav:follow(id, target)
			r.Follow = true
		else
			r.FollowTag = lower(op.Args[2] or target or "")
			r.FollowTimer = 0
		end
	elseif c == "GOTO" then
		local at = r.Prog.Labels[lower(op.Args[1] or "")]
		local cond = op.Args[2]
		if at and (cond == nil or truthy(self.Logic:get(cond))) then
			r.PC = at -- PC already points past this op
		end
	elseif c == "END" then
		return "end"
	end
	return nil
end

function Sim:_run(bot, r, dt)
	local id = bot.Id
	if r.FollowTag then
		r.FollowTimer -= dt
		if r.FollowTimer <= 0 then
			r.FollowTimer = self.Params.FollowRefresh
			for _, other in ipairs(self.Bots:withTag(r.FollowTag)) do
				if other.Id ~= id then
					local x, y, z = self.Bots:position(other.Id)
					if x then
						self.Bots:command(id, "Custom", x, y, z)
					end
					break
				end
			end
		end
	end
	if r.Wait > 0 then
		r.Wait -= dt
		if r.Wait > 0 then
			return
		end
		r.Wait = 0
	end
	if r.Moving then
		r.MoveTimer -= dt
		if bot.State == "Custom" or r.MoveTimer <= 0 then
			r.Moving = false
		else
			return
		end
	end
	if r.WaitFor then
		if truthy(self.Logic:eval(r.WaitFor)) then
			r.WaitFor = nil
		else
			return
		end
	end
	local budget = self.Params.OpsPerStep
	while budget > 0 do
		budget -= 1
		local op = r.Prog.Ops[r.PC]
		if not op then
			if r.Loop and r.Src.Value ~= false and #r.Prog.Ops > 0 then
				r.PC = 1
				if budget < self.Params.OpsPerStep - #r.Prog.Ops - 1 then
					return -- went round once without blocking: carry on next step
				end
			else
				r.Done = true
				return
			end
		else
			r.PC += 1
			local res = self:_exec(bot, r, op)
			if res == "block" then
				return
			elseif res == "end" then
				if r.Loop and r.Src.Value ~= false then
					r.PC = 1
					return
				end
				r.Done = true
				return
			end
		end
	end
end

--------------------------------------------------------------------------------------------------- step

function Sim:step(dt)
	self.Time += dt
	local bots = self.Bots
	-- spawners
	for si, sp in ipairs(self.Spawners) do
		if sp.Active then
			local a = sp.Attrs
			local lo, hi = tonumber(a.SpawnTimeMin) or 4, tonumber(a.SpawnTimeMax) or 10
			if sp.Timer == nil then
				sp.Timer = bots:rand(si * 1009 + sp.Count, math.floor(lo * 100), math.floor(math.max(lo, hi) * 100)) / 100
			end
			sp.Timer -= dt
			if sp.Timer <= 0 then
				sp.Count += 1
				sp.Timer = bots:rand(si * 1009 + sp.Count, math.floor(lo * 100), math.floor(math.max(lo, hi) * 100)) / 100
				local attrs = {
					Behavior = a.Behavior, Class = a.Class, Profile = a.Profile, Outfit = a.Outfit, Nodes = a.Nodes, NodesBreak = a.NodesBreak,
					HostageDifficulty = a.HostageDifficulty, DetectionSpeed = a.DetectionSpeed, Weapon = a.Weapon, Title = a.Title,
					ServerTag = not isBlank(a.ServerTag) and a.ServerTag or a.Tag, EnforceClass = a.EnforceClass,
					CivilianHighlight = a.CivilianHighlight, ObjectiveHighlight = a.ObjectiveHighlight,
				}
				local bot = bots:spawn(attrs, sp.Name)
				if bot then
					emit(self, "SpawnerSpawned", { Bot = bot.Id, Spawner = sp.Name })
				else
					self.SpawnFailures = (self.SpawnFailures or 0) + 1 -- e.g. the spawner names no route (the Diplomat's civilians)
				end
			end
		end
	end
	-- which behaviour should each bot run?
	local alarm = truthy(self.Logic:get(self.Params.Alarm))
	for _, bot in ipairs(bots:alive()) do
		local best
		if alarm then
			for _, al in ipairs(self.Alarmed) do
				if bot.TagSet[al.Tag] then
					best = al
					break
				end
			end
		end
		if not best then
			for _, c in ipairs(self.Conds) do
				if c.Value and bot.TagSet[c.Tag] and (not best or c.Prio > best.Prio) then
					best = c
				end
			end
		end
		local r = self.Runners[bot.Id]
		if r then
			if out(bot) or (bot.Command ~= "Custom" and not (bot.State and bot.State:find("Custom", 1, true))) then
				self:_stop(bot.Id, out(bot) and "Out" or "Taken")
			elseif best ~= r.Src then
				self:_stop(bot.Id, best and "Superseded" or "ConditionEnded")
			end
		end
		if best and not self.Runners[bot.Id] and not out(bot) and bot.Command == nil and not (r and r.Done and best == r.Src) then
			self:_start(bot, best)
		end
	end
	-- run
	local ids = {}
	for id in pairs(self.Runners) do
		ids[#ids + 1] = id
	end
	table.sort(ids)
	for _, id in ipairs(ids) do
		local r = self.Runners[id]
		local bot = bots:bot(id)
		if r and bot and not r.Done then
			self:_run(bot, r, dt)
		end
	end
end

return Behavior
