--!nonstrict
-- M8e tests: BreachBehavior (CustomBehavior scripts, conditions, spawners). Run via tests/run.luau or alone: `luau tests/behavior.luau`
local Behavior = require("../BreachBehavior")
local Alert = require("../BreachAlert")
local Sight = require("../BreachSight")
local Bots = require("../BreachBots")
local Nav = require("../BreachNav")
local Logic = require("../BreachLogic")
local Props = require("../BreachProps")

local DT = 1 / 20

return function(check)
	local function kinds(evs, kind) local out = {} for _, e in ipairs(evs) do if kind == nil or e.Kind == kind then out[#out + 1] = e end end return out end

	----------------------------------------------------------------------------------------------- the language
	do
		local p = Behavior.parse("AUTOCLEANUP\nSETFASTWALK\nMOVETODYNAMIC Node A\n:Loop\nWAIT 0.5\nSET Var 2\nGOTO Loop Flag\nBOGUS 1\nEND\n\n  chat Dialogue.Hi  ")
		check("parse: commands become ops (AUTOCLEANUP is a flag, labels are not ops)", #p.Ops == 7 and p.Cleanup == true, #p.Ops)
		check("parse: a label points at the next op", p.Labels.loop == 3 and p.Ops[p.Labels.loop].Cmd == "WAIT")
		check("parse: arguments and the raw rest are kept (and commands are case-insensitive)", p.Ops[2].Args[1] == "Node" and p.Ops[2].Rest == "Node A" and p.Ops[7].Cmd == "CHAT" and p.Ops[7].Args[1] == "Dialogue.Hi")
		check("parse: unknown commands are skipped and reported", #p.Unknown == 1 and p.Unknown[1] == "BOGUS")
		check("parse: empty / nil source gives an empty program", #Behavior.parse("").Ops == 0 and #Behavior.parse(nil).Ops == 0)
	end

	----------------------------------------------------------------------------------------------- a live scene
	local counter = 0
	local function part(name, x, y, z)
		counter += 1
		return { Name = name, ClassName = "Part", Path = "DebugMission/Nodes/" .. name .. counter, Id = "p" .. counter, Attrs = {}, Children = {},
			Props = { CFrame = { Position = { X = x, Y = y, Z = z }, EulerXYZ = { X = 0, Y = 0, Z = 0 } }, Size = { X = 4, Y = 4, Z = 4 } } }
	end
	local function folder(name, children) counter += 1 return { Name = name, ClassName = "Folder", Path = "DebugMission/" .. name .. counter, Id = "f" .. counter, Attrs = {}, Children = children or {} } end
	local function botNode(name, attrs) counter += 1 return { Name = name, ClassName = "BoolValue", Path = "DebugMission/Bots/" .. name, Id = "b" .. counter, Attrs = attrs or {}, Children = {} } end
	local function comp(ty, name, attrs, where) attrs.Type = ty return { Type = ty, Name = name, Attrs = attrs, Path = "DebugMission/" .. (where or "StateComponents") .. "/" .. name } end
	local function straight(a, b) return { { X = a.X, Y = a.Y or 0, Z = a.Z }, { X = b.X, Y = b.Y or 0, Z = b.Z } } end
	local theCell = { Index = 1 }
	local world = { Cells = { theCell }, Links = {}, cellAt = function() return theCell end }

	-- bots: { X, Z, Tag }; comps; globals
	local function live(botDefs, comps, globals, withAlert)
		local list, routes = {}, {}
		for i, d in ipairs(botDefs) do
			local rname = "Post" .. i
			list[#list + 1] = botNode("bot" .. i, { Behavior = "PatrolWalk", Nodes = rname, PatrolCycleLength = 99999, ServerTag = d.Tag })
			routes[#routes + 1] = folder(rname, { part("Node1", d.X, 0, d.Z or 0), part("Node2", d.X + 6, 0, d.Z or 0) })
		end
		routes[#routes + 1] = folder("Walk", { part("W1", 0, 0, 50), part("W2", 20, 0, 50), part("W3", 40, 0, 50) })
		local botsF, nodesF = folder("Bots", list), folder("Nodes", routes)
		local dyn = folder("Dyn", { part("NodeA", 40, 0, 0), part("NodeB", -40, 0, 0), part("Saferoom", 60, 0, 30) })
		local m = { folder = function(_, n) if n == "Bots" then return botsF elseif n == "Nodes" then return nodesF end end,
			Root = { Children = { botsF, nodesF, dyn } },
			byComponent = function(_, ty) local out = {} for _, c in ipairs(comps or {}) do if c.Type == ty then out[#out + 1] = c end end return out end }
		local l = Logic.fromSpec({ Globals = globals or {} }, {})
		local nav = Nav.new({ pathfinder = straight })
		local bots = Bots.new(m, world, l, nav, { seed = 7 })
		local pr = Props.fromNodes({}, world, l)
		pr:addPlayer("p1", -100, 0, 0)
		local players = Sight.propsPlayers(pr)
		local sight = Sight.new(world, bots, players)
		local al = withAlert and Alert.new(l, { mission = m, bots = bots, sight = sight, players = players, world = world }) or nil
		local bh = Behavior.new(l, { mission = m, bots = bots, nav = nav, alert = al, players = players })
		local function run(seconds) for _ = 1, math.floor(seconds / DT + 0.5) do l:advance(DT) bots:step(DT) bh:step(DT) if al then al:step(DT) end end end
		return bh, bots, l, run, nav, al
	end
	local function id(bots, i) return bots:all()[i].Id end

	----------------------------------------------------------------------------------------------- conditions
	do
		local cbc = comp("CustomBehaviorCondition", "Go", { BotServerTag = "Guard", Condition = "Go", Priority = "Custom1", LoopApply = false,
			CustomBehavior = "AUTOCLEANUP\nSETFASTWALK\nMOVETODYNAMIC NodeA\nSET Arrived\nWAIT 2\nSET Waited 5\nPHONE 1" })
		local bh, bots, l, run, nav = live({ { X = 0, Tag = "Guard" }, { X = 0, Z = 10, Tag = "Other" } }, { cbc }, { Go = "0", Arrived = "0", Waited = "0" })
		local g, o = id(bots, 1), id(bots, 2)
		run(1)
		check("cond: nothing runs while the Condition is false", not bh:isRunning(g) and #bh.Errors == 0 and #bh.Unknown == 0)
		l:set("Go", 1)
		run(0.3)
		check("cond: when it turns true the tagged bot starts the script (and only the tagged bot)", bh:isRunning(g) and not bh:isRunning(o) and bots:bot(g).Command == "Custom")
		check("cond: SETFASTWALK raises the agent speed", nav.Agents[g].MaxSpeed > bots.Params.WalkSpeed)
		run(1)
		check("cond: MOVETODYNAMIC blocks: SET Arrived has not run yet while it walks", l:get("Arrived") == 0)
		run(5)
		check("cond: ... after arriving, SET runs (no value = 1)", l:get("Arrived") == 1)
		local x = bots:position(g)
		check("cond: the bot really walked to the named node", math.abs(x - 40) < 1.5, x)
		run(2.5)
		check("cond: WAIT then SET var value, and PHONE emits a pose", l:get("Waited") == 5 and #kinds(bh:drainEvents(), "BotPose") >= 1)
		l:set("Go", 0)
		run(0.3)
		local evs = bh:drainEvents()
		check("cond: when the Condition ends the script stops (BehaviorFinished ConditionEnded) and AUTOCLEANUP restores speed and poses", not bh:isRunning(g) and kinds(evs, "BehaviorFinished")[1].Why == "ConditionEnded" and nav.Agents[g].MaxSpeed == bots.Params.WalkSpeed and #kinds(evs, "BotPose") == 1)
		check("cond: ... and the bot is back on its patrol", bots:bot(g).Command == nil)
	end

	do -- priorities
		local c1 = comp("CustomBehaviorCondition", "Low", { BotServerTag = "Guard", Condition = "A", Priority = "Custom1", LoopApply = true, CustomBehavior = "MOVETODYNAMIC NodeA\nWAIT 1" })
		local c3 = comp("CustomBehaviorCondition", "High", { BotServerTag = "Guard", Condition = "B", Priority = "Custom3", LoopApply = true, CustomBehavior = "MOVETODYNAMIC NodeB\nWAIT 1" })
		local bh, bots, l, run = live({ { X = 0, Tag = "Guard" } }, { c1, c3 }, { A = "0", B = "0" })
		local g = id(bots, 1)
		l:set("A", 1)
		run(0.3)
		check("priority: the only true condition runs", bh:sourceOf(g) == "Low")
		l:set("B", 1)
		run(0.3)
		check("priority: a higher number takes over (Custom3 beats Custom1)", bh:sourceOf(g) == "High")
		run(6)
		check("priority: ... and the bot goes to the HIGH behaviour's node", bots:position(g) < -20, bots:position(g))
		l:set("B", 0)
		run(0.3)
		check("priority: when it ends the lower one resumes", bh:sourceOf(g) == "Low")
	end

	do -- loops, labels, GOTO, WAITFOR, END
		local loop = comp("CustomBehaviorCondition", "Loop", { BotServerTag = "Guard", Condition = "L", Priority = "Custom1", LoopApply = true, CustomBehavior = "CHAT Dialogue.Hi\nWAIT 1" })
		local once = comp("CustomBehaviorCondition", "Once", { BotServerTag = "Other", Condition = "L", Priority = "Custom1", LoopApply = false, CustomBehavior = "CHAT Dialogue.Hi\nWAIT 1" })
		local bh, bots, l, run = live({ { X = 0, Tag = "Guard" }, { X = 0, Z = 8, Tag = "Other" } }, { loop, once }, { L = "1" })
		run(5.5)
		local said = {}
		for _, e in ipairs(kinds(bh:drainEvents(), "BotSay")) do said[e.Bot] = (said[e.Bot] or 0) + 1 end
		check("loop: LoopApply repeats the script (about once a second)", (said[id(bots, 1)] or 0) >= 4, said[id(bots, 1)])
		check("loop: without LoopApply it runs once", said[id(bots, 2)] == 1, said[id(bots, 2)])
		local prog = comp("CustomBehaviorCondition", "Prog", { BotServerTag = "Guard", Condition = "P", Priority = "Custom1", LoopApply = false,
			CustomBehavior = "WAITFOR Ready\nGOTO Skip Flag\nSET Bad\n:Skip\nSET Good\nEND\nSET NeverRun" })
		local bh2, bots2, l2, run2 = live({ { X = 0, Tag = "Guard" } }, { prog }, { P = "1", Ready = "0", Flag = "1", Bad = "0", Good = "0", NeverRun = "0" })
		run2(2)
		check("script: WAITFOR holds the script until the expression is true", l2:get("Good") == 0 and l2:get("Bad") == 0)
		l2:set("Ready", 1)
		run2(0.5)
		check("script: GOTO label var jumps when the variable is true (Bad skipped), then Good, END stops", l2:get("Bad") == 0 and l2:get("Good") == 1 and l2:get("NeverRun") == 0)
		local bh3, _, l3, run3 = live({ { X = 0, Tag = "Guard" } }, { comp("CustomBehaviorCondition", "Prog", { BotServerTag = "Guard", Condition = "P", Priority = "Custom1", CustomBehavior = "GOTO Skip Flag\nSET Bad\n:Skip\nSET Good" }) }, { P = "1", Flag = "0", Bad = "0", Good = "0" })
		run3(0.5)
		check("script: GOTO with a false variable falls through", l3:get("Bad") == 1 and l3:get("Good") == 1)
	end

	----------------------------------------------------------------------------------------------- alarmed override
	do
		local cbc = comp("CustomBehaviorCondition", "Custom", { BotServerTag = "Dip", Condition = "1", Priority = "Custom4", LoopApply = true, CustomBehavior = "MOVETODYNAMIC NodeB\nWAIT 1" })
		local over = comp("AlarmedBehaviorOverride", "Saferoom", { BotServerTag = "Dip", CustomBehavior = "AUTOCLEANUP\nSETRUNNING\nMOVETODYNAMIC Saferoom\nSET PanicRoomTrigger 1" })
		local off = comp("AlarmedBehaviorOverride", "Old", { BotServerTag = "Dip", CustomBehavior = "SET Wrong 1" }, "Disabled")
		local bh, bots, l, run, nav = live({ { X = 0, Tag = "Dip" } }, { cbc, over, off }, { PanicRoomTrigger = "0", Wrong = "0" })
		local d = id(bots, 1)
		check("alarmed: the override under Disabled/ is not read (1 active)", #bh.Alarmed == 1)
		run(0.5)
		check("alarmed: before the alarm the custom condition runs", bh:sourceOf(d) == "Custom")
		l:set("Mission_AlarmRaised", 1)
		run(0.3)
		check("alarmed: when the alarm goes up the override replaces it (above any custom priority)", bh:sourceOf(d) == "Saferoom")
		run(8)
		check("alarmed: the bot runs to the saferoom and sets PanicRoomTrigger", l:get("PanicRoomTrigger") == 1 and bots:position(d) > 50 and l:get("Wrong") == 0)
		check("alarmed: it runs (SETRUNNING)", nav.Agents[d].MaxSpeed > bots.Params.WalkSpeed * 2)
	end

	----------------------------------------------------------------------------------------------- who is left alone
	do
		local cbc = comp("CustomBehaviorCondition", "Go", { BotServerTag = "Guard", Condition = "Go", Priority = "Custom1", LoopApply = true, CustomBehavior = "MOVETODYNAMIC NodeA\nWAIT 1" })
		local bh, bots, l, run = live({ { X = 0, Tag = "Guard" }, { X = 0, Z = 8, Tag = "Guard" }, { X = 0, Z = 16, Tag = "Guard" } }, { cbc }, { Go = "0" })
		local a, b, c = id(bots, 1), id(bots, 2), id(bots, 3)
		bots:setFlag(b, "Hostage", true)
		bots:command(c, "Fleeing", 0, 0, 30) -- something else (an alert reaction) owns this one
		l:set("Go", 1)
		run(0.5)
		check("busy: a free bot runs it; a hostage and a bot commanded by something else are left alone", bh:isRunning(a) and not bh:isRunning(b) and not bh:isRunning(c))
		bots:command(a, "Fleeing", 0, 0, 30)
		run(0.3)
		check("busy: when something else takes over a running bot the script lets go (BehaviorFinished Taken)", not bh:isRunning(a) and kinds(bh:drainEvents(), "BehaviorFinished")[1].Why == "Taken")
		bots:setFlag(a, "Dead", true)
		run(0.5)
		check("busy: a dead bot never runs it", not bh:isRunning(a))
	end

	do -- ENTERCOMBAT, FOLLOW <tag>
		local cbc = comp("CustomBehaviorCondition", "Fight", { BotServerTag = "Guard", Condition = "F", Priority = "Custom2", CustomBehavior = "ENTERCOMBAT\nTAKEDOWNIMMUNE" })
		local bh, bots, l, run, nav, al = live({ { X = 0, Tag = "Guard" } }, { cbc }, { F = "1" }, true)
		run(0.5)
		check("script: ENTERCOMBAT emits BotEnterCombat and sets the Fighting flag (no lockdown)", al:stateName() == "Fighting" and al:level() == 0 and #kinds(bh:drainEvents(), "BotEnterCombat") == 1)
		check("script: TAKEDOWNIMMUNE marks the bot", bots:bot(id(bots, 1)).Flags.TakedownImmune == true)
		local fol = comp("CustomBehaviorCondition", "Follow", { BotServerTag = "Tail", Condition = "T", Priority = "Custom1", LoopApply = true, CustomBehavior = "FOLLOW x Lead\nWAIT 1000" })
		local bh2, bots2, l2, run2 = live({ { X = 0, Tag = "Tail" }, { X = 60, Tag = "Lead" } }, { fol }, { T = "1" })
		run2(12)
		check("script: FOLLOW <target> <tag> walks toward the bot with that tag", bots2:position(id(bots2, 1)) > 30, bots2:position(id(bots2, 1)))
	end

	----------------------------------------------------------------------------------------------- spawners
	do
		local sp = comp("RandomBotSpawner", "Civs", { SpawningActive = "Active", SpawnTimeMin = 2, SpawnTimeMax = 3, Behavior = "PassingCivilian", Class = "Civ", Nodes = "Walk", Tag = "CivTag", HostageDifficulty = 0 })
		local bh, bots, l, run = live({ { X = 0, Tag = "Guard" } }, { sp }, { Active = "0" })
		run(10)
		check("spawner: nothing spawns while SpawningActive is false", #bots:all() == 1)
		l:set("Active", 1)
		run(3.2)
		local spawned = kinds(bh:drainEvents(), "SpawnerSpawned")
		check("spawner: once active, the first one appears within SpawnTimeMax", #spawned == 1 and bots:withTag("civtag")[1] ~= nil)
		local b = bots:bot(spawned[1].Bot)
		check("spawner: it is a tagged PassingCivilian on the spawner's route, and counts as a bot", b.Behavior == "PassingCivilian" and b.Class == "Civ" and b.Spawned == true and b.RouteName == "Walk")
		run(20)
		local evs = bh:drainEvents()
		check("spawner: it keeps spawning at 2-3 s intervals (7 to 10 in 20 s)", #kinds(evs, "SpawnerSpawned") >= 6 and #kinds(evs, "SpawnerSpawned") <= 11, #kinds(evs, "SpawnerSpawned"))
		check("spawner: a passer-by walks its route once and despawns at the end (BotDespawned, Passed)", b.State == "Despawned")
		local live2 = 0
		for _, x in ipairs(bots:all()) do if x.State ~= "Despawned" then live2 += 1 end end
		check("spawner: old ones are gone, so only a few are alive at once", live2 < 8, live2)
		l:set("Active", 0)
		local before = #bots:all()
		run(10)
		check("spawner: turning SpawningActive off stops it", #bots:all() == before)
	end

	----------------------------------------------------------------------------------------------- determinism
	do
		local function sig()
			local sp = comp("RandomBotSpawner", "Civs", { SpawningActive = "", SpawnTimeMin = 2, SpawnTimeMax = 5, Behavior = "PassingCivilian", Class = "Civ", Nodes = "Walk", Tag = "CivTag" })
			local cbc = comp("CustomBehaviorCondition", "Go", { BotServerTag = "Guard", Condition = "1", Priority = "Custom1", LoopApply = true, CustomBehavior = "CHAT a\nMOVETODYNAMIC NodeA\nWAIT 1\nCHAT b\nMOVETODYNAMIC NodeB" })
			local bh, bots, l, run = live({ { X = 0, Tag = "Guard" } }, { sp, cbc }, {})
			run(40)
			local out = {}
			for _, e in ipairs(bh:drainEvents()) do out[#out + 1] = e.Kind .. "@" .. ("%.2f"):format(e.Time) .. ":" .. tostring(e.Line or e.Spawner or e.Source or "") end
			return table.concat(out, "|")
		end
		local a, b = sig(), sig()
		check("determinism: two runs give identical behaviour and spawn events", a == b and #a > 50)
	end

	----------------------------------------------------------------------------------------------- real maps
	local okE, emb = pcall(require, "./_embedded")
	if not okE then
		print("(real-map behavior tests skipped: tests/_embedded.luau not found)")
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
		local function make(setup)
			local l = Logic.new(mis, { seed = 416, builtins = { Mission_Difficulty = 3 } })
			if setup then setup(l) end
			local nav = Nav.new({ pathfinder = Nav.worldAdapter(w) })
			local bots = Bots.new(mis, w, l, nav, { seed = 416 })
			local bh = Behavior.new(l, { mission = mis, bots = bots, nav = nav })
			local function run(seconds) for _ = 1, math.floor(seconds / DT + 0.5) do l:advance(DT) bots:step(DT) bh:step(DT) end end
			return bh, bots, l, run
		end
		local bh, bots, l, run = make()
		print(("  %s: %d CustomBehaviorCondition, %d AlarmedBehaviorOverride (active), %d RandomBotSpawner, %d bots"):format(label, #bh.Conds, #bh.Alarmed, #bh.Spawners, #bots:all()))
		check(label .. " [behavior]: every real script uses only known commands", #bh.Unknown == 0, bh.Unknown[1])
		local missing
		for _, src in ipairs({ bh.Conds, bh.Alarmed }) do
			for _, c in ipairs(src) do
				for _, op in ipairs(c.Prog.Ops) do
					if op.Cmd == "MOVETODYNAMIC" and not bh.Nodes[op.Args[1]:lower()] then missing = missing or (c.Name .. " -> " .. op.Args[1]) end
				end
			end
		end
		check(label .. " [behavior]: every MOVETODYNAMIC node of every real script exists in the map", missing == nil, missing)
		run(2)
		check(label .. " [behavior]: at the start only scripts whose condition really holds are running", (function()
			for _, b in ipairs(bots:all()) do
				local src = bh:sourceOf(b.Id)
				if src then
					local holds
					for _, c in ipairs(bh.Conds) do if c.Name == src and c.Value then holds = true end end
					for _, c in ipairs(bh.Alarmed) do if c.Name == src and l:get("Mission_AlarmRaised") == 1 then holds = true end end
					if not holds then return false end
				end
			end
			return true
		end)())

		-- every real condition that is a bare variable and has a placed bot with its tag: set it, the bot must start the script
		local tried, started = 0, 0
		for _, c in ipairs(bh.Conds) do
			local comp
			for _, cc in ipairs(mis:byComponent("CustomBehaviorCondition")) do if (cc.Path or cc.Name) == c.Src then comp = cc end end
			local var = comp and tostring(comp.Attrs.Condition):match("^%s*([%a_][%w_]*)%s*$")
			local has
			for _, b in ipairs(bots:all()) do if b.TagSet[c.Tag] then has = true end end
			if var and has then
				tried += 1
				local bh2, bots2, l2, run2 = make()
				l2:set(var, 1)
				run2(1)
				local ok
				for _, b in ipairs(bots2:all()) do if b.TagSet[c.Tag] and bh2:isRunning(b.Id) then ok = true end end
				if ok then started += 1 end
				check(label .. " [behavior]: real condition '" .. var .. "' makes a '" .. c.Tag .. "' bot run '" .. c.Name .. "'", ok == true)
			end
		end
		print(("  %s: %d real conditions exercised end to end (%d started)"):format(label, tried, started))

		-- real alarm overrides
		for _, al in ipairs(bh.Alarmed) do
			local has
			for _, b in ipairs(bots:all()) do if b.TagSet[al.Tag] then has = true end end
			if has then
				local bh2, bots2, l2, run2 = make()
				l2:set("Mission_AlarmRaised", 1)
				run2(1)
				local ok
				for _, b in ipairs(bots2:all()) do if b.TagSet[al.Tag] and bh2:sourceOf(b.Id) == al.Name then ok = true end end
				check(label .. " [behavior]: the alarm makes the '" .. al.Tag .. "' bot run the real override '" .. al.Name .. "'", ok == true)
			end
		end

		-- real spawners
		for i, sp in ipairs(bh.Spawners) do
			local bh2, bots2, l2, run2 = make(function(lg) lg:set("MissionBegin", 1) end)
			local n0 = #bots2:all()
			run2(60)
			local spawned = #kinds(bh2:drainEvents(), "SpawnerSpawned")
			local route = tostring(sp.Attrs.Nodes or "")
			if route ~= "" then
				check(label .. " [behavior]: real spawner '" .. sp.Name .. "' (route " .. route .. ", " .. tostring(sp.Attrs.SpawnTimeMin) .. "-" .. tostring(sp.Attrs.SpawnTimeMax) .. " s) spawns passers-by over 60 s", spawned >= 1 and #bots2:all() > n0, spawned)
			else
				check(label .. " [behavior]: real spawner '" .. sp.Name .. "' names no route, so nothing can be spawned (reported, not crashed)", spawned == 0 and (bh2.SpawnFailures or 0) >= 1, bh2.SpawnFailures)
			end
			print(("  %s: spawner %s -> %d spawned in 60 s, %d failed"):format(label, sp.Name, spawned, bh2.SpawnFailures or 0))
		end

		local function sig()
			local b3, bs3, l3, r3 = make(function(lg) lg:set("MissionBegin", 1) end)
			r3(30)
			local out = {}
			for _, e in ipairs(b3:drainEvents()) do out[#out + 1] = e.Kind .. "@" .. ("%.2f"):format(e.Time) end
			return table.concat(out, "|")
		end
		check(label .. " [behavior]: two seeded runs give identical events", sig() == sig())
	end
end
