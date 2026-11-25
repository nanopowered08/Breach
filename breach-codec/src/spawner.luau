--!nonstrict
--[==[
	BreachSpawner — combat spawners, reinforcement pools and waves (BreachEngine M9f; plan: docs/BreachEngine_M9_Combat_Plan.md, section 5).

	Pure Luau, deterministic (seeded BreachRandom), no Roblox APIs, no requires. It makes the reinforcements: it reads the combat data model
	(BreachCombatData: model.Spawners, model.Pools, model.Spawns) and, while the mission runs, spawns guards through BreachBots:spawnAt.

	    local sp = Spawner.new({ logic = logic, bots = bots, model = model, players = playersFn, phase = function() return combat:phase() end,
	                             inform = function(botId, playerId) combat:inform(botId, playerId, "Reinforcement") end }, { seed = 416, params = { ... } })
	    sp:step(dt)   sp:drainEvents()   sp:alive(spawnerName) -> n   sp:poolRemaining(poolName) -> n | nil   sp:summary()
	    sp:spawnNow(spawnerName, x, y, z, weaponClassIndex?) -> botId | nil     -- a custom spawn: a map script's boss, with the same class and CustomCombatData rules

	A spawner (kind CombatSpawner; sniper and cover-fill spawners are not driven yet) spawns [R from the docs, section 8.3; the rest P]:
	  * only while its `Active` expression is true and its `SpawnsBlockedVariable` is not, and (when the combat phases are on) only in the
	    ATTACKING phase: in Searching reinforcements do not spawn, they start when Attacking begins [P: plan];
	  * one guard every `TimeBetweenSpawns` seconds (an expression, read each time) while fewer than `SpawnCap` of ITS guards are alive;
	  * a guard's weapon and class are drawn from the spawner's `Weapon:Class` pairs (duplicates weight the draw) with the seeded stream;
	  * at one of the spawn parts (model.Spawns) whose SpawnTag is one of the spawner's SpawnTags, that is Enabled, and that is not too close to a
	    player: a part with a Range keeps its spawns at least Range x ProximityStudsPerHop (20 [P]) studs from every player unless the part has
	    IgnoreProximity [P: the doc gives cell hops; this engine measures studs]. No valid part: it tries again next tick.
	A spawned guard gets the spawner's CustomCombatData (as `CustomCombatData` text kept on the bot) and is told where the nearest player is.

	A pool (`ReinforcementPool`) limits a spawner that names it [P]:
	  * its `Limit` expression is how many guards it may spawn per wave; each spawn writes the number left to `RemainingVariable`;
	  * it only gives while its `ActiveVariable` (if it has one) is true;
	  * when nothing is left AND no more than `WaveResetThreshold` (default 0) of its guards are alive, the next wave starts after `WaveResetTime`
	    seconds (default 20): the wave number goes to `WaveVariable`, and that time shrinks by `WaveResetTimeDecrease` per wave down to `WaveResetTimeMinimum`.
	Events: Spawned {Spawner, Bot, Weapon, Class, X, Y, Z, Pool}  PoolExhausted {Pool}  WaveStarted {Pool, Wave}  SpawnSkipped {Spawner, Why}
]==]

local Random = (function()
--@@RANDOM@@
end)()

local Spawner = {}
Spawner.VERSION = "0.1.0"

Spawner.Defaults = {
	ProximityStudsPerHop = 20, -- [P]
	DefaultSpawnCap = 4, DefaultTimeBetweenSpawns = 5, -- when the spawner's expressions give nothing usable [P]
	DefaultWaveResetTime = 20, -- [P]
	RequirePhase = true, -- reinforcements only in the Attacking phase when the combat phases are on [P: plan]
}

local Sim = {}
Sim.__index = Sim

