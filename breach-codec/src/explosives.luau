--!nonstrict
--[==[
	BreachExplosives — grenades and C4 (BreachEngine M9e; plan: docs/BreachEngine_M9_Combat_Plan.md, section 4).

	Pure Luau, deterministic, no Roblox APIs, no requires. It owns the TIMERS and the DAMAGE of explosives; who throws or plants one, and when,
	is decided elsewhere (BreachCombat for guards, the host for a player's own grenade).

	    local ex = Explosives.new({
	        players = playersFn,                    -- () -> { { Id =, X =, Y =, Z = }, ... }
	        bots = bots,                            -- BreachBots: :all() and :position(id)
	        damagePlayer = function(playerId, amount, by) end,
	        damageBot = function(botId, amount, by) end,
	    }, { params = { ... } })
	    ex:throwGrenade(by, x, y, z)       -> id          by = { Kind = "Bot" | "Player", Id = ... }
	    ex:plantC4(by, x, y, z)            -> id
	    ex:startDisarm(playerId, c4Id)     -> true | false, reason      (NoSuchC4 | Gone | TooFar)
	    ex:cancelDisarm(playerId)
	    ex:step(dt)   ex:drainEvents()   ex:active() -> { { Id, Kind, X, Y, Z, Age, Armed } }

	Numbers [P: the plan, section 4; the owner will tune them in Explosives.Defaults]:
	  * grenade: fuse 2.0 s, radius 5, damage 60 at the centre falling LINEARLY to 0 at the edge;
	  * C4: armed 3 s after it is planted, detonates 8 s after it is planted, radius 8, damage 120 (same falloff); a player within
	    C4DisarmRange (3) of it who holds for C4DisarmSeconds (1.5) disarms it, and walking away cancels the attempt.
	Who is hurt: an explosive made by a BOT hurts players only; one made by a PLAYER hurts bots only (no friendly fire, FriendlyFire = false) [P].
	A scale (`opts.scale` in throw/plant, e.g. a class DamageOutput) multiplies the damage.

	Events: GrenadeThrown {Id, By, X, Y, Z}  C4Planted {Id, By, X, Y, Z}  C4Armed {Id}  Explosion {Id, Type = "Grenade" | "C4", X, Y, Z, Radius}
	        ExplosionHit {Id, Target = "Player" | "Bot", TargetId, Damage, Distance}  C4DisarmStarted {Id, Player}
	        C4DisarmCancelled {Id, Player, Why}  C4Disarmed {Id, Player}
]==]

local Explosives = {}
Explosives.VERSION = "0.1.0"

Explosives.Defaults = {
	GrenadeFuse = 2.0, GrenadeRadius = 5, GrenadeDamage = 60,
	C4ArmSeconds = 3, C4FuseSeconds = 8, C4Radius = 8, C4Damage = 120,
	C4DisarmSeconds = 1.5, C4DisarmRange = 3,
	FriendlyFire = false,
}

local Sim = {}
Sim.__index = Sim

local function emit(self, kind, fields)
	fields.Kind = kind
	fields.Time = self.Time
	self.Events[#self.Events + 1] = fields
end

local function out(bot)
	return bot == nil or bot.State == "Despawned" or bot.State == "Dead" or (bot.Flags and (bot.Flags.Dead or bot.Flags.Incapacitated)) or false
end

function Explosives.new(deps, opts)
	opts = opts or {}
	local params = {}
	for k, v in pairs(Explosives.Defaults) do
		params[k] = v
	end
	for k, v in pairs(opts.params or {}) do
		params[k] = v
	end
	return setmetatable({
		PlayersFn = deps.players, Bots = deps.bots, DamagePlayer = deps.damagePlayer, DamageBot = deps.damageBot,
		Params = params, Time = 0, Events = {}, Items = {}, NextId = 1, Disarm = {},
	}, Sim)
end

function Sim:drainEvents()
	local e = self.Events
	self.Events = {}
	return e
end

local function normBy(by)
	if type(by) == "table" then
		return { Kind = by.Kind or "Bot", Id = by.Id }
	end
	return { Kind = "Bot", Id = by }
end

function Sim:throwGrenade(by, x, y, z, scale)
	local id = self.NextId
	self.NextId += 1
	self.Items[id] = { Id = id, Kind = "Grenade", By = normBy(by), X = x, Y = y, Z = z, Age = 0, Scale = scale or 1 }
	emit(self, "GrenadeThrown", { Id = id, By = self.Items[id].By, X = x, Y = y, Z = z })
	return id
end

function Sim:plantC4(by, x, y, z, scale)
	local id = self.NextId
	self.NextId += 1
	self.Items[id] = { Id = id, Kind = "C4", By = normBy(by), X = x, Y = y, Z = z, Age = 0, Scale = scale or 1, Armed = false }
	emit(self, "C4Planted", { Id = id, By = self.Items[id].By, X = x, Y = y, Z = z })
	return id
end

local function player(self, id)
	for _, pl in ipairs(self.PlayersFn()) do
		if pl.Id == id then
			return pl
		end
	end
	return nil
end

local function dist(ax, ay, az, bx, by, bz)
	return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2 + (az - bz) ^ 2)
end

function Sim:startDisarm(playerId, c4Id)
	local item = self.Items[c4Id]
	if not item or item.Kind ~= "C4" then
		return false, "NoSuchC4"
	end
	local pl = player(self, playerId)
	if not pl then
		return false, "Gone"
	end
	if dist(pl.X, pl.Y, pl.Z, item.X, item.Y, item.Z) > self.Params.C4DisarmRange then
		return false, "TooFar"
	end
	local cur = self.Disarm[playerId]
	if cur and cur.C4 == c4Id then
		return true
	end
	self.Disarm[playerId] = { C4 = c4Id, T = 0 }
	emit(self, "C4DisarmStarted", { Id = c4Id, Player = playerId })
	return true
end

function Sim:cancelDisarm(playerId, why)
	local cur = self.Disarm[playerId]
	if cur then
		self.Disarm[playerId] = nil
		emit(self, "C4DisarmCancelled", { Id = cur.C4, Player = playerId, Why = why or "Cancelled" })
	end
end

function Sim:active()
	local list = {}
	for _, id in ipairs(self:_ids()) do
		local it = self.Items[id]
		list[#list + 1] = { Id = id, Kind = it.Kind, X = it.X, Y = it.Y, Z = it.Z, Age = it.Age, Armed = it.Armed == true }
	end
	return list
end

function Sim:_ids()
	local ids = {}
	for id in pairs(self.Items) do
		ids[#ids + 1] = id
	end
	table.sort(ids)
	return ids
end

function Sim:_explode(item)
	local p = self.Params
	local radius = item.Kind == "Grenade" and p.GrenadeRadius or p.C4Radius
	local base = (item.Kind == "Grenade" and p.GrenadeDamage or p.C4Damage) * item.Scale
	self.Items[item.Id] = nil
	for pid, cur in pairs(self.Disarm) do
		if cur.C4 == item.Id then
			self.Disarm[pid] = nil
		end
	end
	emit(self, "Explosion", { Id = item.Id, Type = item.Kind, X = item.X, Y = item.Y, Z = item.Z, Radius = radius })
	local fromBot = item.By.Kind ~= "Player"
	if fromBot or p.FriendlyFire then
		for _, pl in ipairs(self.PlayersFn()) do
			local d = dist(pl.X, pl.Y, pl.Z, item.X, item.Y, item.Z)
			if d < radius and not (item.By.Kind == "Player" and item.By.Id == pl.Id and not p.FriendlyFire) then
				local dmg = base * (1 - d / radius)
				if dmg > 0 then
					emit(self, "ExplosionHit", { Id = item.Id, Target = "Player", TargetId = pl.Id, Damage = dmg, Distance = d })
					if self.DamagePlayer then
						self.DamagePlayer(pl.Id, dmg, item.By.Id)
					end
				end
			end
		end
	end
	if not fromBot or p.FriendlyFire then
		for _, bot in ipairs(self.Bots:all()) do
			if not out(bot) then
				local bx, by, bz = self.Bots:position(bot.Id)
				if bx then
					local d = dist(bx, by, bz, item.X, item.Y, item.Z)
					if d < radius and not (item.By.Kind == "Bot" and item.By.Id == bot.Id and not p.FriendlyFire) then
						local dmg = base * (1 - d / radius)
						if dmg > 0 then
							emit(self, "ExplosionHit", { Id = item.Id, Target = "Bot", TargetId = bot.Id, Damage = dmg, Distance = d })
							if self.DamageBot then
								self.DamageBot(bot.Id, dmg, item.By.Id)
							end
						end
					end
				end
			end
		end
	end
end

function Sim:step(dt)
	self.Time += dt
	local p = self.Params
	-- disarm attempts first: a C4 disarmed this step does not also go off
	local pids = {}
	for pid in pairs(self.Disarm) do
		pids[#pids + 1] = pid
	end
	table.sort(pids)
	for _, pid in ipairs(pids) do
		local cur = self.Disarm[pid]
		local item = self.Items[cur.C4]
		local pl = player(self, pid)
		if not item then
			self.Disarm[pid] = nil
		elseif not pl then
			self:cancelDisarm(pid, "Gone")
		elseif dist(pl.X, pl.Y, pl.Z, item.X, item.Y, item.Z) > p.C4DisarmRange then
			self:cancelDisarm(pid, "TooFar")
		else
			cur.T += dt
			if cur.T >= p.C4DisarmSeconds then
				self.Disarm[pid] = nil
				self.Items[cur.C4] = nil
				emit(self, "C4Disarmed", { Id = cur.C4, Player = pid })
			end
		end
	end
	for _, id in ipairs(self:_ids()) do
		local item = self.Items[id]
		if item then
			item.Age += dt
			if item.Kind == "Grenade" then
				if item.Age >= p.GrenadeFuse then
					self:_explode(item)
				end
			else
				if not item.Armed and item.Age >= p.C4ArmSeconds then
					item.Armed = true
					emit(self, "C4Armed", { Id = id })
				end
				if item.Age >= p.C4FuseSeconds then
					self:_explode(item)
				end
			end
		end
	end
end

return Explosives
