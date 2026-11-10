--!nonstrict
--[==[
	BreachCombat — the lockdown phases and what guards know (BreachEngine M9a; plan: docs/BreachEngine_M9_Combat_Plan.md).

	Pure Luau, deterministic (no randomness), no Roblox APIs. OPT-IN: a mission turns it on with `MissionSetup.BreachLockdown = "TwoPhase"`
	[P: the key], or `Combat.new(..., { enabled = true })`. Off, it does nothing, so every current mission runs unchanged.

	    local combat = Combat.new({ bots = bots, sight = sight, alert = alert, players = playersFn, setup = setup }, { enabled = true })
	    combat:step(dt)                       -- after alert:step(dt)
	    combat:phase()      -> "Off" | "Calm" | "Searching" | "Attacking"
	    combat:knows(botId) -> { Player, X, Y, Z, Age, Source } | nil        where the guard believes the player is
	    combat:noise(kind, x, y, z, playerId) -> how many guards heard it     kind: "shot" | "door" | "footstep"
	    combat:drainEvents()  PhaseChanged {Phase, Prev, Why}  WeaponSeen {Bot, Player}  GuardKnows {Bot, Player, X, Y, Z, Source}
	                          GuardLostTrack {Bot, Player, Why}  NoiseHeard {Bot, Kind, X, Y, Z, Aware}

	Phases [R: the plan, section 2]:
	  * Calm        no lockdown yet.
	  * Searching   the alert reached lockdown (level 3) but nobody knows who: guards NEVER know the player's position.
	  * Attacking   a guard has SEEN A DRAWN WEAPON (the sight meter for that player reached 1). It never falls back by itself.
	A guard that sees a drawn weapon while the level is below lockdown flees and radios at the same time [R: owner, Nov 2026]; the lockdown
	lands when its call does. At lockdown the guards do not flee: they will fight (M9c, M9d).

	Awareness (Attacking only): a guard that sees a drawn weapon, or hears a noise within range, knows the player's position; it keeps
	that for LoseTrackSeconds after it last saw a drawn weapon or heard something [P], then loses track.
	Hearing range = MissionSetup.SoundTravelDistance x NoiseScale[kind] [P: the scales]. In Searching a noise is only reported (Aware = false).
	`concealed` weapons are not detected yet (M9a.1) [P].

	M9c, what guards DO once the lockdown has landed (alert level 3), still opt-in and never touching a guard the alert is busy with
	(fleeing, radioing, questioning, escorting):
	  * Holding        every guard goes to the nearest of its own route nodes and holds there (the engine has no separate Meadow nodes yet) [R: plan]
	  * Investigating  (Searching) a guard that hears a noise goes to the spot, waits InvestigateSeconds, then goes back to hold [P: the time]
	  * Hunting        (Attacking) a guard that knows where the player is goes there, and again when that moves more than HuntRetargetDistance;
	                   when it loses track it goes back to its post [R: plan: "hold, then hunt only after noise or sight"]
	Event: GuardMoves {Bot, Mode, X, Y, Z}.

	M9d, shooting, health and deaths (Attacking phase, lockdown landed, only guards the alert is not busy with):
	  * A guard that SEES a player (and the player is not down) fires its weapon, one round at a time, RoundsPerSecond, hitscan. Every guard
	    carries the S97 [R: owner]: 30 rounds, 0.5 HP per round, so a whole magazine on a player is 15 HP; rate of fire and reload time are [P].
	  * Hit chance per round = clamp(HitChanceBase + HitChancePerSecond x seconds the player has been in its sight, base, max) [P: plan], so
	    shooting starts inaccurate and sharpens. The rolls come from a seeded stream: same seed, same shots.
	  * Players have PlayerMaxHealth (100) [P]; at 0 they are down (PlayerDown), and are not shot at again. The host reports healing with
	    setPlayerHealth. Guards have the health of their class (BreachCombatData class table, 120 for a placed guard [O]) and die at 0.
	  * Damage TO a guard comes from the host (the player's own weapon): combat:damageBot(botId, amount, playerId) -> BotHit / BotDied.
	  * Health bar rule: a guard shows one iff its class says so (MaxHealth above 200, or ForceHealthDisplay) [O].
	Events: GuardFired {Bot, Player, Hit, Weapon}  GuardReloading {Bot}  PlayerHit {Bot, Player, Damage, Health}  PlayerDown {Player, By}
	        BotHit {Bot, Damage, Health, By}  BotDied {Bot, By}
]==]

local Random = (function()
--@@RANDOM@@
end)()

local Combat = {}
Combat.VERSION = "0.1.0"

Combat.Defaults = {
	LoseTrackSeconds = 20, -- [P]
	SoundTravelDistance = 80, -- studs, used when the mission setup has none [P]
	NoticeMeter = 1, -- the sight meter at which a drawn weapon counts as seen
	NoiseScale = { shot = 1.0, door = 0.3, footstep = 0.2 }, -- [P]
	Weapons = { S97 = { Damage = 0.5, MagSize = 30, RoundsPerSecond = 10, ReloadSeconds = 2.5 } }, -- Damage, MagSize [R: owner]; the rest [P]
	GuardWeapon = "S97", -- what every guard carries for now [R: owner: "use an S97"]
	HitChanceBase = 0.15, HitChancePerSecond = 0.1, HitChanceMax = 0.6, -- [P: plan]
	PlayerMaxHealth = 100, -- [P] (to confirm with the owner)
	HuntRetargetDistance = 4, -- studs the known position must move before a hunting guard is sent again [P]
	InvestigateSeconds = 6, -- how long a guard looks around a noise before going back to its post [P]
}

local Sim = {}
Sim.__index = Sim

local function out(bot)
	return bot == nil or bot.State == "Despawned" or bot.State == "Dead" or bot.Flags.Dead or bot.Flags.Incapacitated
end

local function drawn(pl)
	return pl.Weapon == "drawn" or (pl.Weapon == nil and pl.Armed == true)
end

local function emit(self, kind, fields)
	fields.Kind = kind
	fields.Time = self.Time
	self.Events[#self.Events + 1] = fields
end

function Combat.new(deps, opts)
	opts = opts or {}
	local params = {}
	for k, v in pairs(Combat.Defaults) do
		params[k] = v
	end
	params.NoiseScale = {}
	for k, v in pairs(Combat.Defaults.NoiseScale) do
		params.NoiseScale[k] = v
	end
	params.Weapons = {}
	for name, w in pairs(Combat.Defaults.Weapons) do
		local copy = {}
		for k, v in pairs(w) do
			copy[k] = v
		end
		params.Weapons[name] = copy
	end
	for k, v in pairs(opts.params or {}) do
		if k == "NoiseScale" and type(v) == "table" then
			for kind, scale in pairs(v) do
				params.NoiseScale[kind] = scale
			end
		elseif k == "Weapons" and type(v) == "table" then
			for name, fields in pairs(v) do -- merged field by field: { S97 = { ReloadSeconds = 5 } } keeps the rest of the S97
				local w = params.Weapons[name] or {}
				for f, x in pairs(fields) do
					w[f] = x
				end
				params.Weapons[name] = w
			end
		else
			params[k] = v
		end
	end
	local setup = deps.setup
	local enabled = opts.enabled == true or (type(setup) == "table" and setup.BreachLockdown == "TwoPhase")
	return setmetatable({
		Bots = deps.bots, Sight = deps.sight, Alert = deps.alert, PlayersFn = deps.players, Setup = setup,
		Params = params, Phase = enabled and "Calm" or "Off", Knows = {}, Seen = {}, Events = {}, Time = 0,
		Mode = {}, Goal = {}, Wait = {}, Investigate = {},
		Health = {}, Down = {}, BotHealth = {}, Ammo = {}, Reload = {}, Fire = {}, Exposure = {},
		Stream = Random.new(opts.seed or 0),
		ClassInfo = deps.classInfo or function() return { Health = 120, DamageOutput = 1, ShowsHealthBar = false } end,
	}, Sim)
end

function Sim:phase()
	return self.Phase
end

function Sim:drainEvents()
	local e = self.Events
	self.Events = {}
	return e
end

function Sim:knows(botId)
	local k = self.Knows[botId]
	if not k then
		return nil
	end
	return { Player = k.Player, X = k.X, Y = k.Y, Z = k.Z, Age = self.Time - k.T, Source = k.Source }
end

function Sim:_setPhase(phase, why)
	if self.Phase == phase then
		return
	end
	local prev = self.Phase
	self.Phase = phase
	emit(self, "PhaseChanged", { Phase = phase, Prev = prev, Why = why })
end

function Sim:_know(bot, pl, source)
	local k = self.Knows[bot.Id]
	local first = k == nil or k.Player ~= pl.Id
	self.Knows[bot.Id] = { Player = pl.Id, X = pl.X, Y = pl.Y, Z = pl.Z, T = self.Time, Source = source }
	if first then
		emit(self, "GuardKnows", { Bot = bot.Id, Player = pl.Id, X = pl.X, Y = pl.Y, Z = pl.Z, Source = source })
	end
end

function Sim:_weaponSeen(bot, pl)
	emit(self, "WeaponSeen", { Bot = bot.Id, Player = pl.Id })
	self:_setPhase("Attacking", "WeaponSeen")
	self:_know(bot, pl, "Sight")
	if self.Alert:level() < 3 then
		self.Alert:fleeAndRadio(bot.Id, pl.Id, "WeaponSeen") -- the lockdown lands with its call
	end
end

function Sim:step(dt)
	self.Time += dt
	if self.Phase == "Off" then
		return
	end
	if self.Phase == "Calm" and self.Alert:level() >= 3 then
		self:_setPhase("Searching", "Lockdown")
	end
	local bots = self.Bots:all()
	for _, pl in ipairs(self.PlayersFn()) do
		local isDrawn = drawn(pl)
		for _, bot in ipairs(bots) do
			if not out(bot) and not bot.Flags.Hostage then
				local key = bot.Id .. "|" .. pl.Id
				if isDrawn then
					local sees = self.Sight:canSee(bot.Id, pl.Id)
					if sees and self.Sight:meter(bot.Id, pl.Id) >= self.Params.NoticeMeter then
						if not self.Seen[key] then
							self.Seen[key] = true
							self:_weaponSeen(bot, pl)
						elseif self.Phase == "Attacking" then
							self:_know(bot, pl, "Sight") -- still in view: keep the position fresh
						end
					end
				else
					self.Seen[key] = nil -- holstered: the next time it is drawn is a new sighting
				end
			end
		end
	end
	for _, bot in ipairs(bots) do
		local k = self.Knows[bot.Id]
		if k then
			if out(bot) then
				self.Knows[bot.Id] = nil
				emit(self, "GuardLostTrack", { Bot = bot.Id, Player = k.Player, Why = "out" })
			elseif self.Time - k.T > self.Params.LoseTrackSeconds then
				self.Knows[bot.Id] = nil
				self.Seen[bot.Id .. "|" .. k.Player] = nil
				emit(self, "GuardLostTrack", { Bot = bot.Id, Player = k.Player, Why = "timeout" })
			end
		end
	end
	self:_move(bots, dt)
	self:_shoot(bots, dt)
end

local function dist3(ax, ay, az, bx, by, bz)
	return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2 + (az - bz) ^ 2)
end

-- the nearest of the guard's own route nodes (ties: the first)
function Sim:_nearestNode(bot)
	local bx, by, bz = self.Bots:position(bot.Id)
	local best, bestD
	for _, node in ipairs(bot.Route or {}) do
		local d = bx and dist3(bx, by, bz, node.X, node.Y, node.Z) or 0
		if not best or d < bestD then
			best, bestD = node, d
		end
	end
	return best
end

function Sim:_send(bot, mode, state, x, y, z)
	self.Mode[bot.Id] = mode
	self.Goal[bot.Id] = { X = x, Y = y, Z = z }
	self.Bots:command(bot.Id, state, x, y, z)
	emit(self, "GuardMoves", { Bot = bot.Id, Mode = mode, X = x, Y = y, Z = z })
end

-- M9c: what each guard does once the lockdown has landed
function Sim:_move(bots, dt)
	if self.Phase ~= "Searching" and self.Phase ~= "Attacking" then
		return
	end
	local p = self.Params
	local lockdown = self.Alert:level() >= 3
	for _, bot in ipairs(bots) do
		local id = bot.Id
		if out(bot) or bot.Flags.Hostage then
			self.Mode[id], self.Goal[id], self.Wait[id], self.Investigate[id] = nil, nil, nil, nil
		elseif self.Alert:busy(id) then
			self.Mode[id] = nil -- the alert has the guard: not ours to move
		elseif not lockdown then
			if self.Mode[id] then
				self.Mode[id] = nil
				self.Bots:resume(id)
			end
		else
			local k = self.Knows[id]
			local inv = self.Investigate[id]
			if k then
				local g = self.Goal[id]
				if self.Mode[id] ~= "Hunting" or not g or dist3(g.X, g.Y, g.Z, k.X, k.Y, k.Z) > p.HuntRetargetDistance then
					self.Investigate[id], self.Wait[id] = nil, nil
					self:_send(bot, "Hunting", "Hunting", k.X, k.Y, k.Z)
				end
			elseif inv then
				self.Investigate[id], self.Wait[id] = nil, nil
				self:_send(bot, "Investigating", "Investigating", inv.X, inv.Y, inv.Z)
			else
				local mode = self.Mode[id]
				if mode == "Investigating" and bot.State == "Investigating" then -- arrived: look around, then go back
					self.Wait[id] = (self.Wait[id] or p.InvestigateSeconds) - dt
					if self.Wait[id] <= 0 then
						self.Wait[id], mode = nil, nil
					end
				end
				if mode ~= "Investigating" and mode ~= "Holding" then -- nothing to do: back to the nearest post
					local node = self:_nearestNode(bot)
					if node then
						self:_send(bot, "Holding", "Holding", node.X, node.Y, node.Z)
					else
						self.Mode[id] = "Holding"
						self.Bots:hold(id, "Holding")
					end
				end
			end
		end
	end
end

---------------------------------------------------------------------------------------------------------- M9d: shooting, health, deaths
local function clamp(v, lo, hi)
	return math.max(lo, math.min(hi, v))
end

function Sim:playerHealth(id)
	local max = self.Params.PlayerMaxHealth
	local hp = self.Health[id]
	if hp == nil then
		hp = max
	end
	return hp, max, self.Down[id] == true
end

-- the host reports healing (or a respawn): back above 0 the player can be shot at again
function Sim:setPlayerHealth(id, hp)
	self.Health[id] = clamp(hp, 0, self.Params.PlayerMaxHealth)
	self.Down[id] = self.Health[id] <= 0 or nil
end

function Sim:_damagePlayer(bot, pl, amount)
	local hp = self:playerHealth(pl.Id)
	hp = math.max(0, hp - amount)
	self.Health[pl.Id] = hp
	emit(self, "PlayerHit", { Bot = bot.Id, Player = pl.Id, Damage = amount, Health = hp })
	if hp <= 0 then
		self.Down[pl.Id] = true
		emit(self, "PlayerDown", { Player = pl.Id, By = bot.Id })
	end
end

function Sim:_botInfo(bot)
	local info = self.ClassInfo(bot)
	return { Health = info.Health or 120, DamageOutput = info.DamageOutput or 1, ShowsHealthBar = info.ShowsHealthBar == true }
end

function Sim:botHealth(botId)
	local bot = self.Bots:bot(botId)
	if not bot then
		return nil
	end
	local info = self:_botInfo(bot)
	local hp = self.BotHealth[botId]
	if hp == nil then
		hp = info.Health
	end
	return hp, info.Health, info.ShowsHealthBar
end

-- The host reports damage dealt TO a guard (the player's own weapon). Returns the guard's health after it, or nil for an unknown or dead guard.
function Sim:damageBot(botId, amount, playerId)
	local bot = self.Bots:bot(botId)
	if out(bot) or self.Phase == "Off" then
		return nil
	end
	local hp = self:botHealth(botId)
	hp = math.max(0, hp - amount)
	self.BotHealth[botId] = hp
	emit(self, "BotHit", { Bot = botId, Damage = amount, Health = hp, By = playerId })
	if hp <= 0 then
		self.Bots:setFlag(botId, "Dead", true)
		emit(self, "BotDied", { Bot = botId, By = playerId })
	end
	return hp
end

function Sim:_shoot(bots, dt)
	if self.Phase ~= "Attacking" or self.Alert:level() < 3 then
		self.Exposure = {}
		return
	end
	local p = self.Params
	local w = p.Weapons[p.GuardWeapon]
	if not w then
		return
	end
	local interval = 1 / w.RoundsPerSecond
	local players = self.PlayersFn()
	for _, bot in ipairs(bots) do
		local id = bot.Id
		if out(bot) or bot.Flags.Hostage or self.Alert:busy(id) then
			self.Fire[id] = nil
		else
			local target
			for _, pl in ipairs(players) do
				local key = id .. "|" .. pl.Id
				if not self.Down[pl.Id] and self.Sight:canSee(id, pl.Id) then
					self.Exposure[key] = (self.Exposure[key] or 0) + dt
					target = target or pl
				else
					self.Exposure[key] = nil
				end
			end
			if self.Reload[id] then
				self.Reload[id] -= dt
				if self.Reload[id] <= 0 then
					self.Reload[id], self.Ammo[id] = nil, w.MagSize
				end
			elseif target then
				self.Fire[id] = (self.Fire[id] or 0) + dt
				local damage = w.Damage * self:_botInfo(bot).DamageOutput
				while self.Fire[id] >= interval and not self.Down[target.Id] do
					local ammo = self.Ammo[id]
					if ammo == nil then
						ammo = w.MagSize
					end
					if ammo <= 0 then
						break
					end
					self.Fire[id] -= interval
					self.Ammo[id] = ammo - 1
					local chance = clamp(p.HitChanceBase + p.HitChancePerSecond * (self.Exposure[id .. "|" .. target.Id] or 0), p.HitChanceBase, p.HitChanceMax)
					local hit = self.Stream:nextFloat() < chance
					emit(self, "GuardFired", { Bot = id, Player = target.Id, Hit = hit, Weapon = p.GuardWeapon })
					if hit then
						self:_damagePlayer(bot, target, damage)
					end
				end
				if (self.Ammo[id] or w.MagSize) <= 0 then
					self.Reload[id], self.Fire[id] = w.ReloadSeconds, 0
					emit(self, "GuardReloading", { Bot = id })
				end
			else
				self.Fire[id] = 0
			end
		end
	end
end

function Sim:hearingRange(kind)
	local scale = self.Params.NoiseScale[kind]
	if not scale then
		return nil
	end
	local d = type(self.Setup) == "table" and tonumber(self.Setup.SoundTravelDistance) or nil
	return (d or self.Params.SoundTravelDistance) * scale
end

function Sim:noise(kind, x, y, z, playerId)
	local range = self.Phase ~= "Off" and self:hearingRange(kind) or nil
	if not range then
		return 0
	end
	local heard = 0
	for _, bot in ipairs(self.Bots:all()) do
		if not out(bot) and not bot.Flags.Hostage then
			local bx, by, bz = self.Bots:position(bot.Id)
			if bx then
				local d = math.sqrt((bx - x) ^ 2 + (by - y) ^ 2 + (bz - z) ^ 2)
				if d <= range then
					heard += 1
					local aware = self.Phase == "Attacking"
					emit(self, "NoiseHeard", { Bot = bot.Id, Noise = kind, X = x, Y = y, Z = z, Aware = aware })
					if aware then
						self:_know(bot, { Id = playerId or "?", X = x, Y = y, Z = z }, "Noise:" .. kind)
					else
						self.Investigate[bot.Id] = { X = x, Y = y, Z = z } -- Searching: go and look (M9c)
					end
				end
			end
		end
	end
	return heard
end

return Combat
