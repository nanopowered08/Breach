--!nonstrict
--[==[
	BreachCombatData — the combat data model (BreachEngine M9.0; plan: docs/BreachEngine_M9_Combat_Plan.md).

	Pure Luau, no requires, no Roblox APIs. Reads what a mission *declares* about combat and exposes it as plain tables;
	it does not run anything (spawning, shooting and phases are M9a and later).

	    local model = CombatData.fromMission(mission, setup, { expr = Expr })   -- expr optional: compiles every expression
	    model.Spawners   list of {Kind, Name, Path, Active, SpawnCap, TimeBetweenSpawns, Pool, Weapons, EnemyType, Tags,
	                              Squads, SquadSize, AllowDespawn, BlockedVariable, FlowMap, CustomCombatData, ...Program}
	    model.Pools      { [poolName] = {Name, Limit, RemainingVariable, ActiveVariable, Wave..., Path} }
	    model.Spawns     list of {Kind, Name, Position, Enabled, IgnoreProximity, Range, Tag}   (the LoudSpawns / FixedSpawns parts)
	    model.Detectors  list of {Name, Path, Source, Reaction}  bots (anywhere under Bots/ or BotTemplates/) with DetectConcealedWeapons
	    model.ConcealedDisguises  { [disguise] = true }         MissionSetup.ConcealedWeaponDisguise
	    model.SetupCombatData     MissionSetup.CustomCombatData (e.g. RoseCombatAI)
	    model.Warnings   list of strings (unknown pools, expressions that do not compile, ...)

	    CombatData.parseEnemyWeapons("480 MCS:SteelCoveBasic|K45:SteelCoveGrenadier")  -> { {Weapon, Class}, ... } (duplicates kept: they weight the draw)
	    CombatData.classInfo("SteelCoveHeavy", customCombatData)  -> {Class, Health, Grenades, PlantsC4, Heavy, DamageOutput, ShowsHealthBar, ...}
	    CombatData.spawnsFor(model, tag)    the spawn parts carrying SpawnTag == tag

	Evidence tags: [O] seen in The Blacksite pre-release data, [Play] told by the owner, [P] a guess for the owner to tune.
]==]

local CombatData = {}
CombatData.VERSION = "0.1.0"

---------------------------------------------------------------------------------------------------------- the class table [P]
-- The map data pairs a weapon with a class (`K45:SteelCoveGrenadier`) but never says what a class is. These are the engine-side numbers.
-- Tune here. Health 120 is what placed Blacksite guards have [O].
CombatData.Classes = {
	SteelCoveBasic = { Health = 120, Grenades = false, PlantsC4 = false, Heavy = false },
	SteelCoveHeavy = { Health = 250, Grenades = false, PlantsC4 = true, Heavy = true },
	SteelCoveGrenadier = { Health = 150, Grenades = true, PlantsC4 = false, Heavy = false, GrenadeInterval = { 12, 20 }, GrenadeRange = { 6, 25 } },
	SteelCoveShredder = { Health = 400, Grenades = false, PlantsC4 = false, Heavy = true, Melee = true },
}
CombatData.DefaultClass = "SteelCoveBasic"
CombatData.HealthBarAbove = 200 -- [Play] a guard with MORE than this health shows a health bar
CombatData.DefaultDamageOutput = 1.0 -- [O] CustomCombatData.DamageOutput

local function isBlank(v)
	return v == nil or v == "" or (type(v) == "string" and not v:match("%S"))
end

