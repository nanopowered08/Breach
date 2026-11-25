--!nonstrict
-- M9f (spawners, pools, waves) tests: BreachSpawner. Run via tests/run.luau or alone: `luau tests/spawner.luau`
local Spawner = require("../BreachSpawner")
local Bots = require("../BreachBots")
local Nav = require("../BreachNav")
local Logic = require("../BreachLogic")

local DT = 0.1

return function(check)
	local function kinds(evs, kind) local out = {} for _, e in ipairs(evs) do if kind == nil or e.Kind == kind then out[#out + 1] = e end end return out end
	local function straight(a, b) return { { X = a.X, Y = a.Y or 0, Z = a.Z }, { X = b.X, Y = b.Y or 0, Z = b.Z } } end

	-- a world with no placed bots; variables as given; model as given
	local function build(model, globals, opts)
		opts = opts or {}
		local emptyBots = { Name = "Bots", ClassName = "Folder", Path = "DebugMission/Bots", Id = "f1", Attrs = {}, Children = {} }
		local emptyNodes = { Name = "Nodes", ClassName = "Folder", Path = "DebugMission/Nodes", Id = "f2", Attrs = {}, Children = {} }
		local m = { folder = function(_, n) if n == "Bots" then return emptyBots elseif n == "Nodes" then return emptyNodes end end, byComponent = function() return {} end }
		local l = Logic.fromSpec({ Globals = globals or {} }, {})
		local nav = Nav.new({ pathfinder = straight })
		local w = { Cells = { { Index = 1, Node = { Name = "Public" } } }, Links = {}, cellAt = function() return { Index = 1, Node = { Name = "Public" } } end }
		local bots = Bots.new(m, w, l, nav, { seed = 1 })
		local players = { { Id = "p1", X = 0, Y = 0, Z = 0 } }
		local phase = opts.phase or "Off"
		local informed = {}
		local W = { logic = l, bots = bots, players = players, informed = informed, phase = function() return phase end, setPhase = function(p) phase = p end }
		W.sp = Spawner.new({ logic = l, bots = bots, model = model, players = function() return players end, phase = W.phase,
			inform = function(botId, playerId) informed[#informed + 1] = { Bot = botId, Player = playerId } end }, { seed = opts.seed or 5, params = opts.params })
		W.run = function(seconds) for _ = 1, math.floor(seconds / DT + 0.5) do l:advance(DT) bots:step(DT) W.sp:step(DT) end end
		W.kill = function() for _, b in ipairs(bots:all()) do bots:setFlag(b.Id, "Dead", true) end end
		return W
	end
	local function spawner(over)
		local s = { Kind = "CombatSpawner", Name = "S1", Path = "DebugMission/StateComponents/S1", Active = true, SpawnCap = 2, TimeBetweenSpawns = 1, Weapons = { { Weapon = "S97", Class = "SteelCoveBasic" } }, Tags = { "Loud" } }
		for k, v in pairs(over or {}) do s[k] = v end
		return s
	end
	local PART = { Kind = "Loud", Name = "L1", Position = { X = 100, Y = 0, Z = 0 }, Tag = "Loud", IgnoreProximity = true }
	local function model(spawners, pools, spawns) return { Spawners = spawners or { spawner() }, Pools = pools or {}, Spawns = spawns or { PART } } end

	do -- active, cap, time between
		local W = build(model({ spawner({ Active = "Go == 1", SpawnCap = 2, TimeBetweenSpawns = 1 }) }), { Go = 0 })
		W.run(5)
		check("spawner: nothing spawns while Active is false", #W.bots:all() == 0)
		W.logic:set("Go", 1)
		W.run(0.5)
		check("spawner: it spawns as soon as Active turns true", #W.bots:all() == 1)
		W.run(1.0)
		check("spawner: one guard per TimeBetweenSpawns", #W.bots:all() == 2, #W.bots:all())
		W.run(8)
		check("spawner: it stops at SpawnCap alive", #W.bots:all() == 2 and W.sp:aliveOf("S1") == 2)
		local evs = W.sp:drainEvents()
		check("spawner: every spawn is reported with the spawner, weapon, class and position", #kinds(evs, "Spawned") == 2 and kinds(evs, "Spawned")[1].Class == "SteelCoveBasic" and kinds(evs, "Spawned")[1].Weapon == "S97" and kinds(evs, "Spawned")[1].X == 100)
		local b = W.bots:all()[1]
		local x, y, z = W.bots:position(b.Id)
		check("spawner: the guard stands at the spawn part and carries its class and weapon", x == 100 and b.Class == "SteelCoveBasic" and b.Weapon == "S97" and b.Reinforcement ~= nil)
		W.kill()
		W.run(1.5)
		check("spawner: dead guards do not count: it refills up to the cap", W.sp:aliveOf("S1") >= 1 and #W.bots:all() > 2)
	end

	do -- blocked variable, expressions for cap and gap
		local W = build(model({ spawner({ SpawnCap = "Cap", TimeBetweenSpawns = "Gap", BlockedVariable = "Blocked" }) }), { Cap = 1, Gap = 2, Blocked = 1 })
		W.run(5)
		check("spawner: SpawnsBlockedVariable stops it", #W.bots:all() == 0)
		W.logic:set("Blocked", 0)
		W.run(0.5)
		W.logic:set("Cap", 3)
		W.run(2.1)
		check("spawner: SpawnCap is an expression read each time", #W.bots:all() == 2, #W.bots:all())
		W.run(4.2)
		check("spawner: ... and so is TimeBetweenSpawns (2 s apart: 3 by 6 s)", #W.bots:all() == 3, #W.bots:all())
	end

	do -- phases
		local W = build(model(), nil, { phase = "Searching" })
		W.run(5)
		check("spawner: in Searching reinforcements do not spawn", #W.bots:all() == 0)
		W.setPhase("Attacking")
		W.run(1.2)
		check("spawner: ... they start when Attacking begins", #W.bots:all() >= 1)
		local W2 = build(model(), nil, { phase = "Calm" })
		W2.run(3)
		check("spawner: in Calm they do not spawn either", #W2.bots:all() == 0)
		local W3 = build(model(), nil, { phase = "Off" })
		W3.run(1.2)
		check("spawner: with the combat phases off (the classic lockdown) the map's own variables decide", #W3.bots:all() >= 1)
		local W4 = build(model(), nil, { phase = "Searching", params = { RequirePhase = false } })
		W4.run(1.2)
		check("spawner: RequirePhase = false spawns in any phase", #W4.bots:all() >= 1)
	end

	do -- pools and waves
		local pool = { Name = "PoolA", Limit = 3, RemainingVariable = "ARemaining", WaveVariable = "AWave", WaveResetTime = 5, WaveResetTimeDecrease = 2, WaveResetTimeMinimum = 1 }
		local W = build(model({ spawner({ Pool = "PoolA", SpawnCap = 10, TimeBetweenSpawns = 0.5 }) }, { pool }), { ARemaining = 0, AWave = 0 })
		W.run(10)
		check("pool: it gives only Limit (3) guards", #W.bots:all() == 3 and W.sp:poolRemaining("PoolA") == 0)
		check("pool: RemainingVariable follows the count down to 0", W.logic:get("ARemaining") == 0)
		check("pool: PoolExhausted is reported once", #kinds(W.sp:drainEvents(), "PoolExhausted") == 1)
		W.run(10)
		check("pool: no new wave while its guards are still alive", #W.bots:all() == 3 and W.logic:get("AWave") == 0)
		W.kill()
		W.run(4.0)
		check("pool: ... the next wave waits WaveResetTime (5 s) after they are dead", #W.bots:all() == 3)
		W.run(2.0)
		local evs = W.sp:drainEvents()
		check("pool: wave 2 starts: WaveStarted, WaveVariable = 2, 3 more guards", #kinds(evs, "WaveStarted") == 1 and kinds(evs, "WaveStarted")[1].Wave == 2 and W.logic:get("AWave") == 2)
		W.run(6)
		check("pool: ... the pool gave 3 more", #W.bots:all() == 6, #W.bots:all())
		W.kill()
		W.run(3.5)
		check("pool: the wave time shrank by WaveResetTimeDecrease (5 - 2 = 3 s)", W.logic:get("AWave") == 3, W.logic:get("AWave"))
		local W2 = build(model({ spawner({ Pool = "PoolB", SpawnCap = 10 }) }, { { Name = "PoolB", Limit = 5, ActiveVariable = "BOn" } }), { BOn = 0 })
		W2.run(4)
		check("pool: ActiveVariable false: it gives nothing", #W2.bots:all() == 0)
		W2.logic:set("BOn", 1)
		W2.run(1.2)
		check("pool: ... true: it gives", #W2.bots:all() >= 1)
	end

	do -- spawn parts
		local parts = {
			{ Kind = "Loud", Name = "Far", Position = { X = 100, Y = 0, Z = 0 }, Tag = "Loud", Range = 3 },
			{ Kind = "Loud", Name = "Near", Position = { X = 10, Y = 0, Z = 0 }, Tag = "Loud", Range = 3 },
			{ Kind = "Loud", Name = "NearIgnore", Position = { X = 20, Y = 0, Z = 0 }, Tag = "Loud", Range = 3, IgnoreProximity = true },
			{ Kind = "Loud", Name = "OtherTag", Position = { X = 200, Y = 0, Z = 0 }, Tag = "Quiet" },
			{ Kind = "Loud", Name = "Off", Position = { X = 300, Y = 0, Z = 0 }, Tag = "Loud", Enabled = "Gate == 1", IgnoreProximity = true },
		}
		local W = build(model({ spawner({ SpawnCap = 50, TimeBetweenSpawns = 0.2 }) }, nil, parts), { Gate = 0 })
		W.run(10)
		local xs = {}
		for _, e in ipairs(kinds(W.sp:drainEvents(), "Spawned")) do xs[e.X] = true end
		check("parts: the right tag, enabled, and not too close to a player (Range 3 x 20 = 60 studs unless IgnoreProximity)", xs[100] and xs[20] and not xs[10] and not xs[200] and not xs[300])
		W.logic:set("Gate", 1)
		W.run(10)
		local xs2 = {}
		for _, e in ipairs(kinds(W.sp:drainEvents(), "Spawned")) do xs2[e.X] = true end
		check("parts: Enabled is an expression: turned on, the part is used", xs2[300] == true)
		local W2 = build(model({ spawner() }, nil, { { Kind = "Loud", Name = "Close", Position = { X = 5, Y = 0, Z = 0 }, Tag = "Loud", Range = 2 } }))
		W2.run(3)
		local ev = W2.sp:drainEvents()
		check("parts: no valid part: nothing spawns and it says why", #W2.bots:all() == 0 and #kinds(ev, "SpawnSkipped") >= 1 and kinds(ev, "SpawnSkipped")[1].Why == "NoSpawnPart")
		W2.players[1].X = 500
		W2.run(1.5)
		check("parts: once the player has moved away it spawns", #W2.bots:all() >= 1)
	end

	do -- class draw, informing, custom spawns, determinism
		local pairsList = { { Weapon = "K45", Class = "SteelCoveGrenadier" }, { Weapon = "K45", Class = "SteelCoveGrenadier" }, { Weapon = "S97", Class = "SteelCoveBasic" } }
		local W = build(model({ spawner({ Weapons = pairsList, SpawnCap = 1000, TimeBetweenSpawns = 0.1 }) }))
		W.run(30)
		local a, b = 0, 0
		for _, e in ipairs(kinds(W.sp:drainEvents(), "Spawned")) do if e.Class == "SteelCoveGrenadier" then a += 1 else b += 1 end end
		check("draw: duplicates weight the draw (2 grenadier entries to 1 basic)", a > b * 1.4 and a < b * 3.2 and a + b >= 100, a .. " vs " .. b)
		check("inform: every spawned guard is told about the nearest player", #W.informed == a + b and W.informed[1].Player == "p1")
		local W2 = build(model({ spawner({ CustomCombatData = { HasGrenades = true }, Weapons = { { Weapon = "F57", Class = "SteelCoveHeavy" }, { Weapon = "S97", Class = "SteelCoveBasic" } } }) }))
		local id = W2.sp:spawnNow("S1", 7, 0, 8, 1)
		local bot = W2.bots:bot(id)
		local x, y, z = W2.bots:position(id)
		check("custom spawn: spawnNow makes a guard of the given class pair at the given place", bot ~= nil and bot.Class == "SteelCoveHeavy" and bot.Weapon == "F57" and x == 7 and z == 8)
		check("custom spawn: it carries the spawner's CustomCombatData and is informed", bot.Attrs.CustomCombatData ~= nil and bot.Attrs.CustomCombatData.HasGrenades == true and #W2.informed == 1)
		check("custom spawn: an unknown spawner gives nil", W2.sp:spawnNow("Nope", 0, 0, 0) == nil)
		local function trace()
			local Wd = build(model({ spawner({ Weapons = pairsList, SpawnCap = 6, TimeBetweenSpawns = 0.3 }) }, nil, { PART, { Kind = "Loud", Name = "L2", Position = { X = 150, Y = 0, Z = 5 }, Tag = "Loud", IgnoreProximity = true } }), nil, { seed = 9 })
			Wd.run(10)
			local t = {}
			for _, e in ipairs(kinds(Wd.sp:drainEvents(), "Spawned")) do t[#t + 1] = e.Class .. "@" .. e.X .. "@" .. string.format("%.2f", e.Time) end
			return table.concat(t, "|")
		end
		check("spawner: the same seed gives the same spawns", trace() == trace() and trace() ~= "")
		check("spawner: summary lists each spawner", #W.sp:summary() == 1 and W.sp:summary()[1].Spawner == "S1")
	end

	do -- the real model keys pools by name
		local W = build(model({ spawner({ Pool = "PoolK", SpawnCap = 10 }) }, { PoolK = { Name = "PoolK", Limit = 2 } }))
		W.run(8)
		check("pool: a model with pools keyed by name (the CombatData form) limits the spawner", #W.bots:all() == 2 and W.sp:poolRemaining("PoolK") == 0)
	end

	do -- only combat spawners are driven
		local W = build(model({ spawner({ Kind = "SniperSpawner", Name = "Snipe" }), spawner({ Name = "Real" }) }))
		W.run(2)
		check("spawner: sniper and cover-fill spawners are not driven yet", W.sp:aliveOf("Snipe") == 0 and W.sp:aliveOf("Real") >= 1)
	end
end
