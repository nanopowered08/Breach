--!nonstrict
-- M9g (session integration) tests: a small REAL mission model (guard, combat spawner, pool, spawn part) through BreachSession with the combat layers.
-- Run via tests/run.luau or alone: `luau tests/session.luau`
local Session = require("../BreachSession")
local Mission = require("../BreachMission")
local Logic = require("../BreachLogic")
local Nav = require("../BreachNav")
local Bots = require("../BreachBots")
local Props = require("../BreachProps")
local Sight = require("../BreachSight")
local Trespass = require("../BreachTrespass")
local Alert = require("../BreachAlert")
local Combat = require("../BreachCombat")
local CombatData = require("../BreachCombatData")
local Explosives = require("../BreachExplosives")
local Spawner = require("../BreachSpawner")
local Hostage = require("../BreachHostage")
local Behavior = require("../BreachBehavior")
local Expr = require("../BreachExpr")

local function straight(a, b) return { { X = a.X, Y = a.Y or 0, Z = a.Z }, { X = b.X, Y = b.Y or 0, Z = b.Z } } end
local StubNav = { new = function() return Nav.new({ pathfinder = straight }) end, worldAdapter = function() return straight end }

local M = { Logic = Logic, Nav = StubNav, Bots = Bots, Props = Props, Sight = Sight, Trespass = Trespass, Alert = Alert, Combat = Combat,
	CombatData = CombatData, Explosives = Explosives, Spawner = Spawner, Hostage = Hostage, Behavior = Behavior, Expr = Expr }

