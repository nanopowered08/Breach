--!nonstrict
--[[
	BreachMission — the in-memory mission model (BreachEngine M3).

	Pure Luau, no requires, no Roblox APIs. Takes the table that BreachCodec produces, optionally runs
	BreachValidator over it, assigns stable ids and builds lookup indexes. It does NOT create game
	objects: materialising nodes into Roblox Instances (or any other engine's objects) is the host's job,
	driven by this model.

	    local mission = Mission.build(decoded, { validator = require("./BreachValidator") })
	    mission:byComponent("DelayedStateUpdate")   -- all BoolValue components of that Type
	    mission:byClass("Part")
	    mission:folder("Cells")
	    mission:findPath("Cells/Lobby")
	    mission:node("n42")

	Every node gets (in depth-first order):
	    Id        "n1", "n2", ...      stable within this build; Standalone files store it
	    Path      "DebugMission/Props/Door1"   (names; not unique)
	    RefPath   "3.12.2"             child indices from the root, as the codec's instance references use
	    Index     position among its parent's children
	Instance references in properties ({Ref = "3.12.2"}) additionally get `TargetId`.
]]

local Mission = {}
Mission.VERSION = "0.1.0"

local M = {}
M.__index = M

local function componentKey(node)
	if node.ClassName == "BoolValue" then
		return node.Attrs.Type
	end
	return node.Name
end
Mission.componentKey = componentKey

local function push(map, key, node)
	local list = map[key]
	if list == nil then
		list = {}
		map[key] = list
	end
	list[#list + 1] = node
end

function Mission.build(decoded, opts)
	opts = opts or {}
	local self = setmetatable({}, M)
	self.Root = decoded.Root
	self.Setup = decoded.Setup
	self.SetupSource = decoded.SetupSource
	self.SetupModules = decoded.SetupModules
	self.Settings = decoded.Settings
	self.Version = decoded.Version
	self.MapId = decoded.MapId
	self.Warnings = {}
	for _, w in ipairs(decoded.Warnings or {}) do
		self.Warnings[#self.Warnings + 1] = w
	end

	-- optional validation (engine mode by default: fills defaults, reports, keeps unknown attributes)
	if opts.validator and opts.validate ~= false then
		self.Validation = opts.validator.validateMission(decoded, {
			mode = opts.validateMode or "engine",
			includeDefaults = opts.includeDefaults,
			keepUnknown = opts.keepUnknown,
			inPlace = true,
		})
	end

	-- ids, paths, indexes
	local nodes, byId = {}, {}
	local classIdx, compIdx, tagIdx, netIdx = {}, {}, {}, {}
	local counter = 0
	local function walk(node, parent, index)
		counter = counter + 1
		node.Id = "n" .. counter
		node.Index = index
		node.Parent = parent
		if parent then
			node.Path = parent.Path .. "/" .. tostring(node.Name)
			node.RefPath = parent.RefPath == "" and tostring(index) or (parent.RefPath .. "." .. index)
		else
			node.Path = tostring(node.Name)
			node.RefPath = ""
		end
		nodes[counter] = node
		byId[node.Id] = node
		push(classIdx, node.ClassName, node)
		local key = componentKey(node)
		if key ~= nil and node.ClassName == "BoolValue" then
			push(compIdx, key, node)
		end
		local attrs = node.Attrs
		if type(attrs.Tag) == "string" then
			push(tagIdx, attrs.Tag, node)
		end
		if type(attrs.StaticTag) == "string" and attrs.StaticTag ~= attrs.Tag then
			push(tagIdx, attrs.StaticTag, node)
		end
		if type(attrs.NetworkId) == "number" then
			push(netIdx, attrs.NetworkId, node)
		end
		for i, c in ipairs(node.Children) do
			walk(c, node, i)
		end
	end
	walk(self.Root, nil, 1)
	self.Nodes = nodes
	self._byId, self._class, self._comp, self._tag, self._net = byId, classIdx, compIdx, tagIdx, netIdx

	-- resolve instance references
	self.UnresolvedRefs = 0
	for _, node in ipairs(nodes) do
		for _, v in pairs(node.Props) do
			if type(v) == "table" and type(v.Ref) == "string" then
				local target = self:resolveRef(v.Ref)
				if target then
					v.TargetId = target.Id
				else
					self.UnresolvedRefs = self.UnresolvedRefs + 1
					self.Warnings[#self.Warnings + 1] = "unresolved instance reference '" .. v.Ref .. "' on " .. node.Path
				end
			end
		end
	end
	return self
end

local EMPTY = {}

function M:node(id)
	return self._byId[id]
end

function M:byClass(className)
	return self._class[className] or EMPTY
end

function M:byComponent(key)
	return self._comp[key] or EMPTY
end

function M:byTag(tag)
	return self._tag[tag] or EMPTY
end

function M:byNetworkId(id)
	return self._net[id] or EMPTY
end

function M:folder(name)
	for _, c in ipairs(self.Root.Children) do
		if c.Name == name then
			return c
		end
	end
	return nil
end

-- "Cells/Lobby": first child with each name, level by level, starting below the root
function M:findPath(path)
	local cur = self.Root
	for part in string.gmatch(path, "[^/]+") do
		local nextNode
		for _, c in ipairs(cur.Children) do
			if c.Name == part then
				nextNode = c
				break
			end
		end
		if nextNode == nil then
			return nil
		end
		cur = nextNode
	end
	return cur
end

function M:resolveRef(ref)
	local cur = self.Root
	for idx in string.gmatch(ref, "%d+") do
		cur = cur.Children[tonumber(idx)]
		if cur == nil then
			return nil
		end
	end
	return cur
end

function M:componentTypes()
	local out = {}
	for k, list in pairs(self._comp) do
		out[k] = #list
	end
	return out
end

function M:stats()
	local classes = {}
	for k, list in pairs(self._class) do
		classes[k] = #list
	end
	return { nodes = #self.Nodes, classes = classes, components = self:componentTypes() }
end

return Mission
