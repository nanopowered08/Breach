--!nonstrict
-- Put this in ServerScriptService as a Script named "BreachBootstrap".
-- Needs: Game Settings > Security > "Allow HTTP Requests" on, and ServerScriptService.LoadStringEnabled = true.
local HttpService = game:GetService("HttpService")

local REPO, REF = "nanopowered08/Breach", "main" -- the repo name is still a placeholder
local BOOT = ("https://raw.githubusercontent.com/%s/%s/loader/BreachLoader.luau"):format(REPO, REF)

local okBoot, Loader = pcall(function()
	return loadstring(HttpService:GetAsync(BOOT, true))()
end)
if not okBoot then
	warn("[Breach] could not load the loader: " .. tostring(Loader))
	return
end

local Breach = Loader.start({ Repo = REPO, Ref = REF }) -- probes for a new manifest every 5 minutes

local Session = Breach.require("breach-codec/BreachSession")
print("[Breach] loaded, version " .. Breach.version())

-- A hot-swap never touches sessions that already exist. Create the next mission's session from Breach.require again.
Breach.onUpdated(function(info)
	print("[Breach] updated to " .. info.Version .. ": " .. table.concat(info.Changed, ", "))
end)
