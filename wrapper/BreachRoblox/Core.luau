--!nonstrict
--[==[
	BreachRoblox.Core — the host-agnostic half of the Roblox adapter (adapter v0.1).

	No Roblox APIs and no requires here, so it runs (and is tested) under the plain Luau CLI. It connects a BreachSession to a `host`:
	anything that can show bots and report players. RobloxHost.luau is the host that uses Instances; tests use a recording fake.

	    local session, info = Core.loadMission(M, missionCode, { seed = 416 })     -- M = the engine modules (see Init.luau); nil, "decode: ..." on failure
	    local adapter = Core.new(session, host, { maxDt = 0.1 })
	    adapter:syncPlayers(host:getPlayers())      -- every frame: { {Id, X, Y, Z, Stance, Armed, Weapon, HealthFraction}, ... }; joins, moves, leaves are worked out
	    adapter:step(dt)                            -- every frame: steps the session, then shows the result through the host

	The host may implement any of these methods (all optional; they are called as host:name(...)):
	    host:createBot(info)                  info = {Id, Name, Class, Outfit, Weapon, Profile, State, X, Y, Z}
	    host:updateBot(id, x, y, z, fx, fz, state, bot)
	    host:removeBot(id)
	    host:alertChanged(level, before)      Mission_AlertLevel 0..3
	    host:event(ev)                        every event the session logged, in order
]==]

local Core = {}
Core.VERSION = "0.1.0"
Core.Defaults = {
	maxDt = 0.1, -- a long frame (a hitch, a breakpoint) is cut to this, so the simulation never lurches
	seed = 416,
	difficulty = 3,
}

-- Which seed a run uses [R: owner, Nov 2026]. In order: (1) the Workspace attribute "BreachSeed", (2) the `Seed` option of Adapter.start, (3) a fresh
-- random seed (`randomFn()`), like the real game, which draws one per mission. The attribute and the option are a non-negative whole number (or a
-- numeric string) below 2^32; anything else is ignored and reported as the third result so the host can warn. Returns seed, source, ignoredValue.
function Core.resolveSeed(attr, optionSeed, randomFn)
	local function asSeed(v)
		if type(v) == "string" then v = tonumber(v) end
		if type(v) == "number" and v == v and v >= 0 and v < 4294967296 and v == math.floor(v) then
			return v
		end
		return nil
	end
	local a = asSeed(attr)
	if a then
		return a, "BreachSeed"
	end
	local ignored = (attr ~= nil) and attr or nil
	local o = asSeed(optionSeed)
	if o then
		return o, "Seed option", ignored
	end
	return randomFn(), "random", ignored
end

local Adapter = {}
Adapter.__index = Adapter

---------------------------------------------------------------------------------------------------------- loading
-- Decode a mission code and build everything a session needs. Returns session, info  or  nil, "stage: message".
-- M must hold: Codec, Zstd, Mission, Validator, World, Setup, Session, and the nine session layers (Logic, Nav, Bots, Props, Sight, Trespass, Alert, Hostage, Behavior).
function Core.loadMission(M, code, opts)
	opts = opts or {}
	if type(code) ~= "string" or code == "" then
		return nil, "decode: the mission code is empty"
	end
	local function stage(name, fn, ...)
		local ok, a, b = pcall(fn, ...)
		if not ok then return nil, name .. ": " .. tostring(a) end
		if a == nil then return nil, name .. ": " .. tostring(b or "returned nothing") end
		return a, b
	end
	local decoded, err = stage("decode", M.Codec.decode, code, { zstdDecompress = M.Zstd and M.Zstd.decompress })
	if not decoded then return nil, err end
	local mission
	mission, err = stage("build", M.Mission.build, decoded, { validator = M.Validator })
	if not mission then return nil, err end
	local setup, setupErr = M.Setup.parse(decoded.SetupSource or "")
	if not setup then return nil, "setup: " .. tostring(setupErr) end
	local world
	world, err = stage("world", M.World.build, mission)
	if not world then return nil, err end
	local session, why = M.Session.new(M, mission, world, setup, {
		seed = opts.seed or Core.Defaults.seed, difficulty = opts.difficulty or Core.Defaults.difficulty,
		botParams = opts.botParams, alertParams = opts.alertParams, hostageParams = opts.hostageParams, behaviorParams = opts.behaviorParams,
		twoPhase = opts.twoPhase, combatParams = opts.combatParams,
	})
	if not session then return nil, "session: " .. tostring(why) end
	return session, { Mission = mission, Setup = setup, World = world, MapId = decoded.MapId, Decoded = decoded }
