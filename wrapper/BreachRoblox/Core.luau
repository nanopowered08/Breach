--!nonstrict
--[==[
	BreachRoblox.Core — the host-agnostic half of the Roblox adapter (adapter v0.1).

	No Roblox APIs and no requires here, so it runs (and is tested) under the plain Luau CLI. It connects a BreachSession to a `host`:
	anything that can show bots and report players. RobloxHost.luau is the host that uses Instances; tests use a recording fake.

	    local session, info = Core.loadMission(M, missionCode, { seed = 416 })     -- M = the engine modules (see Init.luau); nil, "decode: ..." on failure
	    local adapter = Core.new(session, host, { maxDt = 0.1 })
	    adapter:syncPlayers(host:getPlayers())      -- every frame: { {Id, X, Y, Z, Stance}, ... }; joins, moves, leaves are worked out
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
	})
	if not session then return nil, "session: " .. tostring(why) end
	return session, { Mission = mission, Setup = setup, World = world, MapId = decoded.MapId, Decoded = decoded }
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
		if p.Disguise ~= nil then S:setDisguise(p.Id, p.Disguise) end
	end
	for id in pairs(self.PlayerIds) do
		if not seen[id] then
			self:removePlayer(id)
		end
	end
end

-- The engine has no "remove player" yet (M9 will need one). A player who left is marked as having exited, so nobody sees or counts them.
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
