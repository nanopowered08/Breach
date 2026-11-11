--!nonstrict
-- Tests for BreachShuffle (M11.0, the survey). Synthetic missions only: no map data needed.
local Shuffle = require("../BreachShuffle")

return function(check)
	local counter = 0
	local function node(class, name, attrs, x, y, z, sx, sy, sz)
		counter += 1
		local n = { Id = "n" .. counter, Path = "M/" .. name .. counter, ClassName = class, Name = name, Attrs = attrs or {}, Children = {}, Props = {} }
		if x then
			n.Props.CFrame = { Position = { X = x, Y = y or 0, Z = z or 0 } }
			n.Props.Size = { X = sx or 4, Y = sy or 4, Z = sz or 4 }
		end
		return n
	end
	local function mission(list) return { Nodes = list } end

	local list = {
		node("Part", "PartCollection", { ShuffleTag = "Wing", Index = 1 }, 100, 0, 0, 30, 10, 30),
		node("Part", "PartCollection", { ShuffleTag = "Wing", Index = 2 }, 200, 0, 0),
		node("Part", "PartCollection", { ShuffleTag = "Lab" }),
		node("Part", "ShuffleTarget", { ShuffleTag = "Wing", Index = 1, MatchVariable = "WingA", ResolvePriority = 5 }, 0, 0, 0),
		node("Part", "ShuffleTarget", { ShuffleTag = "Wing", Index = 2, MatchVariable = "WingB", ResolvePriority = 5 }),
		node("Part", "ShuffleTarget", { ShuffleTag = "Wing", Index = 2, MatchVariable = "WingB", ResolvePriority = 1 }),
		node("Part", "ShuffleTarget", { ShuffleTag = "Lab", Index = 7 }),
		node("Model", "Annex", { PartCollection = true, ShuffleTag = "Lab" }), -- carries the attribute instead of the name
		node("Folder", "Boxes", { PickCount = 2, PickSeed = 9, Condition = "Roll == 1" }),
		node("Folder", "Plain", {}),
		node("Part", "WoodChair", {}),
	}
	local s = Shuffle.survey(mission(list))

	check("shuffle: collections counted by name and by attribute", s.Totals.Collections == 4 and #s.Collections == 4)
	check("shuffle: targets counted", s.Totals.Targets == 4 and #s.Targets == 4)
	check("shuffle: a Folder with folder-level options is listed, a plain one is not", s.Totals.Folders == 1 and s.Folders[1].Name == "Boxes")
	check("shuffle: folder attributes are counted", s.AttrCounts.Folder.PickCount == 1 and s.AttrCounts.Folder.Condition == 1 and s.AttrCounts.Folder.PickSeed == 1)
	check("shuffle: target attributes are counted", s.AttrCounts.Target.MatchVariable == 3 and s.AttrCounts.Target.ShuffleTag == 4)
	check("shuffle: a collection keeps its position and size", s.Collections[1].Position.X == 100 and s.Collections[1].Size.X == 30 and s.Collections[3].Position == nil)
	check("shuffle: values are tallied over collections and targets", s.Values.ShuffleTag.Wing == 5 and s.Values.ShuffleTag.Lab == 3, s.Values.ShuffleTag.Wing)
	check("shuffle: MatchVariable and ResolvePriority values are visible", s.Values.MatchVariable.WingB == 2 and s.Values.ResolvePriority["5"] == 2 and s.Values.ResolvePriority["1"] == 1)
	check("shuffle: per tag counts", s.Tags.Wing.Collections == 2 and s.Tags.Wing.Targets == 3 and s.Tags.Lab.Collections == 2 and s.Tags.Lab.Targets == 1)
	check("shuffle: per tag indexes", s.Tags.Wing.Indexes["2"] == 3 and s.Tags.Wing.Indexes["1"] == 2)
	check("shuffle: demand against supply is checked per tag: Lab is asked for by 2 but has 1 target, Wing is fine", #s.Warnings == 1 and string.find(s.Warnings[1], "tag Lab is asked for by 2 but has only 1 targets", 1, true) ~= nil, s.Warnings[1])

	local lines = Shuffle.report(s)
	local text = table.concat(lines, "\n")
	check("shuffle: the report starts with the totals", lines[1] == "4 PartCollection, 4 ShuffleTarget, 0 movers (other nodes with a ShuffleTarget attribute), 1 folders with folder-level options", lines[1])
	check("shuffle: the report shows the MatchVariable values", string.find(text, "MatchVariable (2 distinct): WingB=2, WingA=1", 1, true) ~= nil, text)
	check("shuffle: the report shows a tag line with its indexes", string.find(text, "tag Wing: 2 collections, 3 targets, indexes 2=3, 1=2", 1, true) ~= nil, text)
	check("shuffle: the report is deterministic", table.concat(Shuffle.report(Shuffle.survey(mission(list))), "\n") == text)
	check("shuffle: the report can be cut to a line limit", (function() local cut = Shuffle.report(s, 3) return #cut == 3 and string.find(cut[3], "more lines", 1, true) ~= nil end)())

	-- the Blacksite shape [O]: a collection carries `ShuffleTarget = <tag>` (the tag it WANTS); the tags (`ShuffleTag`) live on the targets
	do
		local bl = {
			node("Part", "PartCollection", { ShuffleTarget = "Zone1_A", ResolvePriority = 2 }, 0, 0, 0, 30, 10, 30),
			node("Part", "PartCollection", { ShuffleTarget = "Zone1_A", ResolvePriority = 2 }, 50, 0, 0, 30, 10, 30),
			node("Part", "PartCollection", { ShuffleTarget = "Zone1_B", ResolvePriority = 2, ShuffleTargetRotation = true }, 100, 0, 0, 20, 10, 20),
			node("Part", "ShuffleTarget", { ShuffleTag = "Zone1_A", MatchVariable = "", ResolvePriority = 2, Move = { X = 1, Y = 0, Z = 2 } }, 200, 0, 0, 30, 10, 30),
			node("Part", "ShuffleTarget", { ShuffleTag = "Zone1_A", MatchVariable = "", ResolvePriority = 2, Open = true }, 300, 0, 0, 30, 10, 30),
			node("Part", "ShuffleTarget", { ShuffleTag = "Zone1_A", MatchVariable = "", ResolvePriority = 2, Open = true }, 400, 0, 0, 24, 10, 24),
			node("Part", "ShuffleTarget", { ShuffleTag = "Zone1_B", MatchVariable = "" }, 500, 0, 0, 20, 10, 20),
			node("Part", "DoorMetal", { ShuffleTarget = "Zone1_A" }), -- a mover: something else that asks for a target
			node("Part", "Chair", {}),
		}
		local b = Shuffle.survey(mission(bl))
		check("blacksite: a collection with the attribute ShuffleTarget is a collection, NOT a target", b.Totals.Collections == 3 and b.Totals.Targets == 4, b.Totals.Targets)
		check("blacksite: another node with the attribute is a mover, counted apart", b.Totals.Movers == 1 and b.MoverKinds["Part:DoorMetal"] == 1)
		check("blacksite: the tag a collection asks for is its ShuffleTarget attribute", b.Tags.Zone1_A.Collections == 2 and b.Tags.Zone1_B.Collections == 1 and b.Tags.Zone1_A.Movers == 1)
		check("blacksite: targets are counted under their own ShuffleTag", b.Tags.Zone1_A.Targets == 3 and b.Tags.Zone1_B.Targets == 1)
		check("blacksite: sizes of what asks and of the targets are tallied per tag", b.Tags.Zone1_A.AskSizes["30x10x30"] == 2 and b.Tags.Zone1_A.TargetSizes["30x10x30"] == 2 and b.Tags.Zone1_A.TargetSizes["24x10x24"] == 1)
		check("blacksite: an empty MatchVariable is visible as the empty string", b.Values.MatchVariable[""] == 4)
		check("blacksite: the other target attributes are tallied (Open, Move)", b.Values.Open["true"] == 2 and b.Values.Move["(1,0,2)"] == 1)
		check("blacksite: a table value shows as text, never as an address", (function() local v = Shuffle.survey(mission({ node("Part", "ShuffleTarget", { ShuffleTag = "T", Path = { Type = "Vector3int16" } }) })).Values.Path return v["{Vector3int16}"] == 1 end)())
		check("blacksite: supply covers demand for Zone1_B, Zone1_A is asked for by 3 and has 3 targets: no warning", #b.Warnings == 0, b.Warnings[1])
		local text = table.concat(Shuffle.report(b), "\n")
		check("blacksite: the report line for a tag shows demand, supply and sizes", string.find(text, "tag Zone1_A: 2 collections, 3 targets, 1 movers, sizes: ask [30x10x30=2] targets [30x10x30=2, 24x10x24=1]", 1, true) ~= nil, text)
		check("blacksite: the report lists the mover kinds", string.find(text, "movers by kind: Part:DoorMetal=1", 1, true) ~= nil, text)
	end

	-- degenerate missions
	local e = Shuffle.survey(mission({ node("Part", "WoodChair", {}) }))
	check("shuffle: no shuffle in the mission: totals are zero and it says so", e.Totals.Collections == 0 and e.Totals.Targets == 0 and #e.Warnings == 1 and string.find(e.Warnings[1], "no physical shuffle", 1, true) ~= nil)
	local one = Shuffle.survey(mission({ node("Part", "PartCollection", { ShuffleTag = "A" }) }))
	check("shuffle: collections without targets are reported", #one.Warnings == 2 and string.find(one.Warnings[1], "one side is missing", 1, true) ~= nil and string.find(one.Warnings[2], "tag A is asked for by 1 but has no target", 1, true) ~= nil)
	local none = Shuffle.survey(nil)
	check("shuffle: no mission: no crash, one warning", none.Totals.Collections == 0 and #none.Warnings == 1)
	check("shuffle: the report works on an empty survey", #Shuffle.report(none) >= 1)

	-- a lot of distinct values are capped, the rest are counted together
	local many = {}
	for i = 1, 90 do
		many[#many + 1] = node("Part", "ShuffleTarget", { ShuffleTag = "T" .. i })
	end
	local m = Shuffle.survey(mission(many))
	local keys = 0
	for _ in pairs(m.Values.ShuffleTag) do keys += 1 end
	check("shuffle: distinct values are capped (60 kept + '(others)')", keys == 61 and m.Values.ShuffleTag["(others)"] == 30, keys)
end