end

---------------------------------------------------------------------------------------------------------- props and doors
-- A mission does not contain the geometry of its props and doors. Its `Props` folder holds one placeholder Part per prop: the Name is the prop's
-- name in the prop library (Templates/Props.rbxm of the missions repo), the CFrame and Size say where, and the Attributes configure it.
-- A library model has a part called `Base` whose Size equals the placeholder's Size [O: SlidingBlastDoor 10.4 x 7.4 x 0.9], so the model is
-- placed with its Base on the placeholder. `DoubleDoor = true` doors are twice the width of one library door: two leaves [P: mirrored].
-- Names that are not in the library are logic markers (ItemSpawn, triggers, nodes ...) or props only the game has; they are counted, not drawn.
--
-- Scalable props have NO model in the library: the game scripts them to resize to their placeholder [O: HANDOFF]. BreachEngine draws each as one plain
-- Part the size of its placeholder, styled by Core.ScalableProps [P: the looks are guesses; Color0/Material0 tinting is not applied yet]. They are
-- returned as a fourth list, with the same fields as a placement, and are not counted as skipped.
--
--   local placements, skipped, total, scalables = Core.propPlacements(mission, function(name) return library[name] ~= nil end)
--   placement = { Name, Path, X, Y, Z, Rx, Ry, Rz (radians, XYZ order), SizeX, SizeY, SizeZ, Leaves = 1 | 2 }
Core.ScalableProps = {
	GarageDoor = { Color = { 0.60, 0.62, 0.64 }, Material = "Metal", Transparency = 0, Collide = true }, -- shown closed, like the other doors
	Window = { Color = { 0.66, 0.80, 0.90 }, Material = "Glass", Transparency = 0.6, Collide = true },
	Ladder = { Color = { 0.45, 0.45, 0.48 }, Material = "Metal", Transparency = 0, Collide = false }, -- not climbable yet: nothing to bump into
	ClimbablePipe = { Color = { 0.50, 0.52, 0.55 }, Material = "Metal", Transparency = 0, Collide = true },
	DecorativePipe = { Color = { 0.50, 0.52, 0.55 }, Material = "Metal", Transparency = 0, Collide = true },
	DecorativeVent = { Color = { 0.62, 0.64, 0.66 }, Material = "Metal", Transparency = 0, Collide = true },
	ScalablePlanter = { Color = { 0.36, 0.26, 0.18 }, Material = "Slate", Transparency = 0, Collide = true },
	ScalableWallPlanter = { Color = { 0.36, 0.26, 0.18 }, Material = "Slate", Transparency = 0, Collide = true },
	ThinBush = { Color = { 0.22, 0.45, 0.20 }, Material = "Grass", Transparency = 0, Collide = false },
}

