--!nonstrict
-- Put this in ServerScriptService as a Script named "BreachBootstrap".
-- Needs: Game Settings > Security > "Allow HTTP Requests" on, and ServerScriptService.LoadStringEnabled = true.
--
-- The mission code is NOT in this repo (the missions are CC BY-NC-SA). Import it once with wrapper/ImportMission.command.luau
-- (paste it into Studio's Command Bar and pick the .txt file): that creates ServerStorage.MissionCode. Save the place afterwards.
-- Other options: set MISSION_URL to somewhere that serves the code, or put it in a StringValue (short codes only).
local HttpService = game:GetService("HttpService")
local ServerStorage = game:GetService("ServerStorage")

local REPO, REF = "nanopowered08/Breach", "main"
local MISSION_URL = nil -- optional, e.g. a local web server

local BOOT = ("https://raw.githubusercontent.com/%s/%s/loader/BreachLoader.luau"):format(REPO, REF)

local okBoot, Loader = pcall(function()
	return loadstring(HttpService:GetAsync(BOOT, true))()
end)
if not okBoot then
	warn("[Breach] could not load the loader: " .. tostring(Loader))
	return
end

local Breach = Loader.start({ Repo = REPO, Ref = REF }) -- probes for a new manifest every 5 minutes
print("[Breach] engine loaded, version " .. Breach.version())

local okAdapter, Adapter = pcall(Breach.require, "wrapper/BreachRoblox/Init")
if not okAdapter then
	warn("[Breach] could not load the adapter: " .. tostring(Adapter))
	return
end

local run = Adapter.start(Breach, {
	MissionValue = ServerStorage:FindFirstChild("MissionCode"), -- a ModuleScript (from the importer) or a StringValue
	MissionUrl = MISSION_URL,
	RenderMap = true,
	ShowBarriers = false,
	ShowNodes = false,
	LogEvents = false,
})

-- A hot-swap never touches the running mission. Restart the play session to pick up a new engine version.
Breach.onUpdated(function(info)
	print("[Breach] updated to " .. info.Version .. ": " .. table.concat(info.Changed, ", ") .. " (applies to the next mission)")
end)
