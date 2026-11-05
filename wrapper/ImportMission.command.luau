--!nonstrict
-- One-time import of a mission code into your place. NOT loaded by the game; run it by hand in Studio.
--
--   1. In Studio: View > Command Bar.
--   2. Paste this whole file into the Command Bar and press Enter.
--   3. Pick your mission code file (Blacksite.txt) in the dialog.
--
-- It stores the code as ServerStorage.MissionCode (a ModuleScript that returns the code as one string), which BreachBootstrap uses.
-- Save the place afterwards (Ctrl+S): scripts only persist when the place is saved. Run it again to replace the mission.
local StudioService = game:GetService("StudioService")
local ServerStorage = game:GetService("ServerStorage")

local file = StudioService:PromptImportFile({ "txt" })
if not file then
	warn("[Breach import] no file was picked")
	return
end

local code = file:GetBinaryContents()
code = code:gsub("\r", "")
code = code:gsub("^%s+", "")
code = code:gsub("%s+$", "")
if #code < 100 or code:find("]==]", 1, true) then
	warn("[Breach import] that does not look like a mission code (length " .. #code .. ")")
	return
end

local old = ServerStorage:FindFirstChild("MissionCode")
if old then old:Destroy() end

local module = Instance.new("ModuleScript")
module.Name = "MissionCode"
module.Source = "return [==[" .. code .. "]==]"
module.Parent = ServerStorage

local ok, back = pcall(require, module)
if ok and back == code then
	print(("[Breach import] mission code stored in ServerStorage.MissionCode and verified: %d characters"):format(#code))
else
	warn("[Breach import] stored, but reading it back did not match: " .. tostring(ok and (#tostring(back) .. " characters") or back))
end