return function(check)
	local function kinds(log, source, kind)
		local out = {}
		for _, e in ipairs(log) do if (source == nil or e.Source == source) and (kind == nil or e.Kind == kind) then out[#out + 1] = e end end
		return out
	end

	local function node(class, name, attrs, props, children)
		return { ClassName = class, Name = name, Attrs = attrs or {}, Props = props or {}, Children = children or {} }
	end
	local function part(name, x, z, attrs, eulerY)
		return node("Part", name, attrs, { CFrame = { Position = { X = x, Y = 0, Z = z }, EulerXYZ = { X = 0, Y = eulerY or 0, Z = 0 } }, Size = { X = 4, Y = 4, Z = 4 } })
	end

	-- the mission: one placed guard at x = -20 facing +X; a spawner that wakes when CombatPhase is 1; a pool of 4; one spawn part far away
	local function mission(weapons)
		local root = node("Folder", "DebugMission", {}, {}, {
			node("Folder", "Bots", {}, {}, { node("BoolValue", "Guard1", { Behavior = "PatrolWalk", Nodes = "Post1", PatrolCycleLength = 99999, Class = "SteelCoveBasic" }, { Value = false }) }),
			node("Folder", "Props", {}, {}, {}),
			node("Folder", "Nodes", {}, {}, { node("Folder", "Post1", {}, {}, { part("Node1", -20, 0, {}, -math.pi / 2) }) }),
			node("Folder", "LoudSpawns", {}, {}, { part("L1", 100, 0, { SpawnTag = "Loud", IgnoreProximity = true }) }),
			node("Folder", "StateComponents", {}, {}, {
				node("BoolValue", "Spawner1", { Type = "CombatSpawner", Active = "CombatPhase == 1", SpawnCap = 3, TimeBetweenSpawns = 1, EnemyWeapons = weapons or "S97:SteelCoveBasic", SpawnTags = "Loud", ReinforcementPool = "P1" }, { Value = false }),
				node("BoolValue", "Pool1", { Type = "ReinforcementPool", PoolName = "P1", PoolLimit = 4, RemainingVariable = "P1Left" }, { Value = false }),
			}),
		})
		return Mission.build({ Root = root, Setup = { Globals = { CombatPhase = 0, P1Left = 0 } }, MapId = 1, Warnings = {} }, {})
	end
	local function world()
		local cells = { { Index = 1, Node = { Name = "Public" } } }
		return { Cells = cells, Links = {}, cellAt = function() return cells[1] end }
	end
	local SETUP = { BreachLockdown = "TwoPhase", SoundTravelDistance = 80, Cells = { Public = {} } }

	local function session(weapons, opts)
		opts = opts or {}
		opts.seed = opts.seed or 7
		local S, why = Session.new(M, mission(weapons), world(), opts.setup or SETUP, opts)
		if S then S:addPlayer("p1", -10, 0, 0) end
		return S, why
	end

	do -- wiring
		local S, why = session(nil, { twoPhase = true })
		check("session: a mission with the combat layers builds", S ~= nil, why)
		check("session: the layers are exposed (Combat, Explosives, Spawner) and the combat phases are on", S.Combat ~= nil and S.Explosives ~= nil and S.Spawner ~= nil and S.Combat:phase() == "Calm")
		check("session: the combat data model reads the spawner, the pool and the spawn part", #S.CombatModel.Spawners == 1 and S.CombatModel.Pools.P1 ~= nil and #S.CombatModel.Spawns == 1)
		local off = session(nil, { setup = { SoundTravelDistance = 80, Cells = { Public = {} } } })
		check("session: a mission that does not ask for the phases has no spawner and the phase is Off (it runs unchanged)", off.Spawner == nil and off.Combat:phase() == "Off")
		local forced = session(nil, { spawners = true, setup = { SoundTravelDistance = 80, Cells = { Public = {} } } })
		check("session: opts.spawners = true turns the spawner on without the phases", forced.Spawner ~= nil)
	end

	do -- a lockdown, a weapon, reinforcements
		local S = session("S97:SteelCoveBasic", { twoPhase = true, combatParams = { PlayerMaxHealth = 100000 } })
		S:run(3)
		check("session: Calm, the spawner is asleep (CombatPhase is 0)", #S.Bots:all() == 1 and #kinds(S:drainLog(), "Spawner", "Spawned") == 0)
		S.Alert:lockdown("test")
		S.Props:setWeapon("p1", "drawn")
		S:run(2)
		check("session: the weapon is seen: Attacking", S.Combat:phase() == "Attacking")
		S.Logic:set("CombatPhase", 1)
		S:run(6)
		local log = S:drainLog()
		local spawned = kinds(log, "Spawner", "Spawned")
		check("session: with the map's variable on and the phase Attacking, reinforcements arrive (SpawnCap 3)", #spawned >= 2 and #S.Bots:all() >= 3, #spawned)
		check("session: they come from the spawn part with the weapon and class of the spawner", spawned[1] ~= nil and spawned[1].X == 100 and spawned[1].Class == "SteelCoveBasic" and spawned[1].Weapon == "S97")
		local id = spawned[1] and spawned[1].Bot
		local k = id and S.Combat:knows(id)
		check("session: a reinforcement is told where the player is and starts hunting", k ~= nil and k.Source == "Reinforcement" and #kinds(log, "Combat", "GuardMoves") > 0)
		S:run(40)
		check("session: the spawner stops at its cap (3 alive) and the pool counts what is left (4 - 3 = 1), also in RemainingVariable", S.Spawner:aliveOf("Spawner1") == 3 and S.Spawner:poolRemaining("P1") == 1 and S.Logic:get("P1Left") == 1, tostring(S.Spawner:poolRemaining("P1")))
		check("session: the reinforcements shoot (Combat events) and the player is hurt", #kinds(S:drainLog(), "Combat", "GuardFired") > 0)
	end

	do -- searching: no reinforcements; the guard's own phases
		local S = session("S97:SteelCoveBasic", { twoPhase = true })
		S.Logic:set("CombatPhase", 1)
		S.Alert:lockdown("test")
		S:run(8)
		check("session: in Searching reinforcements do not spawn even though the map's variable is on", S.Combat:phase() == "Searching" and #kinds(S:drainLog(), "Spawner", "Spawned") == 0)
	end

	do -- grenadier reinforcements throw and the explosions are in the log
		local S = session("K45:SteelCoveGrenadier", { twoPhase = true, combatParams = { PlayerMaxHealth = 100000 } })
		S.Alert:lockdown("test")
		S.Props:setWeapon("p1", "drawn")
		S:run(2)
		S.Logic:set("CombatPhase", 1)
		S:run(60)
		local log = S:drainLog()
		check("session: grenadier reinforcements throw grenades (Combat: GuardThrows)", #kinds(log, "Combat", "GuardThrows") >= 1, #kinds(log, "Combat", "GuardThrows"))
		check("session: ... the explosions are logged by the Explosives layer", #kinds(log, "Explosives", "Explosion") >= 1)
		check("session: ... and the player is hurt by them (PlayerHit from a grenade)", #kinds(log, "Combat", "PlayerHit") >= 1)
	end

	do -- determinism
		local function sig()
			local S = session("S97:SteelCoveBasic|K45:SteelCoveGrenadier", { twoPhase = true, seed = 21, combatParams = { PlayerMaxHealth = 100000 } })
			S.Alert:lockdown("test")
			S.Props:setWeapon("p1", "drawn")
			S:run(2)
			S.Logic:set("CombatPhase", 1)
			S:run(30)
			return S:signature()
		end
		local a, b = sig(), sig()
		check("session: two runs with the same seed have the same signature", a == b and #a > 100)
	end
end
