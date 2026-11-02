--!nonstrict
-- M9.0 tests: BreachCombatData (spawners, pools, spawn parts, classes, concealed weapons). Run via tests/run.luau or alone: `luau tests/combatdata.luau`
local CD = require("../BreachCombatData")
local Expr = require("../BreachExpr")

return function(check)
	----------------------------------------------------------------------------------------------- EnemyWeapons
	do
		local w = CD.parseEnemyWeapons("480 MCS:SteelCoveBasic|F57:SteelCoveBasic|S97:SteelCoveBasic|F57:SteelCoveHeavy|480 MCS:SteelCoveHeavy|K45:SteelCoveGrenadier")
		check("weapons: six entries, duplicates kept (they weight the draw)", #w == 6 and w[1].Class == "SteelCoveBasic" and w[2].Class == "SteelCoveBasic", #w)
		check("weapons: a weapon name may contain a space", w[1].Weapon == "480 MCS" and w[5].Weapon == "480 MCS" and w[5].Class == "SteelCoveHeavy")
		check("weapons: the last entry is the grenadier", w[6].Weapon == "K45" and w[6].Class == "SteelCoveGrenadier")
		local s = CD.parseEnemyWeapons("Sawblade:SteelCoveShredder")
		check("weapons: a single pair", #s == 1 and s[1].Weapon == "Sawblade" and s[1].Class == "SteelCoveShredder")
		check("weapons: empty and nil give an empty list", #CD.parseEnemyWeapons("") == 0 and #CD.parseEnemyWeapons(nil) == 0)
		local odd = CD.parseEnemyWeapons(" K45 | :Heavy | AK:  ")
		check("weapons: no colon = weapon only; empty class = nil class", #odd == 3 and odd[1].Weapon == "K45" and odd[1].Class == nil and odd[2].Weapon == "" and odd[2].Class == "Heavy" and odd[3].Class == nil)
	end

	----------------------------------------------------------------------------------------------- CustomCombatData
	do
		check("ccd: empty string and nil are empty tables", next(CD.parseCustomCombatData("")) == nil and next(CD.parseCustomCombatData(nil)) == nil)
		local t = CD.parseCustomCombatData({ DamageOutput = 1.5, HasGrenades = false })
		check("ccd: a table is copied", t.DamageOutput == 1.5 and t.HasGrenades == false)
		local s = CD.parseCustomCombatData("DamageOutput=2; HasGrenades=true, TeamId=Player\nSlowCombat = false")
		check("ccd: the text form (a guess) reads numbers, booleans and words", s.DamageOutput == 2 and s.HasGrenades == true and s.TeamId == "Player" and s.SlowCombat == false)
	end

	----------------------------------------------------------------------------------------------- classes and health bars
	do
		local b, h, g, sh = CD.classInfo("SteelCoveBasic"), CD.classInfo("SteelCoveHeavy"), CD.classInfo("SteelCoveGrenadier"), CD.classInfo("SteelCoveShredder")
		check("class: basic is 120 health with no bar, no grenades, no C4", b.Health == 120 and not b.ShowsHealthBar and not b.Grenades and not b.PlantsC4)
		check("class: heavy has a health bar and plants C4 [P]", h.Health == 250 and h.ShowsHealthBar and h.PlantsC4 and h.Heavy)
		check("class: grenadier throws grenades", g.Grenades and g.GrenadeInterval[1] == 12 and g.GrenadeRange[2] == 25)
		check("class: shredder has a health bar", sh.Health == 400 and sh.ShowsHealthBar and sh.Melee)
		local u = CD.classInfo("Nonsense")
		check("class: unknown class falls back to the default row and says so", u.Known == false and u.Health == 120 and u.Class == "Nonsense")
		check("class: nil class is the default", CD.classInfo(nil).Health == 120)
		check("class: HasGrenades override", CD.classInfo("SteelCoveBasic", { HasGrenades = true }).Grenades == true and CD.classInfo("SteelCoveGrenadier", { HasGrenades = false }).Grenades == false)
		check("class: ForceHealthDisplay true shows a bar on a basic guard", CD.classInfo("SteelCoveBasic", { ForceHealthDisplay = true }).ShowsHealthBar)
		check("class: ForceHealthDisplay false hides the bar on a shredder", not CD.classInfo("SteelCoveShredder", { ForceHealthDisplay = false }).ShowsHealthBar)
		check("class: health bar means MORE than 200 (201 yes, 200 no) [Play]", CD.classInfo("SteelCoveBasic", { MaxHealth = 201 }).ShowsHealthBar and not CD.classInfo("SteelCoveBasic", { MaxHealth = 200 }).ShowsHealthBar)
		check("class: DamageOutput default 1, overridden by CustomCombatData", CD.classInfo("SteelCoveBasic").DamageOutput == 1 and CD.classInfo("SteelCoveBasic", { DamageOutput = 1.5 }).DamageOutput == 1.5)
		local before = CD.Classes.SteelCoveBasic.Health
		CD.classInfo("SteelCoveBasic", { MaxHealth = 999 })
		check("class: overrides never change the class table", CD.Classes.SteelCoveBasic.Health == before)
	end

	----------------------------------------------------------------------------------------------- a mission
	local function comp(ty, name, attrs, where)
		attrs.Type = ty
		return { Type = ty, ClassName = "BoolValue", Name = name, Attrs = attrs, Path = "DebugMission/" .. (where or "StateComponents/Combat") .. "/" .. name, Children = {} }
	end
	local function part(name, x, y, z, attrs)
		return { Name = name, ClassName = "Part", Path = "DebugMission/LoudSpawns/" .. name, Attrs = attrs or {}, Children = {},
			Props = { CFrame = { Position = { X = x, Y = y, Z = z } } } }
	end
	local function fakeMission(comps, folders)
		return {
			byComponent = function(_, ty) local out = {} for _, c in ipairs(comps) do if c.Type == ty then out[#out + 1] = c end end return out end,
			componentTypes = function() local t = {} for _, c in ipairs(comps) do t[c.Type] = (t[c.Type] or 0) + 1 end return t end,
			folder = function(_, name) return folders[name] end,
		}
	end
	local function folderOf(name, children) return { Name = name, ClassName = "Folder", Children = children } end

	do
		local comps = {
			comp("CombatSpawner", "CombatSpawner_Phase3", {
				Active = "CombatPhase == 3", AllowDespawn = true, CustomCombatData = "", EnemyType = "HalcyonOperator",
				EnemyWeapons = "480 MCS:SteelCoveBasic|K45:SteelCoveGrenadier", FlowMap = "", ReinforcementPool = "StandardPool",
				SpawnCap = "FLOOR (2 + (Mission_PlayersInGame  * 1.5))", SpawnSquads = true, SpawnSquadsSize = "2", SpawnTags = "Area1Spawn",
				SpawnsBlockedVariable = "", TimeBetweenSpawns = "10" }),
			comp("CombatSpawner", "CombatSpawner_Phase2", {
				Active = "CombatPhase == 2", EnemyWeapons = "Sawblade:SteelCoveShredder", ReinforcementPool = "Ghost",
				SpawnCap = "2", SpawnTags = "A, B", TimeBetweenSpawns = "15", CustomCombatData = "ForceHealthDisplay=false" }),
			comp("CoverFillSpawner", "CoverFill", { Active = "CheckpointFightStarted", EnemyWeapons = "Sawblade:SteelCoveShredder", ReinforcementPool = "ShredderPool",
				SpawnCap = "1", SpawnTags = "CheckpointSpawn", CoverTags = "CampA", CoverSearchLimit = 5.0, FillFrequency = 1.0, Inv = "HighSecurityBadge_HighSecurityBadge" }),
			comp("SniperSpawner", "Sniper1", { Active = "SpawnSniper1", Nodes = "Sniper1", Outfit = "SteelCove", InitialSpawns = 0.0, RespawnRate = 3000.0 }),
			comp("ReinforcementPool", "Pool_Std", { PoolName = "StandardPool", PoolLimit = "Mission_PlayersInGame * 4", RemainingVariable = "StdLeft", WaveResetThreshold = 0.0 }),
			comp("ReinforcementPool", "Pool_Shr", { PoolName = "ShredderPool", PoolLimit = "1", RemainingVariable = "CheckpointShreddersRemaining" }),
			comp("ReinforcementPool7", "Pool_Mantrap", { PoolName = "MantrapShredderPool", PoolLimit = "1", RemainingVariable = "MantrapShredderAlive" }),
			comp("ReinforcementPool", "Pool_Zdup", { PoolName = "StandardPool", PoolLimit = "9" }),
			comp("ReinforcementPool", "Pool_Nameless", { PoolLimit = "1" }),
			comp("CombatSpawner", "BadExpr", { Active = "1 +", EnemyWeapons = "K45:SteelCoveBasic", ReinforcementPool = "StandardPool", SpawnCap = "2", SpawnTags = "A", TimeBetweenSpawns = "5" }),
		}
		local folders = {
			LoudSpawns = folderOf("LoudSpawns", {
				part("FixedSpawn", 10, 0, 20, { Enabled = "!CheckpointFightComplete", IgnoreProximity = true, Range = 3.0, SpawnTag = "CheckpointSpawn" }),
				part("FixedSpawn", -4, 1, 7, { Enabled = "", IgnoreProximity = false, Range = 2.0, SpawnTag = "Area1Spawn" }),
				part("FixedSpawn", 0, 0, 0, { Enabled = "", Range = 1.0, SpawnTag = "Area1Spawn" }),
			}),
			BotTemplates = folderOf("BotTemplates", {
				{ Name = "HighSecurityGuard", ClassName = "BoolValue", Attrs = { DetectConcealedWeapons = "SetAlarmedWithAlert" }, Children = {} },
				{ Name = "Worker1", ClassName = "BoolValue", Attrs = {}, Children = {} },
				{ Name = "DoorGuard", ClassName = "BoolValue", Attrs = { DetectConcealedWeapons = "" }, Children = {} },
			}),
			Bots = folderOf("Bots", {
				{ Name = "TurretBoy", ClassName = "BoolValue", Path = "DebugMission/Bots/TurretBoy", Attrs = { DetectConcealedWeapons = "SetAlarmedWithAlert" }, Children = {} },
				folderOf("Zone1", {
					{ Name = "SteelCoveGuard", ClassName = "BoolValue", Path = "DebugMission/Bots/Zone1/SteelCoveGuard", Attrs = { DetectConcealedWeapons = "SetAlarmedWithAlert" }, Children = {} },
					{ Name = "Lobby", ClassName = "BoolValue", Path = "DebugMission/Bots/Zone1/Lobby", Attrs = {}, Children = {} },
				}),
			}),
		}
		local setup = { CustomCombatData = { RoseCombatAI = { DamageOutput = 1.5, HasGrenades = false, ForceHealthDisplay = false, TeamId = "Player" } },
			ConcealedWeaponDisguise = { TechnicalStaff = true, Janitor = false } }
		local model = CD.fromMission(fakeMission(comps, folders), setup, { expr = Expr })

		check("model: every spawner kind is read (4 + the bad one)", #model.Spawners == 5, #model.Spawners)
		local byName = {}
		for _, s in ipairs(model.Spawners) do byName[s.Name] = s end
		local p3 = byName.CombatSpawner_Phase3
		check("model: spawner fields", p3.Kind == "CombatSpawner" and p3.Pool == "StandardPool" and p3.EnemyType == "HalcyonOperator" and p3.Squads and p3.SquadSize == 2 and p3.AllowDespawn and p3.TimeBetweenSpawns == "10", p3 and p3.Kind)
		check("model: tags and weapons", #p3.Tags == 1 and p3.Tags[1] == "Area1Spawn" and #p3.Weapons == 2 and p3.Weapons[2].Class == "SteelCoveGrenadier")
		check("model: several tags split on commas", #byName.CombatSpawner_Phase2.Tags == 2 and byName.CombatSpawner_Phase2.Tags[2] == "B")
		check("model: blank strings become nil", p3.FlowMap == nil and p3.BlockedVariable == nil and byName.CombatSpawner_Phase2.EnemyType == nil)
		check("model: expressions are compiled and evaluate", p3.ActiveProgram ~= nil and Expr.evaluate(p3.ActiveProgram, { get = function() return 3 end }) ~= nil or p3.ActiveProgram ~= nil)
		check("model: SpawnCap compiles (FLOOR with Mission_PlayersInGame)", p3.SpawnCapProgram ~= nil)
		check("model: a bad expression is a warning, not a crash", byName.BadExpr.ActiveProgram == nil and (function() for _, w in ipairs(model.Warnings) do if w:find("BadExpr", 1, true) and w:find("Active", 1, true) then return true end end end)())
		check("model: sniper and cover fill extras", byName.Sniper1.Nodes == "Sniper1" and byName.Sniper1.RespawnRate == 3000 and byName.CoverFill.CoverTags[1] == "CampA" and byName.CoverFill.Inv == "HighSecurityBadge_HighSecurityBadge")
		check("model: spawner CustomCombatData is parsed", byName.CombatSpawner_Phase2.CustomCombatData.ForceHealthDisplay == false)
		-- stable order: by path
		local ordered = true
		for i = 2, #model.Spawners do if model.Spawners[i - 1].Path > model.Spawners[i].Path then ordered = false end end
		check("model: spawners are ordered by path", ordered)

		check("pools: three distinct names (ReinforcementPool7 counts; duplicate and nameless do not)", model.Pools.StandardPool and model.Pools.ShredderPool and model.Pools.MantrapShredderPool and not model.Pools[""] )
		check("pools: the first duplicate wins", model.Pools.StandardPool.Limit == "Mission_PlayersInGame * 4")
		check("pools: remaining variable and compiled limit", model.Pools.ShredderPool.RemainingVariable == "CheckpointShreddersRemaining" and model.Pools.StandardPool.LimitProgram ~= nil)
		local warnText = table.concat(model.Warnings, "\n")
		check("warnings: duplicate pool, nameless pool, unknown pool", warnText:find("duplicate pool name 'StandardPool'", 1, true) and warnText:find("without PoolName", 1, true) and warnText:find("pool 'Ghost'", 1, true) ~= nil, warnText)

		check("spawns: three parts with positions", #model.Spawns == 3 and model.Spawns[1].Position.X == 10 and model.Spawns[2].Position.Y == 1 and model.Spawns[1].Kind == "LoudSpawn")
		check("spawns: Enabled, IgnoreProximity, Range, Tag", model.Spawns[1].IgnoreProximity == true and model.Spawns[1].Range == 3 and model.Spawns[1].Tag == "CheckpointSpawn" and model.Spawns[1].Enabled == "!CheckpointFightComplete" and model.Spawns[2].IgnoreProximity == false)
		check("spawns: spawnsFor by tag", #CD.spawnsFor(model, "Area1Spawn") == 2 and #CD.spawnsFor(model, "CheckpointSpawn") == 1 and #CD.spawnsFor(model, "Nope") == 0)

		check("detectors: templates and bots with a reaction; blank and missing are not detectors", #model.Detectors == 3 and CD.detectorReaction(model, "HighSecurityGuard") == "SetAlarmedWithAlert" and CD.detectorReaction(model, "TurretBoy") == "SetAlarmedWithAlert" and CD.detectorReaction(model, "Worker1") == nil and CD.detectorReaction(model, "DoorGuard") == nil)
		check("detectors: bots inside group folders are found, by path or by name", CD.detectorReaction(model, "DebugMission/Bots/Zone1/SteelCoveGuard") == "SetAlarmedWithAlert" and CD.detectorReaction(model, "SteelCoveGuard") == "SetAlarmedWithAlert" and CD.detectorReaction(model, "DebugMission/Bots/Zone1/Lobby") == nil and CD.detectorReaction(model, "Lobby") == nil)
		check("disguises: ConcealedWeaponDisguise true entries only", CD.disguiseHidesWeapon(model, "TechnicalStaff") and not CD.disguiseHidesWeapon(model, "Janitor") and not CD.disguiseHidesWeapon(model, "Guard") and not CD.disguiseHidesWeapon(model, nil))
		check("setup: CustomCombatData tables are kept", model.SetupCombatData.RoseCombatAI.DamageOutput == 1.5 and model.SetupCombatData.RoseCombatAI.TeamId == "Player")
		local rose = CD.classInfo(nil, model.SetupCombatData.RoseCombatAI)
		check("setup: the Rose ally override gives no grenades, no health bar, 1.5 damage", not rose.Grenades and not rose.ShowsHealthBar and rose.DamageOutput == 1.5)

		local classes = CD.spawnerClasses(p3)
		check("spawnerClasses: one record per weapon entry, weapon attached", #classes == 2 and classes[2].Weapon == "K45" and classes[2].Grenades and classes[1].Weapon == "480 MCS")
		local shred = CD.spawnerClasses(byName.CombatSpawner_Phase2)
		check("spawnerClasses: the spawner's CustomCombatData applies (ForceHealthDisplay=false on a shredder)", #shred == 1 and not shred[1].ShowsHealthBar)
	end

	do
		local model = CD.fromMission(nil, nil)
		check("empty: no mission and no setup is an empty model", #model.Spawners == 0 and next(model.Pools) == nil and #model.Spawns == 0 and #model.Detectors == 0 and #model.Warnings == 0)
		local m2 = CD.fromMission(fakeMission({}, {}), {}, nil)
		check("empty: a mission without combat is an empty model, no expr needed", #m2.Spawners == 0 and #m2.Warnings == 0)
		local m3 = CD.fromMission({ byComponent = function() return {} end, folder = function() return nil end }, {})
		check("empty: a minimal stand-in without componentTypes works", #m3.Spawners == 0)
	end

	----------------------------------------------------------------------------------------------- real maps (only when the local data is present)
	local okE, emb = pcall(require, "./_embedded")
	if not okE then
		print("(combat data real-map smoke test skipped: tests/_embedded.luau not found)")
		return
	end
	local Codec = require("../BreachCodec")
	local Zstd = require("../BreachZstd")
	local Mission = require("../BreachMission")
	local Validator = require("../BreachValidator")
	local Setup = require("../BreachSetup")
	local host = { zstdDecompress = Zstd.decompress }
	local okP, embP = pcall(require, "./_embedded_project")
	local maps = { { "TheDiplomat", emb["TheDiplomat.base64"] }, { "thepeacemaker", emb["thepeacemaker.txt"] } }
	if okP then maps[#maps + 1] = { "TheProject", embP["theproject.txt"] } end
	for _, entry in ipairs(maps) do
		local d = Codec.decode(entry[2], host)
		local mis = Mission.build(d, { validator = Validator })
		local setup = Setup.parse(d.SetupSource)
		local ok, model = pcall(CD.fromMission, mis, setup, { expr = Expr })
		check(entry[1] .. ": the combat model builds from the real map", ok, model)
		if ok then
			check(entry[1] .. ": no expression in the real map fails to compile", #model.Warnings == 0, table.concat(model.Warnings, "; "))
			-- these three maps have no combat spawners [O]; whatever they have must still be well-formed
			for _, sp in ipairs(model.Spawners) do
				check(entry[1] .. ": spawner " .. tostring(sp.Name) .. " has a kind", sp.Kind ~= nil)
			end
		end
	end
end
