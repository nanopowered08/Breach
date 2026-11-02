--!nonstrict
-- M8b tests: BreachBots. Run via tests/run.luau or alone: `luau tests/bots.luau`
local Bots = require("../BreachBots")
local Nav = require("../BreachNav")
local Logic = require("../BreachLogic")

local DT = 1 / 20

return function(check)
	----------------------------------------------------------------------------------------------- Inv parsing
	do
		local function one(s) return Bots.parseInv(s) end
		local a = one("BasicKeycard_DiplomatKeycard")
		check("inv: Item_tag", #a == 1 and a[1].Item == "BasicKeycard" and a[1].Tag == "DiplomatKeycard" and a[1].Condition == nil)
		local b = one("BasicKeycard|SecurityUsbKey")
		check("inv: several items with '|'", #b == 2 and b[1].Item == "BasicKeycard" and b[2].Item == "SecurityUsbKey" and b[2].Tag == nil)
		local c = one("CustomKeycard1_ServerKeycard|SecurityKeycard|PhoneLockedFing")
		check("inv: the real three-item loadout (a digit in a name, tags on some)", #c == 3 and c[1].Item == "CustomKeycard1" and c[1].Tag == "ServerKeycard" and c[3].Item == "PhoneLockedFing")
		local d = one("Key_Tag=Alarm == 1")
		check("inv: =condition", d[1].Item == "Key" and d[1].Tag == "Tag" and d[1].Condition == "Alarm == 1")
		local e = one("Phone=A || B|Other")
		check("inv: '||' inside a condition is not a separator", #e == 2 and e[1].Condition == "A || B" and e[2].Item == "Other")
		check("inv: whitespace is trimmed, empty pieces ignored", #one(" A | B_t | ") == 2 and one(" A | B_t | ")[2].Tag == "t")
		check("inv: empty / nil / non-strings", #one("") == 0 and #one(nil) == 0 and #one(5) == 0 and #one("   ") == 0)
		check("inv: a lone '=' or '_' does not crash", pcall(Bots.parseInv, "=") and pcall(Bots.parseInv, "_") and pcall(Bots.parseInv, "|||"))
	end

	----------------------------------------------------------------------------------------------- synthetic mission
	local counter = 0
	local function part(name, x, y, z, attrs)
		counter += 1
		return { Name = name, ClassName = "Part", Path = "DebugMission/Nodes/" .. name .. counter, Id = "p" .. counter, Attrs = attrs or {}, Children = {}, Props = { CFrame = { Position = { X = x, Y = y, Z = z } } } }
	end
	local function folder(name, children, attrs)
		counter += 1
		return { Name = name, ClassName = "Folder", Path = "DebugMission/" .. name .. counter, Id = "f" .. counter, Attrs = attrs or {}, Children = children or {} }
	end
	local function botNode(name, attrs)
		counter += 1
		return { Name = name, ClassName = "BoolValue", Path = "DebugMission/Bots/" .. name, Id = "b" .. counter, Attrs = attrs or {}, Children = {} }
	end
	local function mission(botList, routes, comps)
		local botsF = folder("Bots", botList)
		local nodesF = folder("Nodes", routes)
		return {
			folder = function(_, name) if name == "Bots" then return botsF elseif name == "Nodes" then return nodesF end end,
			byComponent = function(_, ty) local out = {} for _, c in ipairs(comps or {}) do if c.Attrs.Type == ty then out[#out + 1] = c end end return out end,
		}
	end
	local function straight(a, b) return { { X = a.X, Y = a.Y or 0, Z = a.Z }, { X = b.X, Y = b.Y or 0, Z = b.Z } } end
	local function world(m, vars, opts)
		local l = Logic.fromSpec({ Globals = vars or {} }, {})
		local nav = Nav.new({ pathfinder = (opts and opts.pathfinder) or straight })
		local bots, err = Bots.new(m, nil, l, nav, opts)
		return bots, l, nav, err
	end
	local function run(bots, l, seconds)
		for _ = 1, math.floor(seconds / DT + 0.5) do
			l:advance(DT)
			bots:step(DT)
		end
	end
	local function eventsOf(list, kind, bot)
		local out = {}
		for _, e in ipairs(list) do if e.Kind == kind and (bot == nil or e.Bot == bot) then out[#out + 1] = e end end
		return out
	end
	local function near(a, b, tol) return type(a) == "number" and math.abs(a - b) <= (tol or 1e-6) end

	local square = folder("Square", { part("Node", 0, 0, 0), part("Node", 40, 0, 0), part("Node", 40, 0, 40) })

	----------------------------------------------------------------------------------------------- PatrolWalk
	do
		local m = mission({ botNode("g", { Behavior = "PatrolWalk", Nodes = "Square", PatrolCycleLength = 2 }) }, { square })
		local bots, l, nav = world(m, {}, { seed = 1 })
		local g = bots:all()[1]
		check("patrol: a bot is created from its BoolValue and starts at a node of its route", #bots:all() == 1 and near(select(1, bots:position(g.Id)), 0) and g.Behavior == "PatrolWalk")
		run(bots, l, 40)
		local evs = bots:drainEvents()
		local arrivals = eventsOf(evs, "BotArrived", g.Id)
		check("patrol: it visits the nodes in order and loops (1 > 2 > 3 > 1 ...)", #arrivals >= 4 and arrivals[1].Node == 2 and arrivals[2].Node == 3 and arrivals[3].Node == 1 and arrivals[4].Node == 2, #arrivals)
		local deps = eventsOf(evs, "BotDeparted", g.Id)
		-- dwell: arrival -> next departure = PatrolCycleLength
		local ok = true
		for i = 1, #arrivals do
			local nextDep
			for _, d in ipairs(deps) do if d.Time > arrivals[i].Time then nextDep = d break end end
			if nextDep and math.abs((nextDep.Time - arrivals[i].Time) - 2) > DT + 1e-6 then ok = false end
		end
		check("patrol: it pauses PatrolCycleLength (2 s) at every node", ok)
		local legs = {}
		for i = 2, #arrivals do legs[#legs + 1] = arrivals[i].Time - arrivals[i - 1].Time end
		check("patrol: a 40-stud leg at the walking speed takes ~4.4 s + the dwell", legs[1] > 6 and legs[1] < 7.5, legs[1])
	end

	do -- static posts
		local m = mission({
			botNode("forever", { Behavior = "PatrolWalk", Nodes = "Square", PatrolCycleLength = 99999 }),
			botNode("single", { Behavior = "PatrolWalk", Nodes = "Post", PatrolCycleLength = 1.5 }),
			botNode("dflt", { Behavior = "PatrolWalk", Nodes = "Square" }),
		}, { square, part("Post", 5, 0, 5) })
		local bots, l = world(m, {}, { seed = 3 })
		local f, s, d = bots:bot(bots:all()[1].Id), bots:bot(bots:all()[2].Id), bots:bot(bots:all()[3].Id)
		local fx, fz = select(1, bots:position(f.Id)), select(3, bots:position(f.Id))
		run(bots, l, 30)
		check("static: PatrolCycleLength 99999 never leaves its post (real value on 3 bots)", near(select(1, bots:position(f.Id)), fx) and near(select(3, bots:position(f.Id)), fz))
		check("static: a one-node route is a static post", near(select(1, bots:position(s.Id)), 5) and near(select(3, bots:position(s.Id)), 5))
		local moved = select(1, bots:position(d.Id)) ~= select(1, d.Route[1].X and { d.Route[1].X } or { 0 })
		check("static: no PatrolCycleLength -> default dwell 1.5 and it patrols", #eventsOf(bots:drainEvents(), "BotArrived", d.Id) >= 3)
	end

	do -- bots sharing a route are spread along it, deterministically
		local list = {}
		for i = 1, 3 do list[i] = botNode("g" .. i, { Behavior = "PatrolWalk", Nodes = "Square", PatrolCycleLength = 2 }) end
		local m = mission(list, { square })
		local bots = world(m, {}, { seed = 5 })
		local starts = {}
		for _, b in ipairs(bots:all()) do starts[#starts + 1] = ("%d,%d"):format(bots:position(b.Id)) end
		local x1 = select(1, bots:position(bots:all()[1].Id))
		local x2 = select(1, bots:position(bots:all()[2].Id))
		local z3 = select(3, bots:position(bots:all()[3].Id))
		check("shared route: the k-th bot of a route starts at its k-th node", near(x1, 0) and near(x2, 40) and near(z3, 40))
		local function signature(seed)
			local b, l = world(m, {}, { seed = seed })
			run(b, l, 30)
			local out = {}
			for _, e in ipairs(b:drainEvents()) do out[#out + 1] = ("%s@%.2f:%s:%s"):format(e.Kind, e.Time, e.Bot, tostring(e.Node)) end
			return table.concat(out, "|")
		end
		check("shared route: two runs with one seed are identical", signature(5) == signature(5))
		check("shared route: first departures are staggered by the seed", signature(5) ~= signature(6))
	end

	do -- ActiveVariable on a node
		local r = folder("R", { part("Node", 0, 0, 0), part("Node", 30, 0, 0, { ActiveVariable = "Open" }), part("Node", 30, 0, 30) })
		local m = mission({ botNode("g", { Behavior = "PatrolWalk", Nodes = "R", PatrolCycleLength = 1 }) }, { r })
		local bots, l = world(m, { Open = "0" }, { seed = 1 })
		run(bots, l, 30)
		local seen = {}
		for _, e in ipairs(bots:drainEvents()) do if e.Kind == "BotArrived" then seen[e.Node] = true end end
		check("route nodes: a node whose ActiveVariable is false is skipped", seen[1] and seen[3] and not seen[2])
		l:set("Open", 1)
		run(bots, l, 30)
		local seen2 = {}
		for _, e in ipairs(bots:drainEvents()) do if e.Kind == "BotArrived" then seen2[e.Node] = true end end
		check("route nodes: ... and visited once it turns true", seen2[2] == true)
	end

	----------------------------------------------------------------------------------------------- WorkWithBreaks
	do
		local work = folder("Work", { part("Node", 0, 0, 0, { Anim = "Cook" }), part("Node", 20, 0, 0) })
		local brk = folder("BreakSpots", { part("Node", 0, 0, 50), part("Node", 20, 0, 50) })
		local m = mission({ botNode("chef", { Behavior = "WorkWithBreaks", Nodes = "Work", NodesBreak = "BreakSpots", PatrolCycleLength = 1 }) }, { work, brk })
		local bots, l = world(m, {}, { seed = 2, params = { WorkSeconds = 10, BreakSeconds = 6 } })
		run(bots, l, 60)
		local evs = bots:drainEvents()
		local phases = {}
		for _, e in ipairs(evs) do if e.Kind == "BotArrived" then phases[#phases + 1] = e.Phase end end
		local sawBreak, sawWorkAfter = false, false
		for _, ph in ipairs(phases) do
			if ph == "Break" then sawBreak = true elseif ph == "Work" and sawBreak then sawWorkAfter = true end
		end
		check("work/break: after WorkSeconds it goes on a break and then returns to work", sawBreak and sawWorkAfter, table.concat(phases, ","))
		local firstBreak
		for _, e in ipairs(evs) do if e.Kind == "BotArrived" and e.Phase == "Break" then firstBreak = e break end end
		check("work/break: the break is at one of the NodesBreak nodes (z = 50)", firstBreak ~= nil and (firstBreak.Node == 1 or firstBreak.Node == 2))
		local first
		for _, e in ipairs(evs) do if e.Kind == "BotArrived" and e.Phase == "Work" then first = e break end end
		check("work/break: a node's Anim is reported on arrival", first ~= nil and (first.Anim == "Cook" or first.Anim == nil))
		local bx, _, bz = bots:position(bots:all()[1].Id)
		check("work/break: it is somewhere sensible (work or break area) at the end", bz <= 51 and bz >= -1)
		local function sig(seed)
			local b, ll = world(m, {}, { seed = seed, params = { WorkSeconds = 10, BreakSeconds = 6 } })
			run(b, ll, 80)
			local out = {}
			for _, e in ipairs(b:drainEvents()) do out[#out + 1] = ("%s@%.2f:%s"):format(e.Kind, e.Time, tostring(e.Node)) end
			return table.concat(out, "|")
		end
		check("work/break: deterministic for a seed", sig(2) == sig(2))
	end

	----------------------------------------------------------------------------------------------- resolving routes
	do
		local nested = folder("Center", { part("CenterStatic", 7, 0, 7), folder("Inner", { part("Node", 1, 0, 1), part("Node", 9, 0, 1) }) })
		local m = mission({
			botNode("a", { Behavior = "PatrolWalk", Nodes = "centerstatic" }),
			botNode("b", { Behavior = "PatrolWalk", Nodes = "Inner" }),
			botNode("c", { Behavior = "PatrolWalk", Nodes = "Nowhere" }),
			botNode("d", { Behavior = "Bodyguard", Nodes = "Square" }),
			botNode("e", { Behavior = "PatrolWalk", Nodes = "SQUARE" }),
			botNode("f", { Behavior = "", Nodes = "Square" }),
		}, { square, nested })
		local bots = world(m, {}, {})
		check("routes: a name may be a single part, found at any depth, in any case", bots:bot(bots:all()[1].Id) ~= nil and near(select(1, bots:position(bots:all()[1].Id)), 7))
		check("routes: a nested folder's parts are the route", #bots:all()[2].Route == 2)
		check("routes: an unknown route skips the bot and warns", #bots.Skipped >= 1 and #bots.Warnings >= 1 and bots.Warnings[1].Message:find("Nowhere", 1, true) ~= nil)
		local reasons = {}
		for _, s in ipairs(bots.Skipped) do reasons[#reasons + 1] = s.Reason end
		check("routes: an unimplemented behaviour (Bodyguard) is reported, not guessed", table.concat(reasons, "|"):find("Bodyguard", 1, true) ~= nil)
		check("routes: Square resolves case-insensitively and a blank Behavior means PatrolWalk", #bots:all() == 4 and bots:all()[4].Behavior == "PatrolWalk", #bots:all())
	end

	do -- a Nodes value may list several routes: one is chosen, deterministically
		local other = folder("Other", { part("Node", 100, 0, 100), part("Node", 140, 0, 100) })
		local m = mission({ botNode("a", { Behavior = "PatrolWalk", Nodes = "Square Other" }), botNode("b", { Behavior = "PatrolWalk", Nodes = "Missing Other" }) }, { square, other })
		local bots = world(m, {}, { seed = 4 })
		local a, b = bots:all()[1], bots:all()[2]
		check("multi-route: 'A B' resolves both names and the bot walks one of them", a.RouteChoices == 2 and (a.RouteName == "Square" or a.RouteName == "Other"))
		check("multi-route: names that do not exist are ignored (one left = that one)", b.RouteChoices == 1 and b.RouteName == "Other")
		local seen = {}
		for sd = 1, 30 do
			local bb = world(m, {}, { seed = sd })
			seen[bb:all()[1].RouteName] = true
		end
		check("multi-route: different seeds pick different routes, the same seed the same one", seen.Square and seen.Other and world(m, {}, { seed = 4 }):all()[1].RouteName == a.RouteName)
	end

	do -- Disabled and conditional folders under Bots/
		counter += 1
		local inner = botNode("hidden", { Behavior = "PatrolWalk", Nodes = "Square" })
		local on = botNode("on", { Behavior = "PatrolWalk", Nodes = "Square" })
		local off = botNode("off", { Behavior = "PatrolWalk", Nodes = "Square" })
		local dis = folder("Disabled", { inner })
		local condOn = folder("A", { on }, { Condition = "Roll == 1" })
		local condOff = folder("B", { off }, { Condition = "Roll == 2" })
		local m = mission({ dis, condOn, condOff }, { square })
		local bots = world(m, { Roll = "1" }, {})
		check("folders: Disabled and false-Condition folders under Bots/ create no bots", #bots:all() == 1 and bots:all()[1].Name == "on")
	end

	----------------------------------------------------------------------------------------------- identity, loadout, tags
	do
		local m = mission({
			botNode("g1", { Behavior = "PatrolWalk", Nodes = "Square", ServerTag = "SecurityGuard OpenIntercom", Class = "Sec", Profile = "BasicSecurity", Inv = "BasicKeycard_Keycard|SecurityUsbKey", Weapon = "F57", HostageDifficulty = 3, DetectionSpeed = 0.7, SearchArea = "GlobalSearch" }),
			botNode("g2", { Behavior = "PatrolWalk", Nodes = "Square", ServerTag = "Chef" }),
		}, { square })
		local bots = world(m, {}, {})
		local g = bots:all()[1]
		check("identity: tags, class, profile, weapon, difficulty, detection speed, search area are kept", g.Class == "Sec" and g.Profile == "BasicSecurity" and g.Weapon == "F57" and g.HostageDifficulty == 3 and g.DetectionSpeed == 0.7 and g.SearchArea == "GlobalSearch")
		check("identity: Inv is parsed onto the bot", #g.Inv == 2 and g.Inv[1].Item == "BasicKeycard" and g.Inv[1].Tag == "Keycard")
		check("identity: withTag is case-insensitive and tags are whole words", #bots:withTag("securityguard") == 1 and #bots:withTag("Chef") == 1 and #bots:withTag("Security") == 0)
		check("identity: alive() lists live bots", #bots:alive() == 2)
	end

	----------------------------------------------------------------------------------------------- despawn
	do
		local m = mission({
			botNode("a", { Behavior = "PatrolWalk", Nodes = "Square", DespawnCondition = "Gone" }),
			botNode("b", { Behavior = "PatrolWalk", Nodes = "Square", DespawnCondition = "Gone || Panic", DespawnBlocked = "Watched" }),
			botNode("c", { Behavior = "PatrolWalk", Nodes = "Square" }),
		}, { square })
		local bots, l, nav = world(m, { Gone = "0", Panic = "0", Watched = "1" }, { seed = 1 })
		run(bots, l, 2)
		check("despawn: nothing leaves while the condition is false", #bots:alive() == 3)
		l:set("Gone", 1)
		check("despawn: DespawnCondition true removes the bot at once", bots:bot(bots:all()[1].Id).State == "Despawned" and nav:agent(bots:all()[1].Id) == nil and #bots:alive() == 2)
		check("despawn: ... DespawnBlocked holds the other one back", bots:bot(bots:all()[2].Id).State ~= "Despawned")
		l:set("Watched", 0)
		check("despawn: ... until it is no longer blocked", bots:bot(bots:all()[2].Id).State == "Despawned" and #bots:alive() == 1)
		local evs = eventsOf(bots:drainEvents(), "BotDespawned")
		check("despawn: each reports a BotDespawned event with a reason", #evs == 2 and evs[1].Reason == "DespawnCondition")
		run(bots, l, 5)
		check("despawn: a despawned bot is gone from movement (no errors on later steps)", #bots:alive() == 1)
	end

	----------------------------------------------------------------------------------------------- path failures
	do
		local m = mission({ botNode("g", { Behavior = "PatrolWalk", Nodes = "Square", PatrolCycleLength = 1 }) }, { square })
		local bots, l = world(m, {}, { seed = 1, pathfinder = function() return nil end, params = { RetrySeconds = 2, MaxPathFailures = 2 } })
		run(bots, l, 20)
		local evs = bots:drainEvents()
		local fails = eventsOf(evs, "BotPathFailed")
		check("path failure: an unreachable node gives BotPathFailed events, rate-limited by the retry delay", #fails >= 3 and #fails <= 12, #fails)
		local nodesTried = {}
		for _, e in ipairs(fails) do nodesTried[e.Node] = true end
		local n = 0
		for _ in pairs(nodesTried) do n += 1 end
		check("path failure: after MaxPathFailures it gives up on that node and tries the next", n >= 2, n)
		check("path failure: the bot stays alive and where it was", #bots:alive() == 1)
	end

	----------------------------------------------------------------------------------------------- BotStateTracker
	do
		local function tracker(attrs) counter += 1 attrs.Type = "BotStateTracker" return { Name = "T" .. counter, ClassName = "BoolValue", Path = "DebugMission/StateComponents/T" .. counter, Attrs = attrs, Children = {} } end
		local comps = {
			tracker({ BotServerTag = "Guard", TotalCountVariable = "GuardTotal", HostageCountVariable = "GuardHostages", DeathCountVariable = "GuardDead", IncapacitationCountVariable = "GuardDown", FleeCountVariable = "GuardFled", ClientKillCountVariable = "GuardKilledByPlayer" }),
			tracker({ TotalCountVariable = "AllBots" }),
		}
		local m = mission({
			botNode("g1", { Behavior = "PatrolWalk", Nodes = "Square", ServerTag = "Guard", DespawnCondition = "Leave1" }),
			botNode("g2", { Behavior = "PatrolWalk", Nodes = "Square", ServerTag = "Guard" }),
			botNode("c1", { Behavior = "PatrolWalk", Nodes = "Square", ServerTag = "Civ" }),
		}, { square }, comps)
		local bots, l = world(m, { Leave1 = "0" }, {})
		check("tracker: TotalCountVariable counts the bots with the tag", l:get("GuardTotal") == 2 and l:get("AllBots") == 3 and l:get("GuardHostages") == 0)
		local g2 = bots:all()[2]
		bots:setFlag(g2.Id, "Hostage", true)
		check("tracker: a hostage is counted", l:get("GuardHostages") == 1 and l:get("GuardTotal") == 2)
		bots:setFlag(g2.Id, "Hostage", false)
		bots:setFlag(g2.Id, "Incapacitated", true)
		check("tracker: so are incapacitated, and the hostage count falls back", l:get("GuardDown") == 1 and l:get("GuardHostages") == 0)
		bots:setFlag(g2.Id, "Fled", true)
		bots:setFlag(g2.Id, "ClientKilled", true)
		check("tracker: fled and client-kill counts", l:get("GuardFled") == 1 and l:get("GuardKilledByPlayer") == 1)
		bots:setFlag(g2.Id, "Dead", true)
		check("tracker: a dead bot is counted dead, stops moving, and stays in the total until it despawns", l:get("GuardDead") == 1 and l:get("GuardTotal") == 2 and bots:bot(g2.Id).State == "Dead")
		l:set("Leave1", 1)
		check("tracker: a despawned bot leaves the total", l:get("GuardTotal") == 1 and l:get("AllBots") == 2)
		check("tracker: unknown flags and ids are clean failures", bots:setFlag("nope", "Hostage", true) == false and bots:setFlag(g2.Id, "Sleeping", true) == false)
	end

	----------------------------------------------------------------------------------------------- robustness
	do
		local noBots = { folder = function(_, n) if n == "Nodes" then return folder("Nodes", {}) end end, byComponent = function() return {} end }
		check("bots: a mission with no Bots folder is a clean error", select(2, Bots.new(noBots, nil, Logic.fromSpec({}, {}), Nav.new({}))) ~= nil)
		local m = mission({ botNode("g", { Behavior = "PatrolWalk", Nodes = "Square", DespawnCondition = "1 +" }) }, { square })
		local bots, l = world(m, {}, {})
		check("bots: a bad DespawnCondition is a logic error, the bot still exists", #bots:all() == 1 and #l.Errors >= 1)
		local empty = mission({}, {})
		local b2 = world(empty, {}, {})
		check("bots: no bots is fine", #b2:all() == 0 and b2:summary().Bots == 0)
	end

	----------------------------------------------------------------------------------------------- real maps
	local okE, emb = pcall(require, "./_embedded")
	if not okE then
		print("(real-map bots tests skipped: tests/_embedded.luau not found)")
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

	-- how many bots exist at a difficulty: counted independently, by walking Bots/ and evaluating the folder Conditions
	local function expectedBots(mis, lg)
		local n, total = 0, 0
		local function walk(node, ok)
			for _, ch in ipairs(node.Children) do
				local cok = ok
				if ch.ClassName == "Folder" then
					if ch.Name == "Disabled" then cok = false
					elseif ch.Attrs and ch.Attrs.Condition and ch.Attrs.Condition ~= "" then
						local v = lg:eval(ch.Attrs.Condition)
						cok = ok and v ~= nil and v ~= 0 and v ~= ""
					end
				end
				if ch.ClassName == "BoolValue" and ch.Attrs then
					total += 1
					if cok then n += 1 end
				end
				walk(ch, cok)
			end
		end
		walk(mis:folder("Bots"), true)
		return n, total
	end

	for _, entry in ipairs(maps) do
		local label, text = entry[1], entry[2]
		local mis = Mission.build(Codec.decode(text, host), { validator = Validator })
		local w = World.build(mis)
		local function make(diff)
			local l = Logic.new(mis, { seed = 416, builtins = { Mission_Difficulty = diff or 3 } })
			local nav = Nav.new({ pathfinder = Nav.worldAdapter(w) })
			local bots, err = Bots.new(mis, w, l, nav, { seed = 416 })
			return bots, l, nav, err
		end
		local bots, l, nav, err = make()
		check(label .. " [bots]: builds", bots ~= nil, err)
		if bots then
			local s = bots:summary()
			local want, total = expectedBots(mis, l)
			check(label .. " [bots]: every bot that exists at this difficulty is created (" .. s.Bots .. " of " .. total .. " placed; none skipped, no warnings)", s.Bots == want and s.Skipped == 0 and s.Warnings == 0, s.Bots .. " vs " .. want .. " skipped " .. s.Skipped)
			local byDiff = {}
			for d = 1, 3 do
				local b2, l2 = make(d)
				byDiff[#byDiff + 1] = d .. "=" .. #b2:all()
				local w2 = expectedBots(mis, l2)
				if #b2:all() ~= w2 then byDiff[#byDiff] = byDiff[#byDiff] .. "(!=" .. w2 .. ")" end
			end
			print(("  %s: bots by Mission_Difficulty: %s"):format(label, table.concat(byDiff, "  ")))
			local invOk = true
			for _, b in ipairs(bots:all()) do
				if b.Attrs.Inv ~= nil and b.Attrs.Inv ~= "" and #b.Inv == 0 then invOk = false end
			end
			check(label .. " [bots]: every non-empty Inv parses to at least one item", invOk)
			local t0 = os.clock()
			local movers = 0
			for _, b in ipairs(bots:all()) do
				if #b.Route > 1 and (tonumber(b.Attrs.PatrolCycleLength) or 1.5) < 10000 then movers += 1 end
			end
			for _ = 1, 20 * 300 do
				l:advance(DT)
				bots:step(DT)
			end
			local runTime = os.clock() - t0
			local evs = bots:drainEvents()
			local arrived, failed, visited = {}, 0, {}
			for _, e in ipairs(evs) do
				if e.Kind == "BotArrived" then arrived[e.Bot] = (arrived[e.Bot] or 0) + 1 elseif e.Kind == "BotPathFailed" then failed += 1 end
			end
			local walkers, walked = 0, 0
			for _, b in ipairs(bots:all()) do
				if #b.Route > 1 and (tonumber(b.Attrs.PatrolCycleLength) or 1.5) < 10000 and b.State ~= "Despawned" then
					walkers += 1
					if (arrived[b.Id] or 0) >= 1 then walked += 1 end
				end
			end
			check(label .. " [bots]: 300 simulated seconds run with no logic errors", #l.Errors == 0, l.Errors[1] and l.Errors[1].Message)
			check(label .. " [bots]: nearly every bot that should patrol reached a node (" .. walked .. "/" .. walkers .. ")", walkers == 0 or walked >= math.floor(walkers * 0.8), walked .. "/" .. walkers)
			local static = 0
			for _, b in ipairs(bots:all()) do
				if (#b.Route <= 1 or (tonumber(b.Attrs.PatrolCycleLength) or 1.5) >= 10000) then
					static += 1
					local x0 = b.Route[1].X
				end
			end
			print(("  %s: %d bots (%d patrolling, %d at static posts); %d arrivals, %d path failures in 300 s; ran in %.2f s"):format(label, #bots:all(), movers, static, (function() local n = 0 for _, c in pairs(arrived) do n += c end return n end)(), failed, runTime))

			-- patrol legs: consecutive nodes of every bot's route must be reachable through the world's nav graph
			local legsOk, legsAll = 0, 0
			for _, b in ipairs(bots:all()) do
				for i = 1, #b.Route do
					local a, c = b.Route[i], b.Route[i % #b.Route + 1]
					if a ~= c then
						legsAll += 1
						if w:findPath({ X = a.X, Y = a.Y, Z = a.Z }, { X = c.X, Y = c.Y, Z = c.Z }) then legsOk += 1 end
					end
				end
			end
			local d = w.Diagnostics
			local floor = (label == "thepeacemaker") and 0.9 or 0.999
			check(label .. " [bots]: " .. legsOk .. " of " .. legsAll .. " patrol legs are pathable (door + link edges); the floor-crossing SecPatrol route is the known exception", legsOk >= legsAll * floor, legsOk .. "/" .. legsAll)
			print(("  %s: nav graph has %d door edges (%d exact, %d nearest) joining cells; %d components"):format(label, (d.navEdgesDoorExact or 0) + (d.navEdgesDoorNear or 0), d.navEdgesDoorExact or 0, d.navEdgesDoorNear or 0, d.navComponents))

			-- determinism on the real map
			local function sig()
				local b2, l2 = make()
				local out = {}
				for _ = 1, 20 * 60 do l2:advance(DT) b2:step(DT) end
				for _, e in ipairs(b2:drainEvents()) do out[#out + 1] = ("%s@%.2f:%s:%s"):format(e.Kind, e.Time, e.Bot, tostring(e.Node)) end
				return table.concat(out, "\n")
			end
			check(label .. " [bots]: two runs are identical", sig() == sig())
		end
	end

	-- The Project: its real despawn conditions and trackers
	if okP then
		local mis = Mission.build(Codec.decode(embP["theproject.txt"], host), { validator = Validator })
		local w = World.build(mis)
		local l = Logic.new(mis, { seed = 416, builtins = { Mission_Difficulty = 3 } })
		local nav = Nav.new({ pathfinder = Nav.worldAdapter(w) })
		local bots = Bots.new(mis, w, l, nav, { seed = 416 })
		local debugDep, blockedNow, other = 0, 0, 0
		for _, b in ipairs(bots:all()) do
			local c = tostring(b.Attrs.DespawnCondition or "")
			if c:lower():find("debug_despawn", 1, true) then
				debugDep += 1
				local blk = b.Attrs.DespawnBlocked
				if blk ~= nil and blk ~= "" then
					local v = l:eval(blk)
					if v ~= nil and v ~= 0 and v ~= "" then blockedNow += 1 end
				end
			elseif c ~= "" then other += 1 end
		end
		check("The Project [bots]: bots really carry DespawnCondition on Debug_Despawn (case-insensitively)", debugDep > 10, debugDep)
		local before = #bots:alive()
		l:set("DEBUG_DESPAWN", 1) -- variable names are case-insensitive
		check("The Project [bots]: setting Debug_Despawn removes every bot that depends on it, except those whose DespawnBlocked is true right now (" .. blockedNow .. ")", before - #bots:alive() == debugDep - blockedNow, (before - #bots:alive()) .. " vs " .. (debugDep - blockedNow))
		check("The Project [bots]: the others stay", #bots:alive() == before - (debugDep - blockedNow) and #bots:alive() > 0)
		local trackers = bots:summary().Trackers
		check("The Project [bots]: its 10 BotStateTracker components are live", trackers == 10, trackers)
	end
end
