--!nonstrict
--[==[
	BreachHostage — hostages, bodies and the alt interaction (BreachEngine M8d; plan §3).

	Pure Luau, deterministic. Built on a logic core, BreachBots (the bots and their flags), BreachNav (following) and, for
	client-side expressions and line of sight, BreachProps / BreachSight; optionally BreachAlert (opts.alert) for a guard's radio call.

	    local hs = Hostage.new(logic, { mission = mission, bots = bots, nav = nav, players = playersFn, props = props, sight = sight, world = world })
	    hs:aim(playerId, botId)            -- the host calls this while a player aims a gun at a bot (nil = stopped aiming)
	    hs:take(playerId, botId)           -- take it NOW (range, line of sight and the refusals still apply)
	    hs:release(botId)   hs:incapacitate(botId)
	    hs:step(dt)                        -- after bots:step; moves the players into nav as actors, ticks aims, flee timers, loud
	    hs:isHostage(botId)  hs:stateOf(botId)       -- "Following" | "Frozen" | "Fleeing" | "Body" | nil
	    hs:interactables(playerId) -> { { Bot, Trigger, Name, Kind, Title, Subtitle, HoldTime, Enabled, DisabledTitle, DisabledSubtitle } }
	    hs:interact(playerId, botId, triggerId, held) -> true | false, reason
	    hs:drainEvents()
	    -- HostageTaken {Bot, Player, Loud}  HostageFrozen {Bot}  HostageFollowing {Bot}  HostageFled {Bot}  HostageReleased {Bot}
	    -- BotIncapacitated {Bot}  AltTriggered {Bot, Player, Trigger, Alt ("Bot" | "Body"), Notification, LocalNotification}

	Rules [R = the owner's play observations, P = my defaults, tuned in Hostage.Defaults]:
	  * stealth: a CIVILIAN hostage follows its taker, but FLEES when no gun has been aimed at it for FleeSeconds (about a minute) [R];
	    aiming at it resets the timer [R: "draw a gun"]. An ARMED GUARD (a Weapon, or HostageDifficulty > 0) lasts at most
	    GuardRetaliateSeconds (10 s) [R]: then it stops being a hostage, radios in (opts.alert:radioIn) and retaliates [R].
	  * loud (Mission_AlarmRaised): hostages cannot be moved: they freeze and ignore the follow command [R].
	  * taking: the gun must be aimed for HostageDifficulty x AimSecondsPerDifficulty (0 = at once), in range and in sight [P];
	    a bot with NoHostageDownInCombat cannot be taken while it is loud (the proxy for combat) [P].
	  * alt interaction: BotAltTrigger / BodyAltTrigger are a candidate list like Props: available when the bot has the tag,
	    is a hostage (AllowHostages) or patrolling (AllowPatroling) / is an incapacitated body, ServerEnabled and the player's
	    ClientVisible hold, and the bot is within InteractRange (follow distance + margin) and in the same cell [P]; after
	    HoldTime it sets TriggerVariable (to 1), TriggerClientVariable, and emits the notifications [O: attributes; P: value 1].
]==]

local Hostage = {}
Hostage.VERSION = "0.1.0"

Hostage.Defaults = {
	TakeRange = 30, -- studs [P]
	AimSecondsPerDifficulty = 0.5, -- [P]
	FleeSeconds = 60, -- civilians [R: about a minute]
	GuardRetaliateSeconds = 10, -- armed guards [R: "10 seconds at most"]: then they stop being hostages, radio in and fight back
	InteractRange = 10, -- follow distance 6 + margin 4 [P]
	Loud = "Mission_AlarmRaised", -- the variable that means loud [O, see docs 8.3.1]
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

local Sim = {}
Sim.__index = Sim

function Hostage.new(logic, opts)
	opts = opts or {}
	local params = {}
	for k, v in pairs(Hostage.Defaults) do
		params[k] = v
	end
	for k, v in pairs(opts.params or {}) do
		params[k] = v
	end
	local self = setmetatable({
		Logic = logic, Mission = opts.mission, Bots = opts.bots, Nav = opts.nav, PlayersFn = opts.players, Props = opts.props, Sight = opts.sight,
		World = opts.world, Alert = opts.alert, FleeSpots = opts.fleeSpots, Params = params, Time = 0, Events = {}, H = {}, Aim = {}, AimTime = {}, Aimed = {},
		Triggers = {}, Errors = {},
	}, Sim)
	local function collect(ty, kind)
		local list = opts.altTriggers and opts.altTriggers[ty] or (opts.mission and opts.mission.byComponent and opts.mission:byComponent(ty)) or {}
		for _, comp in ipairs(list) do
			if opts.altTriggers or (comp.Path or ""):find("/StateComponents/", 1, true) then
				self.Triggers[#self.Triggers + 1] = { Kind = kind, Id = comp.Path or comp.Name, Name = comp.Name, Attrs = comp.Attrs }
			end
		end
	end
	collect("BotAltTrigger", "Bot")
	collect("BodyAltTrigger", "Body")
	return self
end

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

function Sim:_loud()
	return truthy(self.Logic:get(self.Params.Loud))
end

local function out(bot)
	return bot == nil or bot.State == "Despawned" or bot.State == "Dead" or bot.Flags.Dead
end

function Sim:_player(id)
	for _, pl in ipairs(self.PlayersFn and self.PlayersFn() or {}) do
		if pl.Id == id then
			return pl
		end
	end
	return nil
end

function Sim:isHostage(botId)
	local h = self.H[botId]
	return h ~= nil and (h.State == "Following" or h.State == "Frozen")
end

function Sim:stateOf(botId)
	local h = self.H[botId]
	return h and h.State or nil
end

--------------------------------------------------------------------------------------------------- taking

function Sim:_canTake(pl, bot)
	if not pl or pl.Exited then
		return false, "no-player"
	end
	if out(bot) or bot.Flags.Incapacitated then
		return false, "not-conscious"
	end
	if bot.Flags.Hostage then
		return false, "already-hostage"
	end
	if bot.Flags.Fled then
		return false, "fleeing"
	end
	local bx, by, bz = self.Bots:position(bot.Id)
	if not bx then
		return false, "no-position"
	end
	local dx, dz = bx - pl.X, bz - pl.Z
	if dx * dx + dz * dz > self.Params.TakeRange ^ 2 then
		return false, "out-of-range"
	end
	if self.Sight and not self.Sight:lineOfSight(pl.X, pl.Y + 3, pl.Z, bx, by + 3, bz) then
		return false, "no-line-of-sight"
	end
	local nh = bot.Attrs and bot.Attrs.NoHostageDownInCombat
	if nh ~= nil and truthy(nh) and self:_loud() then
		return false, "no-hostage-in-combat"
	end
	return true
end

function Sim:take(playerId, botId)
	local bot = self.Bots:bot(botId)
	local pl = self:_player(playerId)
	local ok, why = self:_canTake(pl, bot)
	if not ok then
		return false, why
	end
	local prev = self.H[botId]
	if prev then
		self.H[botId] = nil
	end
	self.Bots:setFlag(botId, "Hostage", true)
	self.Bots:command(botId, "Hostage")
	local loud = self:_loud()
	local h = { Leader = playerId, State = loud and "Frozen" or "Following", FleeTimer = 0 }
	self.H[botId] = h
	if not loud then
		self:_ensureActor(pl)
		self.Nav:follow(botId, playerId)
	end
	emit(self, "HostageTaken", { Bot = botId, Player = playerId, Loud = loud })
	if loud then
		emit(self, "HostageFrozen", { Bot = botId })
	else
		emit(self, "HostageFollowing", { Bot = botId })
	end
	return true
end

function Sim:aim(playerId, botId)
	self.Aim[playerId] = botId
	if botId == nil then
		for key in pairs(self.AimTime) do
			if key:sub(1, #playerId + 1) == playerId .. "|" then
				self.AimTime[key] = nil
			end
		end
	end
end

function Sim:release(botId)
	local h = self.H[botId]
	if not h then
		return false
	end
	self.H[botId] = nil
	local bot = self.Bots:bot(botId)
	self.Nav:stopFollow(botId)
	self.Bots:setFlag(botId, "Hostage", false)
	if bot and not out(bot) then
		self.Bots:resume(botId)
	end
	emit(self, "HostageReleased", { Bot = botId })
	return true
end

-- A takedown / pacify: the bot becomes a body (BodyAltTrigger applies). Works on any live bot, hostage or not.
function Sim:incapacitate(botId)
	local bot = self.Bots:bot(botId)
	local h = self.H[botId]
	if out(bot) or (h and h.State == "Body") then
		return false
	end
	self.Nav:stopFollow(botId)
	self.Nav:stop(botId)
	self.H[botId] = { State = "Body" }
	self.Bots:setFlag(botId, "Hostage", false)
	self.Bots:setFlag(botId, "Incapacitated", true)
	self.Bots:command(botId, "Incapacitated")
	emit(self, "BotIncapacitated", { Bot = botId })
	return true
end

function Sim:_ensureActor(pl)
	if not pl then
		return
	end
	if self.Nav.Actors[pl.Id] then
		self.Nav:moveActor(pl.Id, pl.X, pl.Y, pl.Z)
	else
		self.Nav:addActor(pl.Id, pl.X, pl.Y, pl.Z)
	end
end

function Sim:_fleeSpot(bot, pl)
	local best, bd
	for _, spot in ipairs(self.FleeSpots or bot.Route or {}) do
		local d = pl and ((spot.X - pl.X) ^ 2 + (spot.Z - pl.Z) ^ 2) or 0
		if not bd or d > bd then
			best, bd = spot, d
		end
	end
	if best then
		return best.X, best.Y or 0, best.Z
	end
	return nil
end

-- An armed security guard: a Weapon, or HostageDifficulty > 0 (civilians and workers are 0) [O correlation, P rule].
function Sim:_armed(bot)
	return not isBlank(bot.Weapon) or (bot.HostageDifficulty or 0) > 0
end

function Sim:_retaliate(botId)
	self.H[botId] = { State = "Retaliating" }
	self.Nav:stopFollow(botId)
	self.Bots:setFlag(botId, "Hostage", false)
	emit(self, "HostageRetaliating", { Bot = botId })
	if self.Alert then
		self.Alert:radioIn(botId, "HostageRetaliation") -- radio first, shoot after [R]
	else
		self.Bots:resume(botId)
	end
end

function Sim:_flee(botId, h)
	local bot = self.Bots:bot(botId)
	local pl = self:_player(h.Leader)
	self.H[botId] = { State = "Fleeing" }
	self.Nav:stopFollow(botId)
	self.Bots:setFlag(botId, "Hostage", false)
	self.Bots:setFlag(botId, "Fled", true)
	local x, y, z = self:_fleeSpot(bot, pl)
	if x then
		self.Bots:command(botId, "Fleeing", x, y, z)
	else
		self.Bots:hold(botId, "Fleeing")
	end
	emit(self, "HostageFled", { Bot = botId })
end

--------------------------------------------------------------------------------------------------- step

function Sim:step(dt)
	self.Time += dt
	local players = self.PlayersFn and self.PlayersFn() or {}
	for _, pl in ipairs(players) do
		if not pl.Exited then
			self:_ensureActor(pl)
		end
	end
	-- aims: taking a hostage, and resetting the flee timers
	self.Aimed = {}
	local pids = {}
	for pid in pairs(self.Aim) do
		pids[#pids + 1] = pid
	end
	table.sort(pids)
	for _, pid in ipairs(pids) do
		local botId = self.Aim[pid]
		local bot = botId and self.Bots:bot(botId)
		if bot then
			local h = self.H[botId]
			if h and (h.State == "Following" or h.State == "Frozen") then
				self.Aimed[botId] = true
			elseif not h then
				local pl = self:_player(pid)
				local ok = self:_canTake(pl, bot)
				local key = pid .. "|" .. botId
				if ok then
					self.AimTime[key] = (self.AimTime[key] or 0) + dt
					if self.AimTime[key] + 1e-9 >= (bot.HostageDifficulty or 0) * self.Params.AimSecondsPerDifficulty then
						self.AimTime[key] = nil
						self:take(pid, botId)
						self.Aimed[botId] = true
					end
				else
					self.AimTime[key] = nil
				end
			end
		end
	end
	-- hostages
	local ids = {}
	for id in pairs(self.H) do
		ids[#ids + 1] = id
	end
	table.sort(ids)
	local loud = self:_loud()
	for _, id in ipairs(ids) do
		local h = self.H[id]
		local bot = self.Bots:bot(id)
		if out(bot) then
			self.H[id] = nil
			self.Bots:setFlag(id, "Hostage", false)
		elseif bot.Flags.Incapacitated and h.State ~= "Body" then
			self:incapacitate(id)
		elseif h.State == "Following" or h.State == "Frozen" then
			local pl = self:_player(h.Leader)
			if not pl or pl.Exited then
				self:release(id)
			elseif loud and h.State == "Following" then
				h.State = "Frozen"
				self.Nav:stopFollow(id)
				self.Nav:stop(id)
				emit(self, "HostageFrozen", { Bot = id })
			elseif not loud and h.State == "Frozen" then
				h.State = "Following"
				self.Nav:follow(id, h.Leader)
				emit(self, "HostageFollowing", { Bot = id })
			elseif h.State == "Following" then
				if self.Aimed[id] then
					h.FleeTimer = 0
				else
					h.FleeTimer += dt
					if self:_armed(bot) then
						if h.FleeTimer >= self.Params.GuardRetaliateSeconds then
							self:_retaliate(id)
						end
					elseif h.FleeTimer >= self.Params.FleeSeconds then
						self:_flee(id, h)
					end
				end
			end
		end
	end
end

--------------------------------------------------------------------------------------------------- alt interaction

function Sim:_flag(src, player)
	if isBlank(src) then
		return true
	end
	local v
	if player and self.Props and self.Props.Players and self.Props.Players[player.Id] then
		v = self.Props.Players[player.Id].Replica:eval(src)
	else
		v = self.Logic:eval(src)
	end
	if v == nil then
		return true
	end
	return truthy(v)
end

local function hasTag(bot, a)
	local tag = not isBlank(a.BotServerTag) and a.BotServerTag or (not isBlank(a.BotClientTag) and a.BotClientTag) or nil
	if not tag then
		return true
	end
	return bot.TagSet[lower(tag)] == true
end

function Sim:_cell(x, y, z)
	return self.World and self.World.cellAt and self.World:cellAt(x, y, z) or nil
end

function Sim:interactables(playerId)
	local out_list = {}
	local pl = self:_player(playerId)
	if not pl or pl.Exited then
		return out_list
	end
	local range2 = self.Params.InteractRange ^ 2
	local pcell = self:_cell(pl.X, pl.Y, pl.Z)
	for _, bot in ipairs(self.Bots:all()) do
		local h = self.H[bot.Id]
		local x, y, z = self.Bots:position(bot.Id)
		if x and bot.State ~= "Despawned" and (x - pl.X) ^ 2 + (z - pl.Z) ^ 2 <= range2 and self:_cell(x, y, z) == pcell then
			for _, t in ipairs(self.Triggers) do
				local a = t.Attrs
				local fits
				if t.Kind == "Body" then
					fits = bot.Flags.Incapacitated and not bot.Flags.Dead
				elseif h and (h.State == "Following" or h.State == "Frozen") then
					fits = truthy(a.AllowHostages)
				else
					local patrolling = not h and not bot.Command and not bot.Flags.Incapacitated and not out(bot)
					fits = patrolling and truthy(a.AllowPatroling)
				end
				if fits and hasTag(bot, a) and self:_flag(a.ServerEnabled, nil) and self:_flag(a.ClientVisible, pl) then
					out_list[#out_list + 1] = {
						Bot = bot.Id, Trigger = t.Id, Name = t.Name, Kind = t.Kind, Title = a.TitleKey, Subtitle = a.SubtitleKey,
						HoldTime = tonumber(a.HoldTime) or 1, Enabled = t.Kind == "Body" or self:_flag(a.ClientEnabled, pl),
						DisabledTitle = a.DisabledTitleKey, DisabledSubtitle = a.DisabledSubtitleKey,
					}
				end
			end
		end
	end
	return out_list
end

function Sim:interact(playerId, botId, triggerId, held)
	local entry
	for _, e in ipairs(self:interactables(playerId)) do
		if e.Bot == botId and (e.Trigger == triggerId or e.Name == triggerId) then
			entry = e
			break
		end
	end
	if not entry then
		return false, "unavailable"
	end
	if not entry.Enabled then
		return false, "disabled"
	end
	if held ~= nil and held + 1e-6 < entry.HoldTime then
		return false, "too-short"
	end
	local a
	for _, t in ipairs(self.Triggers) do
		if t.Id == entry.Trigger then
			a = t.Attrs
		end
	end
	if not isBlank(a.TriggerVariable) then
		self.Logic:set(a.TriggerVariable, 1)
	end
	if not isBlank(a.TriggerClientVariable) then
		self.Logic:setClient(playerId, a.TriggerClientVariable, 1)
	end
	if self.Logic.replicate then
		self.Logic:replicate()
	end
	if self.Props and self.Props.refresh then
		self.Props:refresh()
	end
	emit(self, "AltTriggered", {
		Bot = botId, Player = playerId, Trigger = entry.Trigger, Alt = entry.Kind,
		Notification = not isBlank(a.TriggerNotification) and a.TriggerNotification or nil,
		LocalNotification = not isBlank(a.TriggerLocalNotification) and a.TriggerLocalNotification or nil,
	})
	return true
end

return Hostage
