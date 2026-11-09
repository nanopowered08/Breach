--!nonstrict
--[==[
	BreachSight — what bots see, and how fast they notice (BreachEngine M8c, part 1; plan §5).

	Pure Luau, deterministic (no randomness), no Roblox APIs. Sight does NOT decide what being noticed means: it produces
	meters and events. Trespass (is this player allowed here?) and alert (what happens next?) are separate layers.

	    local sight = Sight.new(world, bots, playersFn, { blocked = function(ax, ay, az, bx, by, bz) return closedDoorBetween end })
	    sight:step(dt)                                 -- after bots:step(dt)
	    sight:canSee(botId, playerId) -> visible, distance
	    sight:meter(botId, playerId)                   -- 0..1
	    sight:noticedBy(playerId) -> { botId, ... }    sight:isNoticed(playerId)
	    sight:drainEvents()  -- SightSeen SightSuspicious SightNoticed SightLost    { Bot, Player, Time, Meter, Distance }

	playersFn() -> { { Id =, X =, Y =, Z =, Stance = "stand" | "crouch" | "sprint", Exited = bool, Disguise = string?, Armed = bool? }, ... }   (Sight.propsPlayers(sim) adapts BreachProps)

	A bot sees a player when ALL of these hold [P: every number is a default in Sight.Defaults, to be corrected by feel]:
	  * within ViewRange x the stance factor (crouching shrinks it, sprinting stretches it);
	  * inside the FOV cone of its facing, or inside the small all-round PeripheralRadius;
	  * line of sight: walking the segment between the two, consecutive cells must be joined by a link (a wall between
	    cells with no link blocks it; unmapped space is open), and `opts.blocked` may add more (closed doors, BreachProps).
	Noticing: the meter fills at DetectionSpeed / T(d) per second, where T runs from NoticeNear (point blank) to NoticeFar
	(at the edge of the range); it falls at Decay per second when the player is not seen.  DetectionSpeed is a multiplier
	taken from the bot (real values 0.6 .. 1; lower = slower to notice).
	The alert level scales it too [R: community report passed on by the owner, Nov 2026]: the higher the level, the faster guards
	notice: Calm 0.9x, Normal 1x, Alert 1.1x. Lockdown was not given: it keeps Alert's 1.1x [P]. The host/session supplies the level
	through `sight.LevelFn` (BreachSession wires it to the alert); with no LevelFn the factor is 1.
]==]

local Sight = {}
Sight.VERSION = "0.1.0"

Sight.Defaults = {
	ViewRange = 70, -- studs
	FovDegrees = 110,
	PeripheralRadius = 6, -- noticed from any direction this close (still needs line of sight)
	StanceRange = { stand = 1, crouch = 0.6, sprint = 1.25 },
	NoticeNear = 0.6, -- seconds to notice at point blank (DetectionSpeed 1)
	NoticeFar = 4.0, -- ... and at the edge of the range
	Decay = 0.5, -- meter units per second when not seen
	SuspiciousAt = 0.35,
	NoticedAt = 1,
	LoseSeconds = 3, -- a noticed player must stay unseen this long to be "lost"
	EyeHeight = 4.5,
	TargetHeight = 3,
	LosStep = 1.5, -- studs between line-of-sight samples
	AlertSpeed = { [0] = 0.9, [1] = 1, [2] = 1.1, [3] = 1.1 }, -- detection speed factor by alert level (Calm, Normal, Alert, Lockdown) [R 0..2, P 3]
}

local function clamp(x, lo, hi)
	return math.max(lo, math.min(hi, x))
end

local Sim = {}
Sim.__index = Sim

function Sight.new(world, bots, playersFn, opts)
	opts = opts or {}
	local params = {}
	for k, v in pairs(Sight.Defaults) do
		params[k] = v
	end
	for k, v in pairs(opts.params or {}) do
		params[k] = v
	end
	local self = setmetatable({
		World = world, Bots = bots, PlayersFn = playersFn, Blocked = opts.blocked, Params = params, LevelFn = opts.alertLevel,
		Time = 0, Pairs = {}, Events = {}, Adjacent = {},
	}, Sim)
	-- cells that touch (joined by a link) may see into each other
	if world and world.Links then
		for _, link in ipairs(world.Links) do
			local cells = link.Cells or {}
			for i = 1, #cells do
				for j = 1, #cells do
					if cells[i] ~= cells[j] then
						self.Adjacent[cells[i]] = self.Adjacent[cells[i]] or {}
						self.Adjacent[cells[i]][cells[j]] = true
					end
				end
			end
		end
	end
	return self