function Core.propPlacements(mission, hasModel)
	local placements, skipped, total, scalables = {}, {}, 0, {}
	local root = mission and mission:folder("Props")
	local function walk(node)
		local props = node.Props
		if node.ClassName == "Part" and props and props.CFrame and props.CFrame.Position and props.Size then
			total += 1
			local modelled, scalable = hasModel(node.Name), Core.ScalableProps[node.Name] ~= nil
			if modelled or scalable then
				local cf, size = props.CFrame, props.Size
				local e = cf.EulerXYZ or { X = 0, Y = 0, Z = 0 }
				local p = {
					Name = node.Name, Path = node.Path,
					X = cf.Position.X, Y = cf.Position.Y, Z = cf.Position.Z, Rx = e.X, Ry = e.Y, Rz = e.Z,
					SizeX = size.X, SizeY = size.Y, SizeZ = size.Z,
					Leaves = (node.Attrs and node.Attrs.DoubleDoor == true) and 2 or 1,
				}
				if modelled then -- a library model wins over the plain part
					placements[#placements + 1] = p
				else
					p.Leaves = 1
					scalables[#scalables + 1] = p
				end
			else
				skipped[node.Name] = (skipped[node.Name] or 0) + 1
			end
		end
		for _, child in ipairs(node.Children or {}) do walk(child) end
	end
	if root then walk(root) end
	return placements, skipped, total, scalables
end

---------------------------------------------------------------------------------------------------------- the adapter
function Core.new(session, host, opts)
	opts = opts or {}
	local self = setmetatable({
		Session = session, Host = host or {}, MaxDt = opts.maxDt or Core.Defaults.maxDt,
		Rigs = {}, -- bot id -> true, the bots the host currently shows
		PlayerIds = {}, -- player id -> true, the players the session knows from this adapter
		Alert = nil, Frames = 0, Events = 0, Time = 0,
	}, Adapter)
	return self
end

local function call(host, name, ...)
	local fn = host[name]
	if fn then
		return fn(host, ...)
	end
end

function Adapter:syncPlayers(list)
	local S = self.Session
	local seen = {}
	for _, p in ipairs(list or {}) do
		seen[p.Id] = true
		if not self.PlayerIds[p.Id] then
			S:addPlayer(p.Id, p.X, p.Y, p.Z)
			self.PlayerIds[p.Id] = true
		else
			S:movePlayer(p.Id, p.X, p.Y, p.Z)
		end
		if p.Stance then S.Props:setStance(p.Id, p.Stance) end
		if p.Weapon then S.Props:setWeapon(p.Id, p.Weapon) elseif p.Armed ~= nil then S.Props:setArmed(p.Id, p.Armed) end
		if p.HealthFraction ~= nil and S.Combat then S.Combat:setPlayerHealth(p.Id, p.HealthFraction * S.Combat.Params.PlayerMaxHealth) end
		if p.Disguise ~= nil then S:setDisguise(p.Id, p.Disguise) end
	end
	for id in pairs(self.PlayerIds) do
		if not seen[id] then
			self:removePlayer(id)
		end
	end
end

-- The engine has no "remove player" yet (M9 will need one). A player who left is marked as having exited, so nobody sees or counts them.
-- The player's own round hit a guard (called by the game's weapon script): the weapon's damage (S97 by default) goes to BreachCombat, which
-- lowers the guard's health and kills it at 0. `botId` is the BotId attribute of the guard's model. Returns the guard's health left, or nil.
function Adapter:hitBot(botId, playerId, weapon)
	local combat = self.Session.Combat
	if not combat then
		return nil
	end
	local damage = combat:weaponDamage(weapon or "S97")
	if not damage then
		return nil
	end
	return combat:damageBot(botId, damage, tostring(playerId))
end

function Adapter:removePlayer(id)
	local p = self.Session.Props and self.Session.Props:player(id)
	if p then p.Exited = true end
	self.PlayerIds[id] = nil
end

function Adapter:step(dt)
	local S, host = self.Session, self.Host
	dt = math.min(math.max(dt or 0, 0), self.MaxDt)
	S:step(dt)
	self.Time += dt
	self.Frames += 1

	for _, ev in ipairs(S:drainLog()) do
		self.Events += 1
		call(host, "event", ev)
	end

	-- bots: show new ones, move all, remove the gone
	local alive, present = S.Bots:alive(), {}
	for _, bot in ipairs(alive) do
		local id = bot.Id
		present[id] = true
		local x, y, z = S.Bots:position(id)
		if x then
			local fx, fz = S.Bots:facing(bot)
			if not self.Rigs[id] then
				self.Rigs[id] = true
				call(host, "createBot", { Id = id, Name = bot.Name, Class = bot.Class, Outfit = bot.Outfit, Weapon = bot.Weapon, Profile = bot.Profile, State = bot.State, X = x, Y = y, Z = z })
			end
			call(host, "updateBot", id, x, y, z, fx, fz, bot.State, bot)
		end
	end
	for id in pairs(self.Rigs) do
		if not present[id] then
			self.Rigs[id] = nil
			call(host, "removeBot", id)
		end
	end

	-- alert level
	local level = S.Logic:get("Mission_AlertLevel")
	if type(level) == "number" and level ~= self.Alert then
		local before = self.Alert
		self.Alert = level
		call(host, "alertChanged", level, before)
	end
end

function Adapter:stats()
	local bots, players = 0, 0
	for _ in pairs(self.Rigs) do bots += 1 end
	for _ in pairs(self.PlayerIds) do players += 1 end
	return { Time = self.Time, Frames = self.Frames, Events = self.Events, Bots = bots, Players = players, Alert = self.Alert }
end

return Core
