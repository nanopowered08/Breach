--!nonstrict
-- M8c (alert) tests: BreachAlert. Run via tests/run.luau or alone: `luau tests/alert.luau`
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

	----------------------------------------------------------------------------------------------- raise semantics (unit)
	do
		local l = Logic.fromSpec({ Globals = {} }, {})
		local a = Alert.new(l, {})
		check("raise: starts at 0 and publishes Mission_AlertLevel / Mission_AlarmRaised", a:level() == 0 and l:get("Mission_AlertLevel") == 0 and l:get("Mission_AlarmRaised") == 0)
		check("raise: (1,1,3) adds one", a:raise(1, "x", 1, 3) == 1 and l:get("Mission_AlertLevel") == 1 and l:get("Mission_AlarmRaised") == 0)
		check("raise: it is monotonic, a smaller target never lowers it", a:raise(1, "x", 1, 1) == 1 and a:level() == 1)
		check("raise: Min == Max sets exactly that level ((2,2,2) from 1 -> 2)", a:raise(2, "x", 2, 2) == 2 and l:get("Mission_AlertLevel") == 2)
		check("raise: below the lockdown level the alarm is not raised", l:get("Mission_AlarmRaised") == 0 and not a:isLockdown())
		check("raise: (3,3,3) -> lockdown, Mission_AlarmRaised = 1", a:raise(3, "boom", 3, 3) == 3 and a:isLockdown() and l:get("Mission_AlarmRaised") == 1)
		check("raise: never above 3", a:raise(5, "x", 1, 9) == 3)
		local evs = a:drainEvents()
		check("raise: AlertRaised events carry Level, Before and Reason; one AlarmRaised", #kinds(evs, "AlertRaised") == 3 and kinds(evs, "AlertRaised")[1].Before == 0 and kinds(evs, "AlertRaised")[3].Reason == "boom" and #kinds(evs, "AlarmRaised") == 1)
		local l2 = Logic.fromSpec({ Globals = {} }, {})
		local b = Alert.new(l2, {})
		check("raise: (1,2,2) from 0 jumps to 2 (the real triple)", b:raise(1, "x", 2, 2) == 2)
		local l3 = Logic.fromSpec({ Globals = {} }, {})
		local c = Alert.new(l3, { params = { AlarmRaisedAt = 1 } })
		c:raise(1, "x")
		check("raise: AlarmRaisedAt is configurable (level >= 1)", l3:get("Mission_AlarmRaised") == 1)
		check("raise: lockdown() goes straight to 3", Alert.new(Logic.fromSpec({ Globals = {} }, {}), {}):lockdown("L") == 3)
	end

	do -- the maps write Mission_AlertLevel themselves
		local l = Logic.fromSpec({ Globals = {} }, {})
		local a = Alert.new(l, {})
		l:set("Mission_AlertLevel", 2)
		check("map write: a script setting Mission_AlertLevel 2 moves the alert (state Alert, no alarm)", a:level() == 2 and a:stateName() == "Alert" and l:get("Mission_AlarmRaised") == 0)
		l:set("Mission_AlertLevel", 1)
		local evs = a:drainEvents()
		check("map write: lowering it (Peacemaker's ReduceAlertLevel / bluff) is followed: AlertLowered", a:level() == 1 and #kinds(evs, "AlertLowered") == 1 and kinds(evs, "AlertLowered")[1].Reason == "MapWrite")
		check("map write: raise() works from the new, lower level", a:raise(1, "x") == 2)
		l:set("Mission_AlertLevel", 3)
		check("map write: writing 3 raises the alarm", a:isLockdown() and l:get("Mission_AlarmRaised") == 1)
		l:set("Mission_AlertLevel", 2)
		check("map write: ... Mission_AlarmRaised stays latched when the level is written back down", a:level() == 2 and l:get("Mission_AlarmRaised") == 1)
		l:set("Mission_AlertLevel", 9)
		check("map write: nonsense values are ignored", a:level() == 2)
	end

	----------------------------------------------------------------------------------------------- decay components
	local function scomp(ty, name, attrs) return { Type = ty, Name = name, Attrs = attrs, Path = "DebugMission/StateComponents/" .. name } end
	local function stub(list) return { byComponent = function(_, ty) local out = {} for _, c in ipairs(list) do if c.Type == ty then out[#out + 1] = c end end return out end } end
	do -- AlertLowerCondition
		local l = Logic.fromSpec({ Globals = { Reduced = "0", Reset = "0" } }, {})
		local m = stub({ scomp("AlertLowerCondition", "Reduce", { AlertLevel = "Mission_AlertLevel == 2 && 1 || 0", Condition = "Reduced" }), scomp("AlertLowerCondition", "Reset", { AlertLevel = 0, Condition = "Reset" }) })
		local a = Alert.new(l, { mission = m })
		a:raise(2, "x", 2, 2)
		l:set("Reduced", 1)
		local evs = a:drainEvents()
		check("lower: AlertLowerCondition on a level-2 alert drops it to 1 (the Peacemaker's expression)", a:level() == 1 and l:get("Mission_AlertLevel") == 1 and kinds(evs, "AlertLowered")[1].Reason == "AlertLowerCondition:Reduce")
		l:set("Reduced", 0)
		a:raise(1, "x") -- back to 2
		l:set("Reduced", 1)
		check("lower: a second rising edge lowers again", a:level() == 1)
		l:set("Reset", 1)
		check("lower: the Reset component (AlertLevel = 0) calms it", a:level() == 0 and a:stateName() == "Calm")
		local l2 = Logic.fromSpec({ Globals = { Reduced = "0" } }, {})
		local a2 = Alert.new(l2, { mission = stub({ scomp("AlertLowerCondition", "Reduce", { AlertLevel = 2, Condition = "Reduced" }) }) })
		a2:raise(1, "x") -- level 1; the component says 2: it never RAISES
		l2:set("Reduced", 1)
		check("lower: it never raises the level", a2:level() == 1)
		local l3 = Logic.fromSpec({ Globals = { Reset = "0" } }, {})
		local a3 = Alert.new(l3, { mission = stub({ scomp("AlertLowerCondition", "Reset", { AlertLevel = 0, Condition = "Reset" }) }) })
		a3:lockdown("x")
		l3:set("Reset", 1)
		check("lower: from lockdown the level can drop, but Mission_AlarmRaised stays latched", a3:level() == 0 and l3:get("Mission_AlarmRaised") == 1 and a3:stateName() == "Calm")
	end

	do -- StandardRadioAlertReduction
		local function make(attrs, globals)
			local l = Logic.fromSpec({ Globals = globals or {} }, {})
			l:set("Mission_Difficulty", 3)
			local a = Alert.new(l, { mission = stub({ scomp("StandardRadioAlertReduction", "Std", attrs) }) })
			return a, l
		end
		local function tick(a, l, seconds) for _ = 1, math.floor(seconds / DT + 0.5) do l:advance(DT) a:step(DT) end end
		local a, l = make({ AlertReductionDifficulty = 0, AlertResetDifficulty = 1, AlertReductionDisabled = "Mission_AlarmRaised" })
		a:raise(2, "x", 2, 2)
		tick(a, l, 50)
		check("reduction: nothing changes before the calm spell is over", a:level() == 2)
		tick(a, l, 15)
		check("reduction: after ReductionSeconds of calm, Alert drops to Normal", a:level() == 1 and a:stateName() == "Normal")
		tick(a, l, 50)
		check("reduction: ... still Normal before ResetSeconds", a:level() == 1)
		tick(a, l, 15)
		check("reduction: ... then it resets to Calm", a:level() == 0)
		a:raise(1, "x")
		tick(a, l, 40)
		a:raise(1, "again") -- a new raise restarts the calm spell
		tick(a, l, 40)
		check("reduction: a new raise restarts the calm spell", a:level() == 2)
		a:lockdown("boom")
		tick(a, l, 300)
		check("reduction: never once the alarm is raised (AlertReductionDisabled = Mission_AlarmRaised)", a:level() == 3)
		local b, lb = make({ AlertReductionDifficulty = 0, AlertResetDifficulty = 5, AlertReductionDisabled = 0 })
		b:raise(2, "x", 2, 2)
		tick(b, lb, 200)
		check("reduction: Normal -> Calm needs Mission_Difficulty >= AlertResetDifficulty (3 < 5: it stays Normal)", b:level() == 1)
		local c, lc = make({ AlertReductionDifficulty = 0, AlertResetDifficulty = 1, AlertReductionDisabled = "Hold" }, { Hold = "1" })
		c:raise(2, "x", 2, 2)
		tick(c, lc, 200)
		check("reduction: AlertReductionDisabled true holds the level", c:level() == 2)
		lc:set("Hold", 0)
		tick(c, lc, 130)
		check("reduction: ... and it resumes when it goes false", c:level() == 0)
		local l2 = Logic.fromSpec({ Globals = {} }, {})
		local n = Alert.new(l2, { mission = stub({}) })
		n:raise(2, "x", 2, 2)
		for _ = 1, 4000 do l2:advance(DT) n:step(DT) end
		check("reduction: a mission without the component never decays on its own", n:level() == 2)
	end

	----------------------------------------------------------------------------------------------- AlertRaiseCondition
	local function comp(name, attrs) return { Type = "AlertRaiseCondition", Name = name, Attrs = attrs, Path = "DebugMission/StateComponents/" .. name } end
	do
		local l = Logic.fromSpec({ Globals = { Fled = "0", Boom = "0" } }, {})
		local m = { byComponent = function(_, ty) if ty == "AlertRaiseCondition" then return { comp("A", { Amount = 1, MinValue = 1, MaxValue = 3, Condition = "Fled", Reason = "Notify.Fled" }), comp("B", { Amount = 3, MinValue = 3, MaxValue = 3, Condition = "Boom == 1 && !Mission_AlarmRaised", Reason = "{[Bang]}" }), comp("Off", { Amount = 1, Condition = "" }) } end return {} end }
		local a = Alert.new(l, { mission = m })
		check("condition: nothing happens while the Conditions are false", a:level() == 0 and #a.Conditions == 2)
		l:set("Fled", 1)
		check("condition: the rising edge raises by Amount", a:level() == 1)
		l:set("Fled", 1)
		l:settle()
		check("condition: it fires once per rising edge, not every settle", a:level() == 1 and a.Conditions[1].Fired == 1)
		l:set("Fled", 0)
		l:set("Fled", 1)
		check("condition: a second rising edge raises again (1 -> 2)", a:level() == 2 and a.Conditions[1].Fired == 2)
		l:set("Boom", 1)
		check("condition: (3,3,3) with a !Mission_AlarmRaised guard sets lockdown", a:level() == 3 and l:get("Mission_AlarmRaised") == 1)
		local evs = kinds(a:drainEvents(), "AlertRaised")
		check("condition: the Reason is carried (a CustomStrings key as is, a {expr} template evaluated)", evs[1].Reason == "Notify.Fled" and evs[3].Reason == "Bang")
	end

	----------------------------------------------------------------------------------------------- a live scene
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
		local cells = { { Index = 1, Node = { Name = "Public" } }, { Index = 2, Node = { Name = "Restricted" } }, { Index = 3, Node = { Name = "Vault" } } }
		return { Cells = cells, Links = { { Cells = { 1, 2 } }, { Cells = { 2, 3 } } }, cellAt = function(_, x) if x >= 100 then return cells[3] elseif x >= 0 then return cells[2] end return cells[1] end }
	end
	local function straight(a, b) return { { X = a.X, Y = a.Y or 0, Z = a.Z }, { X = b.X, Y = b.Y or 0, Z = b.Z } } end
	local RULES = {
		Public = {},
		Restricted = { Trespass = true, Allow = { ProSecurity = true }, Enforce = { Sec = true }, EnforceMinor = { Sec = true }, MinorTrespass = { Chef = true } },
		Vault = { Trespass = true, Enforce = { Sec = true } },
	}
	-- botDefs: { Class, Profile, X, Z, Route = { {x,z}, ... } }
	local function live(botDefs, params)
		local list, routes = {}, {}
		for i, d in ipairs(botDefs) do
			local rname = "Post" .. i
			list[#list + 1] = botNode("bot" .. i, { Behavior = "PatrolWalk", Nodes = rname, PatrolCycleLength = 99999, Class = d.Class, Profile = d.Profile, ServerTag = d.Tag })
			local nodes = {}
			for k, pt in ipairs(d.Route or { { d.X, d.Z or 0 } }) do nodes[#nodes + 1] = part("Node" .. k, pt[1], 0, pt[2], {}, FACE_PLUS_X) end
			routes[#routes + 1] = folder(rname, nodes)
		end
		local botsF, nodesF = folder("Bots", list), folder("Nodes", routes)
		local m = { folder = function(_, n) if n == "Bots" then return botsF elseif n == "Nodes" then return nodesF end end, byComponent = function() return {} end }
		local l = Logic.fromSpec({ Globals = {} }, {})
		local nav = Nav.new({ pathfinder = straight })
		local w = liveWorld()
		local bots = Bots.new(m, w, l, nav, { seed = 1 })
		local pr = Props.fromNodes({}, w, l)
		pr:addPlayer("p1", -50, 0, 0)
		local sight = Sight.new(w, bots, Sight.propsPlayers(pr))
		local tr = Trespass.new(w, { Cells = RULES }, l)
		tr:attach(sight, bots, Sight.propsPlayers(pr))
		local al = Alert.new(l, { mission = m, bots = bots, sight = sight, trespass = tr, players = Sight.propsPlayers(pr), world = w, params = params })
		local function run(seconds) for _ = 1, math.floor(seconds / DT + 0.5) do l:advance(DT) bots:step(DT) sight:step(DT) tr:step(DT) al:step(DT) end end
		return al, bots, pr, l, run
	end
	local function botId(bots, i) return bots:all()[i].Id end

	do -- major trespass
		local al, bots, pr, l, run = live({ { Class = "Sec", X = 20 } })
		run(2)
		check("major: nothing happens while the player is in public space", al:level() == 0 and #al:drainEvents() == 0)
		pr:move("p1", 30, 0, 0)
		run(2)
		local mid = al:drainEvents()
		check("major: the witness comments, then radios (BotSay TrespassMajor, BotRadioStarted), no lockdown yet", #kinds(mid, "BotSay") >= 1 and #kinds(mid, "BotRadioStarted") == 1 and al:level() == 0)
		check("major: while radioing the bot is off its patrol", bots:all()[1].State == "Radioing")
		run(6)
		local late = al:drainEvents()
		check("major: the call lands: lockdown (level 3) and Mission_AlarmRaised", al:level() == 3 and l:get("Mission_AlarmRaised") == 1 and #kinds(late, "AlertRaised") == 1 and kinds(late, "AlertRaised")[1].Level == 3)
		check("major: afterwards the bot goes back to its patrol", bots:all()[1].State ~= "Radioing" and bots:all()[1].Command == nil)
	end

	do -- the witness is stopped first
		local al, bots, pr, l, run = live({ { Class = "Sec", X = 20 } })
		pr:move("p1", 30, 0, 0)
		run(3)
		check("cancel: setup: the radio call has started", bots:all()[1].State == "Radioing")
		bots:setFlag(botId(bots, 1), "Dead", true)
		run(8)
		local evs = al:drainEvents()
		check("cancel: a bot killed during the call never completes it: no lockdown, BotRadioCancelled", al:level() == 0 and #kinds(evs, "BotRadioCancelled") == 1)
		local al2, bots2, pr2, l2, run2 = live({ { Class = "Sec", X = 20 } })
		pr2:move("p1", 30, 0, 0)
		run2(3)
		bots2:setFlag(botId(bots2, 1), "Incapacitated", true)
		run2(8)
		check("cancel: ... and the same when it is only incapacitated", al2:level() == 0)
	end

	do -- minor trespass, Bathurst style (no raise)
		local al, bots, pr, l, run = live({ { Class = "Sec", X = 20 } })
		pr:setDisguise("p1", "Chef")
		pr:move("p1", 30, 0, 0)
		run(3)
		local evs = al:drainEvents()
		check("minor: the guard walks up and asks (QuestionAsked)", #kinds(evs, "QuestionAsked") == 1 and bots:all()[1].State == "Questioning")
		check("minor: Bathurst style: asking does NOT raise the alert", al:level() == 0 and #kinds(evs, "AlertRaised") == 0)
		check("minor: answering a question that was not asked, or by the wrong player, is refused", al:answer("nobody", "p1", true) == false and al:answer(botId(bots, 1), "p2", true) == false)
		check("minor: a good answer is accepted", al:answer(botId(bots, 1), "p1", true) == true)
		run(5)
		check("minor: ... the guard returns to its patrol and does not ask again for a while", bots:all()[1].Command == nil and #kinds(al:drainEvents(), "QuestionAsked") == 0 and al:level() == 0)
	end

	do -- minor trespass: the +1 style is a property of the GUARD (a tag), then a failed answer = escorted out
		local al, bots, pr, l, run = live({ { Class = "Sec", X = 20, Tag = "KingSt" } }, { MinorRaiseTags = { "KingSt" } })
		pr:setDisguise("p1", "Chef")
		pr:move("p1", 30, 0, 0)
		run(3)
		check("minor: a guard carrying the tag raises the alert by one when it notices", al:level() == 1 and al:stateName() == "Normal")
		check("minor: ... and then it asks", #kinds(al:drainEvents(), "QuestionAsked") == 1)
		al:answer(botId(bots, 1), "p1", false)
		local evs = al:drainEvents()
		check("minor: a failed answer is a major trespass but NO lockdown: the guard escorts the player out", #kinds(evs, "EscortStarted") == 1 and al:level() == 1 and bots:all()[1].State ~= "Radioing")
		check("minor: ... and the place is burned for that player", al:isBanned("p1", "Restricted") and not al:isBanned("p1", "Vault"))
		run(2)
		pr:move("p1", -30, 0, 0) -- follows the escort out
		run(1)
		check("minor: the player leaving ends the escort (EscortFinished), the guard returns to its patrol", #kinds(al:drainEvents(), "EscortFinished") == 1 and bots:all()[1].Command == nil and al:level() == 1)
		pr:move("p1", 30, 0, 0)
		run(8)
		check("minor: going back into the burned place: the guard that sees you radios LOCKDOWN (no second question)", al:level() == 3)
		local al2, bots2, pr2, l2, run2 = live({ { Class = "Sec", X = 20 } })
		pr2:setDisguise("p1", "Chef")
		pr2:move("p1", 30, 0, 0)
		run2(3)
		check("minor: a guard without the tag only asks (no raise)", al2:level() == 0 and #kinds(al2:drainEvents(), "QuestionAsked") == 1)
		local al3, bots3, pr3, l3, run3 = live({ { Class = "Sec", X = 20 } }, { FailedAnswerLockdown = true })
		pr3:setDisguise("p1", "Chef")
		pr3:move("p1", 30, 0, 0)
		run3(3)
		al3:answer(botId(bots3, 1), "p1", false)
		run3(8)
		check("minor: FailedAnswerLockdown = true restores the old behaviour (radio lockdown)", al3:level() == 3)
	end

	do -- minor trespass, no answer: escorted out; staying put in the escort: lockdown
		local al, bots, pr, l, run = live({ { Class = "Sec", X = 20 } }, { QuestionSeconds = 3, EscortSeconds = 5 })
		pr:setDisguise("p1", "Chef")
		pr:move("p1", 30, 0, 0)
		run(3)
		check("minor: setup: the guard is asking", #kinds(al:drainEvents(), "QuestionAsked") == 1)
		run(3.5)
		local evs = al:drainEvents()
		check("minor: no answer in time: QuestionTimedOut, then the escort starts (no lockdown yet)", #kinds(evs, "QuestionTimedOut") == 1 and #kinds(evs, "EscortStarted") == 1 and al:level() == 0)
		run(12)
		check("minor: a player who will not be escorted out ends in lockdown", al:level() == 3)
	end

	do -- "I'm leaving"
		local al, bots, pr, l, run = live({ { Class = "Sec", X = 20 } }, { LeaveSeconds = 6 })
		pr:setDisguise("p1", "Chef")
		pr:move("p1", 30, 0, 0)
		run(3)
		al:drainEvents()
		check("leave: the answer is accepted", al:answer(botId(bots, 1), "p1", "leave") == true)
		check("leave: the guard waits and watches (nothing escalates)", bots:all()[1].State == "Watching" and al:level() == 0)
		run(2)
		pr:move("p1", -30, 0, 0)
		run(1)
		local evs = al:drainEvents()
		check("leave: leaving by yourself in time: PlayerLeft, no escort, no ban", #kinds(evs, "PlayerLeft") == 1 and #kinds(evs, "EscortStarted") == 0 and not al:isBanned("p1", "Restricted"))
		local al2, bots2, pr2, l2, run2 = live({ { Class = "Sec", X = 20 } }, { LeaveSeconds = 3 })
		pr2:setDisguise("p1", "Chef")
		pr2:move("p1", 30, 0, 0)
		run2(3)
		al2:answer(botId(bots2, 1), "p1", "leave")
		al2:drainEvents()
		run2(4)
		check("leave: not out in time: the guard escorts the player out (and the place is burned)", #kinds(al2:drainEvents(), "EscortStarted") == 1 and al2:isBanned("p1", "Restricted"))
	end

	do -- the player leaves before the guard arrives
		local al, bots, pr, l, run = live({ { Class = "Sec", X = 20, Route = { { 20, 0 } } } })
		pr:setDisguise("p1", "Chef")
		pr:move("p1", 30, 0, 0)
		run(1.3)
		pr:move("p1", -30, 0, 0)
		pr:setDisguise("p1", "None")
		run(6)
		check("minor: a player who leaves the cell before being asked is not chased: the guard goes back to its patrol", bots:all()[1].Command == nil and al.Reaction[botId(bots, 1)] == nil)
		check("minor: and nothing escalates", al:level() == 0)
	end

	do -- disguise piercing
		local al, bots, pr, l, run = live({ { Class = "Sec", Profile = "LeadSecurity", X = 20 }, { Class = "Emp", Profile = "Employee", X = 20, Z = 8 } })
		pr:setDisguise("p1", "ProSecurity")
		pr:move("p1", 30, 0, 0) -- Restricted, but ProSecurity is allowed there
		run(3)
		check("pierce: the lead notices a disguised player and starts to radio", #kinds(al:drainEvents(), "BotRadioStarted") == 1)
		run(7)
		check("pierce: lockdown, although the cell allows the disguise", al:level() == 3)
		local al2, bots2, pr2, l2, run2 = live({ { Class = "Sec", Profile = "BasicSecurity", X = 20 } })
		pr2:setDisguise("p1", "ProSecurity")
		pr2:move("p1", 30, 0, 0)
		run2(10)
		check("pierce: an ordinary guard is fooled by the same disguise", al2:level() == 0)
		local al3, bots3, pr3, l3, run3 = live({ { Class = "Sec", Profile = "LeadSecurity", X = -20 } })
		pr3:move("p1", -10, 0, 0) -- a public cell, no disguise: noticed, but nothing to pierce and nothing forbidden
		run3(8)
		check("pierce: with no disguise the profile rule does not apply (an allowed player in public space stays unbothered)", al3:level() == 0 and #al3:drainEvents() == 0)
	end

	----------------------------------------------------------------------------------------------- anomalies
	do
		local al, bots, pr, l, run = live({ { Class = "Emp", X = 20 }, { Class = "Emp", X = 20, Z = 30 } })
		local a = al:addAnomaly("Radio", 45, 0, 0)
		check("anomaly: an unknown kind is refused", al:addAnomaly("Nope", 0, 0, 0) == nil)
		run(1)
		local evs = al:drainEvents()
		check("anomaly: a bot that sees a dropped radio comments (BotSay + AnomalyFound with the place)", #kinds(evs, "AnomalyFound") == 1 and kinds(evs, "AnomalyFound")[1].Place == "Restricted" and kinds(evs, "AnomalyFound")[1].Anomaly == "Radio" and #kinds(evs, "BotSay") == 1)
		run(8)
		local late = al:drainEvents()
		check("anomaly: it radios (10-66 at the place) and the alert goes up by ONE (not lockdown)", al:level() == 1 and #kinds(late, "AnomalyReported") == 1)
		check("anomaly: the radio call line names the place", (function() for _, e in ipairs(kinds(late, "BotSay")) do if e.Text == "10-66 at Restricted" then return true end end return false end)())
		run(10)
		check("anomaly: it is reported once: the level stays 1", al:level() == 1 and a.Reported)
	end

	do
		local al, bots, pr, l, run = live({ { Class = "Emp", X = 20 } })
		al:addAnomaly("BrokenGlass", -60, 0, 0) -- behind the bot, far outside its view
		run(10)
		check("anomaly: a point the bot cannot see (behind it, out of range) is not found", al:level() == 0 and #al:drainEvents() == 0)
		al:addAnomaly("BrokenCamera", 30, 0, 0)
		run(8)
		check("anomaly: a broken camera in view: alert +1", al:level() == 1)
	end

	do -- a body found = lockdown
		local al, bots, pr, l, run = live({ { Class = "Emp", X = 20 }, { Class = "Emp", X = 40, Z = 3 } })
		bots:setFlag(botId(bots, 2), "Incapacitated", true)
		run(1)
		check("body: an incapacitated bot becomes a Body anomaly by itself", #al:anomalies() == 1 and al:anomalies()[1].Kind == "Body")
		run(9)
		check("body: finding it calls LOCKDOWN", al:level() == 3)
	end

	do -- the finder is stopped, someone else may find the anomaly
		local al, bots, pr, l, run = live({ { Class = "Emp", X = 20 }, { Class = "Emp", X = 20, Z = 5 } })
		al:addAnomaly("Radio", 45, 0, 0)
		run(2)
		local finder
		for _, b in ipairs(bots:all()) do if al.Reaction[b.Id] then finder = b end end
		bots:setFlag(finder.Id, "Dead", true)
		run(10)
		check("anomaly: if the finder is killed before radioing, another bot can still report it", al:level() >= 1)
	end

	----------------------------------------------------------------------------------------------- hiding spots, states
	do
		local al, bots = live({ { Class = "Sec", X = 20 } })
		local bot = bots:all()[1]
		local pl = { Id = "p1", X = 30, Y = 0, Z = 0 }
		local function spot(spots, player, sight)
			al.HidingSpots = spots
			if sight then al.Sight = sight end
			local x, _, z = al:_hidingSpot(bot, player or pl)
			return x and (x .. "," .. z) or nil
		end
		check("hide: priority 1: too close to the player is rejected, too far to run back is rejected, a spot in between is taken", spot({ { X = 35, Z = 0 }, { X = 200, Z = 0 }, { X = 70, Z = 0 } }) == "70,0")
		check("hide: priority 1: nothing qualifies -> do not hide at all", spot({ { X = 35, Z = 0 }, { X = 200, Z = 0 } }) == nil)
		check("hide: priority 2: the easier spot to get to and back wins", spot({ { X = 90, Z = 0 }, { X = 60, Z = 0 } }) == "60,0")
		local realSight = al.Sight
		local walls = { lineOfSight = function(_, ax, ay, az, bx, by, bz) return not ((ax > 50 and bx < 40) or (ax < 40 and bx > 50)) end }
		check("hide: priority 2: a wall in the way doubles the cost: the open spot beats the walled one", spot({ { X = 60, Z = 0 }, { X = 70, Z = 20 } }, nil, { lineOfSight = function(_, ax, ay, az, bx, by, bz) return not (bx == 60 or ax == 60) end }) == "70,20")
		check("hide: priority 3: with a weapon seen, a spot that covers the line of fire wins a tie", spot({ { X = 60, Z = 0 }, { X = 60, Z = 1 } }, { Id = "p1", X = 30, Y = 0, Z = 0, Armed = true }, { lineOfSight = function(_, ax, ay, az, bx, by, bz) return not (az == 1 and bx == 30) end }) == "60,1")
		check("hide: ... but cover never beats priority 1 or 2", spot({ { X = 90, Z = 0 }, { X = 60, Z = 1 } }, { Id = "p1", X = 30, Y = 0, Z = 0, Armed = true }, { lineOfSight = function(_, ax, ay, az, bx, by, bz) return not (az == 0 and bx == 30) end }) == "60,1")
		al.Sight = realSight
	end

	-- Guards flee ONLY from an armed player, and they radio WHILE they flee [R: owner, Nov 2026]
	do -- armed: the guard runs to the hiding spot and the radio call starts at once, landing RadioSeconds later wherever it is
		local al, bots, pr, l, run = live({ { Class = "Sec", X = 20 } })
		al.HidingSpots = { { X = 70, Z = 0 } }
		pr:setArmed("p1", true)
		pr:move("p1", 30, 0, 0)
		run(1.5)
		local early = al:drainEvents()
		local radio = kinds(early, "BotRadioStarted")
		local x1 = bots:position(botId(bots, 1))
		check("flee: an armed player: the radio call starts as soon as the guard flees (not after it arrived)", #radio == 1 and radio[1].Fleeing == true)
		check("flee: ... while the guard is still running to the spot", string.sub(bots:all()[1].State, 1, 6) == "Going:" and x1 < 65, bots:all()[1].State .. " x=" .. tostring(x1))
		check("flee: ... and no lockdown yet", al:level() == 0)
		run(4)
		check("flee: the call lands RadioSeconds after it started, even if the guard has not reached the spot: lockdown", al:level() == 3)
		check("flee: ... and the guard is not left held", bots:all()[1].State ~= "Radioing" and bots:all()[1].Command == nil)
	end

	do -- armed, but the spot is close: the guard arrives first and waits there for the call to land
		local al, bots, pr, l, run = live({ { Class = "Sec", X = 20 } }, { RadioSeconds = 20 })
		al.HidingSpots = { { X = 70, Z = 0 } }
		pr:setArmed("p1", true)
		pr:move("p1", 30, 0, 0)
		run(12)
		local x = bots:position(botId(bots, 1))
		check("flee: a long call: the guard reaches the hiding spot and waits there", x > 65 and bots:all()[1].State == "Radioing" and al:level() == 0, bots:all()[1].State .. " x=" .. tostring(x))
		run(12)
		check("flee: ... and the lockdown lands when the call does", al:level() == 3)
	end

	do -- unarmed: the guard does NOT flee; it radios where it stands [P]
		local al, bots, pr, l, run = live({ { Class = "Sec", X = 20 } })
		al.HidingSpots = { { X = 70, Z = 0 } }
		pr:move("p1", 30, 0, 0) -- same setup as the armed test, only the weapon is missing
		run(1.5)
		local evs = al:drainEvents()
		local radio = kinds(evs, "BotRadioStarted")
		local x = bots:position(botId(bots, 1))
		check("flee: an unarmed player does not make the guard run: it radios in place", #radio == 1 and radio[1].Fleeing == nil and radio[1].Hidden == false and bots:all()[1].State == "Radioing" and x < 30, bots:all()[1].State .. " x=" .. tostring(x))
		run(6)
		check("flee: ... and the call still lands as lockdown", al:level() == 3)
	end

	do -- armed with no usable spot: radio in place (as before)
		local al, bots, pr, l, run = live({ { Class = "Sec", X = 20 } })
		al.HidingSpots = {}
		pr:setArmed("p1", true)
		pr:move("p1", 30, 0, 0)
		run(1.5)
		check("flee: armed but no hiding spot: the guard radios where it stands", bots:all()[1].State == "Radioing" and #kinds(al:drainEvents(), "BotRadioStarted") == 1)
	end

	do -- the armed flag travels from Props through the players adapter
		local al, bots, pr = live({ { Class = "Sec", X = 20 } })
		local fn = Sight.propsPlayers(pr)
		check("armed: a player is unarmed by default", fn()[1].Armed == false)
		check("armed: Props:setArmed reaches the players list, and can be cleared", pr:setArmed("p1", true) and fn()[1].Armed == true and pr:setArmed("p1", false) and fn()[1].Armed == false)
		check("armed: an unknown player is refused", pr:setArmed("nobody", true) == false)
	end

	do -- a guard stopped while fleeing never completes the call
		local al, bots, pr, l, run = live({ { Class = "Sec", X = 20 } })
		al.HidingSpots = { { X = 70, Z = 0 } }
		pr:setArmed("p1", true)
		pr:move("p1", 30, 0, 0)
		run(2)
		bots:setFlag(botId(bots, 1), "Incapacitated", true)
		run(8)
		check("flee: killed or subdued on the run: the call is cancelled, no lockdown", al:level() == 0 and #kinds(al:drainEvents(), "BotRadioCancelled") == 1)
	end

	do
		local l = Logic.fromSpec({ Globals = {} }, {})
		local al = Alert.new(l, {})
		check("states: Calm, Normal, Alert, Lockdown follow the level", al:stateName() == "Calm" and (al:raise(1, "x") and al:stateName() == "Normal") and (al:raise(1, "x") and al:stateName() == "Alert") and (al:lockdown("x") and al:stateName() == "Lockdown"))
		local l2 = Logic.fromSpec({ Globals = {} }, {})
		local a2 = Alert.new(l2, { bots = { bot = function() return nil end, all = function() return {} end } })
		a2:setFighting("b1", true, "test")
		check("states: Fighting (deprecated) is a flag, not a level: no lockdown, level unchanged", a2:stateName() == "Fighting" and a2:level() == 0 and a2:isFighting() and l2:get("Mission_AlarmRaised") == 0 and #kinds(a2:drainEvents(), "BotFighting") == 1)
		a2:setFighting("b1", false)
		check("states: ... and it clears", a2:stateName() == "Calm" and not a2:isFighting())
		a2:setFighting("b1", true)
		a2:lockdown("x")
		check("states: Lockdown outranks Fighting", a2:stateName() == "Lockdown")
	end

	----------------------------------------------------------------------------------------------- determinism
	do
		local function sig()
			local al, bots, pr, l, run = live({ { Class = "Sec", X = 20 }, { Class = "Sec", X = 20, Z = 6, Profile = "LeadSecurity" } })
			al:addAnomaly("Radio", 45, 0, 0)
			pr:setDisguise("p1", "Chef")
			pr:move("p1", 30, 0, 0)
			run(25)
			local out = {}
			local idx = {} for i, b in ipairs(bots:all()) do idx[b.Id] = i end
			for _, e in ipairs(al:drainEvents()) do out[#out + 1] = e.Kind .. "@" .. ("%.2f"):format(e.Time) .. ":" .. tostring(idx[e.Bot]) .. ":" .. tostring(e.Level) end
			return table.concat(out, "|")
		end
		local a, b = sig(), sig()
		check("determinism: two runs give identical alert events", a == b and #a > 0)
	end

	----------------------------------------------------------------------------------------------- real maps
	local okE, emb = pcall(require, "./_embedded")
	if not okE then
		print("(real-map alert tests skipped: tests/_embedded.luau not found)")
		return
	end
	local Codec = require("../BreachCodec")
	local Zstd = require("../BreachZstd")
	local Mission = require("../BreachMission")
	local Validator = require("../BreachValidator")
	local World = require("../BreachWorld")
	local Setup = require("../BreachSetup")
	local host = { zstdDecompress = Zstd.decompress }
	local okP, embP = pcall(require, "./_embedded_project")
	local maps = { { "TheDiplomat", emb["TheDiplomat.base64"] }, { "thepeacemaker", emb["thepeacemaker.txt"] } }
	if okP then maps[#maps + 1] = { "TheProject", embP["theproject.txt"] } end

	for _, entry in ipairs(maps) do
		local label = entry[1]
		local d = Codec.decode(entry[2], host)
		local mis = Mission.build(d, { validator = Validator })
		local w = World.build(mis)
		local setup = Setup.parse(d.SetupSource)
		local function make(params)
			local l = Logic.new(mis, { seed = 416, builtins = { Mission_Difficulty = 3 } })
			local nav = Nav.new({ pathfinder = Nav.worldAdapter(w) })
			local bots = Bots.new(mis, w, l, nav, { seed = 416 })
			local props = Props.new(mis, w, l)
			local sight = Sight.new(w, bots, Sight.propsPlayers(props), { blocked = function(...) return props:sightBlocked(...) end })
			local tr = Trespass.new(w, setup, l)
			tr:attach(sight, bots, Sight.propsPlayers(props))
			local al = Alert.new(l, { mission = mis, bots = bots, sight = sight, trespass = tr, players = Sight.propsPlayers(props), world = w, params = params })
			local function run(seconds) for _ = 1, math.floor(seconds / DT + 0.5) do l:advance(DT) bots:step(DT) sight:step(DT) tr:step(DT) al:step(DT) end end
			return al, l, bots, props, tr, run
		end
		local al, l, bots, props, tr, run = make()
		run(1)
		check(label .. " [alert]: at the start the level is 0 and Mission_AlarmRaised is 0 (no AlertRaiseCondition fires on its own)", al:level() == 0 and l:get("Mission_AlarmRaised") == 0, al:level())
		check(label .. " [alert]: " .. #al.Conditions .. " AlertRaiseCondition component(s) read, none disabled ones, no errors", #al.Errors == 0 and #l.Errors == 0, al.Errors[1] or l.Errors[1])
		print(("  %s: %d AlertRaiseCondition components, %d bots"):format(label, #al.Conditions, #bots:all()))

		local function fire(var, expectLevel, expectReason)
			local a2, l2, _, _, _, run2 = make()
			run2(0.5)
			l2:set(var, 1)
			run2(0.1)
			local ev = kinds(a2:drainEvents(), "AlertRaised")
			check(label .. " [alert]: setting " .. var .. " raises the alert to " .. expectLevel, a2:level() == expectLevel and #ev >= 1, a2:level())
			if expectReason and ev[1] then check(label .. " [alert]: ... with Reason " .. expectReason, ev[1].Reason == expectReason, ev[1].Reason) end
			return a2, l2
		end
		local function sim(secs, f)
			local a2, l2, _, _, _, run2 = make()
			f(a2, l2)
			run2(secs)
			return a2, l2
		end
		if label == "TheDiplomat" then
			local a2 = sim(130, function(a, l) l:set("Mission_AlertLevel", 2) end)
			check(label .. " [alert]: its StandardRadioAlertReduction lowers a level-2 alert to Calm after ~2 minutes", a2:level() == 0, a2:level())
			local a3, l3 = sim(130, function(a, l) a:lockdown("x") end)
			check(label .. " [alert]: ... but not once the alarm is raised", a3:level() == 3 and l3:get("Mission_AlarmRaised") == 1)
		end
		if label == "thepeacemaker" then
			local a2 = sim(0.2, function(a, l) a:raise(2, "x", 2, 2) l:set("AlertLevelReduced", 1) end)
			check(label .. " [alert]: the bluff (AlertLevelReduced) lowers Alert 2 to 1 through the real AlertLowerCondition", a2:level() == 1, a2:level())
			local a3 = sim(0.2, function(a, l) a:raise(2, "x", 2, 2) l:set("AlertLevelReset", 1) end)
			check(label .. " [alert]: AlertLevelReset calms it", a3:level() == 0, a3:level())
			local a4 = sim(130, function(a, l) a:raise(2, "x", 2, 2) end)
			check(label .. " [alert]: it has no StandardRadioAlertReduction, so it does not decay by itself", a4:level() == 2, a4:level())
		end
		if label == "TheDiplomat" then
			check(label .. " [alert]: the component under Disabled/ is not read (3 active)", #al.Conditions == 3, #al.Conditions)
			local a2, l2, _, _, _, run2 = make()
			l2:set("DiplomatFled", 1) -- belongs to the component under Disabled/: must do nothing
			run2(0.2)
			check(label .. " [alert]: DiplomatFled belongs to the disabled component, so it does nothing", a2:level() == 0, a2:level())
			local a3, l3 = fire("PanicRoomTrigger", 3, "Notify.JessicaTriggeredPanicRoom")
			check(label .. " [alert]: ... and the lockdown publishes Mission_AlarmRaised = 1", l3:get("Mission_AlarmRaised") == 1)
		elseif label == "thepeacemaker" then
			fire("CenterEscaping", 2, nil)
			fire("CenterEscapeOpenedAlarm", 1, "Notify.AlarmedDoorOpened")
			local a2, l2 = make()
			l2:set("CenterEscaping", 1)
			l2:set("CenterEscapeOpenedAlarm", 1)
			check(label .. " [alert]: (1,1,1) after a (2,2,2) never lowers the level", a2:level() == 2, a2:level())
		else
			fire("PowerBox3", 3, nil)
			fire("SearchStarted", 2, "Notify.MissingGuardsNoticed")
		end

		-- a real static guard that enforces its own cell
		local found
		for _, b in ipairs(bots:all()) do
			if b.Timer == math.huge and not found then
				local x, y, z = bots:position(b.Id)
				local cell = x and w:cellAt(x, y, z)
				if cell then
					local status, _, rules = tr:status("None", cell)
					if status ~= "allowed" and tr:enforces(b.Class, status, rules) then found = { Bot = b, Status = status } end
				end
			end
		end
		if found then
			local a2, l2, bots2, props2, tr2, run2 = make()
			local bot = bots2:all()[1]
			for _, b in ipairs(bots2:all()) do if b.Id == found.Bot.Id then bot = b end end
			local bx, by, bz = bots2:position(bot.Id)
			local fx, fz = bots2:facing(bot)
			props2:addPlayer("p1", bx + fx * 8, by, bz + fz * 8)
			run2(30)
			local evs = a2:drainEvents()
			if found.Status == "major" then
				check(label .. " [alert]: a real guard that enforces its cell sees an undisguised player in it: it radios, lockdown (" .. bot.Id .. ")", a2:level() == 3 and #kinds(evs, "BotRadioStarted") >= 1, "level " .. a2:level())
			else
				check(label .. " [alert]: a real guard that enforces a MINOR trespass in its cell asks the player", #kinds(evs, "QuestionAsked") >= 1, "events " .. #evs)
			end
			print(("  %s: real %s-trespass guard %s -> level %d after 30 s"):format(label, found.Status, tostring(bot.Class), a2:level()))
		end

		-- determinism on a real map
		local function sig()
			local a2, l2, b2, p2, _, run2 = make()
			for _, b in ipairs(b2:all()) do if b.Timer == math.huge then local x, y, z = b2:position(b.Id) local fx, fz = b2:facing(b) p2:addPlayer("p1", x + fx * 8, y, z + fz * 8) break end end
			run2(20)
			local idx = {} for i, b in ipairs(b2:all()) do idx[b.Id] = i end
			local out = {}
			for _, e in ipairs(a2:drainEvents()) do out[#out + 1] = e.Kind .. "@" .. ("%.2f"):format(e.Time) .. ":" .. tostring(idx[e.Bot]) end
			return table.concat(out, "|")
		end
		check(label .. " [alert]: two seeded runs give identical alert events", sig() == sig())
	end
end