end

-- The detection speed factor for the current alert level (1 when there is no LevelFn).
function Sim:alertFactor()
	local level = self.LevelFn and self.LevelFn()
	if type(level) ~= "number" then
		return 1
	end
	return self.Params.AlertSpeed[clamp(math.floor(level), 0, 3)] or 1
end

-- Adapter: BreachProps' players as the playersFn Sight wants.
function Sight.propsPlayers(sim)
	return function()
		local out = {}
		for _, id in ipairs(sim.Order) do
			local p = sim.Players[id]
			out[#out + 1] = { Id = p.Id, X = p.Pos[1], Y = p.Pos[2], Z = p.Pos[3], Stance = p.Stance or "stand", Exited = p.Exited, Disguise = p.Disguise, Armed = p.Armed or false }
		end
		return out
	end
end

local function emit(self, kind, bot, player, extra)
	local ev = { Kind = kind, Bot = bot, Player = player, Time = self.Time }
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

-- Walls: walking the segment, consecutive distinct cells must be joined by a link.
function Sim:cellsClear(ax, ay, az, bx, by, bz)
	local world = self.World
	if not world or not world.cellAt then
		return true
	end
	-- a cell is a convex box: two points inside the same cell see each other, no sampling needed
	local ca, cb = world:cellAt(ax, ay, az), world:cellAt(bx, by, bz)
	if ca and cb and ca.Index == cb.Index then
		return true
	end
	local dx, dy, dz = bx - ax, by - ay, bz - az
	local len = math.sqrt(dx * dx + dy * dy + dz * dz)
	local steps = math.max(1, math.ceil(len / self.Params.LosStep))
	local prev
	for i = 0, steps do
		local t = i / steps
		local cell = world:cellAt(ax + dx * t, ay + dy * t, az + dz * t)
		if cell then
			local idx = cell.Index
			if prev and idx ~= prev and not (self.Adjacent[prev] and self.Adjacent[prev][idx]) then
				return false
			end
			prev = idx
		end
	end
	return true
end

function Sim:lineOfSight(ax, ay, az, bx, by, bz)
	if not self:cellsClear(ax, ay, az, bx, by, bz) then
		return false
	end
	if self.Blocked and self.Blocked(ax, ay, az, bx, by, bz) then
		return false
	end
	return true
end

-- Can this bot see this player right now? Returns visible, distance (and the reason when not).
function Sim:visibility(bot, player)
	local p = self.Params
	local bx, by, bz = self.Bots:position(bot.Id)
	if not bx then
		return false, math.huge, "gone"
	end
	local dx, dy, dz = player.X - bx, player.Y - by, player.Z - bz
	local d = math.sqrt(dx * dx + dy * dy + dz * dz)
	local range = p.ViewRange * (p.StanceRange[player.Stance or "stand"] or 1)
	if d > range then
		return false, d, "range"
	end
	if d > p.PeripheralRadius then
		local fx, fz = self.Bots:facing(bot)
		local hl = math.sqrt(dx * dx + dz * dz)
		if hl > 1e-6 then
			local cos = (fx * dx + fz * dz) / hl
			if cos < math.cos(math.rad(p.FovDegrees / 2)) then
				return false, d, "fov"
			end
		end
	end
	if not self:lineOfSight(bx, by + p.EyeHeight, bz, player.X, player.Y + p.TargetHeight, player.Z) then
		return false, d, "blocked"
	end
	return true, d
end

function Sim:canSee(botId, playerId)
	local bot = self.Bots:bot(botId)
	if not bot then
		return false, math.huge
	end
	for _, pl in ipairs(self.PlayersFn()) do
		if pl.Id == playerId then
			local v, d = self:visibility(bot, pl)
			return v, d
		end
	end
	return false, math.huge
end

local function observes(bot)
	return bot.State ~= "Despawned" and bot.State ~= "Dead" and not bot.Flags.Incapacitated and not bot.Flags.Dead
end

-- Can this bot see a fixed point (a body, a dropped radio, a broken window)?  Same cone, range and line of sight as for a
-- player standing there, with no stance factor.  Returns visible, distance.
function Sim:canSeePoint(botId, x, y, z)
	local bot = self.Bots:bot(botId)
	if not bot or not observes(bot) then
		return false, math.huge
	end
	return self:visibility(bot, { X = x, Y = y, Z = z, Stance = "stand" })
end

function Sim:pair(botId, playerId)
	local row = self.Pairs[botId]
	if not row then
		row = {}
		self.Pairs[botId] = row
	end
	local st = row[playerId]
	if not st then
		st = { Meter = 0, Visible = false, Suspicious = false, Noticed = false, Unseen = 0 }
		row[playerId] = st
	end
	return st
end

function Sim:step(dt)
	local p = self.Params
	self.Time += dt
	local players = self.PlayersFn()
	for _, bot in ipairs(self.Bots:all()) do
		local observing = observes(bot)
		for _, pl in ipairs(players) do
			local st = self:pair(bot.Id, pl.Id)
			local visible, d = false, math.huge
			if observing and not pl.Exited then
				visible, d = self:visibility(bot, pl)
			end
			if visible then
				local range = p.ViewRange * (p.StanceRange[pl.Stance or "stand"] or 1)
				local t = p.NoticeNear + (p.NoticeFar - p.NoticeNear) * clamp(d / range, 0, 1)
				st.Meter = clamp(st.Meter + (bot.DetectionSpeed or 1) * self:alertFactor() / t * dt, 0, 1)
				st.Unseen = 0
				if not st.Visible then
					st.Visible = true
					emit(self, "SightSeen", bot.Id, pl.Id, { Meter = st.Meter, Distance = d })
				end
				if not st.Suspicious and st.Meter >= p.SuspiciousAt then
					st.Suspicious = true
					emit(self, "SightSuspicious", bot.Id, pl.Id, { Meter = st.Meter, Distance = d })
				end
				if not st.Noticed and st.Meter >= p.NoticedAt then
					st.Noticed = true
					emit(self, "SightNoticed", bot.Id, pl.Id, { Meter = st.Meter, Distance = d })
				end
			else
				st.Visible = false
				st.Unseen += dt
				if st.Noticed then
					-- a bot that has noticed you keeps the meter full until it loses you
					if st.Unseen >= p.LoseSeconds then
						st.Noticed, st.Suspicious, st.Meter = false, true, p.SuspiciousAt
						emit(self, "SightLost", bot.Id, pl.Id, { Meter = st.Meter })
					end
				else
					st.Meter = math.max(0, st.Meter - p.Decay * dt)
					if st.Suspicious and st.Meter < p.SuspiciousAt * 0.5 then
						st.Suspicious = false
					end
				end
			end
		end
	end
end

function Sim:meter(botId, playerId)
	local row = self.Pairs[botId]
	local st = row and row[playerId]
	return st and st.Meter or 0
end

function Sim:noticedBy(playerId)
	local out = {}
	for _, bot in ipairs(self.Bots:all()) do
		local row = self.Pairs[bot.Id]
		local st = row and row[playerId]
		if st and st.Noticed then
			out[#out + 1] = bot.Id
		end
	end
	return out
end

function Sim:isNoticedBy(botId, playerId)
	local row = self.Pairs[botId]
	local st = row and row[playerId]
	return st ~= nil and st.Noticed
end

function Sim:isNoticed(playerId)
	return #self:noticedBy(playerId) > 0
end

-- The highest meter any bot holds for a player (a UI "detection" bar).
function Sim:maxMeter(playerId)
	local m = 0
	for _, row in pairs(self.Pairs) do
		local st = row[playerId]
		if st and st.Meter > m then
			m = st.Meter
		end
	end
	return m
end

return Sight
