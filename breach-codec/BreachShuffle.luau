--!nonstrict
--[==[
	BreachShuffle — randomisation of the physical layout (BreachEngine M11; plan: docs/BreachEngine_M11_Randomisation_Plan.md).

	M11.0 (this file so far): the SURVEY. It reads what a mission declares about shuffling and changes nothing: no behaviour, no moves.
	Pure Luau, no requires, no Roblox APIs.

	    local survey = Shuffle.survey(mission)      -- mission.Nodes is walked (any class, anywhere in the tree)
	    survey.Collections   list of {Id, Path, Class, Name, Attrs, Position, Size}   nodes named "PartCollection" or carrying the attribute PartCollection
	    survey.Targets       the same for nodes named "ShuffleTarget" (or, unnamed, carrying a ShuffleTag)
	    survey.Movers        every OTHER node with a `ShuffleTarget` attribute: something that asks to be moved to a target
	    survey.Folders       Folder/Model nodes with folder-level options (Condition, PickCount, PickSeed, ShuffleContents, ResolvePriority)
	    survey.AttrCounts    { Collection = {attr = n}, Target = {attr = n}, Mover = {attr = n}, Folder = {attr = n} }   which attributes exist, and how often
	    survey.Values        { ShuffleTag = {value = n}, Index, MatchVariable, ResolvePriority, Move, Open, Path, Location, Sound, OnProp, ... }
	    survey.Tags          { [tag] = {Collections, Movers, Targets, Indexes = {index = n}, AskSizes = {"AxBxC" = n}, TargetSizes = {...}} }
	    survey.MoverKinds    { ["Class:Name"] = n }
	    survey.Totals        {Collections, Targets, Movers, Folders}

	What the Blacksite data showed (docs 7.5): every PartCollection carries `ShuffleTarget = <tag>` (the tag it wants, NOT a target itself),
	the tags (`ShuffleTag`) live on the targets, `MatchVariable` is empty on every target and `ResolvePriority` is 2 everywhere.
	    Shuffle.report(survey, maxLines)            -- the survey as lines of text (the adapter prints it)

	What `MatchVariable` and `ResolvePriority` mean is not documented anywhere (see the plan): the survey exists so the real data can say.
]==]

local Shuffle = {}
Shuffle.VERSION = "0.2.0"

local FOLDER_ATTRS = { "Condition", "PickCount", "PickSeed", "ShuffleContents", "ResolvePriority" }
local VALUE_ATTRS = { "ShuffleTag", "Index", "MatchVariable", "ResolvePriority", "ShuffleTargetRotation", "Move", "Open", "Path", "Location", "Sound", "OnProp", "CollectionEnabled", "RemovedVariable", "InstantOpenDoorDetection", "LockOutPlayers" }
local MAX_DISTINCT = 60 -- distinct values kept per attribute; the rest are counted under "(others)"

local function bump(t, key, n)
	t[key] = (t[key] or 0) + (n or 1)
end

-- a stable text for an attribute value (never a table address)
local function show(v)
	local t = type(v)
	if t == "string" then
		return v
	elseif t == "number" or t == "boolean" then
		return tostring(v)
	elseif t == "table" then
		if type(v.X) == "number" and type(v.Y) == "number" and type(v.Z) == "number" then
			return "(" .. tostring(v.X) .. "," .. tostring(v.Y) .. "," .. tostring(v.Z) .. ")"
		end
		return "{" .. tostring(v.Type or "table") .. "}"
	end
	return t
end

local function sizeKey(size)
	if size then
		return tostring(size.X) .. "x" .. tostring(size.Y) .. "x" .. tostring(size.Z)
	end
	return nil
end

local function xyz(v)
	if type(v) == "table" and type(v.X) == "number" then
		return { X = v.X, Y = v.Y or 0, Z = v.Z or 0 }
	end
	return nil
end

local function describe(node, kind)
	local props = node.Props
	local cf = props and props.CFrame
	return {
		Id = node.Id, Path = node.Path, Class = node.ClassName, Name = node.Name, Kind = kind,
		Attrs = node.Attrs or {},
		Position = xyz(cf and cf.Position), Size = xyz(props and props.Size),
	}
end

