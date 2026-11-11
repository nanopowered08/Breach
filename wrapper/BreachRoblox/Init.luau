--!nonstrict
--[==[
	BreachRoblox — the Roblox adapter entry point (adapter v0.1). Loaded through BreachLoader like everything else, so its relative requires work.

	    local Adapter = Breach.require("wrapper/BreachRoblox/Init")
	    local run = Adapter.start(Breach, {
	        MissionValue = game.ServerStorage.MissionCode,   -- a ModuleScript made by wrapper/ImportMission.command.luau, or a StringValue
	                                                     -- or MissionCode = "<the code>", or MissionUrl = "<somewhere that serves it>"
	        RenderMap = true,         -- build the geometry as Parts (default true)
	        RenderProps = true,       -- place props and doors from the prop library (default true; needs ReplicatedStorage.Assets.Props, see below)
	        ApplyLighting = true,     -- apply the mission's LightingSettings preset from ReplicatedStorage.Assets.LightingSettings (default true)
	        PropsLibrary = nil,       -- a Folder of prop Models; default ReplicatedStorage.Assets.Props
	        ShowBarriers = false, ShowNodes = false, LogEvents = false,
	        Seed = nil, TwoPhase = false, Difficulty = 3, BotYOffset = 2.5, PlayerYOffset = 0,
	        -- the seed: Workspace attribute "BreachSeed" first, then Seed, else a fresh random one each run (printed, and kept in the attribute "BreachSeedInUse")
	    })
	    run.Stop()

	Prop library: a mission only has placeholders for its props and doors. Insert Templates/Props.rbxm of the missions repo into Studio (drag the file in)
	and move its `Assets` folder under ReplicatedStorage (the same setup the Prop Preview plugin asks for). Without it the map has no doors or props.

	Returns nil, reason when the mission cannot be loaded (the reason is also printed). Mission codes are not part of this repo.
]==]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local M = {
	Codec = require("../../breach-codec/BreachCodec"),
	Zstd = require("../../breach-codec/BreachZstd"),
	Mission = require("../../breach-codec/BreachMission"),
	Validator = require("../../breach-codec/BreachValidator"),
	World = require("../../breach-codec/BreachWorld"),
	Setup = require("../../breach-codec/BreachSetup"),
	Session = require("../../breach-codec/BreachSession"),
	Logic = require("../../breach-codec/BreachLogic"),
	Nav = require("../../breach-codec/BreachNav"),
	Bots = require("../../breach-codec/BreachBots"),
	Props = require("../../breach-codec/BreachProps"),
	Sight = require("../../breach-codec/BreachSight"),
	Shuffle = require("../../breach-codec/BreachShuffle"),
	Trespass = require("../../breach-codec/BreachTrespass"),
	Alert = require("../../breach-codec/BreachAlert"),
	CombatData = require("../../breach-codec/BreachCombatData"),
	Combat = require("../../breach-codec/BreachCombat"),
	Hostage = require("../../breach-codec/BreachHostage"),
	Behavior = require("../../breach-codec/BreachBehavior"),
}
local Core = require("./Core")
local RobloxHost = require("./RobloxHost")

local Adapter = { VERSION = "0.1.0", Modules = M }

local function fetchCode(options)
	local code
	if type(options.MissionCode) == "string" then
		code = options.MissionCode
	end
	if code == nil and options.MissionValue then
		local v = options.MissionValue
		if v:IsA("StringValue") then
			code = v.Value
		elseif v:IsA("ModuleScript") then
			code = require(v)
		end
	end
	if (code == nil or code == "") and options.MissionUrl then
		code = HttpService:GetAsync(options.MissionUrl, true)
	end
	if type(code) ~= "string" then
		return nil, "no mission code found. Run wrapper/ImportMission.command.luau in the Command Bar to create ServerStorage.MissionCode (or set MissionCode, MissionValue or MissionUrl)"
	end
	return (code:gsub("^%s+", ""):gsub("%s+$", ""))
end

