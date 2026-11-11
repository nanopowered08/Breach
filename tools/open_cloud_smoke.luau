-- Open Cloud smoke task. The mission source arrives as the first binary-input argument.
-- The runner substitutes the immutable commit SHA before submitting this script.
local HttpService = game:GetService("HttpService")

local args = { ... }
local input = args[1]
assert(input and typeof(input.BinaryInput) == "buffer", "Open Cloud mission binary input is missing")
local missionCode = buffer.tostring(input.BinaryInput)
assert(#missionCode > 0, "Mission source is empty")

local REPO = "nanopowered08/Breach"
local REF = __BREACH_COMMIT_SHA__
local loaderUrl = ("https://raw.githubusercontent.com/%s/%s/loader/BreachLoader.luau"):format(REPO, REF)

print("[Breach CI] fetching loader at " .. REF)
local loaderSource = HttpService:GetAsync(loaderUrl, true)
local Loader = assert(loadstring(loaderSource))()
local Breach = Loader.start({ Repo = REPO, Ref = REF })

local Adapter = Breach.require("wrapper/BreachRoblox/Init")
local run, reason = Adapter.start(Breach, {
    MissionCode = missionCode,
    RenderMap = true,
    RenderProps = false,
    ApplyLighting = false,
    ShuffleSurvey = false,
    ShowBarriers = false,
    ShowNodes = false,
    LogEvents = false,
})
assert(run, "Adapter.start failed: " .. tostring(reason))

-- Match RobloxHost:renderMap's inclusion rules so the test waits for every map part,
-- not merely for the first folder to appear or for Adapter.start's early ready log.
local function countRenderable(node)
    local count = 0
    if (node.ClassName == "Part" or node.ClassName == "WedgePart") then
        local props = node.Props or {}
        local cf = props.CFrame
        if cf and cf.Position and props.Size then
            count += 1
        end
    end
    for _, child in ipairs(node.Children or {}) do
        count += countRenderable(child)
    end
    return count
end

local expected = 0
for _, folderName in ipairs({ "Geometry", "Barrier" }) do
    local folder = run.Info.Mission:folder(folderName)
    if folder then
        expected += countRenderable(folder)
    end
end
assert(expected > 0, "Mission contains no renderable Geometry/Barrier parts")

local deadline = os.clock() + 240
local rendered = 0
repeat
    task.wait(0.25)
    local root = workspace:FindFirstChild("BreachWorld")
    local map = root and root:FindFirstChild("Map")
    rendered = 0
    if map then
        for _, descendant in ipairs(map:GetDescendants()) do
            if descendant:IsA("BasePart") then
                rendered += 1
            end
        end
    end
until rendered >= expected or os.clock() >= deadline

if rendered ~= expected then
    run.Stop()
    error(("Map render incomplete: expected %d parts, found %d"):format(expected, rendered))
end

local mapId = tostring(run.Info.MapId)
local botCount = #run.Session.Bots:alive()
run.Stop()

print(("[Breach CI] map %s rendered: %d/%d parts; %d bots initialized")
    :format(mapId, rendered, expected, botCount))

return {
    MapId = mapId,
    RenderedParts = rendered,
    ExpectedParts = expected,
    BotCount = botCount,
    EngineVersion = Breach.version(),
}
