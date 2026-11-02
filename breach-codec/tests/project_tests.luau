--!nonstrict
-- The Project (V1.3, a version-0 map, ~800 KB, plain text): the biggest real map so far. Run via tests/run.luau or `luau tests/project.luau`.
local Logic = require("../BreachLogic")
local Expr = require("../BreachExpr")
local Script = require("../BreachScript")
local CF = require("../BreachCFrame")

return function(check)
	----------------------------------------------------------------------------------------------- engine builtins (unit)
	do
		local spec = { Globals = { Both = "Mission_PlayersInGame == Missing", Pick = "(Mission_Difficulty == 1 && 6) || 10" } }
		local l = Logic.fromSpec(spec, {})
		check("builtins: the engine variables the real maps read have defaults", l:get("Mission_PlayersInGame") == 1 and l:get("Mission_PlayerTotal") == 1 and l:get("Mission_Difficulty") == 1 and l:get("Mission_AlarmRaised") == 0 and l:get("Mission_AlertLevel") == 0 and l:get("Mission_TacticalDifficulty") == 0 and l:get("Mission_Started") == 1)
		check("builtins: 'PlayersInCombatExit == Mission_PlayersInGame' is no longer 0 == 0 (The Project completed itself at t=1 s)", l:get("Both") == 0)
		check("builtins: they feed expressions", l:get("Pick") == 6)
		local o = Logic.fromSpec(spec, {}, { builtins = { Mission_Difficulty = 2, Mission_PlayersInGame = 4 } })
		check("builtins: opts.builtins overrides them one by one, keeping the other defaults", o:get("Mission_Difficulty") == 2 and o:get("Mission_PlayersInGame") == 4 and o:get("Mission_PlayerTotal") == 1 and o:get("Pick") == 10)
		local off = Logic.fromSpec(spec, {}, { defaultBuiltins = false })
		check("builtins: defaultBuiltins = false removes them", off:get("Mission_PlayersInGame") == nil and (off.Undeclared.Mission_PlayersInGame or 0) >= 1)
		local setup = Logic.fromSpec({ Globals = { Mission_Difficulty = "9" } }, {})
		check("builtins: they win over a Setup entry of the same name", setup:get("Mission_Difficulty") == 1)
		local idle = Logic.fromSpec({ Globals = { AllIn = "PlayersIn == Mission_PlayersInGame" } }, { { Type = "MissionCompletionTrigger", Name = "Win", Path = "DebugMission/StateComponents/Win", Attrs = { Condition = "AllIn", Timeout = 1 } } })
		idle:advance(10)
		check("builtins: an idle mission does not complete itself", idle.Outcome == nil)
	end


	----------------------------------------------------------------------------------------------- case-insensitive variable names (unit)
	do
		local function C(ty, name, attrs) return { Type = ty, Name = name, Path = "DebugMission/StateComponents/" .. name, Attrs = attrs } end
		local l = Logic.fromSpec({ Globals = { Bombstarted = "0", Derived = "BombStarted && 5", Mirror = "bombSTARTED + 1" } }, {})
		l:set("BOMBSTARTED", 1)
		check("case: get/set ignore case", l:get("bombstarted") == 1 and l:get("Bombstarted") == 1 and l:get("BombStarted") == 1)
		check("case: a derived variable reads another spelling and follows it (real: Bombstarted vs BombStarted)", l:get("Derived") == 5 and l:get("Mirror") == 2)
		check("case: scopeOf ignores case", l.Store:scopeOf("BOMBSTARTED") == "Globals")
		check("case: there is ONE variable, under the first spelling", l.Store.Globals.Bombstarted == 1 and l.Store.Globals.BombStarted == nil and l.Store.Globals.bombstarted == nil)
		local snap = l.Store:addClient("p")
		local names = {}
		for _, e in ipairs(snap.Globals) do names[#names + 1] = e.Name end
		check("case: packets carry the canonical spelling once", (function() local n = 0 for _, x in ipairs(names) do if x:lower() == "bombstarted" then n += 1 end end return n == 1 end)())
		local r = l:addClient("u1")
		check("case: a replica looks up case-insensitively", r:get("BOMBSTARTED") == 1)
		l:set("bombstarted", 0)
		l:replicate()
		check("case: ... and follows replicated changes", r:get("BombStarted") == 0)

		local chain = Logic.fromSpec({ Globals = { Loudmusic3 = "Powerbox3", Boom = "loudmusic3 && 7" } }, {})
		chain:set("PowerBox3", 1)
		check("case (real: PowerBox3 vs Powerbox3): setting one spelling drives readers of another", chain:get("Loudmusic3") == 1 and chain:get("Boom") == 7)

		local script = Logic.fromSpec({ Globals = { OpenSeasame = "0" } }, { C("StateScript", "S", { Run = "1", ScriptSource = "SET openseasame 1\nINC OPENSEASAME" }) })
		check("case: scripts SET/INC any spelling of a variable (real: OpenSeasame/Openseasame/openseasame)", script:get("OpenSeasame") == 2)
		local cf = Logic.fromSpec({}, { C("StateScript", "S", { Run = "1", ScriptSource = "CFRCOPY PrevCutter Thing\nMOVETO Thing prevcutter" }) }, { world = { cframeOf = function() return Logic.CF.new(1, 2, 3) end } })
		check("case: CFrame variables are case-insensitive too", (function() for _, e in ipairs(cf.Events) do if e.Command == "MOVETO" then return true end end end)() == true)
		local und = Logic.fromSpec({ Globals = { X = "NoSuch + nosuch" } }, {})
		check("case: an undeclared name is reported as written", (und.Undeclared.NoSuch or 0) >= 1 and (und.Undeclared.nosuch or 0) >= 1)
		local delayed = Logic.fromSpec({ Globals = { Src = "0" } }, { C("DelayedStateUpdate", "D", { Watch = "SRC", DelayTime = 1, SetVariable = "OUT" }) })
		delayed:set("src", 3)
		delayed:advance(1)
		check("case: components match names in any case", delayed:get("out") == 3)
	end

	----------------------------------------------------------------------------------------------- the map
	local okE, emb = pcall(require, "./_embedded_project")
	if not okE then
		print("(The Project tests skipped: tests/_embedded_project.luau not found)")
		return
	end
	local Codec = require("../BreachCodec")
	local Zstd = require("../BreachZstd")
	local Mission = require("../BreachMission")
	local Validator = require("../BreachValidator")
	local World = require("../BreachWorld")
	local host = { zstdDecompress = Zstd.decompress }

	local t0 = os.clock()
	local d, err = Codec.decode(emb["theproject.txt"], host)
	local decodeTime = os.clock() - t0
	check("The Project: decodes with no changes to the codec", d ~= nil, err)
	if not d then return end
	check("The Project: it is a version-0 map (not compressed, newlines not escaped)", d.Version == 0)
	check("The Project: no decode warnings", #(d.Warnings or {}) == 0, d.Warnings and d.Warnings[1])
	local m = Mission.build(d, { validator = Validator })
	local count = 0
	local function walk(n) count += 1 for _, c in ipairs(n.Children) do walk(c) end end
	walk(m.Root)
	check("The Project: 10,633 instances, no mission-model warnings", count == 10633 and #(m.Warnings or {}) == 0, count)
	local function size(t) local n = 0 for _ in pairs(t or {}) do n += 1 end return n end
	check("The Project: Setup has 258 Globals, 7 Internals, 1 ClientState and 374 custom strings", size(d.Setup.Globals) == 258 and size(d.Setup.Internals) == 7 and size(d.Setup.ClientState) == 1 and size(d.Setup.CustomStrings) == 374)

	local w = World.build(m)
	check("The Project: 75 cells and 68 links; one warning (3 cells with nav nodes outside their volume)", #w.Cells == 75 and #w.Links == 68 and #w.Warnings == 1 and w.Warnings[1]:find("#10, #14, #26", 1, true) ~= nil, #w.Cells .. "/" .. #w.Links .. "/" .. #w.Warnings)

	-- every expression
	local setupN, setupBad = 0, {}
	for _, store in ipairs({ "Globals", "Internals", "ClientState" }) do
		for name, src in pairs(d.Setup[store]) do
			setupN += 1
			local p, e = Expr.compile(src)
			if not p then setupBad[#setupBad + 1] = store .. "." .. name .. ": " .. e end
		end
	end
	check("The Project: all " .. setupN .. " Setup expressions compile", #setupBad == 0, setupBad[1])
	local STRING_CONTEXT = { DisabledTitle = true, DisabledSubtitle = true }
	local attrN, attrBad = 0, {}
	local function walkAttrs(node)
		local key = Mission.componentKey(node)
		for attr, value in pairs(node.Attrs or {}) do
			if Validator.kindOf(key, attr) == "EXPRESSION" and type(value) == "string" and not STRING_CONTEXT[attr] then
				attrN += 1
				local p, e = Expr.compile(value)
				if not p then attrBad[#attrBad + 1] = (node.Path or node.Name) .. "." .. attr .. ": " .. e end
			end
		end
		for _, c in ipairs(node.Children) do walkAttrs(c) end
	end
	walkAttrs(m.Root)
	check("The Project: all " .. attrN .. " expression attributes compile (EnemyWeaponsWave1-9 are now typed as strings)", attrN > 2000 and #attrBad == 0, attrBad[1])
	check("attr map: EnemyWeaponsWave1..9 are STRING (a '|' weapon pool like EnemyWeapons), not EXPRESSION", (function()
		for i = 1, 9 do if Validator.kindOf("CombatSpawner", "EnemyWeaponsWave" .. i) ~= "STRING" then return false end end
		return Validator.kindOf("CombatSpawner", "EnemyWeapons") == "STRING"
	end)())

	-- scripts
	local scripts, unknown, labels, syntax = 0, 0, 0, 0
	for _, node in ipairs(m:byComponent("StateScript") or {}) do
		scripts += 1
		for _, pr in ipairs(Script.compile(node.Attrs.ScriptSource or "", node.Name).Problems) do
			if pr.Message:find("unknown instruction", 1, true) then unknown += 1
			elseif pr.Message:find("label", 1, true) then labels += 1
			elseif not pr.Message:find("INIT without a value", 1, true) then syntax += 1 print("    lint: " .. node.Name .. ":" .. pr.Line .. " " .. pr.Message) end
		end
	end
	check("The Project: its " .. scripts .. " StateScripts compile with no unknown instructions, missing labels or syntax problems", scripts > 0 and unknown == 0 and labels == 0 and syntax == 0)

	-- the logic core
	local props = function(tag) return CF.new(#tag, 1, 2) end
	local function make(seed) return Logic.new(m, { seed = seed or 416, world = { cframeOf = props } }) end
	local t1 = os.clock()
	local l = make()
	local buildTime = os.clock() - t1
	check("The Project [logic]: builds with no Errors and no Warnings", #l.Errors == 0 and #l.Warnings == 0, l.Errors[1] and (l.Errors[1].Where .. " " .. l.Errors[1].Message))
	local sc = l:summary().Components
	check("The Project [logic]: 49 DelayedStateUpdate, 1 ConditionalStateUpdate, 11 Notification, 10 Timer, 18 StateScript, 2+2 triggers are live", sc.DelayedStateUpdate == 49 and sc.ConditionalStateUpdate == 1 and sc.Notification == 11 and sc.TimerComponent == 10 and sc.StateScript == 18 and sc.MissionCompletionTrigger == 2 and sc.MissionFailedTrigger == 2, (function() local p = {} for k, v in pairs(sc) do p[#p + 1] = k .. "=" .. v end table.sort(p) return table.concat(p, " ") end)())
	local t2 = os.clock()
	for _ = 1, 600 do l:advance(1) end
	local runTime = os.clock() - t2
	check("The Project [logic]: 600 simulated seconds with scripts live, no Errors", #l.Errors == 0, l.Errors[1] and (l.Errors[1].Where .. " " .. l.Errors[1].Message))
	check("The Project [logic]: an idle mission ends with no outcome (nobody has done anything)", l.Outcome == nil, l.Outcome and (l.Outcome.Kind .. " " .. tostring(l.Outcome.Component)))
	local function signature(lg)
		local out = {}
		for _ = 1, 120 do
			lg:advance(1)
			for _, e in ipairs(lg:drainEvents()) do out[#out + 1] = ("%s@%g:%s:%s"):format(e.Kind, e.Time, tostring(e.Component or e.Script), tostring(e.Key or e.Command)) end
		end
		local names = {}
		for k in pairs(lg.Store.Globals) do names[#names + 1] = k end
		table.sort(names)
		for _, k in ipairs(names) do out[#out + 1] = k .. "=" .. tostring(lg.Store.Globals[k]) end
		return table.concat(out, "\n")
	end
	check("The Project [logic]: two runs with one seed are identical", signature(make()) == signature(make()))
	local rep = l:addClient("p1")
	check("The Project [logic]: a client joins with no Errors and no Internal leaks", #rep.Errors == 0 and (function()
		for name in pairs(l.Store.Internals) do if l.Store.Globals[name] == nil and rep.Globals[name] ~= nil then return false end end
		return true
	end)())


	-- The quirk matters in the real map: the lockdown / detonation chain only works if PowerBox3 and Powerbox3 are one variable
	do
		local function fresh() return make() end
		local a = fresh()
		a:advance(5)
		a:set("Mission_AlarmRaised", 1)
		a:advance(9)
		check("The Project [lockdown]: before the 10 s delay the lockdown clock has not started", a:get("LoudTimerStart") == 0)
		a:advance(1)
		check("The Project [lockdown]: 10 s after the alarm the lockdown clock starts at 07:59 (120 + the 359 s offset)", a:get("LoudTimerStart") == 1 and a:get("SearchTimer") == 479 and a:get("SearchTimerFormatted") == "07:59", tostring(a:get("SearchTimer")) .. " " .. tostring(a:get("SearchTimerFormatted")))
		a:advance(60)
		check("The Project [lockdown]: it counts down one second per second", a:get("SearchTimer") == 419 and a:get("SearchTimerFormatted") == "06:59")
		a:advance(419)
		check("The Project [lockdown]: and reaches 00:00 after 479 s, stopping there", a:get("SearchTimer") == 0 and a:get("SearchTimerFormatted") == "00:00")
		a:advance(50)
		check("The Project [lockdown]: it stays at 0", a:get("SearchTimer") == 0 and a.Outcome == nil)

		-- power box (spelled PowerBox3 by the prop, Powerbox3 by the Setup) -> boom -> fail
		local b = fresh()
		b:advance(100)
		b:set("PowerBox3", 1)
		check("The Project [boom]: PowerBox3 (prop spelling) drives Loudmusic3 (Setup spelling)", b:get("Loudmusic3") == 1)
		b:advance(13.3)
		check("The Project [boom]: BoomBegin comes 13.4 s later", b:get("BoomBegin") == 0)
		b:advance(0.1)
		check("The Project [boom]: ... exactly", b:get("BoomBegin") == 1 and b:get("SearchTimer") == 120)
		b:advance(60)
		check("The Project [boom]: the 02:00 detonation countdown runs", b:get("SearchTimer") == 60 and b:get("SearchTimerFormatted") == "01:00" and b.Outcome == nil)
		b:advance(55.9)
		check("The Project [boom]: LoudJoever is 116 s after BoomBegin", b:get("LoudJoever") == 0 and b.Outcome == nil)
		b:advance(0.1)
		check("The Project [boom]: ... and sets it", b:get("LoudJoever") == 1)
		b:advance(0.2)
		check("The Project [boom]: the mission FAILS 0.1 s later (its MissionFailedTrigger Timeout)", b.Outcome ~= nil and b.Outcome.Kind == "Failed" and math.abs(b.Outcome.Time - (100 + 13.4 + 116 + 0.1)) < 0.01, b.Outcome and b.Outcome.Time)

		-- lockdown, then the power box: the lockdown clock is replaced by the detonation clock
		local c = fresh()
		c:advance(5)
		c:set("Mission_AlarmRaised", 1)
		c:advance(95)
		check("The Project [lockdown+boom]: 85 s into the lockdown (alarm t=5, clock starts t=15) it reads 06:34", c:get("SearchTimer") == 394 and c:get("SearchTimerFormatted") == "06:34")
		c:set("PowerBox3", 1)
		c:advance(13.4)
		check("The Project [lockdown+boom]: the detonation restarts the clock at 02:00", c:get("SearchTimer") == 120, c:get("SearchTimer"))
		c:advance(116.2)
		check("The Project [lockdown+boom]: and the mission fails 116 s after BoomBegin", c.Outcome ~= nil and c.Outcome.Kind == "Failed", c.Outcome and c.Outcome.Time)
	end

	-- what is still missing
	local unsupported, kinds = 0, 0
	for _, n in pairs(l.Unsupported) do unsupported += n kinds += 1 end
	local und = 0
	for _ in pairs(l.Undeclared) do und += 1 end
	print(("  The Project: decode %.2fs | logic build %.2fs, 600 s simulated in %.2fs | %d StateComponents unsupported (%d kinds), %d variables read but undeclared"):format(decodeTime, buildTime, runTime, unsupported, kinds, und))
end
