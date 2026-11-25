--!nonstrict
--[==[
	BreachSession — one running mission: owns the step order and the combined event log (BreachEngine M8f).

	Pure Luau, deterministic. It builds nothing new: it wires the existing layers together in the one order they were tested in.
	The module table `M` is passed in (so this file does not require its siblings):

	    local S = Session.new({ Logic = Logic, Nav = Nav, Bots = Bots, Props = Props, Sight = Sight, Trespass = Trespass,
	                            Alert = Alert, Combat = Combat, Hostage = Hostage, Behavior = Behavior }, mission, world, setup, { seed = 416 })
	    S:addPlayer("p1", x, y, z)   S:movePlayer("p1", x, y, z)   S:setDisguise("p1", "ProSecurity")
	    S:aim("p1", botId)   S:answer(botId, "p1", "bluff")
	    S:step(dt)   S:run(seconds)
	    S:drainLog()        -- every event of every layer since the last call, tagged {Source = "Bots"|"Alert"|"Hostage"|"Behavior"}
	    S:signature()       -- a string of the whole run so far, for "two runs are identical"

	Step order [tested]: logic:advance, bots, sight, trespass, alert (it drains the trespass events), spawner (M9f, only with the combat phases on or
	opts.spawners), combat (M9a, opt-in: does nothing unless the mission sets MissionSetup.BreachLockdown = "TwoPhase" or opts.twoPhase), explosives (M9e),
	hostage, behavior.
	Exposed layers: S.Logic S.Nav S.Bots S.Props S.Sight S.Trespass S.Alert S.Combat S.Explosives S.Spawner S.Hostage S.Behavior. Options for the new layers:
	opts.combatParams, opts.explosiveParams, opts.spawnerParams, opts.spawners, opts.safePlaces.
]==]

local Session = {}
Session.VERSION = "0.1.0"

local Sim = {}
Sim.__index = Sim

