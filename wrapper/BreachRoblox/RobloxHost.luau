--!nonstrict
--[==[
	BreachRoblox.RobloxHost — the Instance-based host for BreachRoblox.Core (adapter v0.1). Roblox only: it cannot run under the plain Luau CLI.

	Shows the mission as Parts under Workspace.BreachWorld:
	    Map/      the exported geometry (Geometry and Barrier folders), built in chunks so the server does not freeze
	    Bots/     one simple rig per engine bot (body, head, name + state label); moved every frame from the engine position
	    Debug/    optional: the patrol nodes
	Reads players from the Players service. A character can set the attribute "BreachStance" to "stand", "crouch" or "sprint", and "BreachArmed" (true/false; default: holding a Tool) and "BreachWeapon" ("holstered", "drawn" or "concealed"). Guards flee only from an armed player.
	Sets Workspace attribute "BreachAlertLevel" (0..3) when the alert level changes.
]==]

local Players = game:GetService("Players")

local Host = {}
Host.__index = Host

local CLASS_COLORS = {
	Sec = Color3.fromRGB(70, 90, 140),
	Civ = Color3.fromRGB(150, 150, 150),
}
local DEFAULT_COLOR = Color3.fromRGB(120, 120, 120)

function Host.new(options)
	options = options or {}
	local old = workspace:FindFirstChild("BreachWorld")
	if old then old:Destroy() end
	local root = Instance.new("Folder")
	root.Name = "BreachWorld"
	local map = Instance.new("Folder")
	map.Name = "Map"
	map.Parent = root
	local bots = Instance.new("Folder")
	bots.Name = "Bots"
	bots.Parent = root
	root.Parent = workspace
	return setmetatable({
		Root = root, MapFolder = map, BotsFolder = bots, Rigs = {}, Options = options,
		BotYOffset = options.BotYOffset or 2.5, PlayerYOffset = options.PlayerYOffset or 0,
	}, Host)
end

function Host:destroy()
	self.Root:Destroy()
	self.Rigs = {}
end

---------------------------------------------------------------------------------------------------------- bots
local function labelText(info, state)
	return ("%s\n%s"):format(tostring(info.Name), tostring(state or ""))
end

function Host:createBot(info)
	local model = Instance.new("Model")
	model.Name = "Bot_" .. tostring(info.Id)

	local body = Instance.new("Part")
	body.Name = "Body"
	body.Size = Vector3.new(2, 3, 1)
	body.Anchored = true
	body.CanCollide = false
	body.Material = Enum.Material.SmoothPlastic
	body.Color = CLASS_COLORS[info.Class] or DEFAULT_COLOR
	body.Parent = model

	local head = Instance.new("Part")
	head.Name = "Head"
	head.Shape = Enum.PartType.Ball
	head.Size = Vector3.new(1.2, 1.2, 1.2)
	head.Anchored = true
	head.CanCollide = false
	head.Material = Enum.Material.SmoothPlastic
	head.Color = Color3.fromRGB(235, 200, 170)
	head.CFrame = body.CFrame * CFrame.new(0, 2.1, 0)
	head.Parent = model

	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(180, 44)
	gui.StudsOffset = Vector3.new(0, 2.2, 0)
	gui.AlwaysOnTop = true
	gui.Adornee = head
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.4
	label.TextScaled = true
	label.Font = Enum.Font.GothamMedium
	label.Text = labelText(info, info.State)
	label.Parent = gui
	gui.Parent = head

	model.PrimaryPart = body
	model:SetAttribute("BotId", info.Id)
	model:SetAttribute("BotClass", info.Class)
	model:SetAttribute("BotWeapon", info.Weapon)
	model.Parent = self.BotsFolder
	self.Rigs[info.Id] = { Model = model, Label = label, Info = info, State = info.State }
end

function Host:updateBot(id, x, y, z, fx, fz, state)
	local rig = self.Rigs[id]
	if not rig then return end
	local pos = Vector3.new(x, y + self.BotYOffset, z)
	local look = Vector3.new(fx or 0, 0, fz or 1)
	if look.Magnitude < 1e-4 then look = Vector3.new(0, 0, 1) end
	rig.Model:PivotTo(CFrame.lookAt(pos, pos + look))
	if state ~= rig.State then
		rig.State = state
		rig.Label.Text = labelText(rig.Info, state)
		rig.Model:SetAttribute("BotState", state)
	end
