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
]==]

local Combat = {}
Combat.VERSION = "0.1.0"

Combat.Defaults = {
	LoseTrackSeconds = 20, -- [P]
	SoundTravelDistance = 80, -- studs, used when the mission setup has none [P]
	NoticeMeter = 1, -- the sight meter at which a drawn weapon counts as seen
	NoiseScale = { shot = 1.0, door = 0.3, footstep = 0.2 }, -- [P]
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
	for k, v in pairs(opts.params or {}) do
		if k == "NoiseScale" and type(v) == "table" then
			for kind, scale in pairs(v) do
				params.NoiseScale[kind] = scale
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
					end
				end
			end
		end
	end
	return heard
end

return Combat
