--!nonstrict
-- Tests for ConditionalStateUpdate, DelayedStateUpdate, VariableShuffle. Run via tests/run.luau or `luau tests/state.luau`.
local Logic = require("../BreachLogic")
local CF = require("../BreachCFrame")

return function(check)
	local function C(ty, name, attrs) return { Type = ty, Name = name, Path = "DebugMission/StateComponents/" .. name, Attrs = attrs } end
	local function spec(setup, comps, opts) return Logic.fromSpec(setup, comps, opts) end

	----------------------------------------------------------------------------------------------- ConditionalStateUpdate
	do
		local l = spec({ Globals = { Src = "0", Gate = "1" } }, { C("ConditionalStateUpdate", "Cond", { Watch = "Src", Condition = "Gate", ActiveVariable = "A", InactiveVariable = "I" }) })
		l:set("Src", 5)
		check("conditional: while Condition is true, ActiveVariable follows Watch", l:get("A") == 5 and l:get("I") == 0)
		l:set("Gate", 0)
		check("conditional: when Condition turns false the current Watch goes to InactiveVariable", l:get("I") == 5)
		l:set("Src", 9)
		check("conditional: ActiveVariable stops following (it keeps its last value)", l:get("A") == 5 and l:get("I") == 9)
		l:set("Gate", 1)
		check("conditional: a Condition change re-evaluates immediately", l:get("A") == 9)

		-- the real Diplomat pattern: DiplomatDeadInStealth := DiplomatKilled while !Mission_AlarmRaised
		local d = spec({ Globals = { DiplomatKilled = "0" } }, { C("ConditionalStateUpdate", "Stealth", { Watch = "DiplomatKilled", Condition = "!Mission_AlarmRaised", ActiveVariable = "DiplomatDeadInStealth" }) }, { builtins = { Mission_AlarmRaised = 0 } })
		d:set("DiplomatKilled", 1)
		check("conditional (real pattern): killed while undetected -> DeadInStealth", d:get("DiplomatDeadInStealth") == 1)
		d:set("Mission_AlarmRaised", 1)
		d:set("DiplomatKilled", 0)
		check("conditional (real pattern): after the alarm it no longer follows (latched)", d:get("DiplomatDeadInStealth") == 1)
		local d2 = spec({ Globals = { DiplomatKilled = "0" } }, { C("ConditionalStateUpdate", "Stealth", { Watch = "DiplomatKilled", Condition = "!Mission_AlarmRaised", ActiveVariable = "X" }) }, { builtins = { Mission_AlarmRaised = 1 } })
		d2:set("DiplomatKilled", 1)
		check("conditional (real pattern): killed after the alarm -> never set", d2:get("X") == 0)

		local noInactive = spec({ Globals = { S = "3", G = "0" } }, { C("ConditionalStateUpdate", "C", { Watch = "S", Condition = "G", ActiveVariable = "A" }) })
		check("conditional: a blank InactiveVariable writes nothing", noInactive:get("A") == 0)
		local w = spec({}, { C("ConditionalStateUpdate", "NoWatch", { Condition = "1", ActiveVariable = "A" }), C("ConditionalStateUpdate", "NoTarget", { Watch = "1", Condition = "1" }) })
		check("conditional: missing Watch or targets are warnings", #w.Warnings == 2 and #w.Errors == 0)
		local bad = spec({}, { C("ConditionalStateUpdate", "Bad", { Watch = "1 +", Condition = "1", ActiveVariable = "A" }) })
		check("conditional: a bad expression is an Error naming the attribute", #bad.Errors == 1 and bad.Errors[1].Where:find("Bad.Watch", 1, true) ~= nil)
		local two = spec({ Globals = { Alarm = "0", Acc = "0" } }, {
			C("ConditionalStateUpdate", "A1", { Watch = "Acc", Condition = "Alarm", ActiveVariable = "Unlocking" }),
			C("ConditionalStateUpdate", "A2", { Watch = "Alarm", Condition = "Acc", ActiveVariable = "Unlocking" }),
		})
		two:set("Alarm", 1)
		two:set("Acc", 1)
		check("conditional (real pattern): two components feeding one variable agree", two:get("Unlocking") == 1)
	end

	----------------------------------------------------------------------------------------------- DelayedStateUpdate
	do
		local l = spec({ Globals = { Src = "0" } }, { C("DelayedStateUpdate", "D", { Watch = "Src", DelayTime = 2, SetVariable = "Out", OnlyMatch = false }) })
		l:advance(3)
		l:set("Src", 1)
		l:advance(1.9)
		check("delayed: the value arrives only after DelayTime", l:get("Out") == 0)
		l:advance(0.1)
		check("delayed: ... exactly on time", l:get("Out") == 1)

		local line = spec({ Globals = { Src = "0" } }, { C("DelayedStateUpdate", "D", { Watch = "Src", DelayTime = 2, SetVariable = "Out", OnlyMatch = false }) })
		line:advance(5)
		line:set("Src", 1)
		line:advance(1)
		line:set("Src", 0)
		line:advance(1)
		check("delayed (OnlyMatch=false): a pure delay line delivers every change, in order", line:get("Out") == 1)
		line:advance(1)
		check("delayed (OnlyMatch=false): ... the later change arrives later", line:get("Out") == 0)

		local om = spec({ Globals = { Src = "0" } }, { C("DelayedStateUpdate", "D", { Watch = "Src", DelayTime = 2, SetVariable = "Out", OnlyMatch = true }) })
		om:advance(5)
		om:set("Src", 1)
		om:advance(1)
		om:set("Src", 0)
		om:advance(5)
		check("delayed (OnlyMatch=true): a change before the delay ends cancels the old value", om:get("Out") == 0)
		local om2 = spec({ Globals = { Src = "0" } }, { C("DelayedStateUpdate", "D", { Watch = "Src", DelayTime = 2, SetVariable = "Out", OnlyMatch = true }) })
		om2:advance(5)
		om2:set("Src", 1)
		om2:advance(2)
		check("delayed (OnlyMatch=true): an unchanged value is applied", om2:get("Out") == 1)

		local zero = spec({ Globals = { Src = "0" } }, { C("DelayedStateUpdate", "D", { Watch = "Src", DelayTime = 0, SetVariable = "Out", OnlyMatch = true }) })
		zero:set("Src", 7)
		check("delayed: DelayTime 0 applies at once (real: RevealSkipped)", zero:get("Out") == 7)

		local stair = spec({ Globals = { Printed = "0" } }, {
			C("DelayedStateUpdate", "F1", { Watch = "Printed", DelayTime = 1, SetVariable = "P1" }),
			C("DelayedStateUpdate", "F2", { Watch = "P1", DelayTime = 1, SetVariable = "P2" }),
			C("DelayedStateUpdate", "F3", { Watch = "P2", DelayTime = 1, SetVariable = "P3" }),
			C("Notification", "N3", { Condition = "P3", Notification = "k" }),
		})
		stair:advance(0.5)
		stair:drainEvents()
		stair:set("Printed", 1)
		stair:advance(2.9)
		check("delayed (real ForgeDelay chain): each stage waits one second", stair:get("P1") == 1 and stair:get("P2") == 1 and stair:get("P3") == 0)
		stair:advance(0.1)
		local ev = stair:drainEvents()
		check("delayed (real ForgeDelay chain): the last stage lands at exactly +3 s", stair:get("P3") == 1 and #ev == 1 and math.abs(ev[1].Time - 3.5) < 1e-9, ev[1] and ev[1].Time)

		local expr = spec({ Globals = { Src = "0", Wait = "4" } }, { C("DelayedStateUpdate", "D", { Watch = "Src", DelayTime = "Wait / 2", SetVariable = "Out" }) })
		expr:advance(1)
		expr:set("Src", 1)
		expr:advance(1.9)
		check("delayed: DelayTime may be an expression", expr:get("Out") == 0)
		expr:advance(0.1)
		check("delayed: ... evaluated when the change happens", expr:get("Out") == 1)

		local init = spec({ Globals = { Src = "5" } }, { C("DelayedStateUpdate", "D", { Watch = "Src", DelayTime = 3, SetVariable = "Out" }) })
		init:advance(3)
		check("delayed: the starting value is copied across after the delay", init:get("Out") == 5)

		local same = spec({ Globals = { Src = "1", Tick = "0" } }, { C("DelayedStateUpdate", "D", { Watch = "Src && 1", DelayTime = 1, SetVariable = "Out" }) })
		same:advance(2)
		local before = #same.Timeline
		same:set("Tick", 1)
		check("delayed: re-evaluating without a change schedules nothing", #same.Timeline == before)

		local w = spec({}, { C("DelayedStateUpdate", "NoVar", { Watch = "1" }), C("DelayedStateUpdate", "NoWatch", { SetVariable = "X" }) })
		check("delayed: missing Watch or SetVariable are warnings", #w.Warnings == 2 and #w.Errors == 0)
		local k = spec({ Globals = { Src = "0" } }, { C("DelayedStateUpdate", "D", { Watch = "Src", DelayTime = 10, SetVariable = "Out" }) })
		k:set("Src", 1)
		check("delayed: pending updates are scheduled, not applied early", k:get("Out") == 0 and #k.Timeline >= 1)
	end

	----------------------------------------------------------------------------------------------- VariableShuffle
	do
		local guards = {}
		for i = 1, 18 do guards[i] = tostring(i) end
		local attrs = { Prefix0 = "Guard", Prefix1 = "", Seed = "1234", InternalOnly = false, Set0 = table.concat(guards, "|"), Set1 = "SecurityRoom|HighSecurity|InsidePatrol|FirstFloorPatrol|GatePatrol|WingPatrol|HighSecurity" }
		local function make(seed, a) return spec({ Globals = { First = "Guard1" } }, { C("VariableShuffle", "NodesShuffle", a or attrs) }, { seed = seed }) end
		local l = make(416)
		local counts, allSet = {}, true
		for i = 1, 18 do
			local v = l:get("Guard" .. i)
			if type(v) ~= "string" then allSet = false else counts[v] = (counts[v] or 0) + 1 end
		end
		check("shuffle (Diplomat shape): Guard1..Guard18 are all assigned a location", allSet)
		local ok = true
		for _, name in ipairs({ "SecurityRoom", "InsidePatrol", "FirstFloorPatrol", "GatePatrol", "WingPatrol" }) do
			if (counts[name] or 0) < 2 or counts[name] > 3 then ok = false end
		end
		check("shuffle (Diplomat shape): the deck is dealt round-robin, so every area gets 2-3 guards", ok)
		check("shuffle (Diplomat shape): a location listed twice gets twice the guards", (counts.HighSecurity or 0) >= 4, counts.HighSecurity)
		check("shuffle: it runs BEFORE Setup (Setup can read the result)", l:get("First") == l:get("Guard1"))
		check("shuffle: reproducible for one mission seed", make(416):get("Guard7") == l:get("Guard7") and make(416):get("Guard18") == l:get("Guard18"))
		local differ = false
		for sd = 1, 12 do if make(sd):get("Guard1") ~= l:get("Guard1") then differ = true end end
		check("shuffle: different mission seeds deal differently", differ)
		local seedAttrs = {}
		for k, v in pairs(attrs) do seedAttrs[k] = v end
		seedAttrs.Seed = "999"
		local sig1, sig2 = {}, {}
		for i = 1, 18 do sig1[i] = tostring(make(416):get("Guard" .. i)) sig2[i] = tostring(make(416, seedAttrs):get("Guard" .. i)) end
		check("shuffle: the component's own Seed matters too", table.concat(sig1, ",") ~= table.concat(sig2, ","))
		check("shuffle: values replicate like any Global (Guard assignments are public)", (function()
			local r = l:addClient("p")
			return r:get("Guard1") == l:get("Guard1")
		end)())

		-- Peacemaker shape: numbered codenames with a reverse map, internal only
		local names = spec({}, { C("VariableShuffle", "CodenameAssign", { Prefix0 = "Name", Prefix1 = "NameOwner", Seed = "871", InternalOnly = true, Set0 = "Sci1|Sci2|Sci3|Sci4|Sci5|Sci0", Set1 = "0|1|2|3|4|5" }) }, { seed = 416 })
		local seen, perm = {}, true
		for _, sci in ipairs({ "Sci1", "Sci2", "Sci3", "Sci4", "Sci5", "Sci0" }) do
			local v = names:get("Name" .. sci)
			if type(v) ~= "number" or v < 0 or v > 5 or seen[v] then perm = false end
			seen[v] = true
		end
		check("shuffle (Peacemaker names): six numbers 0..5 dealt as a permutation, stored as numbers", perm)
		local back = true
		for _, sci in ipairs({ "Sci1", "Sci2", "Sci3", "Sci4", "Sci5", "Sci0" }) do
			if names:get("NameOwner" .. names:get("Name" .. sci)) ~= sci then back = false end
		end
		check("shuffle (Peacemaker names): Prefix1 builds the reverse map (owner of each value)", back)
		check("shuffle: InternalOnly keeps results out of the Globals and out of replicas", names.Store.Internals.NameSci1 ~= nil and names.Store.Globals.NameSci1 == nil and names:addClient("p"):get("NameSci1") == nil)

		local roles = spec({}, { C("VariableShuffle", "TechLeadAssign", { Prefix0 = "", Prefix1 = "Role", Seed = "87147", InternalOnly = true, Set0 = "Sci1|Sci2|Sci3|Sci4|Sci5|Sci0", Set1 = "TechLead|NetworkSpecialist|Dummy" }) })
		local sciOk = true
		for _, sci in ipairs({ "Sci1", "Sci2", "Sci3", "Sci4", "Sci5", "Sci0" }) do
			local role = roles:get(sci)
			if role ~= "TechLead" and role ~= "NetworkSpecialist" and role ~= "Dummy" then sciOk = false end
		end
		check("shuffle (Peacemaker roles): every scientist gets one of the three roles", sciOk)
		local owner = roles:get("RoleTechLead")
		check("shuffle (Peacemaker roles): RoleTechLead names a scientist who really has that role (RoleTechLead == [SciINDEX])", type(owner) == "string" and roles:get(owner) == "TechLead")

		local w = spec({}, { C("VariableShuffle", "Empty", { Prefix0 = "X", Seed = "1" }) })
		check("shuffle: empty sets are a warning", #w.Warnings == 1 and #w.Errors == 0)
		local b = spec({}, { C("VariableShuffle", "BadSeed", { Prefix0 = "X", Set0 = "a", Set1 = "b", Seed = "1 +" }) })
		check("shuffle: a bad Seed is an Error and nothing is assigned", #b.Errors == 1 and b:get("Xa") == nil)
		local e = spec({}, { C("VariableShuffle", "Blank", { Prefix0 = "X", Set0 = "a|b", Set1 = "q", Seed = "" }) })
		check("shuffle: a blank Seed is allowed (mission seed only)", e:get("Xa") == "q" and e:get("Xb") == "q")
		local sp = spec({}, { C("VariableShuffle", "Spaces", { Prefix0 = "P", Set0 = " a | b ", Set1 = " x | y ", Seed = "1" }) })
		check("shuffle: whitespace around list items is trimmed", sp:get("Pa") ~= nil and sp:get("Pb") ~= nil and sp:get("Pa") ~= sp:get("Pb"))
	end

	----------------------------------------------------------------------------------------------- real maps
	local okE, emb = pcall(require, "./_embedded")
	if not okE then return end
	local Codec = require("../BreachCodec")
	local Zstd = require("../BreachZstd")
	local Mission = require("../BreachMission")
	local Validator = require("../BreachValidator")
	local host = { zstdDecompress = Zstd.decompress }
	local props = function(tag) return CF.new(#tag, 1, 2) end

	local D = Mission.build(Codec.decode(emb["TheDiplomat.base64"], host), { validator = Validator })
	local function makeD(seed) return Logic.new(D, { seed = seed or 416, builtins = { Mission_Difficulty = 2, Mission_PlayerTotal = 1 }, world = { cframeOf = props } }) end
	local dl = makeD()
	check("The Diplomat [state]: builds with no Errors", #dl.Errors == 0, dl.Errors[1] and (dl.Errors[1].Where .. " " .. dl.Errors[1].Message))
	check("The Diplomat [state]: its preprocess VariableShuffle ran (Guard1..Guard18 exist)", type(dl:get("Guard1")) == "string" and type(dl:get("Guard18")) == "string")
	local spawns, templates, skipped = {}, {}, 0
	for _, ev in ipairs(dl:drainEvents()) do
		if ev.Kind == "ScriptCommand" and ev.Command == "SPAWNBOT" then spawns[#spawns + 1] = ev templates[ev.Args[1]] = true end
	end
	for k in pairs(dl.Issues) do if k:find("command%-skipped") then skipped += 1 end end
	check("The Diplomat [state]: the spawn script now emits all 18 SPAWNBOT commands", #spawns == 18, #spawns)
	check("The Diplomat [state]: ... for Guard1..Guard18, with no command skipped", templates.Guard1 and templates.Guard18 and skipped == 0, skipped)
	check("The Diplomat [state]: each spawn carries the CFrame of the location its guard was dealt", (function()
		for _, ev in ipairs(spawns) do
			local loc = dl:get(ev.Args[1])
			if not CF.isCF(ev.Args[2]) or ev.Args[2][1] ~= #loc then return false end -- props(tag) = CF.new(#tag, ...)
		end
		return true
	end)())
	check("The Diplomat [state]: ... and the whole assignment follows the mission seed", (function()
		local other = makeD(417)
		local same = makeD(416)
		local diff = false
		for i = 1, 18 do
			if other:get("Guard" .. i) ~= dl:get("Guard" .. i) then diff = true end
			if same:get("Guard" .. i) ~= dl:get("Guard" .. i) then return false end
		end
		return diff
	end)())
	-- the 13 DelayedStateUpdates + ConditionalStateUpdate are live
	local sc = dl:summary().Components
	check("The Diplomat [state]: its 13 DelayedStateUpdate and 1 ConditionalStateUpdate run", sc.DelayedStateUpdate == 13 and sc.ConditionalStateUpdate == 1, tostring(sc.DelayedStateUpdate) .. "/" .. tostring(sc.ConditionalStateUpdate))
	dl:advance(60)
	check("The Diplomat [state]: 60 s with all of it live, still no Errors", #dl.Errors == 0, dl.Errors[1] and dl.Errors[1].Message)
	local u = 0
	for _, n in pairs(dl.Unsupported) do u += n end
	print(("  The Diplomat: %d components still unsupported (of the 100 under StateComponents), %d variables read but undeclared"):format(u, dl:summary().UndeclaredNames))

	local P = Mission.build(Codec.decode(emb["thepeacemaker.txt"], host), { validator = Validator })
	local function makeP(seed) return Logic.new(P, { seed = seed or 416, builtins = { Mission_Difficulty = 2, Mission_PlayerTotal = 1, Mission_TacticalDifficulty = 0 }, world = { cframeOf = props } }) end
	local pl = makeP()
	check("The Peacemaker [state]: builds with no Errors", #pl.Errors == 0, pl.Errors[1] and (pl.Errors[1].Where .. " " .. pl.Errors[1].Message))
	local owner = pl:get("RoleTechLead")
	check("The Peacemaker [state]: the role assignment ran (RoleTechLead == [SciINDEX] has an owner)", type(owner) == "string" and pl:get(owner) == "TechLead", tostring(owner))
	check("The Peacemaker [state]: codenames 0..5 were dealt to the six scientists", (function()
		local seen = {}
		for _, sci in ipairs({ "Sci1", "Sci2", "Sci3", "Sci4", "Sci5", "Sci0" }) do
			local v = pl:get("Name" .. sci)
			if type(v) ~= "number" then return false end
			seen[v] = true
		end
		local n = 0
		for _ in pairs(seen) do n += 1 end
		return n == 6
	end)())
	check("The Peacemaker [state]: the shuffles are InternalOnly, so a joining client sees none of them", (function()
		local r = pl:addClient("p")
		return r:get("RoleTechLead") == nil and r:get("NameSci1") == nil
	end)())
	local pc = pl:summary().Components
	print(("  The Peacemaker: DelayedStateUpdate x%d, ConditionalStateUpdate x%d, VariableShuffle x%d"):format(pc.DelayedStateUpdate or 0, pc.ConditionalStateUpdate or 0, pc.VariableShuffle or 0))
	check("The Peacemaker [state]: its 24 delayed + 22 conditional updates and 2 shuffles are live", pc.DelayedStateUpdate == 24 and pc.ConditionalStateUpdate == 22 and pc.VariableShuffle == 2)
	pl:advance(300)
	check("The Peacemaker [state]: 300 s with all of it live, still no Errors", #pl.Errors == 0, pl.Errors[1] and pl.Errors[1].Message)
	local function sig(make)
		local lg = make()
		local out = {}
		for _ = 1, 100 do lg:advance(1) end
		local names = {}
		for k in pairs(lg.Store.Globals) do names[#names + 1] = k end
		for k in pairs(lg.Store.Internals) do names[#names + 1] = "i:" .. k end
		table.sort(names)
		for _, k in ipairs(names) do out[#out + 1] = k .. "=" .. tostring(lg.Store.Globals[k] or lg.Store.Internals[k:gsub("^i:", "")]) end
		return table.concat(out, "\n")
	end
	check("The Peacemaker [state]: two runs end in an identical state", sig(makeP) == sig(makeP))
end