end

function Host:removeBot(id)
	local rig = self.Rigs[id]
	if rig then
		rig.Model:Destroy()
		self.Rigs[id] = nil
	end
end

---------------------------------------------------------------------------------------------------------- alert and events
function Host:alertChanged(level, before)
	workspace:SetAttribute("BreachAlertLevel", level)
	if before ~= nil then
		print(("[Breach] alert level %s -> %s"):format(tostring(before), tostring(level)))
	end
end

function Host:event(ev)
	if self.Options.LogEvents then
		print(("[Breach] %s.%s %s"):format(tostring(ev.Source), tostring(ev.Kind), tostring(ev.Bot or ev.Spawner or ev.Level or "")))
	end
end

---------------------------------------------------------------------------------------------------------- players
function Host:getPlayers()
	local out = {}
	for _, plr in ipairs(Players:GetPlayers()) do
		local char = plr.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if hrp then
			local p = hrp.Position
			-- armed: the attribute "BreachArmed" (true/false) wins; without it a character holding a Tool counts as armed [P]
			local armed = char:GetAttribute("BreachArmed")
			if armed == nil then armed = char:FindFirstChildOfClass("Tool") ~= nil end
			-- weapon state (M9a): the attribute "BreachWeapon" = "holstered" | "drawn" | "concealed"; without it, armed means "drawn"
			local weapon = char:GetAttribute("BreachWeapon")
			if weapon ~= "holstered" and weapon ~= "drawn" and weapon ~= "concealed" then weapon = armed and "drawn" or "holstered" end
			out[#out + 1] = { Id = tostring(plr.UserId), X = p.X, Y = p.Y + self.PlayerYOffset, Z = p.Z, Stance = char:GetAttribute("BreachStance") or "stand", Armed = weapon == "drawn", Weapon = weapon }
		end
	end
	return out
end

---------------------------------------------------------------------------------------------------------- the map
local function cframeOf(props)
	local cf = props.CFrame
	if not cf or not cf.Position then return nil end
	local p, e = cf.Position, cf.EulerXYZ or { X = 0, Y = 0, Z = 0 }
	return CFrame.new(p.X, p.Y, p.Z) * CFrame.fromEulerAnglesXYZ(e.X, e.Y, e.Z)
end

-- Builds the geometry of a mission (a BreachMission) as Parts. Yields (task.wait) every 250 parts. Returns the number of parts made.
function Host:renderMap(mission, options)
	options = options or {}
	local count = 0
	local function makePart(node, group, barrier)
		local props = node.Props or {}
		local cf, size = cframeOf(props), props.Size
		if not cf or not size then return end
		local part = Instance.new(node.ClassName)
		part.Name = node.Name
		part.Anchored = true
		part.Size = Vector3.new(size.X, size.Y, size.Z)
		part.CFrame = cf
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		if barrier then
			part.Color = Color3.fromRGB(200, 40, 40)
			part.Transparency = options.ShowBarriers and 0.8 or 1
			part.CanQuery = false
		else
			if props.Color then part.Color = Color3.new(props.Color.R or 0, props.Color.G or 0, props.Color.B or 0) end
			local okM, mat = pcall(function() return Enum.Material[props.Material] end)
			if okM and mat then part.Material = mat end
			if node.ClassName == "Part" and props.Shape and props.Shape ~= "Block" then
				pcall(function() part.Shape = Enum.PartType[props.Shape] end)
			end
			part.Transparency = props.Transparency or 0
			if props.CanCollide == false then part.CanCollide = false end
		end
		part.Parent = group
		count += 1
		if count % 250 == 0 then task.wait() end
	end
	local function walk(node, group, barrier)
		if node.ClassName == "Part" or node.ClassName == "WedgePart" then
			makePart(node, group, barrier)
		end
		for _, child in ipairs(node.Children or {}) do walk(child, group, barrier) end
	end
	for _, folderName in ipairs(options.Folders or { "Geometry", "Barrier" }) do
		local folder = mission:folder(folderName)
		if folder then
			local group = Instance.new("Folder")
			group.Name = folderName
			group.Parent = self.MapFolder
			walk(folder, group, folderName == "Barrier")
		end
	end
	if options.ShowNodes then
		local debug = Instance.new("Folder")
		debug.Name = "Debug"
		debug.Parent = self.Root
		local nodes = mission:folder("Nodes")
		local function mark(node)
			local cf = node.Props and cframeOf(node.Props)
			if cf then
				local dot = Instance.new("Part")
				dot.Shape = Enum.PartType.Ball
				dot.Size = Vector3.new(1, 1, 1)
				dot.Anchored = true
				dot.CanCollide = false
				dot.CanQuery = false
				dot.Material = Enum.Material.Neon
				dot.Color = Color3.fromRGB(0, 255, 120)
				dot.CFrame = cf
				dot.Name = node.Name
				dot.Parent = debug
			end
			for _, child in ipairs(node.Children or {}) do mark(child) end
		end
		if nodes then mark(nodes) end
	end
	return count
end

-- Places prop and door models from the prop library (a Folder of Models, each with a `Base` part) at the given placements (see Core.propPlacements).
-- Everything is anchored. Doors are shown closed; they do not open yet. Yields every 50 props. Returns how many models were placed.
function Host:renderProps(placements, library)
	local group = Instance.new("Folder")
	group.Name = "Props"
	group.Parent = self.MapFolder
	local placed = 0
	for i, p in ipairs(placements) do
		local template = library:FindFirstChild(p.Name)
		if template then
			local target = CFrame.new(p.X, p.Y, p.Z) * CFrame.fromEulerAnglesXYZ(p.Rx, p.Ry, p.Rz)
			for leaf = 1, p.Leaves do
				local clone = template:Clone()
				local base = clone:FindFirstChild("Base")
				local offset = base and base:IsA("BasePart") and base.CFrame:ToObjectSpace(clone:GetPivot()) or CFrame.identity
				local cf = target
				if p.Leaves == 2 then
					local dx = p.SizeX / 4
					if leaf == 1 then
						cf = target * CFrame.new(-dx, 0, 0)
					else
						cf = target * CFrame.new(dx, 0, 0) * CFrame.Angles(0, math.pi, 0)
					end
				end
				clone:PivotTo(cf * offset)
				for _, d in ipairs(clone:GetDescendants()) do
					if d:IsA("BasePart") then d.Anchored = true end
				end
				clone.Parent = group
				placed += 1
			end
		end
		if i % 50 == 0 then task.wait() end
	end
	return placed
end

-- Applies a mission's `LightingSettings` (MissionSetup) from the prop library's lighting presets: a Folder per preset whose attributes are
-- Lighting properties (Brightness, OutdoorAmbient, EnvironmentDiffuseScale) and whose children are the effects (Sky, Atmosphere, Blur, SunRays,
-- ColorCorrection, Clouds). `setting` is the preset name, or a table that holds it (`Preset` / `Name` / first entry). `presets` is
-- ReplicatedStorage.Assets.LightingSettings. Effects of a class the preset brings replace the ones already in Lighting; Clouds go under
-- Workspace.Terrain (the only place Studio shows them). Returns the preset name, or nil, reason.
function Host:applyLighting(setting, presets)
	local name = setting
	if type(setting) == "table" then
		name = setting.Preset or setting.Name or setting[1]
	end
	if type(name) ~= "string" or name == "" then
		return nil, "the mission's LightingSettings is not a preset name"
	end
	if not presets then
		return nil, "no lighting presets (ReplicatedStorage.Assets.LightingSettings)"
	end
	local folder = presets:FindFirstChild(name)
	if not folder then
		local have = {}
		for _, c in ipairs(presets:GetChildren()) do have[#have + 1] = c.Name end
		return nil, ("no lighting preset named \"%s\" (have: %s)"):format(name, table.concat(have, ", "))
	end
	local Lighting = game:GetService("Lighting")
	local brought = {}
	for _, c in ipairs(folder:GetChildren()) do brought[c.ClassName] = true end
	for _, c in ipairs(Lighting:GetChildren()) do
		if brought[c.ClassName] then c:Destroy() end
	end
	if brought.Clouds then
		for _, c in ipairs(workspace.Terrain:GetChildren()) do
			if c:IsA("Clouds") then c:Destroy() end
		end
	end
	for key, value in pairs(folder:GetAttributes()) do
		pcall(function() Lighting[key] = value end)
	end
	for _, c in ipairs(folder:GetChildren()) do
		local clone = c:Clone()
		clone.Parent = c:IsA("Clouds") and workspace.Terrain or Lighting
	end
	return name
end

return Host