function Shuffle.survey(mission)
	local s = {
		Collections = {}, Targets = {}, Movers = {}, Folders = {},
		AttrCounts = { Collection = {}, Target = {}, Mover = {}, Folder = {} },
		Values = {}, Tags = {}, MoverKinds = {},
		Totals = { Collections = 0, Targets = 0, Movers = 0, Folders = 0 },
		Warnings = {},
	}
	for _, a in ipairs(VALUE_ATTRS) do
		s.Values[a] = {}
	end
	local nodes = type(mission) == "table" and mission.Nodes
	if type(nodes) ~= "table" then
		s.Warnings[#s.Warnings + 1] = "the mission has no node list; nothing surveyed"
		return s
	end

	local distinct = {} -- attribute -> how many distinct values are kept so far
	local function addValues(attrs)
		for _, a in ipairs(VALUE_ATTRS) do
			local v = attrs[a]
			if v ~= nil then
				local bucket, key = s.Values[a], show(v)
				if bucket[key] == nil then
					if (distinct[a] or 0) < MAX_DISTINCT then
						distinct[a] = (distinct[a] or 0) + 1
					else
						key = "(others)"
					end
				end
				bump(bucket, key)
			end
		end
	end
	local function tagEntry(tag)
		local t = s.Tags[tag]
		if not t then
			t = { Collections = 0, Movers = 0, Targets = 0, Indexes = {}, AskSizes = {}, TargetSizes = {} }
			s.Tags[tag] = t
		end
		return t
	end
	-- the tag a collection or mover asks for: its `ShuffleTarget` attribute (a string) [O: Blacksite], or a ShuffleTag
	local function askedTag(attrs)
		if type(attrs.ShuffleTarget) == "string" and attrs.ShuffleTarget ~= "" then
			return attrs.ShuffleTarget
		end
		if attrs.ShuffleTag ~= nil then
			return show(attrs.ShuffleTag)
		end
		return nil
	end

	for _, node in ipairs(nodes) do
		local attrs = node.Attrs or {}
		local isCollection = node.Name == "PartCollection" or attrs.PartCollection ~= nil
		local isTarget = not isCollection and (node.Name == "ShuffleTarget" or attrs.ShuffleTag ~= nil)
		local isMover = not isCollection and not isTarget and attrs.ShuffleTarget ~= nil
		if isCollection then
			local d = describe(node, "Collection")
			s.Collections[#s.Collections + 1] = d
			s.Totals.Collections += 1
			for k in pairs(attrs) do
				bump(s.AttrCounts.Collection, k)
			end
			addValues(attrs)
			local tag = askedTag(attrs)
			if tag then
				local t = tagEntry(tag)
				t.Collections += 1
				if d.Size then
					bump(t.AskSizes, sizeKey(d.Size))
				end
				if attrs.Index ~= nil then
					bump(t.Indexes, show(attrs.Index))
				end
			end
		elseif isTarget then
			local d = describe(node, "Target")
			s.Targets[#s.Targets + 1] = d
			s.Totals.Targets += 1
			for k in pairs(attrs) do
				bump(s.AttrCounts.Target, k)
			end
			addValues(attrs)
			if attrs.ShuffleTag ~= nil then
				local t = tagEntry(show(attrs.ShuffleTag))
				t.Targets += 1
				if d.Size then
					bump(t.TargetSizes, sizeKey(d.Size))
				end
				if attrs.Index ~= nil then
					bump(t.Indexes, show(attrs.Index))
				end
			end
		elseif isMover then
			s.Movers[#s.Movers + 1] = describe(node, "Mover")
			s.Totals.Movers += 1
			bump(s.MoverKinds, node.ClassName .. ":" .. tostring(node.Name))
			for k in pairs(attrs) do
				bump(s.AttrCounts.Mover, k)
			end
			addValues(attrs)
			local tag = askedTag(attrs)
			if tag then
				tagEntry(tag).Movers += 1
			end
		elseif node.ClassName == "Folder" or node.ClassName == "Model" then
			local found = false
			for _, a in ipairs(FOLDER_ATTRS) do
				if attrs[a] ~= nil then
					found = true
					bump(s.AttrCounts.Folder, a)
				end
			end
			if found then
				s.Folders[#s.Folders + 1] = describe(node, "Folder")
				s.Totals.Folders += 1
			end
		end
	end
	if s.Totals.Collections == 0 and s.Totals.Targets == 0 then
		s.Warnings[#s.Warnings + 1] = "no PartCollection or ShuffleTarget found: the mission has no physical shuffle"
	elseif s.Totals.Collections == 0 or s.Totals.Targets == 0 then
		s.Warnings[#s.Warnings + 1] = ("PartCollection %d, ShuffleTarget %d: one side is missing, nothing can be moved"):format(s.Totals.Collections, s.Totals.Targets)
	end
	-- demand against supply, tag by tag (sorted, so the text is deterministic)
	local names = {}
	for tag in pairs(s.Tags) do
		names[#names + 1] = tag
	end
	table.sort(names)
	for _, tag in ipairs(names) do
		local g = s.Tags[tag]
		local asks = g.Collections + g.Movers
		if asks > 0 and g.Targets == 0 then
			s.Warnings[#s.Warnings + 1] = ("tag %s is asked for by %d but has no target"):format(tag, asks)
		elseif asks > g.Targets then
			s.Warnings[#s.Warnings + 1] = ("tag %s is asked for by %d but has only %d targets (are targets reused?)"):format(tag, asks, g.Targets)
		end
	end
	return s
end

-- "name=count" pairs, biggest first (ties by name), at most `limit` of them, then "... +N more"
local function top(map, limit, numericKeys)
	local list = {}
	for k, n in pairs(map) do
		list[#list + 1] = { k = k, n = n }
	end
	table.sort(list, function(a, b)
		if a.n ~= b.n then
			return a.n > b.n
		end
		local an, bn = tonumber(a.k), tonumber(b.k)
		if numericKeys and an and bn and an ~= bn then
			return an < bn
		end
		return a.k < b.k
	end)
	local out = {}
	for i = 1, math.min(#list, limit) do
		out[#out + 1] = list[i].k .. "=" .. list[i].n
	end
	if #list > limit then
		out[#out + 1] = ("... +%d more"):format(#list - limit)
	end
	return table.concat(out, ", "), #list
end

function Shuffle.report(survey, maxLines)
	maxLines = maxLines or 40
	local lines = {}
	local function add(text)
		lines[#lines + 1] = text
	end
	local t = survey.Totals
	add(("%d PartCollection, %d ShuffleTarget, %d movers (other nodes with a ShuffleTarget attribute), %d folders with folder-level options"):format(t.Collections, t.Targets, t.Movers or 0, t.Folders))
	for _, kind in ipairs({ "Collection", "Target", "Mover", "Folder" }) do
		local text, n = top(survey.AttrCounts[kind] or {}, 16)
		if n > 0 then
			add(("%s attributes: %s"):format(kind, text))
		end
	end
	local mk, mn = top(survey.MoverKinds or {}, 8)
	if mn > 0 then
		add(("movers by kind: %s"):format(mk))
	end
	for _, a in ipairs(VALUE_ATTRS) do
		local text, n = top(survey.Values[a], 10, true)
		if n > 0 then
			add(("%s (%d distinct): %s"):format(a, n, text))
		end
	end
	local tags = {}
	for tag in pairs(survey.Tags) do
		tags[#tags + 1] = tag
	end
	table.sort(tags)
	for _, tag in ipairs(tags) do
		local g = survey.Tags[tag]
		local idx = top(g.Indexes, 10, true)
		local ask, tgt = top(g.AskSizes or {}, 2), top(g.TargetSizes or {}, 2)
		local line = ("tag %s: %d collections, %d targets"):format(tag, g.Collections, g.Targets)
		if (g.Movers or 0) > 0 then
			line ..= (", %d movers"):format(g.Movers)
		end
		if idx ~= "" then
			line ..= ", indexes " .. idx
		end
		if ask ~= "" or tgt ~= "" then
			line ..= (", sizes: ask [%s] targets [%s]"):format(ask, tgt)
		end
		add(line)
	end
	for _, w in ipairs(survey.Warnings) do
		add("warning: " .. w)
	end
	if #lines > maxLines then
		local extra = #lines - (maxLines - 1)
		for i = #lines, maxLines, -1 do
			lines[i] = nil
		end
		add(("... (%d more lines)"):format(extra))
	end
	return lines
end

return Shuffle