local function trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function split(s, pattern)
	local out = {}
	if isBlank(s) then return out end
	for piece in tostring(s):gmatch(pattern) do
		piece = trim(piece)
		if piece ~= "" then out[#out + 1] = piece end
	end
	return out
end

local function asBool(v)
	if type(v) == "boolean" then return v end
	if type(v) == "string" then
		local l = v:lower()
		if l == "true" or l == "1" then return true end
		if l == "false" or l == "0" then return false end
	end
	if type(v) == "number" then return v ~= 0 end
	return nil
end

local function asNumber(v)
	if type(v) == "number" then return v end
	if type(v) == "string" then return tonumber(trim(v)) end
	return nil
end

---------------------------------------------------------------------------------------------------------- EnemyWeapons
-- "480 MCS:SteelCoveBasic|F57:SteelCoveBasic|K45:SteelCoveGrenadier" [O]: groups split on "|", each "Weapon:Class" split at the LAST colon,
-- so a weapon name may contain a space ("480 MCS"). Duplicates are kept on purpose: in the real data the Basic class appears several times
-- next to one Grenadier, which reads as a weighted draw [P].
function CombatData.parseEnemyWeapons(source)
	local out = {}
	for group in tostring(source or ""):gmatch("[^|]+") do
		group = trim(group)
		if group ~= "" then
			local weapon, class = group:match("^(.-):([^:]*)$")
			if weapon then
				out[#out + 1] = { Weapon = trim(weapon), Class = trim(class) ~= "" and trim(class) or nil }
			else
				out[#out + 1] = { Weapon = group, Class = nil }
			end
		end
	end
	return out
end

---------------------------------------------------------------------------------------------------------- CustomCombatData
-- A MissionSetup table already is a table. On a spawner or bot it is a string and was empty in every real sample [O], so the text format is a guess [P]:
-- "Key=Value" pairs split on ";", "," or new lines; values true/false/number/text.
function CombatData.parseCustomCombatData(value)
	if type(value) == "table" then
		local copy = {}
		for k, v in pairs(value) do copy[k] = v end
		return copy
	end
	local out = {}
	if isBlank(value) then return out end
	for pair in tostring(value):gmatch("[^;,\r\n]+") do
		local k, v = pair:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
		if k then
			local b = asBool(v)
			if b ~= nil and (v:lower() == "true" or v:lower() == "false") then
				out[k] = b
			else
				out[k] = asNumber(v) or v
			end
		end
	end
	return out
end

---------------------------------------------------------------------------------------------------------- class info
-- Merge: class table row, then CustomCombatData overrides (HasGrenades, IsHeavyUnit, DamageOutput, ForceHealthDisplay, MaxHealth/Health).
-- ShowsHealthBar: ForceHealthDisplay when set, else Health above 200 [Play].
function CombatData.classInfo(className, customCombatData)
	local row = CombatData.Classes[className or ""]
	local known = row ~= nil
	row = row or CombatData.Classes[CombatData.DefaultClass]
	local info = { Class = className or CombatData.DefaultClass, Known = known }
	for k, v in pairs(row) do info[k] = v end
	info.DamageOutput = CombatData.DefaultDamageOutput
	local ccd = customCombatData or {}
	local n = asNumber(ccd.DamageOutput)
	if n then info.DamageOutput = n end
	local hp = asNumber(ccd.MaxHealth) or asNumber(ccd.Health)
	if hp then info.Health = hp end
	local b = asBool(ccd.HasGrenades)
	if b ~= nil then info.Grenades = b end
	b = asBool(ccd.IsHeavyUnit)
	if b ~= nil then info.Heavy = b end
	b = asBool(ccd.SlowCombat)
	if b ~= nil then info.SlowCombat = b end
	b = asBool(ccd.NoBreachTactics)
	if b ~= nil then info.NoBreachTactics = b end
	b = asBool(ccd.NoRushingTargets)
	if b ~= nil then info.NoRushingTargets = b end
	if ccd.TeamId ~= nil then info.TeamId = ccd.TeamId end
	local force = asBool(ccd.ForceHealthDisplay)
	if force ~= nil then
		info.ShowsHealthBar = force
	else
		info.ShowsHealthBar = info.Health > CombatData.HealthBarAbove
	end
	return info
end

---------------------------------------------------------------------------------------------------------- reading a mission
local SPAWNER_KINDS = { CombatSpawner = true, CoverFillSpawner = true, SniperSpawner = true }

-- "ReinforcementPool" and, in The Blacksite, "ReinforcementPool7" (one component has a digit after the name) [O]
local function isPoolType(ty)
	return type(ty) == "string" and ty:match("^ReinforcementPool%d*$") ~= nil
end

local function positionOf(node)
	local props = node.Props or {}
	local cf = props.CFrame
	local p = cf and cf.Position
	if p then return { X = p.X or 0, Y = p.Y or 0, Z = p.Z or 0 } end
	return nil
end

local function compileInto(rec, field, source, ctx)
	-- ctx = { expr = Expr module or nil, warnings = {} }
	if not ctx.expr or isBlank(source) then return end
	local program, err = ctx.expr.compile(source)
	if program then
		rec[field .. "Program"] = program
	else
		ctx.warnings[#ctx.warnings + 1] = ("%s: cannot compile %s '%s' (%s)"):format(tostring(rec.Name), field, tostring(source), tostring(err))
	end
end

local function readSpawner(kind, comp, ctx)
	local a = comp.Attrs or {}
	local rec = {
		Kind = kind, Name = comp.Name, Path = comp.Path,
		Active = a.Active, SpawnCap = a.SpawnCap, TimeBetweenSpawns = a.TimeBetweenSpawns,
		Pool = not isBlank(a.ReinforcementPool) and a.ReinforcementPool or nil,
		Weapons = CombatData.parseEnemyWeapons(a.EnemyWeapons),
		EnemyType = not isBlank(a.EnemyType) and a.EnemyType or nil,
		Tags = split(a.SpawnTags, "[^,;|]+"),
		Squads = asBool(a.SpawnSquads) == true,
		SquadSize = asNumber(a.SpawnSquadsSize),
		AllowDespawn = asBool(a.AllowDespawn) == true,
		BlockedVariable = not isBlank(a.SpawnsBlockedVariable) and a.SpawnsBlockedVariable or nil,
		FlowMap = not isBlank(a.FlowMap) and a.FlowMap or nil,
		CustomCombatData = CombatData.parseCustomCombatData(a.CustomCombatData),
		-- sniper / cover fill extras [O]
		Nodes = a.Nodes, Outfit = a.Outfit, InitialSpawns = asNumber(a.InitialSpawns), RespawnRate = asNumber(a.RespawnRate),
		CoverTags = split(a.CoverTags, "[^,;|]+"), CoverSearchLimit = asNumber(a.CoverSearchLimit), FillFrequency = asNumber(a.FillFrequency),
		Inv = a.Inv,
	}
	compileInto(rec, "Active", rec.Active, ctx)
	compileInto(rec, "SpawnCap", rec.SpawnCap, ctx)
	compileInto(rec, "TimeBetweenSpawns", rec.TimeBetweenSpawns, ctx)
	return rec
end

local function readPool(comp, ctx)
	local a = comp.Attrs or {}
	local rec = {
		Name = a.PoolName, Path = comp.Path, Type = a.Type,
		Limit = a.PoolLimit, ActiveVariable = not isBlank(a.ActiveVariable) and a.ActiveVariable or nil,
		RemainingVariable = not isBlank(a.RemainingVariable) and a.RemainingVariable or nil,
		WaveVariable = not isBlank(a.WaveVariable) and a.WaveVariable or nil,
		WaveStateVariable = not isBlank(a.WaveStateVariable) and a.WaveStateVariable or nil,
		WaveResetThreshold = asNumber(a.WaveResetThreshold), WaveResetTime = a.WaveResetTime, WaveResetMaxTime = a.WaveResetMaxTime,
		WaveResetTimeDecrease = asNumber(a.WaveResetTimeDecrease), WaveResetTimeMinimum = asNumber(a.WaveResetTimeMinimum),
	}
	rec.Id = not isBlank(rec.Name) and rec.Name or nil
	compileInto(rec, "Limit", rec.Limit, ctx)
	return rec
end

local function readSpawnFolder(folder, kind, out, ctx)
	if not folder then return end
	for _, node in ipairs(folder.Children or {}) do
		local a = node.Attrs or {}
		local rec = {
			Kind = kind, Name = node.Name, Path = node.Path, Position = positionOf(node),
			Enabled = a.Enabled, IgnoreProximity = asBool(a.IgnoreProximity) == true, Range = asNumber(a.Range),
			Tag = not isBlank(a.SpawnTag) and a.SpawnTag or nil,
		}
		compileInto(rec, "Enabled", rec.Enabled, ctx)
		out[#out + 1] = rec
	end
end

-- Placed bots sit in group folders (Bots/Zone1/HighSecurityGuard) [O], so walk the whole tree. `Name` is the bot's instance name
-- (the guard type); `Path` tells two bots of the same type apart.
local function readDetectors(folder, source, out)
	if not folder then return end
	local function walk(node)
		for _, child in ipairs(node.Children or {}) do
			local reaction = child.Attrs and child.Attrs.DetectConcealedWeapons
			if not isBlank(reaction) then
				out[#out + 1] = { Name = child.Name, Path = child.Path, Source = source, Reaction = trim(tostring(reaction)) }
			end
			walk(child)
		end
	end
	walk(folder)
end

function CombatData.fromMission(mission, setup, opts)
	opts = opts or {}
	local model = { Spawners = {}, Pools = {}, Spawns = {}, Detectors = {}, ConcealedDisguises = {}, SetupCombatData = {}, Warnings = {} }
	local ctx = { expr = opts.expr, warnings = model.Warnings }

	if mission then
		local seenComponents = {}
		for kind in pairs(SPAWNER_KINDS) do
			for _, comp in ipairs(mission:byComponent(kind)) do
				seenComponents[comp] = true
			end
		end
		-- stable order: by path, so tests and signatures do not depend on table iteration
		local comps = {}
		for comp in pairs(seenComponents) do comps[#comps + 1] = comp end
		table.sort(comps, function(x, y) return tostring(x.Path or x.Name) < tostring(y.Path or y.Name) end)
		for _, comp in ipairs(comps) do
			model.Spawners[#model.Spawners + 1] = readSpawner(comp.Attrs and comp.Attrs.Type or comp.Type or "CombatSpawner", comp, ctx)
		end

		-- pool components: the Type is "ReinforcementPool" or "ReinforcementPool<digit>" [O]. A mission model lists its types;
		-- a minimal stand-in without componentTypes only gets the plain name.
		local poolComps = {}
		local types = mission.componentTypes and mission:componentTypes() or { ReinforcementPool = 1 }
		for ty in pairs(types) do
			if isPoolType(ty) then
				for _, comp in ipairs(mission:byComponent(ty)) do poolComps[#poolComps + 1] = comp end
			end
		end
		table.sort(poolComps, function(x, y) return tostring(x.Path or x.Name) < tostring(y.Path or y.Name) end)
		for _, comp in ipairs(poolComps) do
			local pool = readPool(comp, ctx)
			if isBlank(pool.Id) then
				model.Warnings[#model.Warnings + 1] = "pool component without PoolName: " .. tostring(comp.Path)
			elseif model.Pools[pool.Id] then
				model.Warnings[#model.Warnings + 1] = "duplicate pool name '" .. pool.Id .. "' (" .. tostring(comp.Path) .. "); the first one is kept"
			else
				model.Pools[pool.Id] = pool
			end
		end

		readSpawnFolder(mission:folder("LoudSpawns"), "LoudSpawn", model.Spawns, ctx)
		readSpawnFolder(mission:folder("FixedSpawns"), "FixedSpawn", model.Spawns, ctx)
		readDetectors(mission:folder("BotTemplates"), "BotTemplates", model.Detectors)
		readDetectors(mission:folder("Bots"), "Bots", model.Detectors)
	end

	if type(setup) == "table" then
		if type(setup.CustomCombatData) == "table" then
			for k, v in pairs(setup.CustomCombatData) do model.SetupCombatData[k] = CombatData.parseCustomCombatData(v) end
		end
		if type(setup.ConcealedWeaponDisguise) == "table" then
			for k, v in pairs(setup.ConcealedWeaponDisguise) do
				if v == true then model.ConcealedDisguises[k] = true end
			end
		end
	end

	for _, sp in ipairs(model.Spawners) do
		if sp.Pool and not model.Pools[sp.Pool] then
			model.Warnings[#model.Warnings + 1] = ("%s uses reinforcement pool '%s', which no component defines"):format(tostring(sp.Name), sp.Pool)
		end
	end
	return model
end

---------------------------------------------------------------------------------------------------------- queries
function CombatData.spawnsFor(model, tag)
	local out = {}
	for _, s in ipairs(model.Spawns) do
		if s.Tag == tag then out[#out + 1] = s end
	end
	return out
end

-- Does this bot spot concealed weapons? Pass its Path (exact bot) or its Name (any bot of that type). Returns the reaction name or nil.
function CombatData.detectorReaction(model, pathOrName)
	for _, d in ipairs(model.Detectors) do
		if d.Path ~= nil and d.Path == pathOrName then return d.Reaction end
	end
	for _, d in ipairs(model.Detectors) do
		if d.Name == pathOrName then return d.Reaction end
	end
	return nil
end

-- Can a player wearing this disguise carry a concealed weapon without being spotted by non-detectors? [Play: MissionSetup.ConcealedWeaponDisguise]
function CombatData.disguiseHidesWeapon(model, disguise)
	return model.ConcealedDisguises[disguise or ""] == true
end

-- The class records a spawner can produce: one per EnemyWeapons entry, with the spawner's own CustomCombatData applied.
function CombatData.spawnerClasses(spawner)
	local out = {}
	for _, w in ipairs(spawner.Weapons) do
		local info = CombatData.classInfo(w.Class, spawner.CustomCombatData)
		info.Weapon = w.Weapon
		out[#out + 1] = info
	end
	return out
end

return CombatData
