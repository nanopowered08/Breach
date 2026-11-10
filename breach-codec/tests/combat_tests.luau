--!nonstrict
-- M9a (lockdown phases, awareness) tests: BreachCombat. Run via tests/run.luau or alone: `luau tests/combat.luau`
local Combat = require("../BreachCombat")
local Alert = require("../BreachAlert")
local Trespass = require("../BreachTrespass")
local Sight = require("../BreachSight")
local Bots = require("../BreachBots")
local Nav = require("../BreachNav")
local Logic = require("../BreachLogic")
local Props = require("../BreachProps")

local DT = 1 / 20

return function(check)
	local function kinds(evs, kind) local out = {} for _, e in ipairs(evs) do if kind == nil or e.Kind == kind then out[#out + 1] = e end end return out end

	local counter = 0
	local function part(name, x, y, z, attrs, eulerY)
		counter += 1
		return { Name = name, ClassName = "Part", Path = "DebugMission/Nodes/" .. name .. counter, Id = "p" .. counter, Attrs = attrs or {}, Children = {},
			Props = { CFrame = { Position = { X = x, Y = y, Z = z }, EulerXYZ = { X = 0, Y = eulerY or 0, Z = 0 } }, Size = { X = 4, Y = 4, Z = 4 } } }
	end
	local function folder(name, children) counter += 1 return { Name = name, ClassName = "Folder", Path = "DebugMission/" .. name .. counter, Id = "f" .. counter, Attrs = {}, Children = children or {} } end
	local function botNode(name, attrs) counter += 1 return { Name = name, ClassName = "BoolValue", Path = "DebugMission/Bots/" .. name, Id = "b" .. counter, Attrs = attrs or {}, Children = {} } end
	local FACE_PLUS_X = -math.pi / 2
	local function liveWorld()
		local cells = { { Index = 1, Node = { Name = "Public" } } }
		return { Cells = cells, Links = {}, cellAt = function() return cells[1] end }
	end
	local function straight(a, b) return { { X = a.X, Y = a.Y or 0, Z = a.Z }, { X = b.X, Y = b.Y or 0, Z = b.Z } } end

	-- botDefs: { X, Z } (all guards of class Sec, facing +X, public space). opts: { enabled, setup, params }
	local function live(botDefs, opts)
		opts = opts or {}
		local list, routes = {}, {}
		for i, d in ipairs(botDefs) do
			local rname = "Post" .. i
			list[#list + 1] = botNode("bot" .. i, { Behavior = "PatrolWalk", Nodes = rname, PatrolCycleLength = 99999, Class = "Sec" })
			local nodeParts = {}
			for j, n in ipairs(d.Route or { { X = d.X, Z = d.Z } }) do nodeParts[#nodeParts + 1] = part("Node" .. j, n.X, 0, n.Z or 0, {}, FACE_PLUS_X) end
			routes[#routes + 1] = folder(rname, nodeParts)
		end
		local botsF, nodesF = folder("Bots", list), folder("Nodes", routes)
		local m = { folder = function(_, n) if n == "Bots" then return botsF elseif n == "Nodes" then return nodesF end end, byComponent = function() return {} end }
		local l = Logic.fromSpec({ Globals = {} }, {})
		local nav = Nav.new({ pathfinder = straight })
		local w = liveWorld()
		local bots = Bots.new(m, w, l, nav, { seed = 1 })
		local pr = Props.fromNodes({}, w, l)
		pr:addPlayer("p1", -10, 0, 0)
		local players = Sight.propsPlayers(pr)
		local sight = Sight.new(w, bots, players)
		local tr = Trespass.new(w, { Cells = { Public = {} } }, l)
		tr:attach(sight, bots, players)
		local al = Alert.new(l, { mission = m, bots = bots, sight = sight, trespass = tr, players = players, world = w })
		local combat = Combat.new({ bots = bots, sight = sight, alert = al, players = players, setup = opts.setup, classInfo = opts.classInfo }, { enabled = opts.enabled ~= false, params = opts.params, seed = opts.seed })
		local function run(seconds) for _ = 1, math.floor(seconds / DT + 0.5) do l:advance(DT) bots:step(DT) sight:step(DT) tr:step(DT) al:step(DT) combat:step(DT) end end
		return combat, al, bots, pr, run
	end
	local function botId(bots, i) return bots:all()[i].Id end

	do -- off by default
		local combat, al, bots, pr, run = live({ { X = -20 } }, { enabled = false })
		pr:setWeapon("p1", "drawn")
		run(4)
		check("combat: not opted in: the phase is Off", combat:phase() == "Off")
		check("combat: not opted in: a drawn weapon in plain view changes nothing (no events, no alert)", #combat:drainEvents() == 0 and al:level() == 0 and combat:knows(botId(bots, 1)) == nil)
		check("combat: not opted in: a noise is ignored", combat:noise("shot", 0, 0, 0, "p1") == 0)
	end

	do -- the opt-in key in the mission setup
		local combat = live({ { X = -20 } }, { enabled = false, setup = { BreachLockdown = "TwoPhase" } })
		check("combat: MissionSetup.BreachLockdown = \"TwoPhase\" turns it on", combat:phase() == "Calm")
		local off = live({ { X = -20 } }, { enabled = false, setup = { BreachLockdown = "OnePhase" } })
		check("combat: any other value leaves it off", off:phase() == "Off")
	end

	do -- a holstered or concealed weapon is not seen
		local combat, al, bots, pr, run = live({ { X = -20 } })
		check("combat: opted in it starts Calm", combat:phase() == "Calm")
		run(4)
		check("combat: a holstered weapon in plain view stays Calm", combat:phase() == "Calm" and #kinds(combat:drainEvents(), "WeaponSeen") == 0)
		check("combat: setWeapon rejects an unknown state", pr:setWeapon("p1", "bazooka") == false and pr:setWeapon("nobody", "drawn") == false)
		check("combat: concealed is not armed", pr:setWeapon("p1", "concealed") == true and Sight.propsPlayers(pr)()[1].Armed == false and Sight.propsPlayers(pr)()[1].Weapon == "concealed")
		run(4)
		check("combat: a concealed weapon is not detected yet [P]", combat:phase() == "Calm")
	end

	do -- a drawn weapon is seen: Attacking, the guard flees and radios, the lockdown lands with its call
		local combat, al, bots, pr, run = live({ { X = -20 } })
		pr:setWeapon("p1", "drawn")
		run(2)
		local evs = combat:drainEvents()
		check("combat: a drawn weapon in view is seen once", #kinds(evs, "WeaponSeen") == 1 and kinds(evs, "WeaponSeen")[1].Player == "p1")
		check("combat: ... the phase goes straight to Attacking", combat:phase() == "Attacking" and kinds(evs, "PhaseChanged")[1].Phase == "Attacking" and kinds(evs, "PhaseChanged")[1].Why == "WeaponSeen")
		local k = combat:knows(botId(bots, 1))
		check("combat: ... and the guard knows where the player is", k ~= nil and k.Player == "p1" and k.Source == "Sight" and math.abs(k.X - -10) < 1e-6)
		local aev = al:drainEvents()
		check("combat: ... it radios while it flees (BotRadioStarted), no lockdown yet", #kinds(aev, "BotRadioStarted") == 1 and kinds(aev, "BotRadioStarted")[1].Why == "WeaponSeen" and al:level() == 0)
		run(5)
		check("combat: ... the lockdown lands with the call", al:level() == 3)
		check("combat: ... and the phase stays Attacking", combat:phase() == "Attacking")
	end

	do -- Alert:fleeAndRadio refuses what it cannot do
		local combat, al, bots, pr, run = live({ { X = -20 } })
		check("combat: fleeAndRadio: an unknown player is refused", al:fleeAndRadio(botId(bots, 1), "nobody", "x") == false)
		check("combat: fleeAndRadio: a guard accepts once", al:fleeAndRadio(botId(bots, 1), "p1", "x") == true)
		check("combat: fleeAndRadio: ... and not again while it is already on the run", al:fleeAndRadio(botId(bots, 1), "p1", "x") == false)
		local c2, a2, b2 = live({ { X = -20 } })
		b2:setFlag(botId(b2, 1), "Dead", true)
		check("combat: fleeAndRadio: a dead guard is refused", a2:fleeAndRadio(botId(b2, 1), "p1", "x") == false)
	end

	do -- out of range, or a dead guard: nothing seen
		local combat, al, bots, pr, run = live({ { X = -20 } })
		pr:move("p1", -140, 0, 0)
		pr:setWeapon("p1", "drawn")
		run(3)
		check("combat: a drawn weapon out of view range is not seen", combat:phase() == "Calm" and #kinds(combat:drainEvents(), "WeaponSeen") == 0)
		local c2, a2, b2, p2, r2 = live({ { X = -20 } })
		b2:setFlag(botId(b2, 1), "Dead", true)
		p2:setWeapon("p1", "drawn")
		r2(3)
		check("combat: a dead guard sees nothing", c2:phase() == "Calm")
	end

	do -- Searching: lockdown without a weapon seen, guards never know the player
		local combat, al, bots, pr, run = live({ { X = -20 } })
		al:lockdown("test")
		run(0.2)
		check("combat: lockdown with nobody armed: Searching", combat:phase() == "Searching" and kinds(combat:drainEvents(), "PhaseChanged")[1].Why == "Lockdown")
		check("combat: Searching: a noise is heard but does not tell the guard where the player is", combat:noise("shot", -10, 0, 0, "p1") == 1 and combat:knows(botId(bots, 1)) == nil)
		check("combat: ... the event says it was not aware", kinds(combat:drainEvents(), "NoiseHeard")[1].Aware == false)
		pr:setWeapon("p1", "drawn")
		run(2)
		check("combat: Searching: a drawn weapon seen makes it Attacking", combat:phase() == "Attacking" and combat:knows(botId(bots, 1)) ~= nil)
		check("combat: ... at lockdown the guard does not flee and radio again", #kinds(al:drainEvents(), "BotRadioStarted") == 0)
	end

	do -- hearing: kind and range
		local combat, al, bots, pr, run = live({ { X = -20 } })
		pr:setWeapon("p1", "drawn")
		run(2)
		combat:drainEvents()
		check("combat: default hearing: a shot carries 80, a door 24, a footstep 16", combat:hearingRange("shot") == 80 and combat:hearingRange("door") == 24 and math.abs(combat:hearingRange("footstep") - 16) < 1e-9)
		check("combat: a shot 50 studs from the guard is heard", combat:noise("shot", 30, 0, 0, "p1") == 1)
		check("combat: a door 50 studs from the guard is not", combat:noise("door", 30, 0, 0, "p1") == 0)
		check("combat: a footstep 10 studs from the guard is", combat:noise("footstep", -10, 0, 0, "p1") == 1)
		check("combat: an unknown noise kind is ignored", combat:noise("whistle", 0, 0, 0, "p1") == 0)
		local k = combat:knows(botId(bots, 1))
		check("combat: Attacking: hearing refreshes where the guard thinks the player is", k.Source == "Noise:footstep" and k.X == -10)
		local c2 = live({ { X = 0 } }, { setup = { SoundTravelDistance = 200 } })
		check("combat: the mission's SoundTravelDistance scales the range", c2:hearingRange("shot") == 200 and c2:hearingRange("door") == 60)
	end

	do -- losing track
		local combat, al, bots, pr, run = live({ { X = -20 } })
		pr:setWeapon("p1", "drawn")
		run(2)
		combat:drainEvents()
		pr:move("p1", -300, 0, 0)
		run(15)
		check("combat: out of sight for 15 s the guard still knows (LoseTrackSeconds 20)", combat:knows(botId(bots, 1)) ~= nil)
		run(7)
		local lost = kinds(combat:drainEvents(), "GuardLostTrack")
		check("combat: after 20 s without seeing or hearing it, the guard loses track", combat:knows(botId(bots, 1)) == nil and #lost == 1 and lost[1].Why == "timeout")
		check("combat: Attacking never falls back by itself", combat:phase() == "Attacking")
		local c2, a2, b2, p2, r2 = live({ { X = -20 } }, { params = { LoseTrackSeconds = 3 } })
		p2:setWeapon("p1", "drawn")
		r2(1.5)
		p2:move("p1", -300, 0, 0)
		r2(6)
		check("combat: LoseTrackSeconds is a parameter", c2:knows(botId(b2, 1)) == nil)
	end

	do -- a guard that goes down loses what it knew
		local combat, al, bots, pr, run = live({ { X = -20 } })
		pr:setWeapon("p1", "drawn")
		run(2)
		combat:drainEvents()
		bots:setFlag(botId(bots, 1), "Incapacitated", true)
		run(0.2)
		local lost = kinds(combat:drainEvents(), "GuardLostTrack")
		check("combat: an incapacitated guard drops what it knew", #lost == 1 and lost[1].Why == "out" and combat:knows(botId(bots, 1)) == nil)
	end

	do -- holstering and drawing again is a new sighting
		local combat, al, bots, pr, run = live({ { X = -20 } }, { params = { LoseTrackSeconds = 100 } })
		pr:setWeapon("p1", "drawn")
		run(2)
		pr:setWeapon("p1", "holstered")
		run(1)
		pr:setWeapon("p1", "drawn")
		run(2)
		check("combat: drawing the weapon again is seen again", #kinds(combat:drainEvents(), "WeaponSeen") == 2)
	end

	-------------------------------------------------------------------------------- M9c: what guards do once the lockdown has landed
	local function moves(evs, mode) local out = {} for _, e in ipairs(evs) do if e.Kind == "GuardMoves" and (mode == nil or e.Mode == mode) then out[#out + 1] = e end end return out end

	do -- Searching: every guard holds at its post
		local combat, al, bots, pr, run = live({ { X = -20 } })
		run(1)
		check("move: before the lockdown a guard is not touched", #moves(combat:drainEvents()) == 0 and bots:all()[1].Command == nil)
		al:lockdown("test")
		run(2)
		local m = moves(combat:drainEvents(), "Holding")
		check("move: at lockdown the guard is sent to hold at its nearest post", #m == 1 and math.abs(m[1].X - -20) < 1e-6)
		check("move: ... and holds there", bots:all()[1].State == "Holding")
		run(5)
		check("move: it is not sent again and again", #moves(combat:drainEvents()) == 0)
	end

	do -- Searching: a noise is investigated, then the guard goes back to the NEAREST post
		local combat, al, bots, pr, run = live({ { Route = { { X = -60 }, { X = -20 } } } })
		al:lockdown("test")
		run(3)
		combat:drainEvents()
		check("move: it starts at the first route node and holds at the nearest one (itself)", math.abs(bots:position(botId(bots, 1)) - -60) < 2)
		check("move: a noise 25 studs away is heard in Searching", combat:noise("shot", -35, 0, 0, "p1") == 1)
		run(0.2)
		local inv = moves(combat:drainEvents(), "Investigating")
		check("move: the guard goes to look at the noise", #inv == 1 and inv[1].X == -35)
		run(6)
		check("move: it gets there and looks around", math.abs(bots:position(botId(bots, 1)) - -35) < 3 and bots:all()[1].State == "Investigating", bots:all()[1].State)
		run(8)
		local back = moves(combat:drainEvents(), "Holding")
		check("move: after InvestigateSeconds it goes back to hold at the nearest post (-20, not -60)", #back == 1 and back[1].X == -20, back[1] and back[1].X)
		run(6)
		check("move: ... and is there", math.abs(bots:position(botId(bots, 1)) - -20) < 3 and bots:all()[1].State == "Holding")
		check("move: Searching never tells a guard where the player is", combat:knows(botId(bots, 1)) == nil)
	end

	do -- Attacking: not before the lockdown lands; then hunt; retarget; lose track; back to the post
		local combat, al, bots, pr, run = live({ { Route = { { X = -60 }, { X = -20 } } } })
		pr:setWeapon("p1", "drawn")
		run(2.5)
		check("move: a weapon seen below lockdown: the guard flees and radios, Combat does not move it", #moves(combat:drainEvents()) == 0 and al:level() == 0)
		run(6)
		check("move: the lockdown landed", al:level() == 3)
		local hunt = moves(combat:drainEvents(), "Hunting")
		check("move: then the guard hunts the position it knows (the player at -10)", #hunt >= 1 and math.abs(hunt[1].X - -10) < 1e-6, #hunt)
		run(12)
		check("move: it reaches the player", math.abs(bots:position(botId(bots, 1)) - -10) < 4 and bots:all()[1].State == "Hunting", bots:all()[1].State .. " x=" .. tostring(bots:position(botId(bots, 1))))
		combat:drainEvents()
		pr:move("p1", -2, 0, 0)
		run(2)
		local again = moves(combat:drainEvents(), "Hunting")
		check("move: the player moved 8 studs: the guard is sent again, to the new spot", #again == 1 and math.abs(again[1].X - -2) < 1e-6, #again)
		pr:move("p1", -2, 0, 3)
		run(2)
		check("move: a 3 stud move is not worth a new order", #moves(combat:drainEvents(), "Hunting") == 0)
		pr:move("p1", -400, 0, 0) -- out of sight and out of the way
		run(25)
		local lost = kinds(combat:drainEvents(), "GuardLostTrack")
		check("move: it loses track", #lost == 1 and combat:knows(botId(bots, 1)) == nil)
		run(8)
		check("move: ... and goes back to hold at its nearest post", bots:all()[1].State == "Holding" and math.abs(bots:position(botId(bots, 1)) - -20) < 5, bots:all()[1].State .. " x=" .. tostring(bots:position(botId(bots, 1))))
	end

	do -- a guard the alert is busy with, or one that is down, is not moved
		local combat, al, bots, pr, run = live({ { X = -20 }, { X = -40 } })
		al:lockdown("test")
		bots:setFlag(botId(bots, 2), "Dead", true)
		run(2)
		local m = moves(combat:drainEvents())
		check("move: a dead guard is not sent anywhere", #m == 1 and m[1].Bot == botId(bots, 1))
		pr:setWeapon("p1", "drawn")
		check("move: a guard in a reaction (here: fleeing and radioing) is left to the alert", al:fleeAndRadio(botId(bots, 1), "p1", "x") == true and al:busy(botId(bots, 1)) == true)
		run(0.2)
		check("move: ... so it is not given a Holding order meanwhile", #moves(combat:drainEvents()) == 0)
	end

	do -- off: nothing moves
		local combat, al, bots, pr, run = live({ { X = -20 } }, { enabled = false })
		al:lockdown("test")
		run(3)
		check("move: not opted in: lockdown moves nobody", #moves(combat:drainEvents()) == 0 and bots:all()[1].Command == nil)
	end

	-------------------------------------------------------------------------------- M9d: shooting, health, deaths
	local SURE = { HitChanceBase = 1, HitChanceMax = 1 } -- every round hits
	local function count(evs, kind, pred) local n = 0 for _, e in ipairs(evs) do if e.Kind == kind and (pred == nil or pred(e)) then n += 1 end end return n end
	-- lockdown first, so a weapon seen goes straight to Attacking with no flight; returns after the weapon was seen
	local function armedFight(opts)
		local combat, al, bots, pr, run = live({ { X = -20 } }, opts)
		al:lockdown("test")
		pr:setWeapon("p1", "drawn")
		local waited = 0
		while combat:phase() ~= "Attacking" and waited < 5 do run(0.1) waited += 0.1 end
		return combat, al, bots, pr, run
	end

	do
		local combat, al, bots, pr, run = armedFight({ params = SURE })
		combat:drainEvents()
		run(1)
		local evs = combat:drainEvents()
		local fired = count(evs, "GuardFired")
		check("shoot: the S97 fires 10 rounds a second [P]", fired >= 9 and fired <= 11, fired)
		check("shoot: every round names the weapon, the guard and the player", evs[1] ~= nil and evs[1].Kind == "GuardFired" and evs[1].Weapon == "S97" and evs[1].Player == "p1" and evs[1].Hit == true)
		run(3)
		combat:drainEvents()
		local hp, max = combat:playerHealth("p1")
		check("shoot: a whole S97 magazine (30 rounds x 0.5) takes 15 HP off a player [R: owner]", max == 100 and hp <= 85 + 1e-9 and hp >= 85 - 6, hp)
	end

	do -- exactly one magazine
		local combat, al, bots, pr, run = armedFight({ params = { HitChanceBase = 1, HitChanceMax = 1, Weapons = { S97 = { ReloadSeconds = 100 } } } })
		run(6)
		local evs = combat:drainEvents()
		check("shoot: with a long reload it stops after exactly 30 rounds, and says it is reloading", count(evs, "GuardFired") == 30 and count(evs, "GuardReloading") == 1, count(evs, "GuardFired"))
		check("shoot: 30 rounds that all hit = exactly 15 HP", math.abs(combat:playerHealth("p1") - 85) < 1e-9, combat:playerHealth("p1"))
	end

	do -- reload then shoot again
		local combat, al, bots, pr, run = armedFight({ params = SURE })
		run(3.3)
		local mag = count(combat:drainEvents(), "GuardFired")
		check("shoot: the first magazine is the 30 rounds", mag == 30, mag)
		run(2)
		check("shoot: for the next 2.5 s (the reload [P]) nothing is fired", count(combat:drainEvents(), "GuardFired") == 0)
		run(2)
		check("shoot: after the reload it fires again", count(combat:drainEvents(), "GuardFired") > 0)
	end

	do -- accuracy sharpens with time in sight, and misses happen
		local combat, al, bots, pr, run = armedFight({ params = { PlayerMaxHealth = 1e9 } })
		combat:drainEvents()
		run(40)
		local evs = combat:drainEvents()
		local fired, hits = count(evs, "GuardFired"), count(evs, "GuardFired", function(e) return e.Hit end)
		check("shoot: hit chance 0.15 sharpening to 0.6: over 40 s about half the rounds hit", fired > 200 and hits / fired > 0.35 and hits / fired < 0.62, hits .. "/" .. fired)
		local firstWindow, firstHits = 0, 0
		for i = 1, 10 do if evs[i] and evs[i].Kind == "GuardFired" then firstWindow += 1 if evs[i].Hit then firstHits += 1 end end end
		check("shoot: ... so the first rounds miss more than the later ones", firstWindow > 0 and firstHits / firstWindow < 0.5)
	end

	do -- a player who goes down is left alone, until healed
		local combat, al, bots, pr, run = armedFight({ params = { HitChanceBase = 1, HitChanceMax = 1, PlayerMaxHealth = 1 } })
		run(3)
		local evs = combat:drainEvents()
		check("shoot: a player at 0 HP is down, once", count(evs, "PlayerDown") == 1 and select(3, combat:playerHealth("p1")) == true and combat:playerHealth("p1") == 0)
		local downAt = 0
		for i, e in ipairs(evs) do if e.Kind == "PlayerDown" then downAt = i end end
		check("shoot: ... and no round is fired at them afterwards", count({ table.unpack(evs, downAt + 1) }, "GuardFired") == 0)
		run(3)
		check("shoot: ... not even later", count(combat:drainEvents(), "GuardFired") == 0)
		combat:setPlayerHealth("p1", 1)
		run(2)
		check("shoot: healed above 0 they can be shot at again", count(combat:drainEvents(), "GuardFired") > 0)
	end

	do -- two players: the first goes down, the guard turns to the second
		local combat, al, bots, pr, run = armedFight({ params = SURE })
		pr:addPlayer("p2", -8, 0, 0)
		combat:setPlayerHealth("p1", 0)
		combat:drainEvents()
		run(1)
		local evs = combat:drainEvents()
		check("shoot: with the first player down, it shoots the second", count(evs, "GuardFired", function(e) return e.Player == "p2" end) > 0 and count(evs, "GuardFired", function(e) return e.Player == "p1" end) == 0)
	end

	do -- when it does NOT shoot
		local combat, al, bots, pr, run = live({ { X = -20 } }, { params = SURE })
		al:lockdown("test")
		run(4)
		check("shoot: Searching (lockdown, nobody armed): a guard that sees the player does not shoot", count(combat:drainEvents(), "GuardFired") == 0)
		local c2, a2, b2, p2, r2 = live({ { X = -20 } }, { params = SURE })
		p2:setWeapon("p1", "drawn")
		r2(3.5)
		check("shoot: Attacking but the lockdown has not landed: the guard is fleeing and radioing, not shooting", c2:phase() == "Attacking" and a2:level() == 0 and count(c2:drainEvents(), "GuardFired") == 0)
		local c3, a3, b3, p3, r3 = armedFight({ params = SURE })
		b3:setFlag(botId(b3, 1), "Dead", true)
		c3:drainEvents()
		r3(2)
		check("shoot: a dead guard does not shoot", count(c3:drainEvents(), "GuardFired") == 0)
		local c4, a4, b4, p4, r4 = armedFight({ params = SURE })
		p4:move("p1", -400, 0, 0)
		c4:drainEvents()
		r4(2)
		check("shoot: nobody in sight: nobody to shoot at", count(c4:drainEvents(), "GuardFired") == 0)
		local c5 = live({ { X = -20 } }, { enabled = false, params = SURE })
		check("shoot: not opted in: nothing is ever fired", count(c5:drainEvents(), "GuardFired") == 0)
	end

	do -- damage to a guard, death, health bar rule
		local combat, al, bots, pr, run = armedFight({ params = SURE })
		local id = botId(bots, 1)
		local hp, max, bar = combat:botHealth(id)
		check("health: a guard starts with its class health (120 for a placed guard [O]), no bar", hp == 120 and max == 120 and bar == false)
		combat:drainEvents()
		check("health: damage reported by the host lowers it", combat:damageBot(id, 50, "p1") == 70 and select(1, combat:botHealth(id)) == 70)
		check("health: ... with a BotHit event", count(combat:drainEvents(), "BotHit", function(e) return e.Bot == id and e.Damage == 50 and e.Health == 70 and e.By == "p1" end) == 1)
		check("health: lethal damage returns 0", combat:damageBot(id, 100, "p1") == 0)
		local evs = combat:drainEvents()
		check("health: ... the guard dies (BotDied) and is flagged Dead", count(evs, "BotDied") == 1 and bots:all()[1].Flags.Dead == true)
		run(1)
		check("health: a dead guard drops what it knew and stops shooting", combat:knows(id) == nil and count(combat:drainEvents(), "GuardFired") == 0)
		check("health: a dead guard cannot be hurt again", combat:damageBot(id, 1, "p1") == nil)
		check("health: an unknown guard cannot be hurt", combat:damageBot("nobody", 1, "p1") == nil)
		local off = live({ { X = -20 } }, { enabled = false })
		check("health: not opted in: the host's damage is ignored", off:damageBot("x", 1, "p1") == nil)
	end

	do -- class data: health, bar and DamageOutput come from the class table
		local info = { Health = 250, DamageOutput = 2, ShowsHealthBar = true }
		local combat, al, bots, pr, run = armedFight({ params = { HitChanceBase = 1, HitChanceMax = 1, Weapons = { S97 = { ReloadSeconds = 100 } } }, classInfo = function() return info end })
		local hp, max, bar = combat:botHealth(botId(bots, 1))
		check("health: a heavy guard (250 HP) shows a health bar", hp == 250 and max == 250 and bar == true)
		run(6)
		check("health: DamageOutput 2 doubles the damage: a magazine takes 30 HP", math.abs(combat:playerHealth("p1") - 70) < 1e-9, combat:playerHealth("p1"))
	end

	do -- the seeded stream: same seed = same shots, another seed = other shots
		local function shots(seed)
			local combat, al, bots, pr, run = armedFight({ seed = seed, params = { PlayerMaxHealth = 1e9 } })
			combat:drainEvents()
			run(10)
			local t = {}
			for _, e in ipairs(combat:drainEvents()) do if e.Kind == "GuardFired" then t[#t + 1] = e.Hit and "1" or "0" end end
			return table.concat(t)
		end
		local a, b, c = shots(7), shots(7), shots(8)
		check("shoot: the same seed fires the same hits and misses", a == b and #a > 50)
		check("shoot: another seed fires a different pattern", a ~= c)
	end

	do -- determinism
		local function trace()
			local combat, al, bots, pr, run = live({ { X = -20 }, { X = -40 } })
			pr:setWeapon("p1", "drawn")
			run(3)
			combat:noise("shot", 5, 0, 0, "p1")
			run(8)
			local index = {} -- bot ids come from a global counter of the test: compare by position in the list
			for i, b in ipairs(bots:all()) do index[b.Id] = i end
			local t = {}
			for _, e in ipairs(combat:drainEvents()) do t[#t + 1] = ("%s@%.2f:%s"):format(e.Kind, e.Time, tostring(e.Bot and index[e.Bot] or e.Phase or "")) end
			return table.concat(t, "|")
		end
		local a, b = trace(), trace()
		check("combat: two identical runs give identical events", a == b and #a > 0, a)
	end
end
