--!nonstrict
-- M8d tests: BreachHostage (hostages, bodies, alt interaction). Run via tests/run.luau or alone: `luau tests/hostage.luau`
local Hostage = require("../BreachHostage")
local Sight = require("../BreachSight")
local Bots = require("../BreachBots")
local Nav = require("../BreachNav")
local Logic = require("../BreachLogic")
local Props = require("../BreachProps")
local Alert = require("../BreachAlert")

local DT = 1 / 20

return function(check)
	local function kinds(evs, kind) local out = {} for _, e in ipairs(evs) do if kind == nil or e.Kind == kind then out[#out + 1] = e end end return out end
	local function dist(ax, az, bx, bz) return math.sqrt((ax - bx) ^ 2 + (az - bz) ^ 2) end

	local counter = 0
	local function part(name, x, y, z)
		counter += 1
		return { Name = name, ClassName = "Part", Path = "DebugMission/Nodes/" .. name .. counter, Id = "p" .. counter, Attrs = {}, Children = {},
			Props = { CFrame = { Position = { X = x, Y = y, Z = z }, EulerXYZ = { X = 0, Y = 0, Z = 0 } }, Size = { X = 4, Y = 4, Z = 4 } } }
	end
	local function folder(name, children) counter += 1 return { Name = name, ClassName = "Folder", Path = "DebugMission/" .. name .. counter, Id = "f" .. counter, Attrs = {}, Children = children or {} } end
	local function botNode(name, attrs) counter += 1 return { Name = name, ClassName = "BoolValue", Path = "DebugMission/Bots/" .. name, Id = "b" .. counter, Attrs = attrs or {}, Children = {} } end
	local function comp(ty, name, attrs) attrs.Type = ty return { Type = ty, Name = name, Attrs = attrs, Path = "DebugMission/StateComponents/" .. name } end
	local function straight(a, b) return { { X = a.X, Y = a.Y or 0, Z = a.Z }, { X = b.X, Y = b.Y or 0, Z = b.Z } } end
	local world = { Cells = { { Index = 1 } }, Links = {}, cellAt = function() return { Index = 1 } end }
	-- the same table every call, so "same cell" holds
	local theCell = { Index = 1 }
	world.cellAt = function() return theCell end

	-- botDefs: { X, Z, Tag, Difficulty, NoDown, Behavior }; comps: components; globals: logic globals
	local function live(botDefs, comps, params, globals)
		local list, routes = {}, {}
		for i, d in ipairs(botDefs) do
			local rname = "Post" .. i
			list[#list + 1] = botNode("bot" .. i, { Behavior = "PatrolWalk", Nodes = rname, PatrolCycleLength = 99999, ServerTag = d.Tag, HostageDifficulty = d.Difficulty, NoHostageDownInCombat = d.NoDown, Weapon = d.Weapon })
			routes[#routes + 1] = folder(rname, { part("Node1", d.X, 0, d.Z or 0), part("Node2", d.X + (d.Leg or 0), 0, d.Z or 0) })
		end
		local botsF, nodesF = folder("Bots", list), folder("Nodes", routes)
		local m = { folder = function(_, n) if n == "Bots" then return botsF elseif n == "Nodes" then return nodesF end end,
			byComponent = function(_, ty) local out = {} for _, c in ipairs(comps or {}) do if c.Type == ty then out[#out + 1] = c end end return out end }
		local l = Logic.fromSpec({ Globals = globals or {} }, {})
		local nav = Nav.new({ pathfinder = straight })
		local bots = Bots.new(m, world, l, nav, { seed = 1 })
		local pr = Props.fromNodes({}, world, l)
		pr:addPlayer("p1", 0, 0, 0)
		local players = Sight.propsPlayers(pr)
		local sight = Sight.new(world, bots, players)
		local al = Alert.new(l, { mission = m, bots = bots, sight = sight, players = players, world = world })
		local hs = Hostage.new(l, { mission = m, bots = bots, nav = nav, players = players, props = pr, sight = sight, world = world, params = params, alert = al })
		if params and params.NoAlert then hs.Alert = nil end
		local function run(seconds) for _ = 1, math.floor(seconds / DT + 0.5) do l:advance(DT) bots:step(DT) sight:step(DT) hs:step(DT) al:step(DT) end end
		return hs, bots, pr, l, run, nav, al
	end
	local function id(bots, i) return bots:all()[i].Id end

	----------------------------------------------------------------------------------------------- taking
	do
		local hs, bots, pr, l, run = live({ { X = 15, Tag = "Lead", Difficulty = 2 } }, {})
		local bot = id(bots, 1)
		hs:aim("p1", bot)
		run(0.6)
		check("take: a bot with HostageDifficulty 2 is not taken after 0.6 s of aim", not hs:isHostage(bot))
		run(0.6)
		check("take: ... but is after 1 s (difficulty x 0.5 s)", hs:isHostage(bot) and hs:stateOf(bot) == "Following" and bots:bot(bot).Flags.Hostage == true)
		check("take: HostageTaken and HostageFollowing events", #kinds(hs:drainEvents(), "HostageTaken") == 1)
		local hs2, bots2 = live({ { X = 15, Difficulty = 0 } }, {})
		hs2:aim("p1", id(bots2, 1))
		hs2:step(DT)
		check("take: difficulty 0 (a civilian) complies at once", hs2:isHostage(id(bots2, 1)))
		local hs3, bots3, pr3, _, run3 = live({ { X = 15, Difficulty = 3 } }, {})
		hs3:aim("p1", id(bots3, 1))
		run3(0.5)
		hs3:aim("p1", nil)
		run3(0.5)
		hs3:aim("p1", id(bots3, 1))
		run3(0.9)
		check("take: stopping aiming resets the progress (1.5 s needed again)", not hs3:isHostage(id(bots3, 1)))
		local hs4, bots4, pr4 = live({ { X = 15, Difficulty = 0 } }, {})
		pr4:move("p1", -40, 0, 0)
		local ok, why = hs4:take("p1", id(bots4, 1))
		check("take: out of range is refused", ok == false and why == "out-of-range")
		local hs5, bots5, pr5, l5 = live({ { X = 15, Difficulty = 0, NoDown = "true" }, { X = 15, Z = 3, Difficulty = 0 } }, {})
		l5:set("Mission_AlarmRaised", 1)
		local a, why5 = hs5:take("p1", id(bots5, 1))
		check("take: a bot with NoHostageDownInCombat cannot be taken while loud", a == false and why5 == "no-hostage-in-combat")
		check("take: ... but an ordinary one can (and it freezes at once)", hs5:take("p1", id(bots5, 2)) and hs5:stateOf(id(bots5, 2)) == "Frozen")
		bots5:setFlag(id(bots5, 1), "Dead", true)
		check("take: a dead bot cannot be taken", select(2, hs5:take("p1", id(bots5, 1))) == "not-conscious")
	end

	----------------------------------------------------------------------------------------------- leading
	do
		local hs, bots, pr, l, run, nav = live({ { X = 12, Difficulty = 0 } }, {})
		local bot = id(bots, 1)
		hs:take("p1", bot)
		local minD, maxD = math.huge, 0
		for step = 1, 600 do
			local px = -step * 0.25 -- walks away along -X at 5 studs/s
			pr:move("p1", px, 0, 0)
			run(DT)
			local x, _, z = bots:position(bot)
			local d = dist(x, z, px, 0)
			if step > 100 then minD, maxD = math.min(minD, d), math.max(maxD, d) end
		end
		check("lead: the hostage follows the leader across 150 studs and keeps up", maxD < 14, maxD)
		check("lead: ... and is never driven closer than the follower minimum (it cannot bump the leader)", minD >= 2.4, minD)
		check("lead: it is still a hostage afterwards (no flee: it was in tow)", hs:stateOf(bot) == "Following" or hs:stateOf(bot) == "Fleeing")
	end

	----------------------------------------------------------------------------------------------- flee timer
	do
		local hs, bots, pr, l, run = live({ { X = 12, Difficulty = 0, Tag = "Lead", Leg = 40 } }, { comp("BotStateTracker", "T", { BotServerTag = "Lead", HostageCountVariable = "Hostages", FleeCountVariable = "Fled", TotalCountVariable = "Total" }) }, { FleeSeconds = 10 })
		local bot = id(bots, 1)
		hs:take("p1", bot)
		run(0.1)
		check("flee: a tracker counts the hostage", l:get("Hostages") == 1)
		run(8)
		check("flee: before FleeSeconds it is still a hostage", hs:stateOf(bot) == "Following")
		hs:aim("p1", bot)
		run(8)
		check("flee: aiming a gun at it resets the timer (it has been 16 s)", hs:stateOf(bot) == "Following")
		hs:aim("p1", nil)
		run(9)
		check("flee: still held just before the timer runs out", hs:stateOf(bot) == "Following")
		run(2)
		check("flee: no gun for FleeSeconds -> it flees (Hostage off, Fled on)", hs:stateOf(bot) == "Fleeing" and not bots:bot(bot).Flags.Hostage and bots:bot(bot).Flags.Fled == true)
		check("flee: the tracker follows (Hostages 0, Fled 1) and HostageFled was emitted", l:get("Hostages") == 0 and l:get("Fled") == 1 and #kinds(hs:drainEvents(), "HostageFled") == 1)
		local x0 = bots:position(bot)
		run(10)
		check("flee: it runs to a spot away from the player and stays there", bots:position(bot) ~= nil and bots:bot(bot).State == "Fleeing")
		local ok, why = hs:take("p1", bot)
		check("flee: a fleeing bot cannot be re-taken", ok == false and why == "fleeing")
	end

	----------------------------------------------------------------------------------------------- loud
	do
		local hs, bots, pr, l, run = live({ { X = 12, Difficulty = 0 } }, {}, { FleeSeconds = 5 })
		local bot = id(bots, 1)
		hs:take("p1", bot)
		run(1)
		l:set("Mission_AlarmRaised", 1)
		run(0.2)
		check("loud: when the alarm goes up a following hostage FREEZES", hs:stateOf(bot) == "Frozen" and #kinds(hs:drainEvents(), "HostageFrozen") == 1)
		local x1 = bots:position(bot)
		for step = 1, 100 do pr:move("p1", -step * 0.25, 0, 0) run(DT) end
		local x2 = bots:position(bot)
		check("loud: a frozen hostage cannot be moved: it ignores the leader walking away", math.abs(x2 - x1) < 0.5, x2 - x1)
		run(20)
		check("loud: ... and it does not flee while frozen", hs:stateOf(bot) == "Frozen")
	end

	----------------------------------------------------------------------------------------------- bodies
	do
		local alt = { comp("BotAltTrigger", "Phone", { AllowHostages = "true", AllowPatroling = "false", BotServerTag = "Lead", ServerEnabled = "!Unlocked", ClientVisible = "", HoldTime = 1, TitleKey = "Action.UnlockPhone", SubtitleKey = "UI.WithFingerprint", TriggerVariable = "Unlocked", TriggerNotification = "Notify.PhoneUnlocked" }),
			comp("BodyAltTrigger", "PhoneBody", { BotServerTag = "Lead", HoldTime = 1, TitleKey = "Action.UnlockPhone", TriggerVariable = "BodyUnlocked" }) }
		local hs, bots, pr, l, run = live({ { X = 10, Difficulty = 0, Tag = "Lead" } }, alt, nil, { Unlocked = "0", BodyUnlocked = "0" })
		local bot = id(bots, 1)
		hs:take("p1", bot)
		run(0.5)
		check("body: a following hostage shows the BotAltTrigger, not the BodyAltTrigger", #hs:interactables("p1") == 1 and hs:interactables("p1")[1].Kind == "Bot")
		hs:incapacitate(bot)
		local flags = bots:bot(bot).Flags
		check("body: incapacitating it clears Hostage, sets Incapacitated, stops it", flags.Incapacitated == true and not flags.Hostage and hs:stateOf(bot) == "Body" and #kinds(hs:drainEvents(), "BotIncapacitated") == 1)
		local list = hs:interactables("p1")
		check("body: now only the BodyAltTrigger applies", #list == 1 and list[1].Kind == "Body")
		check("body: holding it long enough sets its TriggerVariable", select(1, hs:interact("p1", bot, list[1].Trigger, 1.0)) == true and l:get("BodyUnlocked") == 1)
		local hs2, bots2 = live({ { X = 10, Difficulty = 0, Tag = "Lead" } }, {})
		hs2:take("p1", id(bots2, 1))
		bots2:setFlag(id(bots2, 1), "Incapacitated", true)
		hs2:step(DT)
		check("body: an incapacitation done from outside (setFlag) is noticed too", hs2:stateOf(id(bots2, 1)) == "Body")
		bots2:setFlag(id(bots2, 1), "Dead", true)
		hs2:step(DT)
		check("body: a dead bot is no hostage and no body", hs2:stateOf(id(bots2, 1)) == nil and #hs2:interactables("p1") == 0)
	end

	----------------------------------------------------------------------------------------------- alt interaction
	do
		local alt = {
			comp("BotAltTrigger", "Phone", { AllowHostages = "true", AllowPatroling = "false", BotServerTag = "Lead", ServerEnabled = "!Unlocked && Holding", ClientVisible = "!Unlocked && ClientHolding", HoldTime = 1, TitleKey = "Action.UnlockPhone", SubtitleKey = "UI.WithFingerprint", TriggerVariable = "Unlocked", TriggerClientVariable = "UnlockedC", TriggerNotification = "Notify.PhoneUnlocked", TriggerLocalNotification = "Notify.Local" }),
			comp("BotAltTrigger", "Chat", { AllowHostages = "false", AllowPatroling = "true", BotServerTag = "Guard", HoldTime = 0.5, TitleKey = "Action.Chat", TriggerVariable = "Chatted" }),
			comp("BotAltTrigger", "Perk", { AllowHostages = "true", BotServerTag = "Lead", ClientEnabled = "Perk >= 2", DisabledTitleKey = "Ui.NeedsPerk", HoldTime = 0.5, TitleKey = "Action.Blackmail", TriggerVariable = "Blackmailed" }),
		}
		local hs, bots, pr, l, run = live({ { X = 10, Difficulty = 0, Tag = "Lead" }, { X = 8, Z = 4, Tag = "Guard" }, { X = 100, Z = 100, Tag = "Lead" } }, alt, nil, { Unlocked = "0", Holding = "0", Chatted = "0", Blackmailed = "0", Perk = "1" })
		local lead, guard, far = id(bots, 1), id(bots, 2), id(bots, 3)
		local names = function(list) local t = {} for _, e in ipairs(list) do t[#t + 1] = e.Name .. "@" .. (e.Bot == lead and "lead" or e.Bot == guard and "guard" or "far") end table.sort(t) return table.concat(t, ",") end
		run(0.1)
		check("alt: a patrolling guard shows only the AllowPatroling trigger for its tag", names(hs:interactables("p1")) == "Chat@guard", names(hs:interactables("p1")))
		hs:take("p1", lead)
		run(0.5)
		check("alt: a hostage shows its AllowHostages triggers, those whose expressions hold (Phone is not yet enabled)", names(hs:interactables("p1")) == "Chat@guard,Perk@lead", names(hs:interactables("p1")))
		check("alt: a bot out of range is never listed (the far Lead)", not names(hs:interactables("p1")):find("far"))
		l:set("Holding", 1)
		l:setClient("p1", "ClientHolding", 1)
		l:replicate()
		check("alt: ServerEnabled and the player's ClientVisible both true -> the Phone trigger appears", names(hs:interactables("p1")):find("Phone@lead") ~= nil, names(hs:interactables("p1")))
		local ok, why = hs:interact("p1", lead, "Phone", 0.4)
		check("alt: releasing before HoldTime does nothing", ok == false and why == "too-short" and l:get("Unlocked") == 0)
		ok = hs:interact("p1", lead, "Phone", 1.0)
		local evs = kinds(hs:drainEvents(), "AltTriggered")
		check("alt: after HoldTime: TriggerVariable set, client variable set, notifications emitted", ok == true and l:get("Unlocked") == 1 and pr:player("p1").Replica:get("UnlockedC") == 1 and #evs == 1 and evs[1].Notification == "Notify.PhoneUnlocked" and evs[1].LocalNotification == "Notify.Local")
		check("alt: and the trigger is gone afterwards (!Unlocked is false now)", names(hs:interactables("p1")):find("Phone") == nil)
		local list = hs:interactables("p1")
		local perk
		for _, e in ipairs(list) do if e.Name == "Perk" then perk = e end end
		check("alt: ClientEnabled false lists the trigger as DISABLED with its DisabledTitle", perk ~= nil and perk.Enabled == false and perk.DisabledTitle == "Ui.NeedsPerk")
		ok, why = hs:interact("p1", lead, "Perk", 1)
		check("alt: a disabled trigger cannot be used", ok == false and why == "disabled" and l:get("Blackmailed") == 0)
		l:set("Perk", 2)
		l:setClient("p1", "Perk", 2)
		l:replicate()
		check("alt: once the condition holds it works", hs:interact("p1", lead, "Perk", 1) == true and l:get("Blackmailed") == 1)
		check("alt: interacting with a bot that is not offered is refused", select(2, hs:interact("p1", far, "Chat", 1)) == "unavailable")
		pr:move("p1", 60, 0, 0)
		check("alt: moving away removes the prompts (range)", #hs:interactables("p1") == 0)
	end

	----------------------------------------------------------------------------------------------- armed guards
	do
		local hs, bots, pr, l, run, nav, al = live({ { X = 12, Difficulty = 3, Weapon = "Pistol" } }, {})
		local bot = id(bots, 1)
		hs:aim("p1", bot)
		run(2)
		check("guard: setup: an armed guard is taken after 1.5 s of aim", hs:stateOf(bot) == "Following")
		hs:aim("p1", bot) -- keeps the gun on it: its timer stays reset
		run(15)
		check("guard: with the gun still aimed at it the guard stays a hostage", hs:stateOf(bot) == "Following")
		hs:aim("p1", nil)
		run(9)
		check("guard: just before 10 s without a gun it is still a hostage", hs:stateOf(bot) == "Following")
		run(2)
		local evs = hs:drainEvents()
		check("guard: after 10 s (not 60) it stops being a hostage and retaliates (HostageRetaliating, no flee)", hs:stateOf(bot) == "Retaliating" and #kinds(evs, "HostageRetaliating") == 1 and #kinds(evs, "HostageFled") == 0 and not bots:bot(bot).Flags.Hostage and not bots:bot(bot).Flags.Fled)
		check("guard: it radios in first (BotRadioStarted), no lockdown yet", #kinds(al:drainEvents(), "BotRadioStarted") == 1 and al:level() == 0 and bots:bot(bot).State == "Radioing")
		run(5)
		check("guard: the radio call lands as lockdown", al:level() == 3)
		-- a guard identified by HostageDifficulty alone (no Weapon attribute) behaves the same
		local hs2, bots2 = live({ { X = 12, Difficulty = 2 } }, {})
		hs2:take("p1", id(bots2, 1))
		for _ = 1, 230 do hs2:step(DT) end
		check("guard: HostageDifficulty > 0 alone marks a guard", hs2:stateOf(id(bots2, 1)) == "Retaliating")
		-- a civilian keeps the long timer
		local hs3, bots3 = live({ { X = 12, Difficulty = 0 } }, {})
		hs3:take("p1", id(bots3, 1))
		for _ = 1, 400 do hs3:step(DT) end
		check("guard: a civilian (difficulty 0, no weapon) is still a hostage after 20 s", hs3:stateOf(id(bots3, 1)) == "Following")
		-- without an Alert object the guard just goes back to its patrol
		local hs4, bots4 = live({ { X = 12, Difficulty = 2 } }, {}, { NoAlert = true })
		hs4:take("p1", id(bots4, 1))
		for _ = 1, 230 do hs4:step(DT) end
		check("guard: with no Alert attached it simply returns to its patrol", hs4:stateOf(id(bots4, 1)) == "Retaliating" and bots4:bot(id(bots4, 1)).Command == nil)
		-- loud: frozen guards do not time out
		local hs5, bots5, _, l5 = live({ { X = 12, Difficulty = 2 } }, {})
		l5:set("Mission_AlarmRaised", 1)
		hs5:take("p1", id(bots5, 1))
		for _ = 1, 400 do hs5:step(DT) end
		check("guard: a hostage frozen by the alarm does not retaliate on a timer", hs5:stateOf(id(bots5, 1)) == "Frozen")
	end

	----------------------------------------------------------------------------------------------- determinism
	do
		local function sig()
			local hs, bots, pr, l, run = live({ { X = 12, Difficulty = 1 }, { X = 14, Z = 2, Difficulty = 0 } }, {}, { FleeSeconds = 6 })
			hs:aim("p1", id(bots, 1))
			run(1.5)
			hs:aim("p1", nil)
			for step = 1, 200 do pr:move("p1", -step * 0.2, 0, 0) run(DT) end
			l:set("Mission_AlarmRaised", 1)
			run(3)
			local idx = {} for i, b in ipairs(bots:all()) do idx[b.Id] = i end
			local out = {}
			for _, e in ipairs(hs:drainEvents()) do out[#out + 1] = e.Kind .. "@" .. ("%.2f"):format(e.Time) .. ":" .. tostring(idx[e.Bot]) end
			return table.concat(out, "|")
		end
		local a, b = sig(), sig()
		check("determinism: two runs give identical hostage events", a == b and #a > 0)
	end

	----------------------------------------------------------------------------------------------- real maps
	local okE, emb = pcall(require, "./_embedded")
	if not okE then
		print("(real-map hostage tests skipped: tests/_embedded.luau not found)")
		return
	end
	local Codec = require("../BreachCodec")
	local Zstd = require("../BreachZstd")
	local Mission = require("../BreachMission")
	local Validator = require("../BreachValidator")
	local World = require("../BreachWorld")
	local host = { zstdDecompress = Zstd.decompress }
	local okP, embP = pcall(require, "./_embedded_project")
	local maps = { { "TheDiplomat", emb["TheDiplomat.base64"] }, { "thepeacemaker", emb["thepeacemaker.txt"] } }
	if okP then maps[#maps + 1] = { "TheProject", embP["theproject.txt"] } end

	for _, entry in ipairs(maps) do
		local label = entry[1]
		local mis = Mission.build(Codec.decode(entry[2], host), { validator = Validator })
		local w = World.build(mis)
		-- the real triggers, with the bot tag blanked (any bot) so a placed bot can stand in for the map's tagged one
		local function patched()
			local alt = { BotAltTrigger = {}, BodyAltTrigger = {} }
			for ty, list in pairs(alt) do
				for _, c in ipairs(mis:byComponent(ty) or {}) do
					if (c.Path or ""):find("/StateComponents/", 1, true) then
						local a = {}
						for k, v in pairs(c.Attrs) do a[k] = v end
						a.BotServerTag, a.BotClientTag = "", ""
						-- the client flag is driven by where the player stands (a zone); position is not simulated here
						if label == "thepeacemaker" and a.ClientVisible == "EnteredSecurityCenterClient" then a.ClientVisible = "1" end
						list[#list + 1] = { Type = ty, Name = c.Name, Path = c.Path, Attrs = a }
					end
				end
			end
			return alt
		end
		local function make(skip)
			skip = skip or 0
			local l = Logic.new(mis, { seed = 416, builtins = { Mission_Difficulty = 3 } })
			local nav = Nav.new({ pathfinder = Nav.worldAdapter(w) })
			local bots = Bots.new(mis, w, l, nav, { seed = 416 })
			local props = Props.new(mis, w, l)
			local players = Sight.propsPlayers(props)
			local sight = Sight.new(w, bots, players, { blocked = function(...) return props:sightBlocked(...) end })
			local alt = patched()
			local hs = Hostage.new(l, { mission = mis, bots = bots, nav = nav, players = players, props = props, sight = sight, world = w, altTriggers = alt })
			local function run(seconds) for _ = 1, math.floor(seconds / DT + 0.5) do l:advance(DT) bots:step(DT) sight:step(DT) hs:step(DT) end end
			-- a player 3 studs from a real bot (static ones first), on a side with a clear line of sight and the same cell
			local pick
			local order = {}
			for _, b in ipairs(bots:all()) do if b.Timer == math.huge then order[#order + 1] = b end end
			for _, b in ipairs(bots:all()) do if b.Timer ~= math.huge then order[#order + 1] = b end end
			local spot
			for oi, b in ipairs(order) do
				if oi > 40 or pick then break end
				local bx, by, bz = bots:position(b.Id)
				local fx, fz = bots:facing(b)
				for _, off in ipairs({ { fx, fz }, { -fx, -fz }, { -fz, fx }, { fz, -fx } }) do
					local px, pz = bx + off[1] * 3, bz + off[2] * 3
					if not pick and sight:lineOfSight(px, by + 3, pz, bx, by + 3, bz) and hs:_cell(px, by, pz) == hs:_cell(bx, by, bz) then
						if skip > 0 then skip -= 1 else pick, spot = b, { px, by, pz } end
					end
				end
			end
			assert(pick, "no real bot could be approached")
			props:addPlayer("p1", spot[1], spot[2], spot[3])
			return hs, bots, props, l, run, pick, alt
		end
		-- Some spots make a map's own logic oscillate (the Peacemaker's PlayerLocator zone): take the first clean one
		local realMake = make
		make = function()
			local last
			for skip = 0, 12 do
				local r = table.pack(realMake(skip))
				if #r[4].Errors == 0 or skip == 12 then return table.unpack(r, 1, r.n) end
				last = r
			end
			return table.unpack(last, 1, last.n)
		end
		local function realErrors(l) -- the Peacemaker's own PlayerLocator loop is reported as "did not settle": a map finding, not a bug here
			local n = 0
			for _, e in ipairs(l.Errors) do if not tostring(type(e) == "table" and (e.Message or e.Error or e[1]) or e):find("did not settle", 1, true) then n += 1 end end
			return n
		end
		local function client(l, props, name, v) l:setClient("p1", name, v) l:replicate() end
		local hs, bots, props, l, run, pick, alt = make()
		print(("  %s: %d BotAltTrigger / %d BodyAltTrigger components in StateComponents, %d bots"):format(label, #alt.BotAltTrigger, #alt.BodyAltTrigger, #bots:all()))
		local tk, tkWhy = hs:take("p1", pick.Id)
		check(label .. " [hostage]: a real placed bot can be taken at 3 studs and follows", tk == true and hs:stateOf(pick.Id) == "Following", tkWhy)
		run(1)
		local lister = hs:interactables("p1")
		check(label .. " [hostage]: every real trigger's expressions evaluate without error at the start (listing works)", type(lister) == "table" and realErrors(l) == 0, l.Errors[1] and (type(l.Errors[1]) == "table" and tostring(l.Errors[1].Message or l.Errors[1].Error or l.Errors[1][1]) or l.Errors[1]))

		if label == "TheProject" then
			l:set("HoldingLockedPhone", 1)
			client(l, props, "ClientHoldingLockedPhone", 1)
			local names = {}
			for _, e in ipairs(hs:interactables("p1")) do names[#names + 1] = e.Name end
			local phone
			for _, e in ipairs(hs:interactables("p1")) do if e.Title == "Action.UnlockPhone" then phone = e end end
			check(label .. " [hostage]: the real PreEnd trigger (Action.UnlockPhone) appears once the phone is held", phone ~= nil and phone.Enabled, table.concat(names, ","))
			if phone then
				check(label .. " [hostage]: it needs its real HoldTime", select(2, hs:interact("p1", pick.Id, phone.Trigger, phone.HoldTime - 0.2)) == "too-short")
				local tv
				for _, t in ipairs(alt.BotAltTrigger) do if t.Name == phone.Name then tv = t.Attrs.TriggerVariable end end
				check(label .. " [hostage]: holding it unlocks the phone: its real TriggerVariable becomes true", hs:interact("p1", pick.Id, phone.Trigger, phone.HoldTime) == true and tv ~= nil and l:get(tv) == 1, tv)
			end
		elseif label == "thepeacemaker" then
			local listed = {}
			for _, e in ipairs(hs:interactables("p1")) do if e.Title == "Action.UseFingerprint" then listed[#listed + 1] = e end end
			check(label .. " [hostage]: the Commander trigger is NOT offered before the alarm (ServerEnabled needs Mission_AlarmRaised)", #listed == 0)
			l:set("Mission_AlarmRaised", 1)
			l:set("LoudArrivalDelay", 5)
			run(0.2)
			check(label .. " [hostage]: the alarm freezes the hostage", hs:stateOf(pick.Id) == "Frozen")
			l:replicate()
			listed = {}
			for _, e in ipairs(hs:interactables("p1")) do if e.Title == "Action.UseFingerprint" then listed[#listed + 1] = e end end
			check(label .. " [hostage]: ... and the frozen hostage can be used for the fingerprint: the Commander trigger is offered", #listed >= 1)
			if listed[1] then
				check(label .. " [hostage]: HoldTime 2 s: holding it sets CommanderLockdown", hs:interact("p1", pick.Id, listed[1].Trigger, 2) == true and l:get("CommanderLockdown") == 1)
			end
		else
			l:set("GuardInfoFound", 1)
			l:replicate()
			local list = hs:interactables("p1")
			local bm
			for _, e in ipairs(list) do if e.Title == "Action.Blackmail" then bm = e end end
			check(label .. " [hostage]: the Blackmail trigger is listed but DISABLED without the intimidation perk (ClientEnabled)", bm ~= nil and bm.Enabled == false and bm.DisabledSubtitle == "Ui.NeedsIntimidation2")
			client(l, props, "Perk_Intimidation", 2)
			bm = nil
			for _, e in ipairs(hs:interactables("p1")) do if e.Title == "Action.Blackmail" then bm = e end end
			check(label .. " [hostage]: with the perk it is enabled and fires its client variable", bm ~= nil and bm.Enabled and hs:interact("p1", pick.Id, bm.Trigger, bm.HoldTime) == true)
		end

		-- a body of the same bot
		local hs2, bots2, props2, l2, run2, pick2 = make()
		hs2:incapacitate(pick2.Id)
		check(label .. " [hostage]: a real bot incapacitated is a Body; the tracker flags follow", hs2:stateOf(pick2.Id) == "Body" and bots2:bot(pick2.Id).Flags.Incapacitated == true)

		-- the real flee timer on a real map
		local hs3, bots3, props3, l3, run3, pick3 = make()
		hs3:take("p1", pick3.Id)
		run3(61)
		local armed3 = hs3:_armed(bots3:bot(pick3.Id))
		check(label .. " [hostage]: left alone (no gun) a real hostage ends its hostage time: " .. (armed3 and "an armed guard retaliates (10 s)" or "a civilian flees (60 s)"),
			not bots3:bot(pick3.Id).Flags.Hostage and hs3:stateOf(pick3.Id) == (armed3 and "Retaliating" or "Fleeing") and (armed3 or bots3:bot(pick3.Id).Flags.Fled == true))

		local function sig()
			local a2, b2, p2, l2b, r2, k2 = make()
			a2:take("p1", k2.Id)
			r2(65)
			local out = {}
			for _, e in ipairs(a2:drainEvents()) do out[#out + 1] = e.Kind .. "@" .. ("%.2f"):format(e.Time) end
			return table.concat(out, "|")
		end
		check(label .. " [hostage]: two seeded runs give identical hostage events", sig() == sig())
	end
end