function Session.new(M, mission, world, setup, opts)
	opts = opts or {}
	local seed = opts.seed or 0
	local logic = M.Logic.new(mission, { seed = seed, builtins = { Mission_Difficulty = opts.difficulty or 3 } })
	local nav = M.Nav.new({ pathfinder = M.Nav.worldAdapter(world) })
	local bots, why = M.Bots.new(mission, world, logic, nav, { seed = seed, params = opts.botParams })
	if not bots then
		return nil, why
	end
	local props = M.Props.new(mission, world, logic)
	local players = M.Sight.propsPlayers(props)
	local sight = M.Sight.new(world, bots, players, { blocked = function(...) return props:sightBlocked(...) end })
	local tr = M.Trespass.new(world, setup, logic)
	tr:attach(sight, bots, players)
	local alert = M.Alert.new(logic, { mission = mission, bots = bots, sight = sight, trespass = tr, players = players, world = world, params = opts.alertParams, hidingSpots = opts.hidingSpots })
	sight.LevelFn = function() return alert:level() end -- the higher the alert level, the faster guards notice (Calm 0.9x, Normal 1x, Alert 1.1x)
	local model = M.CombatData and M.CombatData.fromMission(mission, setup, { expr = M.Expr }) or nil
	local CD = M.CombatData
	local combat
	-- M9e: grenades and C4. Inert until a guard (BreachCombat) or the host throws or plants one.
	local explosives = M.Explosives and M.Explosives.new({ players = players, bots = bots,
		damagePlayer = function(id, amount, by) return combat and combat:hurtPlayer(id, amount, by) end,
		damageBot = function(id, amount, by) return combat and combat:damageBot(id, amount, by) end }, { params = opts.explosiveParams }) or nil
	combat = M.Combat and M.Combat.new({ bots = bots, sight = sight, alert = alert, players = players, setup = setup, explosives = explosives,
		classInfo = CD and function(bot) return CD.classInfo(bot.Class, CD.parseCustomCombatData(bot.Attrs and bot.Attrs.CustomCombatData)) end or nil,
		detector = model and function(bot) return CD.detectorReaction(model, bot.Node and bot.Node.Path or bot.Path) or CD.detectorReaction(model, bot.Name) end or nil,
		hidesWeapon = model and function(pl) return CD.disguiseHidesWeapon(model, pl.Disguise) end or nil,
		setStance = function(id, stance) return props:setStance(id, stance) end,
		movePlayer = function(id, x, y, z) return props:move(id, x, y, z) end,
		trespassStatus = function(id) return (tr:statusOf(id)) end,
		safePlaces = opts.safePlaces or (function()
			local list = {}
			for _, nd in ipairs(mission and mission.Nodes or {}) do
				local cf = nd.Props and nd.Props.CFrame
				if nd.Name == "HostageEscapePoint" and cf and cf.Position then
					list[#list + 1] = { X = cf.Position.X, Y = cf.Position.Y or 0, Z = cf.Position.Z }
				end
			end
			return list
		end)(),
	}, { enabled = opts.twoPhase == true, params = opts.combatParams, seed = seed }) or nil
	-- M9f: reinforcements. OPT-IN like the phases: only when the combat phases are on (or opts.spawners = true), so a mission that does not ask for
	-- them runs exactly as before.
	local spawner
	if M.Spawner and model and (opts.spawners == true or (combat and combat:phase() ~= "Off")) then
		spawner = M.Spawner.new({ logic = logic, bots = bots, model = model, players = players,
			phase = function() return combat and combat:phase() or "Off" end,
			inform = function(botId, playerId) if combat then combat:inform(botId, playerId, "Reinforcement") end end }, { seed = seed, params = opts.spawnerParams })
	end
	local hostage = M.Hostage.new(logic, { mission = mission, bots = bots, nav = nav, players = players, props = props, sight = sight, world = world, alert = alert, params = opts.hostageParams, altTriggers = opts.altTriggers })
	local behavior = M.Behavior.new(logic, { mission = mission, bots = bots, nav = nav, alert = alert, players = players, params = opts.behaviorParams })
	return setmetatable({
		Logic = logic, Nav = nav, Bots = bots, Props = props, Sight = sight, Trespass = tr, Alert = alert, Combat = combat, Hostage = hostage, Behavior = behavior, CombatModel = model, Explosives = explosives, Spawner = spawner,
		Players = players, Time = 0, Log = {}, Trace = {},
	}, Sim)
end

function Sim:addPlayer(id, x, y, z)
	return self.Props:addPlayer(id, x, y, z)
end

function Sim:movePlayer(id, x, y, z)
	return self.Props:move(id, x, y, z)
end

function Sim:setDisguise(id, disguise)
	return self.Props:setDisguise(id, disguise)
end

function Sim:aim(playerId, botId)
	return self.Hostage:aim(playerId, botId)
end

function Sim:answer(botId, playerId, response)
	return self.Alert:answer(botId, playerId, response)
end

local function collect(self, source, events)
	for _, ev in ipairs(events) do
		ev.Source = source
		self.Log[#self.Log + 1] = ev
		self.Trace[#self.Trace + 1] = ("%s.%s@%.2f:%s:%s"):format(source, ev.Kind, ev.Time or self.Time, tostring(ev.Bot or ev.Spawner or ""), tostring(ev.Level or ev.Reason or ev.Line or ev.Node or ""))
	end
end

function Sim:step(dt)
	self.Time += dt
	self.Logic:advance(dt)
	self.Bots:step(dt)
	collect(self, "Bots", self.Bots:drainEvents())
	self.Sight:step(dt)
	self.Trespass:step(dt)
	self.Alert:step(dt)
	collect(self, "Alert", self.Alert:drainEvents())
	if self.Spawner then
		self.Spawner:step(dt) -- before combat: a reinforcement made this tick is told about the player and moves in the same tick
		collect(self, "Spawner", self.Spawner:drainEvents())
	end
	if self.Combat then
		self.Combat:step(dt)
		collect(self, "Combat", self.Combat:drainEvents())
	end
	if self.Explosives then
		self.Explosives:step(dt) -- after combat: a grenade thrown this tick starts its fuse now
		collect(self, "Explosives", self.Explosives:drainEvents())
	end
	self.Hostage:step(dt)
	collect(self, "Hostage", self.Hostage:drainEvents())
	self.Behavior:step(dt)
	collect(self, "Behavior", self.Behavior:drainEvents())
end

function Sim:run(seconds, dt)
	dt = dt or 1 / 20
	for _ = 1, math.floor(seconds / dt + 0.5) do
		self:step(dt)
	end
end

function Sim:drainLog()
	local l = self.Log
	self.Log = {}
	return l
end

function Sim:signature()
	return table.concat(self.Trace, "|")
end

return Session
