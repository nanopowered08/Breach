--!nonstrict
--[==[
	BreachRoblox — the Roblox adapter entry point (adapter v0.1). Loaded through BreachLoader like everything else, so its relative requires work.

	    local Adapter = Breach.require("wrapper/BreachRoblox/Init")
	    local run = Adapter.start(Breach, {
	        MissionValue = game.ServerStorage.MissionCode,   -- a ModuleScript made by wrapper/ImportMission.command.luau, or a StringValue
	                                                     -- or MissionCode = "<the code>", or MissionUrl = "<somewhere that serves it>"
	        RenderMap = true,         -- build the geometry as Parts (default true)
	        RenderProps = true,       -- place props and doors from the prop library (default true; needs ReplicatedStorage.Assets.Props, see below)
	        PropsLibrary = nil,       -- a Folder of prop Models; default ReplicatedStorage.Assets.Props
	        ShowBarriers = false, ShowNodes = false, LogEvents = false,
	        Seed = 416, Difficulty = 3, BotYOffset = 2.5, PlayerYOffset = 0,
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
	Trespass = require("../../breach-codec/BreachTrespass"),
	Alert = require("../../breach-codec/BreachAlert"),
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
	local session, info = Core.loadMission(M, code, { seed = options.Seed, difficulty = options.Difficulty })
	if not session then
		warn("[Breach] could not load the mission: " .. tostring(info))
		return nil, info
	end
	local host = RobloxHost.new(options)
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
				if not library then
					print("[Breach] no prop library: doors and props are not drawn. Insert Props.rbxm and move its Assets folder under ReplicatedStorage (see wrapper/BreachRoblox/Init.luau)")
					return
				end
				local placements, skipped, total = Core.propPlacements(info.Mission, function(name) return library:FindFirstChild(name) ~= nil end)
				local okP, placed = pcall(host.renderProps, host, placements, library)
				local skippedKinds = 0
				for _ in pairs(skipped) do skippedKinds += 1 end
				print(okP and ("[Breach] props placed: %d models from %d placeholders (%d placeholders of %d kinds not in the library)"):format(placed, #placements, total - #placements, skippedKinds)
					or ("[Breach] prop render failed: " .. tostring(placed)))
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