function Adapter.start(Breach, options)
	options = options or {}
	local okFetch, code, why = pcall(fetchCode, options)
	if not okFetch then
		code, why = nil, code
	end
	if not code then
		warn("[Breach] " .. tostring(why))
		return nil, why
	end
	local t0 = os.clock()
	-- The seed decides everything the mission randomises (variables, shuffles, patrol picks): the Workspace attribute "BreachSeed", else options.Seed,
	-- else a fresh random one. The one in use is printed and kept in the Workspace attribute "BreachSeedInUse", so a run can be replayed.
	local seed, seedSource, ignoredSeed = Core.resolveSeed(workspace:GetAttribute("BreachSeed"), options.Seed, function()
		return Random.new():NextInteger(1, 2147483646)
	end)
	if ignoredSeed ~= nil then
		warn(("[Breach] the BreachSeed attribute %q is not a whole number from 0 to 4294967295; ignored"):format(tostring(ignoredSeed)))
	end
	print(("[Breach] seed %d (%s)"):format(seed, seedSource))
	workspace:SetAttribute("BreachSeedInUse", seed)
	local session, info = Core.loadMission(M, code, { seed = seed, difficulty = options.Difficulty, twoPhase = options.TwoPhase == true })
	if not session then
		warn("[Breach] could not load the mission: " .. tostring(info))
		return nil, info
	end
	local host = RobloxHost.new(options)

	-- M11.0: what the mission declares about shuffling its layout (PartCollection / ShuffleTarget, folder-level options). Information only: nothing is moved yet.
	if options.ShuffleSurvey ~= false then
		local okS, lines = pcall(function() return M.Shuffle.report(M.Shuffle.survey(info.Mission), 90) end)
		if okS then
			for _, line in ipairs(lines) do print("[Breach] shuffle: " .. line) end
		else
			print("[Breach] shuffle survey failed: " .. tostring(lines))
		end
		-- M11.1a: which target each PartCollection would go to for this seed (decided and printed only: nothing is moved yet)
		local okL, layoutLines = pcall(function() return M.Shuffle.layoutReport(M.Shuffle.layout(info.Mission, seed), 30) end)
		if okL then
			for _, line in ipairs(layoutLines) do print("[Breach] " .. line) end
		else
			print("[Breach] layout failed: " .. tostring(layoutLines))
		end
	end

	-- The mission's lighting preset (MissionSetup.LightingSettings), taken from the prop library's presets. Set ApplyLighting = false to keep the place's own.
	local setting = info.Setup and info.Setup.LightingSettings
	if options.ApplyLighting ~= false and setting ~= nil then
		local assets = ReplicatedStorage:FindFirstChild("Assets")
		local okL, applied, whyL = pcall(host.applyLighting, host, setting, assets and assets:FindFirstChild("LightingSettings"))
		if okL and applied then
			print(("[Breach] lighting preset %s applied"):format(applied))
		else
			print("[Breach] lighting not applied: " .. tostring(okL and whyL or applied))
		end
	end
	local adapter = Core.new(session, host, { maxDt = options.MaxDt })
	print(("[Breach] mission %s ready in %.1fs: %d bots (engine %s)"):format(tostring(info.MapId), os.clock() - t0, #session.Bots:alive(), Breach and Breach.version and Breach.version() or "?"))

	if options.RenderMap ~= false then
		task.spawn(function()
			local ok, n = pcall(host.renderMap, host, info.Mission, options)
			print(ok and ("[Breach] map rendered: %d parts"):format(n) or ("[Breach] map render failed: " .. tostring(n)))
			if options.RenderProps ~= false then
				local library = options.PropsLibrary
				if not library then
					local assets = ReplicatedStorage:FindFirstChild("Assets")
					library = assets and assets:FindFirstChild("Props")
				end
				local hasModel = function(name) return library ~= nil and library:FindFirstChild(name) ~= nil end
				if not library then
					print("[Breach] no prop library: doors and most props are not drawn. Insert Props.rbxm and move its Assets folder under ReplicatedStorage (see wrapper/BreachRoblox/Init.luau)")
				end
				local placements, skipped, _, scalables = Core.propPlacements(info.Mission, hasModel)
				local okS, made = pcall(host.renderScalables, host, scalables, Core.ScalableProps)
				print(okS and ("[Breach] scalable props drawn as plain parts: %d (windows, garage doors, ladders, pipes, vents, planters, bushes)"):format(made)
					or ("[Breach] scalable props failed: " .. tostring(made)))
				if library then
					local okP, placed = pcall(host.renderProps, host, placements, library)
					local skippedKinds, skippedCount = 0, 0
					for _, count in pairs(skipped) do
						skippedKinds += 1
						skippedCount += count
					end
					print(okP and ("[Breach] props placed: %d models from %d placeholders (%d placeholders of %d kinds not in the library, not drawn)"):format(placed, #placements, skippedCount, skippedKinds)
						or ("[Breach] prop render failed: " .. tostring(placed)))
					-- which kinds, so it is clear what is missing (many are logic markers that are not meant to be seen)
					local kinds = {}
					for name, count in pairs(skipped) do
						kinds[#kinds + 1] = { name = name, count = count }
					end
					table.sort(kinds, function(a, b) if a.count ~= b.count then return a.count > b.count end return a.name < b.name end)
					local parts = {}
					for i = 1, math.min(#kinds, 40) do
						parts[#parts + 1] = kinds[i].name .. "=" .. kinds[i].count
					end
					if #parts > 0 then print("[Breach] not drawn: " .. table.concat(parts, ", ")) end
				end
			end
		end)
	end

	local failures = 0
	local conn
	conn = RunService.Heartbeat:Connect(function(dt)
		local ok, err = pcall(function()
			adapter:syncPlayers(host:getPlayers())
			adapter:step(dt)
		end)
		if ok then
			failures = 0
		else
			failures += 1
			if failures == 1 then warn("[Breach] frame error: " .. tostring(err)) end
			if failures >= 30 then
				warn("[Breach] too many frame errors in a row; stopping")
				conn:Disconnect()
			end
		end
	end)

	return {
		Adapter = adapter, Session = session, Host = host, Info = info,
		Stop = function() conn:Disconnect(); host:destroy() end,
	}
end

return Adapter