local function emit(self, kind, fields)
	fields.Kind = kind
	fields.Time = self.Time
	self.Events[#self.Events + 1] = fields
end

local function truthy(v)
	return v ~= nil and v ~= false and v ~= 0 and v ~= ""
end

local function isBlank(v)
	return v == nil or v == "" or (type(v) == "string" and not v:match("%S"))
end

local function alive(bot)
	return bot ~= nil and bot.State ~= "Despawned" and bot.State ~= "Dead" and not (bot.Flags and (bot.Flags.Dead or bot.Flags.Incapacitated))
end

function Spawner.new(deps, opts)
	opts = opts or {}
	local params = {}
	for k, v in pairs(Spawner.Defaults) do
		params[k] = v
	end
	for k, v in pairs(opts.params or {}) do
		params[k] = v
	end
	local self = setmetatable({
		Logic = deps.logic, Bots = deps.bots, Model = deps.model or { Spawners = {}, Pools = {}, Spawns = {} }, PlayersFn = deps.players,
		PhaseFn = deps.phase, InformFn = deps.inform, Params = params, Stream = Random.new(opts.seed or 0), Time = 0, Events = {},
		State = {}, Pools = {}, Mine = {}, Order = {},
	}, Sim)
	for i, sp in ipairs(self.Model.Spawners) do
		if sp.Kind == "CombatSpawner" then
			local key = sp.Path or sp.Name or tostring(i)
			self.State[key] = { Next = 0, Spawned = 0 }
			self.Mine[key] = {}
			self.Order[#self.Order + 1] = { Key = key, Spec = sp }
		end
	end
	-- model.Pools is a map { [poolName] = pool } (BreachCombatData); a plain list of pools with a Name is accepted too
	for key, pool in pairs(self.Model.Pools) do
		local name = pool.Name or pool.Id or (type(key) == "string" and key or nil)
		if name then
			self.Pools[name] = { Spec = pool, Remaining = nil, Wave = 1, WaveTime = tonumber(pool.WaveResetTime) or params.DefaultWaveResetTime, Reset = nil }
		end
	end
	return self
end

function Sim:drainEvents()
	local e = self.Events
	self.Events = {}
	return e
end

-- an attribute that may be a literal or an expression over the mission's variables
function Sim:_value(v)
	if v == nil then
		return nil
	end
	if type(v) == "string" then
		local ok, r = pcall(self.Logic.eval, self.Logic, v)
		if ok then
			return r
		end
		return nil
	end
	return v
end

function Sim:_variable(name)
	if isBlank(name) then
		return nil
	end
	return self.Logic:get(name)
end

function Sim:alive(key)
	local n = 0
	for _, id in ipairs(self.Mine[key] or {}) do
		if alive(self.Bots:bot(id)) then
			n += 1
		end
	end
	return n
end

local function specKey(self, name)
	for _, e in ipairs(self.Order) do
		if e.Key == name or e.Spec.Name == name then
			return e.Key, e.Spec
		end
	end
	return nil
end

function Sim:aliveOf(name)
	local key = specKey(self, name)
	return key and self:alive(key) or 0
end

function Sim:poolRemaining(name)
	local pool = self.Pools[name]
	return pool and pool.Remaining or nil
end

local function pick(self, list)
	if #list == 0 then
		return nil
	end
	return list[1 + math.floor(self.Stream:nextFloat() * #list) % #list]
end

function Sim:_validSpawns(spec)
	local tags = {}
	for _, t in ipairs(spec.Tags or {}) do
		tags[t] = true
	end
	local players = self.PlayersFn and self.PlayersFn() or {}
	local out = {}
	for _, part in ipairs(self.Model.Spawns) do
		if part.Position and (next(tags) == nil or (part.Tag and tags[part.Tag])) then
			local enabled = part.Enabled == nil or truthy(self:_value(part.Enabled))
			if enabled then
				local ok = true
				if not part.IgnoreProximity and part.Range and part.Range > 0 then
					local minDist = part.Range * self.Params.ProximityStudsPerHop
					for _, pl in ipairs(players) do
						local d = math.sqrt((pl.X - part.Position.X) ^ 2 + (pl.Y - part.Position.Y) ^ 2 + (pl.Z - part.Position.Z) ^ 2)
						if d < minDist then
							ok = false
							break
						end
					end
				end
				if ok then
					out[#out + 1] = part
				end
			end
		end
	end
	return out
end

local function nearestPlayer(self, x, y, z)
	local best, bd
	for _, pl in ipairs(self.PlayersFn and self.PlayersFn() or {}) do
		local d = (pl.X - x) ^ 2 + (pl.Y - y) ^ 2 + (pl.Z - z) ^ 2
		if not bd or d < bd then
			best, bd = pl, d
		end
	end
	return best
end

function Sim:_make(key, spec, x, y, z, weaponClass, poolName)
	local attrs = { Class = weaponClass and weaponClass.Class or spec.EnemyType, Weapon = weaponClass and weaponClass.Weapon or nil, ServerTag = "Reinforcement" }
	if spec.CustomCombatData and next(spec.CustomCombatData) ~= nil then
		attrs.CustomCombatData = spec.CustomCombatData
	end
	local bot = self.Bots:spawnAt(x, y, z, attrs, spec.Name or "Reinforcement")
	if not bot then
		return nil
	end
	bot.Reinforcement = key
	local mine = self.Mine[key]
	if mine then
		mine[#mine + 1] = bot.Id
	end
	emit(self, "Spawned", { Spawner = spec.Name or key, Bot = bot.Id, Weapon = attrs.Weapon, Class = attrs.Class, X = x, Y = y, Z = z, Pool = poolName })
	local target = nearestPlayer(self, x, y, z)
	if target and self.InformFn then
		self.InformFn(bot.Id, target.Id)
	end
	return bot.Id
end

-- A custom spawn (a boss from the map's script): the spawner's class pairs and CustomCombatData, at a position of the caller's choosing.
function Sim:spawnNow(name, x, y, z, index)
	local key, spec = specKey(self, name)
	if not key then
		return nil
	end
	local wc = spec.Weapons[index or 1 + math.floor(self.Stream:nextFloat() * math.max(1, #spec.Weapons)) % math.max(1, #spec.Weapons)]
	return self:_make(key, spec, x, y, z, wc, spec.Pool)
end

function Sim:_poolState(pool)
	if pool.Remaining == nil then
		local limit = tonumber(self:_value(pool.Spec.Limit))
		pool.Remaining = limit and math.max(0, math.floor(limit)) or 0
		local rv = pool.Spec.RemainingVariable
		if not isBlank(rv) then
			self.Logic:set(rv, pool.Remaining)
		end
	end
end

function Sim:_poolAlive(poolName)
	local n = 0
	for _, e in ipairs(self.Order) do
		if e.Spec.Pool == poolName then
			n += self:alive(e.Key)
		end
	end
	return n
end

function Sim:_pools(dt)
	for _, name in ipairs(self:_poolNames()) do
		local pool = self.Pools[name]
		self:_poolState(pool)
		if pool.Remaining <= 0 then
			if pool.Reset == nil then
				emit(self, "PoolExhausted", { Pool = name })
				pool.Reset = false
			end
			if pool.Reset == false and self:_poolAlive(name) <= (pool.Spec.WaveResetThreshold or 0) then
				pool.Reset = pool.WaveTime
			end
			if type(pool.Reset) == "number" then
				pool.Reset -= dt
				if pool.Reset <= 0 then
					pool.Wave += 1
					pool.Reset = nil
					pool.Remaining = nil
					local dec, min = pool.Spec.WaveResetTimeDecrease or 0, pool.Spec.WaveResetTimeMinimum or 0
					pool.WaveTime = math.max(min, pool.WaveTime - dec)
					if not isBlank(pool.Spec.WaveVariable) then
						self.Logic:set(pool.Spec.WaveVariable, pool.Wave)
					end
					self:_poolState(pool)
					emit(self, "WaveStarted", { Pool = name, Wave = pool.Wave })
				end
			end
		end
	end
end

function Sim:_poolNames()
	local names = {}
	for name in pairs(self.Pools) do
		names[#names + 1] = name
	end
	table.sort(names)
	return names
end

function Sim:step(dt)
	self.Time += dt
	self:_pools(dt)
	local phase = self.PhaseFn and self.PhaseFn() or "Off"
	local phaseOk = not self.Params.RequirePhase or phase == "Off" or phase == "Attacking"
	for _, e in ipairs(self.Order) do
		local key, spec, st = e.Key, e.Spec, self.State[e.Key]
		local active = truthy(self:_value(spec.Active))
		local blocked = not isBlank(spec.BlockedVariable) and truthy(self:_variable(spec.BlockedVariable))
		if active and not blocked and phaseOk and self.Time >= st.Next then
			local cap = tonumber(self:_value(spec.SpawnCap)) or self.Params.DefaultSpawnCap
			if self:alive(key) < cap then
				local pool = spec.Pool and self.Pools[spec.Pool] or nil
				local poolOk = true
				if pool then
					self:_poolState(pool)
					local av = pool.Spec.ActiveVariable
					poolOk = pool.Remaining > 0 and (isBlank(av) or truthy(self:_variable(av)))
				end
				if poolOk then
					local parts = self:_validSpawns(spec)
					local part = pick(self, parts)
					if not part then
						emit(self, "SpawnSkipped", { Spawner = spec.Name or key, Why = "NoSpawnPart" })
						st.Next = self.Time + 1
					else
						local wc = pick(self, spec.Weapons)
						local id = self:_make(key, spec, part.Position.X, part.Position.Y, part.Position.Z, wc, spec.Pool)
						if id then
							st.Spawned += 1
							if pool then
								pool.Remaining -= 1
								if not isBlank(pool.Spec.RemainingVariable) then
									self.Logic:set(pool.Spec.RemainingVariable, pool.Remaining)
								end
							end
						end
						local gap = tonumber(self:_value(spec.TimeBetweenSpawns)) or self.Params.DefaultTimeBetweenSpawns
						st.Next = self.Time + math.max(0.05, gap)
					end
				end
			end
		end
	end
end

function Sim:summary()
	local rows = {}
	for _, e in ipairs(self.Order) do
		rows[#rows + 1] = { Spawner = e.Spec.Name or e.Key, Alive = self:alive(e.Key), Spawned = self.State[e.Key].Spawned }
	end
	return rows
end

return Spawner
