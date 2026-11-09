--!nonstrict
--[==[
	BreachShuffle — randomisation of the physical layout (BreachEngine M11; plan: docs/BreachEngine_M11_Randomisation_Plan.md).

	M11.0 (this file so far): the SURVEY. It reads what a mission declares about shuffling and changes nothing: no behaviour, no moves.
	Pure Luau, no requires, no Roblox APIs.

	    local survey = Shuffle.survey(mission)      -- mission.Nodes is walked (any class, anywhere in the tree)
	    survey.Collections   list of {Id, Path, Class, Name, Attrs, Position, Size}   nodes named "PartCollection" or carrying the attribute PartCollection
	    survey.Targets       the same for "ShuffleTarget"
	    survey.Folders       Folder/Model nodes with folder-level options (Condition, PickCount, PickSeed, ShuffleContents, ResolvePriority)
	    survey.AttrCounts    { Collection = {attr = n}, Target = {attr = n}, Folder = {attr = n} }   which attributes exist, and how often
	    survey.Values        { ShuffleTag = {value = n}, Index = ..., MatchVariable = ..., ResolvePriority = ... }   over collections and targets
	    survey.Tags          { [tag] = {Collections = n, Targets = n, Indexes = {index = n}} }
	    survey.Totals        {Collections, Targets, Folders}
	    Shuffle.report(survey, maxLines)            -- the survey as lines of text (the adapter prints it)

	What `MatchVariable` and `ResolvePriority` mean is not documented anywhere (see the plan): the survey exists so the real data can say.
]==]

local Shuffle = {}
Shuffle.VERSION = "0.1.0"

local FOLDER_ATTRS = { "Condition", "PickCount", "PickSeed", "ShuffleContents", "ResolvePriority" }
local VALUE_ATTRS = { "ShuffleTag", "Index", "MatchVariable", "ResolvePriority" }
local MAX_DISTINCT = 60 -- distinct values kept per attribute; the rest are counted under "(others)"

local function bump(t, key, n)
	t[key] = (t[key] or 0) + (n or 1)
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
		Collections = {}, Targets = {}, Folders = {},
		AttrCounts = { Collection = {}, Target = {}, Folder = {} },
		Values = {}, Tags = {},
		Totals = { Collections = 0, Targets = 0, Folders = 0 },
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
				local bucket, key = s.Values[a], tostring(v)
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

	for _, node in ipairs(nodes) do
		local attrs = node.Attrs or {}
		local isCollection = node.Name == "PartCollection" or attrs.PartCollection ~= nil
		local isTarget = node.Name == "ShuffleTarget" or attrs.ShuffleTarget ~= nil
		if isCollection then
			s.Collections[#s.Collections + 1] = describe(node, "Collection")
			s.Totals.Collections += 1
			for k in pairs(attrs) do
				bump(s.AttrCounts.Collection, k)
			end
			addValues(attrs)
		end
		if isTarget then
			s.Targets[#s.Targets + 1] = describe(node, "Target")
			s.Totals.Targets += 1
			for k in pairs(attrs) do
				bump(s.AttrCounts.Target, k)
			end
			addValues(attrs)
		end
		if (isCollection or isTarget) and attrs.ShuffleTag ~= nil then
			local tag = tostring(attrs.ShuffleTag)
			local t = s.Tags[tag]
			if not t then
				t = { Collections = 0, Targets = 0, Indexes = {} }
				s.Tags[tag] = t
			end
			if isCollection then
				t.Collections += 1
			end
			if isTarget then
				t.Targets += 1
			end
			if attrs.Index ~= nil then
				bump(t.Indexes, tostring(attrs.Index))
			end
		end
		if not isCollection and not isTarget and (node.ClassName == "Folder" or node.ClassName == "Model") then
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
	local function add(s)
		lines[#lines + 1] = s
	end
	local t = survey.Totals
	add(("%d PartCollection, %d ShuffleTarget, %d folders with folder-level options"):format(t.Collections, t.Targets, t.Folders))
	for _, kind in ipairs({ "Collection", "Target", "Folder" }) do
		local text, n = top(survey.AttrCounts[kind], 14)
		if n > 0 then
			add(("%s attributes: %s"):format(kind, text))
		end
	end
	for _, a in ipairs(VALUE_ATTRS) do
		local text, n = top(survey.Values[a], 12, true)
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
		add(("tag %s: %d collections, %d targets%s"):format(tag, g.Collections, g.Targets, idx ~= "" and (", indexes " .. idx) or ""))
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
