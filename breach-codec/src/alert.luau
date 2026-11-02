--!nonstrict
--[==[
	BreachAlert — the alert level and what bots do about trouble (BreachEngine M8c, part 3; plan §5).

	Pure Luau, deterministic (no randomness), no Roblox APIs. Built on a logic core (the variables), BreachBots (who the
	bots are, and commands to move them), BreachSight (what they can see) and BreachTrespass (who minds a trespass).

	    local alert = Alert.new(logic, { mission = mission, bots = bots, sight = sight, trespass = tr, players = playersFn, world = world })
	    alert:step(dt)                              -- after bots:step, sight:step, tr:step (it drains the trespass events itself)
	    alert:level()   alert:isLockdown()          -- 0..3
	    alert:raise(amount, reason, min, max)       -- clamp(level + amount, min, max), never lowers; min == max sets exactly that level
	    alert:lockdown(reason)                      -- level 3
	    alert:answer(botId, playerId, response)     -- reply to a guard's question: true/"bluff", "leave", or false/"fail"
	    alert:stateName()   alert:setFighting(botId, on)   -- Calm / Normal / Alert / Lockdown (levels 0..3); Fighting is a deprecated flag, not a level
	    alert:radioIn(botId, why)                   -- the bot radios where it stands; lockdown after RadioSeconds
	    alert:isBanned(playerId, rule)              -- a place the player was escorted out of: seen there again = lockdown
	    alert:addAnomaly(kind, x, y, z) -> anomaly  -- kind = "Body" | "Radio" | "BrokenGlass" | "BrokenCamera"
	    alert:drainEvents()
	    -- AlertRaised / AlertLowered {Level, Before, Reason}  (AlertLowerCondition, StandardRadioAlertReduction and map writes lower it)   (Reason "MapWrite" = the map set Mission_AlertLevel itself)
	    --    AlarmRaised {Reason}   BotSay {Bot, Line, Text, Place}
	    -- BotRadioStarted {Bot, Why}   BotRadioCancelled {Bot, Why, Reaction}   QuestionAsked {Bot, Player}   QuestionAnswered {Bot, Player, Success}
	    -- QuestionTimedOut {Bot, Player}   AnomalyFound {Bot, Anomaly, Place}   AnomalyReported {Bot, Anomaly}

	It writes the engine variables Mission_AlertLevel and Mission_AlarmRaised through logic:set, so the maps' own expressions see them.
	The AlertRaiseCondition component (Amount, MinValue, MaxValue, Condition, Reason) raises the level on the RISING EDGE of its
	Condition [R: attributes; P: clamp(level + Amount, Min, Max); real triples (3,3,3) (1,1,1) (2,2,2) (1,2,2)].

	Player-observed rules [R = the owner's gameplay observations]:
	  * a MAJOR trespass: the witness runs to a hiding spot and radios LOCKDOWN; killing/subduing it first cancels the call [R];
	    bumping into a guard never makes them shoot [R]. Hiding spot priority [R]: (1) far from the player but close enough to run back
	    and ask, else it does not hide; (2) easy to get to and back; (3) covers the line of fire if a weapon was seen.
	  * a MINOR trespass: the guard walks up and asks what you were doing. King Street style (alert +1 first) vs Bathurst Street style
	    (only asks) belongs to the GUARD (a tag, `params.MinorRaiseTags`), not to the mission [R]. A bluff that works silences it for a while.
	    Say you are leaving: you get LeaveSeconds to walk out, else you are escorted [owner idea]. A failed or unanswered question is a
	    major trespass but the guard ESCORTS you to an allowed place [R]; that place is then burned for you: a guard that sees you in it
	    again radios lockdown [owner idea].
	  * a bot with a profile in `PiercingProfiles` (Lead Security) notices a disguised player as a major trespass anywhere [R].
	  * anomalies: a BODY called in = lockdown; a dropped RADIO, broken glass door, broken camera = alert +1 [R]. The bot that SEES
	    the point comments, then radios; a body is registered by itself from bots:setFlag Dead/Incapacitated.
	[P] numbers live in Alert.Defaults.
]==]

local Alert = {}
Alert.VERSION = "0.1.0"

Alert.Defaults = {
	AlarmRaisedAt = 3, -- Mission_AlarmRaised = level >= this, latched [O: the maps' usage says lockdown, see docs 8.3.1]
	MinorRaisesAlert = false, -- fallback for a guard with no tag: does a minor trespass raise the alert by one first?
	MinorRaiseTags = {}, -- ServerTags that make a guard raise it (King Street style); the owner thinks it is a tag on the guard [P: name unknown]
	MinorRaiseAmount = 1,
	RadioSeconds = 4, -- from "radio started" to the call landing [P]
	CommentSeconds = 1.5, -- a bot says its line this long before it radios an anomaly [P]
	ReductionSeconds = 60, -- StandardRadioAlertReduction: calm for this long and Alert (2) drops to Normal (1) [P: the times]
	ResetSeconds = 60, -- ... and Normal (1) drops to Calm (0)
	FleeMaxSeconds = 20, -- a witness that cannot reach its hiding spot radios where it stands [P]
	QuestionRange = 4, -- studs: close enough to ask [P]
	QuestionSeconds = 8, -- time the player has to answer [P]
	SilenceSeconds = 60, -- after a good answer the same guard does not ask again [P]
	FailedAnswerLockdown = false, -- false [R]: a failed answer is a major trespass, but the guard ESCORTS you out; true = old behaviour, radio lockdown
	LeaveSeconds = 15, -- told the guard you are leaving: time to get out by yourself before you are escorted [P: owner idea]
	EscortSeconds = 25, -- an escort that has not got the player out by then radios lockdown [P]
	HideMinDistance = 20, -- hiding spot priority 1: at least this far from the player ...
	HideMaxReturn = 60, -- ... but no farther than this, so the guard can run back and ask [R rule, P numbers]
	HideCostBucket = 10, -- priority 2 costs within this many studs tie, so priority 3 (cover) can decide [P]
	PiercingProfiles = { LeadSecurity = true }, -- [R names, P default]
}

-- Mission_AlertLevel 0..3. "Fighting" (deprecated, kept for compatibility) is NOT a level: guards attack without a lockdown.
Alert.Names = { [0] = "Calm", [1] = "Normal", [2] = "Alert", [3] = "Lockdown" }

local ANOMALY = {
	Body = { Amount = 3, Min = 3, Max = 3, Line = "BodyFound", Text = "Body!" },
	Radio = { Amount = 1, Min = 1, Max = 3, Line = "RadioDropped", Text = "Dropped radio..." },
	BrokenGlass = { Amount = 1, Min = 1, Max = 3, Line = "BrokenGlass", Text = "What the... Just found broken glass." },
	BrokenCamera = { Amount = 1, Min = 1, Max = 3, Line = "BrokenCamera", Text = "The camera seems broken.." },
}
Alert.Anomalies = ANOMALY

local function lower(s)
	return tostring(s):lower()
end

local function isBlank(v)
	return v == nil or v == "" or (type(v) == "string" and not v:match("%S"))
end

local function truthy(v)
	return v ~= nil and v ~= false and v ~= 0 and v ~= ""
end

local Sim = {}
Sim.__index = Sim

local function emit(self, kind, extra)
	local ev = { Kind = kind, Time = self.Time }
	for k, v in pairs(extra or {}) do
		ev[k] = v
	end
	self.Events[#self.Events + 1] = ev
end

function Alert.new(logic, opts)
	opts = opts or {}
	local params = {}
	for k, v in pairs(Alert.Defaults) do
		params[k] = v
	end
	for k, v in pairs(opts.params or {}) do
		params[k] = v
	end
	local piercing = {}
	for k, v in pairs(params.PiercingProfiles or {}) do
		if v then
			piercing[lower(k)] = true
		end
	end
	local self = setmetatable({
		Logic = logic, Mission = opts.mission, Bots = opts.bots, Sight = opts.sight, Trespass = opts.trespass, World = opts.world,
		PlayersFn = opts.players, HidingSpots = opts.hidingSpots, SafePoint = opts.safePoint, PathLength = opts.pathLength, Fighting = {}, Banned = {}, Params = params, Piercing = piercing, Level = 0, Time = 0, Events = {}, Reaction = {}, Silenced = {},
		AnomalyList = {}, SeenBodies = {}, Pierced = {}, Conditions = {}, Errors = {}, Alarm = false,
	}, Sim)
	if logic then
		logic:set("Mission_AlertLevel", 0)
		logic:set("Mission_AlarmRaised", 0)
	end
	-- The maps write Mission_AlertLevel themselves: scripts (`SET Mission_AlertLevel 2`) and components such as the Peacemaker's
	-- ReduceAlertLevel / ResetAlertLevel (a bluff over the intercom lowers it). Follow such writes, up or down. Mission_AlarmRaised
	-- stays LATCHED once it is up (the maps' StandardRadioAlertReduction is disabled while it is) [O: usage, P: latching].
	if logic then
		logic:watch("Mission_AlertLevel", function(v)
			local n = tonumber(v)
			if n and n >= 0 and n <= 3 and n ~= self.Level then
				local before = self.Level
				self.Level = math.floor(n)
				emit(self, before < self.Level and "AlertRaised" or "AlertLowered", { Level = self.Level, Before = before, Reason = "MapWrite" })
				local alarm = self.Level >= self.Params.AlarmRaisedAt
				if alarm and not self.Alarm then
					self.Alarm = true
					logic:set("Mission_AlarmRaised", 1)
					emit(self, "AlarmRaised", { Reason = "MapWrite" })
				end
			end
		end, "BreachAlert follows Mission_AlertLevel")
	end
	-- AlertLowerCondition: on the rising edge of Condition the level drops to the value of AlertLevel (an expression, e.g. the
	-- Peacemaker's `Mission_AlertLevel == 2 && 1 || 0`); it only ever lowers.
	local function inStateComponents(c)
		return (c.Path or ""):find("/StateComponents/", 1, true) ~= nil
	end
	local lowers = opts.mission and opts.mission.byComponent and opts.mission:byComponent("AlertLowerCondition") or {}
	for _, comp in ipairs(lowers) do
		if inStateComponents(comp) and not isBlank(comp.Attrs.Condition) then
			local c = { Prev = false, Name = comp.Name, Fired = 0, Level = comp.Attrs.AlertLevel }
			self.Lowers = self.Lowers or {}
			self.Lowers[#self.Lowers + 1] = c
			logic:watch(comp.Attrs.Condition, function(v)
				local now = truthy(v)
				if now and not c.Prev then
					c.Fired += 1
					local to = c.Level
					if type(to) == "string" then
						to = logic:eval(to)
					end
					self:lower(tonumber(to) or 0, "AlertLowerCondition:" .. tostring(c.Name))
				end
				c.Prev = now
			end, "AlertLowerCondition " .. tostring(comp.Name))
		end
	end
	-- StandardRadioAlertReduction: with it present, a calm spell lowers the alert on its own: Alert -> Normal when
	-- Mission_Difficulty >= AlertReductionDifficulty, Normal -> Calm when Mission_Difficulty >= AlertResetDifficulty, never while
	-- AlertReductionDisabled is true [O: the three attributes; P: this reading of them and the times].
	for _, comp in ipairs(opts.mission and opts.mission.byComponent and opts.mission:byComponent("StandardRadioAlertReduction") or {}) do
		if inStateComponents(comp) then
			self.Reducer = { Disabled = comp.Attrs.AlertReductionDisabled, Reduction = comp.Attrs.AlertReductionDifficulty, Reset = comp.Attrs.AlertResetDifficulty, Calm = 0 }
		end
	end
	-- AlertRaiseCondition components
	local comps = opts.mission and opts.mission.byComponent and opts.mission:byComponent("AlertRaiseCondition") or {}
	for _, comp in ipairs(comps) do
		if (comp.Path or ""):find("/StateComponents/", 1, true) and not isBlank(comp.Attrs.Condition) then
			local a = comp.Attrs
			local c = {
				Amount = tonumber(a.Amount) or 1, Min = tonumber(a.MinValue) or 1, Max = tonumber(a.MaxValue) or 3, Reason = a.Reason,
				Prev = false, Name = comp.Name, Fired = 0,
			}
			self.Conditions[#self.Conditions + 1] = c
			local handle = logic:watch(a.Condition, function(v)
				local now = truthy(v)
				if now and not c.Prev then
					c.Fired += 1
					self:raise(c.Amount, self:_reason(c.Reason, "AlertRaiseCondition:" .. tostring(c.Name)), c.Min, c.Max)
				end
				c.Prev = now
			end, "AlertRaiseCondition " .. tostring(comp.Name))
			if not handle then
				self.Errors[#self.Errors + 1] = "cannot compile Condition of " .. tostring(comp.Name)
			end
		end
	end
	return self
end

function Sim:drainEvents()
	local e = self.Events
	self.Events = {}
	return e
end

-- A Reason is a CustomStrings key, a {expression} template or blank; templates are evaluated now.
function Sim:_reason(reason, fallback)
	if isBlank(reason) then
		return fallback
	end
	local inner = tostring(reason):match("^%s*{(.*)}%s*$")
	if inner and self.Logic then
		local v = self.Logic:eval(inner)
		if v ~= nil then
			return tostring(v)
		end
	end
	return tostring(reason)
end

function Sim:level()
	return self.Level
end

function Sim:isLockdown()
	return self.Level >= 3
end

function Sim:stateName()
	if self.Level >= 3 then
		return "Lockdown"
	end
	if next(self.Fighting) then
		return "Fighting"
	end
	return Alert.Names[self.Level]
end

-- Deprecated state, kept for engine compatibility: a bot attacks without a lockdown being issued. Never changes the level.
function Sim:setFighting(botId, on, reason)
	if on and not self.Fighting[botId] then
		self.Fighting[botId] = true
		emit(self, "BotFighting", { Bot = botId, Reason = reason })
	elseif not on then
		self.Fighting[botId] = nil
	end
end

function Sim:isFighting()
	return next(self.Fighting) ~= nil
end

function Sim:_publish(reason)
	local lv = self.Level
	self.Logic:set("Mission_AlertLevel", lv)
	if lv >= self.Params.AlarmRaisedAt and not self.Alarm then -- latched: lowering the level never clears it
		self.Alarm = true
		self.Logic:set("Mission_AlarmRaised", 1)
		emit(self, "AlarmRaised", { Reason = reason })
	end
end

function Sim:raise(amount, reason, min, max)
	min, max = min or 1, max or 3
	local target = math.max(min, math.min(max, self.Level + (amount or 1)))
	target = math.min(3, math.max(0, target))
	if target <= self.Level then -- monotonic
		return self.Level
	end
	local before = self.Level
	self.Level = target
	if self.Reducer then
		self.Reducer.Calm = 0
	end
	emit(self, "AlertRaised", { Level = target, Before = before, Reason = reason })
	self:_publish(reason)
	return target
end

-- Lowers the level (never raises; Mission_AlarmRaised stays latched).
function Sim:lower(to, reason)
	to = math.max(0, math.floor(to or 0))
	if to >= self.Level then
		return self.Level
	end
	local before = self.Level
	self.Level = to
	if self.Reducer then
		self.Reducer.Calm = 0
	end
	emit(self, "AlertLowered", { Level = to, Before = before, Reason = reason })
	self:_publish(reason)
	return to
end

function Sim:lockdown(reason)
	return self:raise(3, reason, 3, 3)
end

--------------------------------------------------------------------------------------------------- bots

local function out(bot)
	return bot == nil or bot.State == "Despawned" or bot.State == "Dead" or bot.Flags.Dead or bot.Flags.Incapacitated
end

local function free(bot)
	return not out(bot) and not bot.Command and not bot.Flags.Hostage
end

local function dist2(ax, az, bx, bz)
	return (ax - bx) ^ 2 + (az - bz) ^ 2
end

function Sim:_player(id)
	local fn = self.PlayersFn or (self.Trespass and self.Trespass.PlayersFn)
	for _, pl in ipairs(fn and fn() or {}) do
		if pl.Id == id then
			return pl
		end
	end
	return nil
end

function Sim:_place(x, y, z)
	local cell = self.World and self.World.cellAt and self.World:cellAt(x, y, z)
	if cell then
		return (cell.Node and cell.Node.Name) or cell.Name
	end
	return nil
end

-- Hiding spot [R priorities, P numbers]. Candidates are props (opts.hidingSpots) or, with none given, the bot's own route nodes.
--   1. far from the player (>= HideMinDistance) but close enough to run back and ask (<= HideMaxReturn); none qualifies: don't hide;
--   2. how easy it is to get there and back (distance there + back, doubled when a wall is in the way), in HideCostBucket steps;
--   3. when the player has a weapon out: a spot that covers the line of fire (no line of sight to the player).
function Sim:_hidingSpot(bot, pl)
	local p = self.Params
	if not pl then
		return nil
	end
	local bx, by, bz = self.Bots:position(bot.Id)
	local cands = self.HidingSpots or bot.Route or {}
	local armed = pl.Armed or pl.WeaponDrawn
	local best, bestKey
	for i, spot in ipairs(cands) do
		local dp = math.sqrt(dist2(spot.X, spot.Z, pl.X, pl.Z))
		if dp >= p.HideMinDistance and dp <= p.HideMaxReturn then
			local dg = bx and math.sqrt(dist2(spot.X, spot.Z, bx, bz)) or 0
			local clear = (not self.Sight) or self.Sight:lineOfSight(bx or spot.X, (by or 0) + 3, bz or spot.Z, spot.X, (spot.Y or 0) + 3, spot.Z)
			local cost = self.PathLength and self.PathLength(bx, by, bz, spot.X, spot.Y or 0, spot.Z) or (dg * (clear and 1 or 2))
			cost += self.PathLength and 0 or (dp * (clear and 1 or 2))
			local cover = 1
			if armed and self.Sight and not self.Sight:lineOfSight(spot.X, (spot.Y or 0) + 4.5, spot.Z, pl.X, pl.Y + 3, pl.Z) then
				cover = 0
			end
			local key = { math.floor(cost / p.HideCostBucket), armed and cover or 0, cost, i }
			local better = not bestKey
			if bestKey then
				for k = 1, 4 do
					if key[k] ~= bestKey[k] then
						better = key[k] < bestKey[k]
						break
					end
				end
			end
			if better then
				best, bestKey = spot, key
			end
		end
	end
	if best then
		return best.X, best.Y or 0, best.Z
	end
	return nil
end

-- the nearest point of a cell where this player is allowed to be (for an escort); opts.safePoint(player) overrides
function Sim:_safePoint(pl)
	if self.SafePoint then
		return self.SafePoint(pl)
	end
	local best, bd
	for _, cell in ipairs(self.World and self.World.Cells or {}) do
		local f = cell.Floors and cell.Floors[1]
		if f and self.Trespass and (self.Trespass:status(pl.Disguise, cell)) == "allowed" then
			local d = dist2(f.center.X, f.center.Z, pl.X, pl.Z)
			if not bd or d < bd then
				best, bd = f.center, d
			end
		end
	end
	if best then
		return best.X, best.Y, best.Z
	end
	return nil
end

function Sim:_cancel(botId, why)
	local r = self.Reaction[botId]
	if not r then
		return
	end
	self.Reaction[botId] = nil
	if r.Phase == "Radioing" or r.Phase == "Fleeing" then
		emit(self, "BotRadioCancelled", { Bot = botId, Why = why, Reaction = r.Kind })
	end
	local bot = self.Bots:bot(botId)
	if r.Anomaly then
		r.Anomaly.Reporting = nil
	end
	if bot and not out(bot) then
		self.Bots:resume(botId)
	end
end

function Sim:_startFlee(bot, pl, why, rule)
	local r = self.Reaction[bot.Id]
	if r and r.Kind == "Flee" then
		return
	end
	if r then
		self:_cancel(bot.Id, "superseded")
	end
	local x, y, z = self:_hidingSpot(bot, pl)
	self.Reaction[bot.Id] = { Kind = "Flee", Phase = "Fleeing", Player = pl and pl.Id, Why = why, Rule = rule, Timer = self.Params.FleeMaxSeconds }
	emit(self, "BotSay", { Bot = bot.Id, Line = "TrespassMajor", Text = "Hey! You can't be here!" })
	if x then
		self.Bots:command(bot.Id, "Fleeing", x, y, z)
	else -- no good hiding spot: don't hide, radio where it stands
		local mine = self.Reaction[bot.Id]
		mine.Phase, mine.Timer = "Radioing", self.Params.RadioSeconds
		self.Bots:hold(bot.Id, "Radioing")
		emit(self, "BotRadioStarted", { Bot = bot.Id, Why = why, Hidden = false })
	end
end

-- King Street style (+1 first) vs Bathurst style (only asks) is a property of the GUARD, not the mission [R]: a ServerTag in
-- params.MinorRaiseTags, or a MinorRaisesAlert attribute on the bot; otherwise params.MinorRaisesAlert.
function Sim:_raisesOnMinor(bot)
	for _, tag in ipairs(self.Params.MinorRaiseTags or {}) do
		if bot.TagSet and bot.TagSet[lower(tag)] then
			return true
		end
	end
	local a = bot.Attrs and bot.Attrs.MinorRaisesAlert
	if a ~= nil and a ~= "" then
		return truthy(a)
	end
	return self.Params.MinorRaisesAlert and true or false
end

-- A bot radios right where it stands (no hiding spot): the call lands as lockdown after RadioSeconds. Used by BreachHostage
-- when an armed guard stops being a hostage: "radioing in before shooting" [R].
function Sim:radioIn(botId, why)
	local bot = self.Bots:bot(botId)
	if out(bot) then
		return false
	end
	if self.Reaction[botId] then
		self:_cancel(botId, "superseded")
	end
	self.Reaction[botId] = { Kind = "Flee", Phase = "Radioing", Why = why, Timer = self.Params.RadioSeconds }
	self.Bots:hold(botId, "Radioing")
	emit(self, "BotRadioStarted", { Bot = botId, Why = why, Hidden = false })
	return true
end

function Sim:_startQuestion(bot, pl, rule)
	if self.Reaction[bot.Id] then
		return
	end
	if (self.Silenced[bot.Id .. "|" .. pl.Id] or -1) > self.Time then
		return
	end
	if self:_raisesOnMinor(bot) then
		self:raise(self.Params.MinorRaiseAmount, "MinorTrespass:" .. tostring(rule))
	end
	self.Reaction[bot.Id] = { Kind = "Question", Phase = "Approach", Player = pl.Id, Rule = rule }
	self.Bots:command(bot.Id, "Questioning", pl.X, pl.Y, pl.Z)
end

-- response: true / "bluff" = the guard buys it; "leave" = "I'm leaving", you may walk out yourself; false / "fail" = it does not.
function Sim:answer(botId, playerId, response)
	local r = self.Reaction[botId]
	if not r or r.Kind ~= "Question" or r.Phase ~= "Asking" or r.Player ~= playerId then
		return false
	end
	local mode = (response == true or response == "bluff") and "bluff" or response == "leave" and "leave" or "fail"
	emit(self, "QuestionAnswered", { Bot = botId, Player = playerId, Success = mode == "bluff", Response = mode })
	self.Reaction[botId] = nil
	local bot = self.Bots:bot(botId)
	local pl = self:_player(playerId)
	if mode == "bluff" then
		self.Silenced[botId .. "|" .. playerId] = self.Time + self.Params.SilenceSeconds
		self.Bots:resume(botId)
	elseif mode == "leave" and pl then
		self.Reaction[botId] = { Kind = "Leave", Phase = "Leaving", Player = playerId, Rule = r.Rule, Timer = self.Params.LeaveSeconds }
		self.Bots:hold(botId, "Watching")
		emit(self, "BotSay", { Bot = botId, Line = "LeaveNow", Text = "Then go on, leave." })
	else
		self.Bots:resume(botId)
		self:_failed(bot, pl, r.Rule)
	end
	return true
end

-- A failed (or unanswered) question is a major trespass; by default the guard escorts you out and the place is then
-- "burned" for you: a guard that sees you in there again radios lockdown [R: escort; owner idea: the re-entry rule].
function Sim:_failed(bot, pl, rule)
	if not bot or not pl then
		return
	end
	if self.Params.FailedAnswerLockdown then
		self:_startFlee(bot, pl, "FailedAnswer", rule)
		return
	end
	self:_startEscort(bot, pl, rule)
end

function Sim:_startEscort(bot, pl, rule)
	if out(bot) then
		return
	end
	if self.Reaction[bot.Id] then
		self:_cancel(bot.Id, "superseded")
	end
	local x, y, z = self:_safePoint(pl)
	self.Reaction[bot.Id] = { Kind = "Escort", Phase = "Escorting", Player = pl.Id, Rule = rule, Timer = self.Params.EscortSeconds }
	self:_ban(pl.Id, rule)
	if x then
		self.Bots:command(bot.Id, "Escorting", x, y, z)
	else
		self.Bots:hold(bot.Id, "Escorting")
	end
	emit(self, "BotSay", { Bot = bot.Id, Line = "EscortOut", Text = "Come with me. I'll show you out." })
	emit(self, "EscortStarted", { Bot = bot.Id, Player = pl.Id, Rule = rule })
end

function Sim:_ban(playerId, rule)
	if rule == nil then
		return
	end
	self.Banned[playerId] = self.Banned[playerId] or {}
	self.Banned[playerId][lower(rule)] = true
end

function Sim:isBanned(playerId, rule)
	return rule ~= nil and self.Banned[playerId] ~= nil and self.Banned[playerId][lower(rule)] == true
end

function Sim:_onWitness(ev)
	local bot = self.Bots:bot(ev.Bot)
	local pl = self:_player(ev.Player)
	if out(bot) or not pl or bot.Flags.Hostage then
		return
	end
	local busy = self.Reaction[bot.Id]
	if busy and (busy.Kind == "Escort" or busy.Kind == "Leave") and busy.Player == pl.Id then
		return
	end
	if self:isBanned(pl.Id, ev.Rule) then -- the place is burned for this player: no more questions
		if not (busy and busy.Kind == "Flee") then
			self:_startFlee(bot, pl, "BannedReentry", ev.Rule)
		end
		return
	end
	if ev.Status == "major" then
		local r = self.Reaction[bot.Id]
		if r and r.Kind == "Question" then
			self:_cancel(bot.Id, "escalated")
		end
		self:_startFlee(bot, pl, "MajorTrespass", ev.Rule)
	elseif ev.Status == "minor" then
		self:_startQuestion(bot, pl, ev.Rule)
	end
end

function Sim:_onCleared(ev)
	local r = self.Reaction[ev.Bot]
	if r and r.Kind == "Question" and r.Phase == "Approach" and r.Player == ev.Player then
		self:_cancel(ev.Bot, "lost the player")
	end
end

--------------------------------------------------------------------------------------------------- anomalies

function Sim:addAnomaly(kind, x, y, z)
	if not ANOMALY[kind] then
		return nil
	end
	local a = { Kind = kind, X = x, Y = y, Z = z, Reported = false, Id = #self.AnomalyList + 1 }
	self.AnomalyList[#self.AnomalyList + 1] = a
	return a
end

function Sim:anomalies()
	return self.AnomalyList
end

function Sim:_scanBodies()
	for _, bot in ipairs(self.Bots:all()) do
		if (bot.Flags.Dead or bot.Flags.Incapacitated) and bot.State ~= "Despawned" and not self.SeenBodies[bot.Id] then
			local x, y, z = self.Bots:position(bot.Id)
			if x then
				self.SeenBodies[bot.Id] = true
				self:addAnomaly("Body", x, y, z)
			end
		end
	end
end

function Sim:_scanAnomalies()
	for _, a in ipairs(self.AnomalyList) do
		if not a.Reported and not a.Reporting then
			for _, bot in ipairs(self.Bots:all()) do
				if free(bot) and not self.Reaction[bot.Id] and self.Sight:canSeePoint(bot.Id, a.X, a.Y, a.Z) then
					local def = ANOMALY[a.Kind]
					local place = self:_place(a.X, a.Y, a.Z)
					a.Reporting = bot.Id
					self.Reaction[bot.Id] = { Kind = "Anomaly", Phase = "Commenting", Anomaly = a, Timer = self.Params.CommentSeconds }
					self.Bots:hold(bot.Id, "Commenting")
					emit(self, "AnomalyFound", { Bot = bot.Id, Anomaly = a.Kind, Place = place })
					emit(self, "BotSay", { Bot = bot.Id, Line = def.Line, Text = def.Text, Place = place })
					break
				end
			end
		end
	end
end

--------------------------------------------------------------------------------------------------- step

function Sim:step(dt)
	self.Time += dt
	local p = self.Params
	-- standard alert reduction
	local red = self.Reducer
	if red then
		local function val(v)
			if type(v) == "string" then
				return self.Logic:eval(v)
			end
			return v
		end
		if self.Level < 1 or self.Level > 2 or self.Alarm or truthy(val(red.Disabled)) or next(self.Reaction) or next(self.Fighting) then
			red.Calm = 0 -- a calm spell only counts while nothing is going on
		else
			red.Calm += dt
			local diff = tonumber(self.Logic:get("Mission_Difficulty")) or 0
			if self.Level == 2 and red.Calm >= p.ReductionSeconds and diff >= (tonumber(val(red.Reduction)) or 0) then
				self:lower(1, "Reduction")
			elseif self.Level == 1 and red.Calm >= p.ResetSeconds and diff >= (tonumber(val(red.Reset)) or 0) then
				self:lower(0, "Reset")
			end
		end
	end
	-- trespass events
	if self.Trespass then
		for _, ev in ipairs(self.Trespass:drainEvents()) do
			if ev.Kind == "TrespassWitnessed" then
				self:_onWitness(ev)
			elseif ev.Kind == "TrespassCleared" then
				self:_onCleared(ev)
			end
		end
	end
	-- disguise-piercing bots
	if self.Sight and self.PlayersFn and next(self.Piercing) then
		for _, bot in ipairs(self.Bots:all()) do
			if not out(bot) and self.Piercing[lower(bot.Profile or "")] then
				for _, pl in ipairs(self.PlayersFn()) do
					local d = pl.Disguise
					local key = bot.Id .. "|" .. pl.Id
					if d and d ~= "" and lower(d) ~= "none" and not pl.Exited and not self.Pierced[key] and self.Sight:isNoticedBy(bot.Id, pl.Id) then
						self.Pierced[key] = true
						self:_startFlee(bot, pl, "DisguisePierced", "Disguise")
					end
				end
			end
		end
	end
	-- anomalies
	if self.Bots then
		self:_scanBodies()
		if self.Sight then
			self:_scanAnomalies()
		end
	end
	for id in pairs(self.Fighting) do
		if out(self.Bots:bot(id)) then
			self.Fighting[id] = nil
		end
	end
	-- reactions
	local ids = {}
	for id in pairs(self.Reaction) do
		ids[#ids + 1] = id
	end
	table.sort(ids)
	for _, id in ipairs(ids) do
		local r = self.Reaction[id]
		local bot = self.Bots:bot(id)
		if r then
			if out(bot) then
				self:_cancel(id, bot and (bot.Flags.Dead and "dead" or bot.State == "Despawned" and "despawned" or "incapacitated") or "gone")
			elseif r.Kind == "Flee" then
				if r.Phase == "Fleeing" then
					r.Timer -= dt
					if bot.State == "Fleeing" or r.Timer <= 0 then
						r.Phase, r.Timer = "Radioing", p.RadioSeconds
						self.Bots:hold(id, "Radioing")
						emit(self, "BotRadioStarted", { Bot = id, Why = r.Why })
					end
				else
					r.Timer -= dt
					if r.Timer <= 0 then
						self.Reaction[id] = nil
						self:lockdown("Radio:" .. tostring(r.Why))
						self.Bots:resume(id)
					end
				end
			elseif r.Kind == "Question" then
				local pl = self:_player(r.Player)
				if r.Phase == "Approach" then
					local x, _, z = self.Bots:position(id)
					if not pl or pl.Exited then
						self:_cancel(id, "player gone")
					elseif x and dist2(x, z, pl.X, pl.Z) <= p.QuestionRange ^ 2 or bot.State == "Questioning" then
						r.Phase, r.Timer = "Asking", p.QuestionSeconds
						self.Bots:hold(id, "Questioning")
						emit(self, "BotSay", { Bot = id, Line = "WhatWereYouDoing", Text = "What were you doing in there?" })
						emit(self, "QuestionAsked", { Bot = id, Player = r.Player })
					elseif pl and bot.State ~= "Going:Questioning" then
						self.Bots:command(id, "Questioning", pl.X, pl.Y, pl.Z)
					end
				else
					r.Timer -= dt
					if r.Timer <= 0 then
						emit(self, "QuestionTimedOut", { Bot = id, Player = r.Player })
						self.Reaction[id] = nil
						self.Bots:resume(id)
						self:_failed(bot, pl, r.Rule)
					end
				end
			elseif r.Kind == "Leave" or r.Kind == "Escort" then
				local pl = self:_player(r.Player)
				local status = self.Trespass and self.Trespass:statusOf(r.Player) or "allowed"
				r.Timer -= dt
				if not pl or pl.Exited or status == "allowed" then
					self.Reaction[id] = nil
					self.Bots:resume(id)
					emit(self, r.Kind == "Leave" and "PlayerLeft" or "EscortFinished", { Bot = id, Player = r.Player })
				elseif r.Timer <= 0 then
					self.Reaction[id] = nil
					self.Bots:resume(id)
					if r.Kind == "Leave" then
						emit(self, "BotSay", { Bot = id, Line = "TimeIsUp", Text = "Time's up." })
						self:_startEscort(bot, pl, r.Rule)
					else
						self:_startFlee(bot, pl, "EscortFailed", r.Rule)
					end
				end
			elseif r.Kind == "Anomaly" then
				r.Timer -= dt
				if r.Phase == "Commenting" and r.Timer <= 0 then
					r.Phase, r.Timer = "Radioing", p.RadioSeconds
					self.Bots:hold(id, "Radioing")
					emit(self, "BotRadioStarted", { Bot = id, Why = r.Anomaly.Kind })
					emit(self, "BotSay", { Bot = id, Line = "RadioCall", Text = "10-66 at " .. tostring(self:_place(r.Anomaly.X, r.Anomaly.Y, r.Anomaly.Z) or "my location") })
				elseif r.Phase == "Radioing" and r.Timer <= 0 then
					local a = r.Anomaly
					self.Reaction[id] = nil
					a.Reported, a.Reporting = true, nil
					emit(self, "AnomalyReported", { Bot = id, Anomaly = a.Kind })
					local def = ANOMALY[a.Kind]
					self:raise(def.Amount, "Anomaly:" .. a.Kind, def.Min, def.Max)
					self.Bots:resume(id)
				end
			end
		end
	end
end

return Alert
