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
	check("shuffle: demand against supply is checked per tag: Lab is asked for by 2 but has 1 target, Wing is fine", #s.Warnings == 1 and string.find(s.Warnings[1], "tag Lab is asked for by 2 collections but has only 1 targets", 1, true) ~= nil, s.Warnings[1])

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

	-------------------------------------------------------------------------------- M11.1a: the layout
	do
		local function item(name, attrs, x, y, z, sx, sy, sz, yaw)
			counter += 1
			return { Id = "n" .. counter, Path = "M/" .. name .. counter, ClassName = "Part", Name = name, Attrs = attrs or {}, Children = {},
				Props = { CFrame = { Position = { X = x, Y = y, Z = z }, EulerXYZ = { X = 0, Y = yaw or 0, Z = 0 } }, Size = { X = sx, Y = sy, Z = sz } } }
		end
		-- 3 collections ask for tag A (7 targets), 1 for B (1 target, 4 rotation steps), 2 for C (1 target: not enough), 1 for D (none), 1 has no tag
		local L = {}
		for i = 1, 3 do L[#L + 1] = item("PartCollection", { ShuffleTarget = "A" }, i * 100, 14, 0, 32, 28, 32) end
		L[#L + 1] = item("PartCollection", { ShuffleTarget = "B", ShuffleTargetRotation = 4 }, 400, 14, 0, 32, 28, 32)
		for i = 1, 2 do L[#L + 1] = item("PartCollection", { ShuffleTarget = "C" }, 500 + i, 14, 0, 20, 28, 20) end
		L[#L + 1] = item("PartCollection", { ShuffleTarget = "D" }, 600, 14, 0, 20, 28, 20)
		L[#L + 1] = item("PartCollection", {}, 700, 14, 0, 20, 28, 20)
		for i = 1, 7 do L[#L + 1] = item("ShuffleTarget", { ShuffleTag = "A" }, 1000 + i * 50, 6, 200, 24, 12, 24) end
		L[#L + 1] = item("ShuffleTarget", { ShuffleTag = "B" }, 2000, 6, 300, 24, 12, 24, math.pi / 2)
		L[#L + 1] = item("ShuffleTarget", { ShuffleTag = "C" }, 3000, 6, 400, 12, 12, 12)

		local lay = Shuffle.layout(mission(L), 123)
		check("layout: placements and unplaced add up to the collections", lay.Stats.Collections == 8 and lay.Stats.Placed + lay.Stats.Unplaced == 8 and #lay.Placements == lay.Stats.Placed)
		local byTag, used, dup = {}, {}, false
		for _, p in ipairs(lay.Placements) do
			byTag[p.Tag] = (byTag[p.Tag] or 0) + 1
			if used[p.Target] then dup = true end
			used[p.Target] = true
		end
		check("layout: every collection of a tag with enough targets is placed (A 3, B 1, C 1)", byTag.A == 3 and byTag.B == 1 and byTag.C == 1 and lay.Stats.Placed == 5, lay.Stats.Placed)
		check("layout: a target is never used twice", dup == false)
		local whys = {}
		for _, u in ipairs(lay.Unplaced) do whys[u.Why .. ":" .. tostring(u.Tag)] = true end
		check("layout: a tag with too few targets leaves the extra collection unplaced", whys["not enough targets:C"] == true)
		check("layout: a tag with no target, and a collection with no tag, are reported", whys["no target:D"] == true and whys["no tag:nil"] == true and #lay.Unplaced == 3)
		local right = true
		for _, p in ipairs(lay.Placements) do
			if p.Tag == "A" and not (p.To.X >= 1050 and p.To.X <= 1350 and p.To.Z == 200) then right = false end
		end
		check("layout: an A collection lands on one of the A targets", right)

		-- determinism and the seed
		local function sig(seed)
			local t = {}
			for _, p in ipairs(Shuffle.layout(mission(L), seed).Placements) do t[#t + 1] = p.Tag .. ">" .. tostring(p.To.X) .. "/" .. p.Steps end
			return table.concat(t, ",")
		end
		check("layout: the same seed gives the same layout", sig(5) == sig(5))
		local different = false
		for seed = 6, 40 do if sig(seed) ~= sig(5) then different = true break end end
		check("layout: other seeds give other layouts", different)

		-- geometry: floor on floor, turned by (target yaw - collection yaw)
		local pB
		for _, p in ipairs(lay.Placements) do if p.Tag == "B" then pB = p end end
		check("layout: the collection's floor sits on the target's floor (target 12 high at y 6, collection 28 high: centre y 14)", pB ~= nil and math.abs(pB.To.Y - 14) < 1e-9 and pB.To.X == 2000 and pB.To.Z == 300)
		check("layout: ShuffleTargetRotation = 4 adds a whole number of quarter turns on top of the target's own yaw", pB ~= nil and pB.Steps >= 0 and pB.Steps <= 3 and math.abs(((pB.Yaw - math.pi / 2) / (math.pi / 2)) - pB.Steps) < 1e-9)
		local seen = {}
		for seed = 1, 60 do for _, p in ipairs(Shuffle.layout(mission(L), seed).Placements) do if p.Tag == "B" then seen[p.Steps] = true end end end
		check("layout: over many seeds all four quarter turns occur", seen[0] and seen[1] and seen[2] and seen[3])
		local noRot = Shuffle.layout(mission({ item("PartCollection", { ShuffleTarget = "Z" }, 0, 14, 0, 32, 28, 32), item("ShuffleTarget", { ShuffleTag = "Z" }, 50, 6, 50, 24, 12, 24, math.pi) }), 1)
		check("layout: without ShuffleTargetRotation the turn is only target yaw minus collection yaw", #noRot.Placements == 1 and noRot.Placements[1].Steps == 0 and math.abs(noRot.Placements[1].Yaw - math.pi) < 1e-9)

		-- moving points
		local p0 = { From = { X = 0, Y = 14, Z = 0 }, To = { X = 100, Y = 14, Z = 50 }, Yaw = 0 }
		local x, y, z = Shuffle.moved(p0, 5, 17, 2)
		check("layout: moved, no turn: the offset from the centre is kept", x == 105 and y == 17 and z == 52)
		local p90 = { From = { X = 0, Y = 14, Z = 0 }, To = { X = 100, Y = 20, Z = 50 }, Yaw = math.pi / 2 }
		x, y, z = Shuffle.moved(p90, 5, 17, 0)
		check("layout: moved, a quarter turn about the old centre, up 6 to the new floor", math.abs(x - 100) < 1e-9 and math.abs(y - 23) < 1e-9 and math.abs(z - 45) < 1e-9, x .. "," .. y .. "," .. z)
		x, y, z = Shuffle.moved(p90, 0, 14, 0)
		check("layout: the old centre goes to the new centre", math.abs(x - 100) < 1e-9 and y == 20 and math.abs(z - 50) < 1e-9)

		-- inside
		local col = { Position = { X = 0, Y = 14, Z = 0 }, Size = { X = 40, Y = 28, Z = 10 }, Yaw = 0 }
		check("layout: inside a box", Shuffle.inside(col, 19, 14, 4) and not Shuffle.inside(col, 21, 14, 0) and not Shuffle.inside(col, 0, 29, 0) and not Shuffle.inside(col, 0, 14, 6))
		col.Yaw = math.pi / 2
		check("layout: inside a box turned a quarter: the long side now runs along z", Shuffle.inside(col, 4, 14, 19) and not Shuffle.inside(col, 19, 14, 4))
		check("layout: a collection without a size contains nothing", Shuffle.inside({}, 0, 0, 0) == false)

		-- the report
		local lines = Shuffle.layoutReport(lay)
		check("layout: the report says how many are placed", lines[1] == "layout (seed 123): 5 of 8 collections placed on targets, 3 unplaced", lines[1])
		local text = table.concat(lines, "\n")
		check("layout: the report names why collections are unplaced and shows placements", string.find(text, "unplaced:", 1, true) ~= nil and string.find(text, "not enough targets: C=1", 1, true) ~= nil and string.find(text, "A #1:", 1, true) ~= nil, text)
		check("layout: the report can be cut", #Shuffle.layoutReport(lay, 3) <= 3)
		check("layout: no mission: an empty layout, no crash", Shuffle.layout(nil, 1).Stats.Collections == 0)
	end

	-------------------------------------------------------------------------------- the yaw bug found in the first layout run, and movers
	do
		-- Euler (180, 30, 180) is a heading of 150 degrees, not 30 [found in the Blacksite: "turned 150 degrees", "30 degrees"]
		check("yaw: a plain turn about Y is its Y angle", math.abs(Shuffle.yawOf({ X = 0, Y = 0.5, Z = 0 }) - 0.5) < 1e-9 and math.abs(Shuffle.yawOf({ X = 0, Y = math.pi / 2, Z = 0 }) - math.pi / 2) < 1e-9)
		check("yaw: a flipped part (180, y, 180) has the heading 180 - y", math.abs(Shuffle.yawOf({ X = math.pi, Y = 0.5, Z = math.pi }) - (math.pi - 0.5)) < 1e-9 and math.abs(Shuffle.yawOf({ X = math.pi, Y = math.pi / 2, Z = math.pi }) - math.pi / 2) < 1e-9)
		check("yaw: no angles is no heading", Shuffle.yawOf(nil) == 0 and Shuffle.yawOf({}) == 0)
		local function flipped(name, attrs, x, y, z, sx, sy, sz, ex, ey, ez)
			counter += 1
			return { Id = "n" .. counter, Path = "M/" .. name .. counter, ClassName = "Part", Name = name, Attrs = attrs, Children = {},
				Props = { CFrame = { Position = { X = x, Y = y, Z = z }, EulerXYZ = { X = ex, Y = ey, Z = ez } }, Size = { X = sx, Y = sy, Z = sz } } }
		end
		local lay = Shuffle.layout(mission({ flipped("PartCollection", { ShuffleTarget = "F" }, 0, 14, 0, 32, 28, 32, 0, 0, 0), flipped("ShuffleTarget", { ShuffleTag = "F" }, 50, 6, 50, 24, 12, 24, math.pi, 0.5, math.pi) }), 1)
		check("yaw: a layout onto a flipped target turns by its real heading (150 degrees), not by the Y angle (30)", #lay.Placements == 1 and math.abs(lay.Placements[1].Yaw - (math.pi - 0.5)) < 1e-9, lay.Placements[1] and lay.Placements[1].Yaw)

		-- movers ride along: they are not demand
		local m = Shuffle.survey(mission({
			node("Part", "PartCollection", { ShuffleTarget = "X" }), node("Part", "ShuffleTarget", { ShuffleTag = "X" }),
			node("Model", "Default", { ShuffleTarget = "X" }), node("Model", "Default", { ShuffleTarget = "X" }), node("Model", "Default", { ShuffleTarget = "X" }),
			node("Model", "Default", { ShuffleTarget = "Orphan" }), node("Model", "Default", { ShuffleTarget = "Orphan" }),
		}))
		check("movers: five movers on a tag with 1 collection and 1 target are no shortage", (function() for _, w in ipairs(m.Warnings) do if string.find(w, "tag X", 1, true) then return false end end return true end)())
		check("movers: a tag with movers and no collection is said so, once", (function() local n = 0 for _, w in ipairs(m.Warnings) do if w == "tag Orphan has 2 movers but no collection to move them with" then n += 1 end end return n == 1 end)(), m.Warnings[1])
	end

	-- degenerate missions
	local e = Shuffle.survey(mission({ node("Part", "WoodChair", {}) }))
	check("shuffle: no shuffle in the mission: totals are zero and it says so", e.Totals.Collections == 0 and e.Totals.Targets == 0 and #e.Warnings == 1 and string.find(e.Warnings[1], "no physical shuffle", 1, true) ~= nil)
	local one = Shuffle.survey(mission({ node("Part", "PartCollection", { ShuffleTag = "A" }) }))
	check("shuffle: collections without targets are reported", #one.Warnings == 2 and string.find(one.Warnings[1], "one side is missing", 1, true) ~= nil and string.find(one.Warnings[2], "tag A is asked for by 1 collections but has no target", 1, true) ~= nil)
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

	-------------------------------------------------------------------------------- M11.1b: Shuffle.apply
	do
		local Geometry = require("../BreachWorld").Geometry
		local function near(a, b) return math.abs(a - b) < 1e-6 end
		local function angDiff(a, b) local d = (a - b) % (2 * math.pi) return math.min(d, 2 * math.pi - d) end

		-- turning an Euler rotation by a yaw is the same as turning the rotated vector about Y
		local worst = 0
		for _, e in ipairs({ { 0, 0, 0 }, { 0, 0.7, 0 }, { math.pi, 0.5, math.pi }, { 0.3, -0.4, 1.1 }, { 1.2, 0.2, -2.5 }, { 0, math.pi / 2, 0 } }) do
			for _, yaw in ipairs({ 0.4, math.pi / 2, math.pi, -2.2 }) do
				local rx, ry, rz = Shuffle.turnedEuler({ X = e[1], Y = e[2], Z = e[3] }, yaw)
				local nx, ny, nz = Geometry.rotate({ X = rx, Y = ry, Z = rz }, 1, 2, 3)
				local ox, oy, oz = Geometry.rotate({ X = e[1], Y = e[2], Z = e[3] }, 1, 2, 3)
				local c, s = math.cos(yaw), math.sin(yaw)
				local ex, ey, ez = ox * c + oz * s, oy, -ox * s + oz * c
				worst = math.max(worst, math.abs(nx - ex), math.abs(ny - ey), math.abs(nz - ez))
			end
		end
		check("apply: turnedEuler equals a yaw about Y applied after the old rotation (24 cases)", worst < 1e-9, worst)

		local function build()
			local id = 0
			local function n(class, name, attrs, x, y, z, sx, sy, sz, eul)
				id += 1
				local node = { Id = "a" .. id, Path = "M/" .. name .. id, ClassName = class, Name = name, Attrs = attrs or {}, Children = {}, Props = {} }
				if x then
					node.Props.CFrame = { Position = { X = x, Y = y, Z = z }, EulerXYZ = eul or { X = 0, Y = 0, Z = 0 } }
					node.Props.Size = { X = sx or 4, Y = sy or 4, Z = sz or 4 }
				end
				return node
			end
			local list = {
				n("Part", "PartCollection", { ShuffleTarget = "A" }, 100, 14, 0, 20, 28, 20),
				n("Part", "ShuffleTarget", { ShuffleTag = "A" }, 0, 6, 0, 12, 12, 12, { X = 0, Y = math.pi / 2, Z = 0 }),
				n("Part", "WoodChair", {}, 105, 3, 2, 2, 2, 2, { X = 0, Y = 0.5, Z = 0 }), -- inside the collection
				n("Part", "FarChair", {}, 500, 3, 0, 2, 2, 2), -- outside every collection
				n("Model", "Cell", { Path = '{"Node":[[100,1,0],[104,1,3]],"Link":[[2],[1]],"Placed":[[98,1,-2]]}' }), -- a Meadow map inside the collection
				n("Model", "FarCell", { Path = '{"Node":[[500,1,0]],"Link":[[]]}' }),
				n("Part", "PartCollection", { ShuffleTarget = "B" }, 300, 14, 0, 20, 28, 20), -- asks for a tag with no target: stays
				n("Part", "StayChair", {}, 302, 3, 0, 2, 2, 2),
			}
			return { Nodes = list }, list
		end

		local m, list = build()
		local layout = Shuffle.layout(m, 5)
		local p = layout.Placements[1]
		local st = Shuffle.apply(m, layout)
		check("apply: one collection is placed, stats count what moved", #layout.Placements == 1 and st.Collections == 1 and st.Nodes == 2 and st.NavPoints == 3, st.Nodes)
		local chair = list[3].Props.CFrame
		local ex, ey, ez = Shuffle.moved(p, 105, 3, 2)
		check("apply: a prop inside the collection moves with it (same transform as Shuffle.moved)", near(chair.Position.X, ex) and near(chair.Position.Y, ey) and near(chair.Position.Z, ez))
		check("apply: the collection lands floor on floor over the target", near(list[1].Props.CFrame.Position.X, 0) and near(list[1].Props.CFrame.Position.Z, 0) and near(list[1].Props.CFrame.Position.Y - 14, p.To.Y - 14) and near(p.To.Y - 14, 0), list[1].Props.CFrame.Position.Y)
		check("apply: its rotation is turned by the placement's yaw", angDiff(Shuffle.yawOf(chair.EulerXYZ), Shuffle.yawOf({ X = 0, Y = 0.5, Z = 0 }) + p.Yaw) < 1e-6)
		check("apply: the distance from the collection centre is kept (rigid)", near(math.sqrt((chair.Position.X - list[1].Props.CFrame.Position.X) ^ 2 + (chair.Position.Z - list[1].Props.CFrame.Position.Z) ^ 2), math.sqrt(5 ^ 2 + 2 ^ 2)))
		check("apply: the target, a prop outside, and an unplaced collection's contents do not move", list[2].Props.CFrame.Position.X == 0 and list[4].Props.CFrame.Position.X == 500 and list[8].Props.CFrame.Position.X == 302 and list[7].Props.CFrame.Position.X == 300)
		-- the Meadow map
		local text = list[5].Attrs.Path
		local x1, y1, z1 = Shuffle.moved(p, 100, 1, 0)
		local x2 = Shuffle.moved(p, 98, 1, -2)
		check("apply: a nav Path inside the collection is moved point by point, links untouched", string.find(text, '"Link":[[2],[1]]', 1, true) ~= nil and string.find(text, tostring(x1):sub(1, 6), 1, true) ~= nil and list[5].Attrs.Path ~= '{"Node":[[100,1,0],[104,1,3]],"Link":[[2],[1]],"Placed":[[98,1,-2]]}', text)
		check("apply: a nav Path outside every collection is left as it was", list[6].Attrs.Path == '{"Node":[[500,1,0]],"Link":[[]]}')
		-- twice = once
		local before = chair.Position.X
		local again = Shuffle.apply(m, layout)
		check("apply: a second apply does nothing", again.Nodes == 0 and chair.Position.X == before)
		-- determinism
		local m2, list2 = build()
		Shuffle.apply(m2, Shuffle.layout(m2, 5))
		check("apply: the same seed gives the same moved positions", list2[3].Props.CFrame.Position.X == chair.Position.X and list2[3].Props.CFrame.Position.Z == chair.Position.Z and list2[5].Attrs.Path == list[5].Attrs.Path)
		-- degenerate input
		check("apply: no mission or no placements is harmless", Shuffle.apply(nil, layout).Nodes == 0 and Shuffle.apply({ Nodes = {} }, { Placements = {} }).Nodes == 0)
		-- a node that is itself a placed collection uses its own placement even if its centre lies in another collection
		local mm = { Nodes = {
			{ Id = "x1", Path = "M/c1", ClassName = "Part", Name = "PartCollection", Attrs = { ShuffleTarget = "T" }, Children = {}, Props = { CFrame = { Position = { X = 0, Y = 0, Z = 0 } }, Size = { X = 40, Y = 40, Z = 40 } } },
			{ Id = "x2", Path = "M/c2", ClassName = "Part", Name = "PartCollection", Attrs = { ShuffleTarget = "U" }, Children = {}, Props = { CFrame = { Position = { X = 5, Y = 0, Z = 0 } }, Size = { X = 10, Y = 10, Z = 10 } } },
			{ Id = "x3", Path = "M/t1", ClassName = "Part", Name = "ShuffleTarget", Attrs = { ShuffleTag = "T" }, Children = {}, Props = { CFrame = { Position = { X = 1000, Y = 0, Z = 0 } }, Size = { X = 40, Y = 40, Z = 40 } } },
			{ Id = "x4", Path = "M/t2", ClassName = "Part", Name = "ShuffleTarget", Attrs = { ShuffleTag = "U" }, Children = {}, Props = { CFrame = { Position = { X = -1000, Y = 0, Z = 0 } }, Size = { X = 10, Y = 10, Z = 10 } } },
		} }
		Shuffle.apply(mm, Shuffle.layout(mm, 1))
		check("apply: an overlapping collection keeps its own target", mm.Nodes[1].Props.CFrame.Position.X == 1000 and mm.Nodes[2].Props.CFrame.Position.X == -1000, mm.Nodes[2].Props.CFrame.Position.X)
	end
end
