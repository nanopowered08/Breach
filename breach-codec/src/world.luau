--!nonstrict
--[[
	BreachWorld — the spatial layer of a mission (BreachEngine M4).

	Pure Luau, no requires, no Roblox APIs. Built on BreachMission (it reads mission.Root).

	    local world = World.build(mission)
	    world:cellAt(x, y, z)            -- the first cell containing the point (like the plugin's ZoneUtil)
	    world:cellsAt(x, y, z)           -- every containing cell
	    world:neighbors(cell)            -- adjacent cells (through links)
	    world:hops(a, b)                 -- link hops between two cells (BFS), or nil
	    world:route(a, b)                -- list of cells from a to b
	    world:findPath(from, to)         -- A* over the navigation graph: {points = {{x,y,z},...}, length = n}

	WHAT IS KNOWN vs GUESSED (read this before trusting adjacency)
	  Verified on two real maps:
	    * a cell is a Model/Folder directly under `Cells`, named after its trespass ZONE CLASS
	      (e.g. "InsideHighlyRestricted"); several cells share a name. Its volume is its `Floor` and `Roof`
	      parts; its attributes are `Location` (localisation key), `Preposition`, optional `ServerTag`, and
	      `Path` = JSON {"Node": [[x,y,z],...], "Link": [[i,j],...], "Placed": [...]} (the navigation map).
	    * `Cells/Links` holds `Part`s named "Link" with Move / Open / Path / Sound (/ OneWay) attributes.
	  GUESSED (heuristic, tunable, NOT calibrated): WHICH cells a link joins. A link is a flat slab placed
	  across a doorway, so we sample points inside its box and take the cells containing a large enough
	  share of them. The exported data contains no ground truth for this: `Cells.LinkList` looks like one but
	  is byte-identical in two different real maps, i.e. leftover template data, so it must NOT be used.
	  `world.Diagnostics` reports what the heuristic produced.
	  Cells whose navigation nodes all lie outside their own volume are flagged `NavSuspect` (a real map had 9
	  such cells with copied `Path` data); their nodes are kept in the graph, as the engine presumably does.
	  Rotations are read as Roblox Euler XYZ (R = Rx * Ry * Rz) — assumed, not yet tested in Roblox.
]]

local World = {}
World.VERSION = "0.1.0"

local sub, find, match, concat = string.sub, string.find, string.match, table.concat
local char = string.char

local function fail(msg)
	error("BreachWorld: " .. msg, 0)
end

--@@JSON@@

-------------------------------------------------------------------------------
-- Geometry (oriented boxes with Euler XYZ rotation)
-------------------------------------------------------------------------------
local Geometry = {}
World.Geometry = Geometry

-- R * v, with R = Rx * Ry * Rz
function Geometry.rotate(e, x, y, z)
	local cx, sx, cy, sy, cz, sz = math.cos(e.X), math.sin(e.X), math.cos(e.Y), math.sin(e.Y), math.cos(e.Z), math.sin(e.Z)
	local x1, y1 = cz * x - sz * y, sz * x + cz * y
	local x2, z2 = cy * x1 + sy * z, -sy * x1 + cy * z
	return x2, cx * y1 - sx * z2, sx * y1 + cx * z2
end

-- R^T * v
function Geometry.unrotate(e, x, y, z)
	local cx, sx, cy, sy, cz, sz = math.cos(e.X), math.sin(e.X), math.cos(e.Y), math.sin(e.Y), math.cos(e.Z), math.sin(e.Z)
	local y1, z1 = cx * y + sx * z, -sx * y + cx * z
	local x2, z2 = cy * x - sy * z1, sy * x + cy * z1
	return cz * x2 + sz * y1, -sz * x2 + cz * y1, z2
end

local function makeBox(node)
	local cf, size = node.Props.CFrame, node.Props.Size
	if type(cf) ~= "table" or type(size) ~= "table" then
		return nil
	end
	local box = { center = cf.Position, euler = cf.EulerXYZ, size = size }
	-- axis-aligned bounds of the rotated box
	local hx, hy, hz = size.X / 2, size.Y / 2, size.Z / 2
	local minx, miny, minz, maxx, maxy, maxz = math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge
	for _, sx in ipairs({ -1, 1 }) do
		for _, sy in ipairs({ -1, 1 }) do
			for _, sz in ipairs({ -1, 1 }) do
				local ox, oy, oz = Geometry.rotate(box.euler, sx * hx, sy * hy, sz * hz)
				local px, py, pz = box.center.X + ox, box.center.Y + oy, box.center.Z + oz
				minx, miny, minz = math.min(minx, px), math.min(miny, py), math.min(minz, pz)
				maxx, maxy, maxz = math.max(maxx, px), math.max(maxy, py), math.max(maxz, pz)
			end
		end
	end
	box.min = { X = minx, Y = miny, Z = minz }
	box.max = { X = maxx, Y = maxy, Z = maxz }
	return box
end

-- point in the box's local space
local function localPoint(box, x, y, z)
	return Geometry.unrotate(box.euler, x - box.center.X, y - box.center.Y, z - box.center.Z)
end

-------------------------------------------------------------------------------
-- Cells
-------------------------------------------------------------------------------
local function parseNav(raw)
	-- `Path` JSON (verified on two real maps):
	--   Node   = [[x,y,z], ...]       auto navigation nodes
	--   Link   = [[j,k,...], ...]     ADJACENCY LISTS: entry i lists the (1-based) Node indices adjacent to node i
	--   Placed = [[x,y,z], ...]       manually placed nodes (role unverified; kept, not part of the graph)
	local nav = { Nodes = {}, Adjacency = {}, Placed = {} }
	if type(raw) ~= "string" or raw == "" then
		return nav
	end
	local ok, data = pcall(jsonDecode, raw)
	if not ok or type(data) ~= "table" then
		return nav, "unparseable Path attribute"
	end
	for _, p in ipairs(data.Node or {}) do
		if type(p) == "table" and type(p[1]) == "number" and type(p[2]) == "number" and type(p[3]) == "number" then
			nav.Nodes[#nav.Nodes + 1] = { X = p[1], Y = p[2], Z = p[3] }
		end
	end
	for i, list in ipairs(data.Link or {}) do
		local out = {}
		if type(list) == "table" then
			for _, j in ipairs(list) do
				if type(j) == "number" and j >= 1 and j <= #nav.Nodes and j ~= i then
					out[#out + 1] = j
				end
			end
		end
		nav.Adjacency[i] = out
	end
	for _, p in ipairs(data.Placed or {}) do
		if type(p) == "table" and type(p[1]) == "number" and type(p[2]) == "number" and type(p[3]) == "number" then
			nav.Placed[#nav.Placed + 1] = { X = p[1], Y = p[2], Z = p[3] }
		end
	end
	return nav
end

local function cellContains(cell, x, y, z)
	-- cheap reject
	local mn, mx = cell.Min, cell.Max
	if x < mn.X or x > mx.X or y < mn.Y or y > mx.Y or z < mn.Z or z > mx.Z then
		return false
	end
	local floorOK = #cell.Floors == 0
	for _, b in ipairs(cell.Floors) do
		local lx, ly, lz = localPoint(b, x, y, z)
		if math.abs(lx) <= b.size.X / 2 and math.abs(lz) <= b.size.Z / 2 and ly >= 0 then
			floorOK = true
			break
		end
	end
	if not floorOK then
		return false
	end
	for _, b in ipairs(cell.Roofs) do
		local lx, ly, lz = localPoint(b, x, y, z)
		if math.abs(lx) <= b.size.X / 2 and math.abs(lz) <= b.size.Z / 2 and ly <= 0 then
			return true
		end
	end
	return false
end

-------------------------------------------------------------------------------
-- World
-------------------------------------------------------------------------------
local W = {}
W.__index = W

local DEFAULTS = {
	minHitFraction = 0.15, -- a link joins the cells that contain >= this share of the best cell's sample hits (0.5 in M4 dropped a second cell overlapped unevenly; 0.15 makes every real patrol leg of all three maps pathable except 20 in the Peacemaker, see doc 13.14)
	sampleGrid = { 5, 3, 5 }, -- sample points per link box axis (including both faces)
}

local function samples(n)
	local out = {}
	if n <= 1 then
		return { 0 }
	end
	for i = 0, n - 1 do
		out[#out + 1] = -1 + 2 * i / (n - 1)
	end
	return out
end

function World.build(mission, opts)
	opts = opts or {}
	local minHit = opts.minHitFraction or DEFAULTS.minHitFraction
	local grid = opts.sampleGrid or DEFAULTS.sampleGrid
	local self = setmetatable({}, W)
	self.Mission = mission
	self.Cells, self.Links, self.Warnings = {}, {}, {}
	local warnings = self.Warnings

	local cellsFolder = mission.folder and mission:folder("Cells") or nil
	if cellsFolder == nil then
		warnings[#warnings + 1] = "mission has no Cells folder"
	else
		self.LinkListRaw = cellsFolder.Attrs.LinkList
		for _, node in ipairs(cellsFolder.Children) do
			if node.Name ~= "Links" and (node.ClassName == "Model" or node.ClassName == "Folder") then
				local cell = {
					Index = #self.Cells + 1,
					Node = node,
					Id = node.Id,
					Zone = node.Name,
					Location = node.Attrs.Location,
					Preposition = node.Attrs.Preposition,
					ServerTag = node.Attrs.ServerTag,
					Floors = {},
					Roofs = {},
				}
				for _, part in ipairs(node.Children) do
					local box = makeBox(part)
					if box then
						if part.Name == "Floor" then
							cell.Floors[#cell.Floors + 1] = box
						elseif part.Name == "Roof" then
							cell.Roofs[#cell.Roofs + 1] = box
						end
					end
				end
				if #cell.Floors + #cell.Roofs == 0 then
					warnings[#warnings + 1] = "cell '" .. node.Path .. "' has no Floor or Roof parts and was skipped"
				else
					local mn = { X = math.huge, Y = math.huge, Z = math.huge }
					local mx = { X = -math.huge, Y = -math.huge, Z = -math.huge }
					for _, list in ipairs({ cell.Floors, cell.Roofs }) do
						for _, b in ipairs(list) do
							mn = { X = math.min(mn.X, b.min.X), Y = math.min(mn.Y, b.min.Y), Z = math.min(mn.Z, b.min.Z) }
							mx = { X = math.max(mx.X, b.max.X), Y = math.max(mx.Y, b.max.Y), Z = math.max(mx.Z, b.max.Z) }
						end
					end
					cell.Min, cell.Max = mn, mx
					local nav, navErr = parseNav(node.Attrs.Path)
					if navErr then
						warnings[#warnings + 1] = "cell '" .. node.Path .. "': " .. navErr
					end
					cell.Nav = nav
					self.Cells[#self.Cells + 1] = cell
				end
			end
		end

		-- links
		local linksFolder
		for _, c in ipairs(cellsFolder.Children) do
			if c.Name == "Links" then
				linksFolder = c
			end
		end
		local gx, gy, gz = samples(grid[1]), samples(grid[2]), samples(grid[3])
		for _, node in ipairs(linksFolder and linksFolder.Children or {}) do
			local box = makeBox(node)
			if box then
				local link = {
					Index = #self.Links + 1,
					Node = node,
					Open = node.Attrs.Open,
					Path = node.Attrs.Path,
					Move = node.Attrs.Move,
					Sound = node.Attrs.Sound,
					OneWay = node.Attrs.OneWay,
					Center = box.center,
					Cells = {},
				}
				local hits, best = {}, 0
				for _, ax in ipairs(gx) do
					for _, ay in ipairs(gy) do
						for _, az in ipairs(gz) do
							local ox, oy, oz = Geometry.rotate(box.euler, ax * box.size.X / 2, ay * box.size.Y / 2, az * box.size.Z / 2)
							local x, y, z = box.center.X + ox, box.center.Y + oy, box.center.Z + oz
							for _, cell in ipairs(self.Cells) do
								if cellContains(cell, x, y, z) then
									local h = (hits[cell.Index] or 0) + 1
									hits[cell.Index] = h
									if h > best then
										best = h
									end
								end
							end
						end
					end
				end
				for ci, h in pairs(hits) do
					if h >= best * minHit then
						link.Cells[#link.Cells + 1] = ci
					end
				end
				table.sort(link.Cells, function(a, b)
					if hits[a] ~= hits[b] then
						return hits[a] > hits[b]
					end
					return a < b
				end)
				link.Hits = hits
				self.Links[#self.Links + 1] = link
			end
		end
	end

	-- navigation data sanity: a cell whose nav nodes all lie OUTSIDE its own volume almost certainly carries a
	-- copied `Path` attribute (seen on a real map: five cells sharing one identical 38-node list)
	local suspect = {}
	for _, cell in ipairs(self.Cells) do
		local n = #cell.Nav.Nodes
		if n > 0 then
			local inside = false
			for _, p in ipairs(cell.Nav.Nodes) do
				if cellContains(cell, p.X, p.Y, p.Z) then
					inside = true
					break
				end
			end
			if not inside then
				cell.NavSuspect = true
				suspect[#suspect + 1] = cell
			end
		end
	end
	if #suspect > 0 then
		local names = {}
		for i = 1, math.min(10, #suspect) do
			names[i] = "#" .. suspect[i].Index
		end
		warnings[#warnings + 1] = #suspect .. " cell(s) have navigation nodes entirely outside their own volume (copied Path data?): " .. concat(names, ", ") .. (#suspect > 10 and ", ..." or "")
	end

	-- adjacency (clique over each link's cells)
	local adj = {}
	for i = 1, #self.Cells do
		adj[i] = {}
	end
	local bridging, orphan = 0, 0
	for _, link in ipairs(self.Links) do
		local cs = link.Cells
		if #cs == 0 then
			orphan = orphan + 1
		elseif #cs >= 2 then
			bridging = bridging + 1
		end
		for i = 1, #cs do
			for j = i + 1, #cs do
				local a, b = cs[i], cs[j]
				adj[a][b] = adj[a][b] or {}
				adj[b][a] = adj[b][a] or {}
				table.insert(adj[a][b], link)
				table.insert(adj[b][a], link)
			end
		end
	end
	self._adj = adj

	-- navigation graph
	local nav = { nodes = {}, edges = {}, byCell = {} } -- edges[a] = { {to, w, kind}, ... }
	for _, cell in ipairs(self.Cells) do
		local ids = {}
		for i, p in ipairs(cell.Nav.Nodes) do
			nav.nodes[#nav.nodes + 1] = { id = #nav.nodes + 1, cell = cell.Index, index = i, X = p.X, Y = p.Y, Z = p.Z }
			ids[i] = #nav.nodes
		end
		nav.byCell[cell.Index] = ids
	end
	for i = 1, #nav.nodes do
		nav.edges[i] = {}
	end
	local function dist(a, b)
		local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
		return math.sqrt(dx * dx + dy * dy + dz * dz)
	end
	local function addEdge(a, b, kind, directed)
		if a == b then
			return
		end
		local w = dist(nav.nodes[a], nav.nodes[b])
		nav.edges[a][#nav.edges[a] + 1] = { to = b, w = w, kind = kind }
		if not directed then
			nav.edges[b][#nav.edges[b] + 1] = { to = a, w = w, kind = kind }
		end
	end
	local intra, inter, oneWayEdges = 0, 0, 0
	for _, cell in ipairs(self.Cells) do
		local ids = nav.byCell[cell.Index]
		local listed = {}
		for i, list in pairs(cell.Nav.Adjacency) do
			for _, j in ipairs(list) do
				listed[i .. ">" .. j] = true
			end
		end
		for i, list in pairs(cell.Nav.Adjacency) do
			for _, j in ipairs(list) do
				local a, b = ids[i], ids[j]
				if a and b then
					if listed[j .. ">" .. i] then
						if i < j then
							addEdge(a, b, "intra", false) -- both directions listed: one undirected edge
							intra = intra + 1
						end
					else
						addEdge(a, b, "intra", true) -- listed one way only: keep it directed
						intra = intra + 1
						oneWayEdges = oneWayEdges + 1
					end
				end
			end
		end
	end
	local function nearestInCell(ci, p)
		local best, bd
		for _, id in ipairs(nav.byCell[ci] or {}) do
			local d = dist(nav.nodes[id], p)
			if bd == nil or d < bd then
				best, bd = id, d
			end
		end
		return best
	end
	for _, link in ipairs(self.Links) do
		if link.Path == true and #link.Cells >= 2 then
			for i = 1, #link.Cells do
				for j = i + 1, #link.Cells do
					local a = nearestInCell(link.Cells[i], link.Center)
					local b = nearestInCell(link.Cells[j], link.Center)
					if a and b then
						addEdge(a, b, "link")
						inter = inter + 1
					end
				end
			end
		end
	end
	-- Door edges. The Meadow Map tool puts a node 4.5 studs either side of every `Door*` prop (door.CFrame * (0, -3, +-4.5), on
	-- the floor); a door on a cell boundary puts its two nodes in different cells, and nothing else joins them (BreachEngine
	-- doc 13.13). Tier 1 (exact): both nodes within `doorTolerance` of the expected points -> an edge. Tier 2 (opt.doorNearest,
	-- for maps whose nodes were placed by hand, e.g. the Peacemaker): the nearest node of the cell on each side within
	-- `doorNearestRange`, only if the two sides are in different cells and not yet connected.
	local doorEdgesExact, doorEdgesNear, doorsSeen = 0, 0, 0
	if opts.doorEdges ~= false and mission.folder then
		local props = mission:folder("Props")
		local tol = opts.doorTolerance or 0.5
		local range = opts.doorNearestRange or 7
		local function isDoor(name)
			return name == "GarageDoor" or name:match("^Door%u") ~= nil or name == "Door" or name:match("%uDoor$") ~= nil
		end
		local function connected(a, b)
			for _, e in ipairs(nav.edges[a]) do
				if e.to == b then
					return true
				end
			end
			return false
		end
		local function nodeNear(x, y, z, limit, cellIndex)
			local best, bd
			for _, n in ipairs(nav.nodes) do
				if cellIndex == nil or n.cell == cellIndex then
					local d = math.sqrt((n.X - x) ^ 2 + (n.Y - y) ^ 2 + (n.Z - z) ^ 2)
					if d <= limit and (bd == nil or d < bd) then
						best, bd = n.id, d
					end
				end
			end
			return best
		end
		local function visit(node)
			for _, ch in ipairs(node.Children or {}) do
				if ch.ClassName == "Part" and isDoor(ch.Name) and ch.Props and type(ch.Props.CFrame) == "table" then
					doorsSeen = doorsSeen + 1
					local pos, e = ch.Props.CFrame.Position, ch.Props.CFrame.EulerXYZ
					local function at(z)
						local ox, oy, oz = Geometry.rotate(e, 0, -3, z)
						return pos.X + ox, pos.Y + oy, pos.Z + oz
					end
					local ax, ay, az = at(4.5)
					local bx, by, bz = at(-4.5)
					local na, nb = nodeNear(ax, ay, az, tol), nodeNear(bx, by, bz, tol)
					if na and nb and na ~= nb then
						if not connected(na, nb) then
							addEdge(na, nb, "door")
							doorEdgesExact = doorEdgesExact + 1
						end
					elseif opts.doorNearest ~= false and not (na and nb) then
						local ca, cb = self:cellAt(ax, ay, az), self:cellAt(bx, by, bz)
						if ca and cb and ca ~= cb then
							local a2 = na or nodeNear(ax, ay, az, range, ca.Index)
							local b2 = nb or nodeNear(bx, by, bz, range, cb.Index)
							if a2 and b2 and a2 ~= b2 and not connected(a2, b2) then
								addEdge(a2, b2, "door-near")
								doorEdgesNear = doorEdgesNear + 1
							end
						end
					end
				end
				visit(ch)
			end
		end
		if props then
			visit(props)
		end
	end
	self._nav = nav

	-- diagnostics
	self.Diagnostics = {
		cells = #self.Cells,
		links = #self.Links,
		linksBridgingCells = bridging,
		linksTouchingNoCell = orphan,
		cellComponents = self:components(),
		navNodes = #nav.nodes,
		navEdgesIntra = intra,
		navEdgesInter = inter,
		navOneWayEdges = oneWayEdges,
		doorsSeen = doorsSeen,
		navEdgesDoorExact = doorEdgesExact,
		navEdgesDoorNear = doorEdgesNear,
		navSuspectCells = #suspect,
		navComponents = self:navComponents(),
	}
	return self
end

-------------------------------------------------------------------------------
-- Queries
-------------------------------------------------------------------------------
local function pointArgs(x, y, z)
	if type(x) == "table" then
		return x.X, x.Y, x.Z
	end
	return x, y, z
end

function W:cellsAt(x, y, z)
	x, y, z = pointArgs(x, y, z)
	local out = {}
	for _, cell in ipairs(self.Cells) do
		if cellContains(cell, x, y, z) then
			out[#out + 1] = cell
		end
	end
	return out
end

function W:cellAt(x, y, z)
	x, y, z = pointArgs(x, y, z)
	for _, cell in ipairs(self.Cells) do
		if cellContains(cell, x, y, z) then
			return cell
		end
	end
	return nil
end

function W:neighbors(cell)
	local out = {}
	for j in pairs(self._adj[cell.Index]) do
		out[#out + 1] = self.Cells[j]
	end
	table.sort(out, function(a, b)
		return a.Index < b.Index
	end)
	return out
end

-- opts.open (default false): only count links whose Open attribute is true.  opts.path: only Path == true links.
local function linkUsable(link, opts)
	if opts then
		if opts.open and link.Open ~= true then
			return false
		end
		if opts.path and link.Path ~= true then
			return false
		end
	end
	return true
end

function W:route(a, b, opts)
	if a == b then
		return { a }
	end
	local prev, queue, head = { [a.Index] = false }, { a.Index }, 1
	while head <= #queue do
		local ci = queue[head]
		head = head + 1
		for cj, links in pairs(self._adj[ci]) do
			if prev[cj] == nil then
				local usable = false
				for _, l in ipairs(links) do
					if linkUsable(l, opts) then
						usable = true
						break
					end
				end
				if usable then
					prev[cj] = ci
					if cj == b.Index then
						local path, cur = {}, cj
						while cur do
							table.insert(path, 1, self.Cells[cur])
							cur = prev[cur]
						end
						return path
					end
					queue[#queue + 1] = cj
				end
			end
		end
	end
	return nil
end

function W:hops(a, b, opts)
	local r = self:route(a, b, opts)
	return r and (#r - 1) or nil
end

function W:components(opts)
	local seen, n = {}, 0
	for i = 1, #self.Cells do
		if not seen[i] then
			n = n + 1
			local stack = { i }
			seen[i] = true
			while #stack > 0 do
				local ci = table.remove(stack)
				for cj, links in pairs(self._adj[ci]) do
					if not seen[cj] then
						local ok = false
						for _, l in ipairs(links) do
							if linkUsable(l, opts) then
								ok = true
								break
							end
						end
						if ok then
							seen[cj] = true
							stack[#stack + 1] = cj
						end
					end
				end
			end
		end
	end
	return n
end

function W:navComponents()
	local nav, seen, n = self._nav, {}, 0
	for i = 1, #nav.nodes do
		if not seen[i] then
			n = n + 1
			local stack = { i }
			seen[i] = true
			while #stack > 0 do
				local a = table.remove(stack)
				for _, e in ipairs(nav.edges[a]) do
					if not seen[e.to] then
						seen[e.to] = true
						stack[#stack + 1] = e.to
					end
				end
			end
		end
	end
	return n
end

local function nearestNav(self, p, cell)
	local nav = self._nav
	local best, bd
	local ids = cell and nav.byCell[cell.Index]
	local function consider(id)
		local nd = nav.nodes[id]
		local dx, dy, dz = nd.X - p.X, nd.Y - p.Y, nd.Z - p.Z
		local d = dx * dx + dy * dy + dz * dz
		if bd == nil or d < bd then
			best, bd = id, d
		end
	end
	if ids and #ids > 0 then
		for _, id in ipairs(ids) do
			consider(id)
		end
	else
		for id = 1, #nav.nodes do
			consider(id)
		end
	end
	return best
end

-- A* over the navigation graph. from/to: {X,Y,Z} (or x,y,z via tables). Returns { points = {...}, length = n } or nil.
function W:findPath(from, to)
	local nav = self._nav
	if #nav.nodes == 0 then
		return nil
	end
	local startId = nearestNav(self, from, self:cellAt(from))
	local goalId = nearestNav(self, to, self:cellAt(to))
	if not startId or not goalId then
		return nil
	end
	local goal = nav.nodes[goalId]
	local function h(id)
		local nd = nav.nodes[id]
		local dx, dy, dz = nd.X - goal.X, nd.Y - goal.Y, nd.Z - goal.Z
		return math.sqrt(dx * dx + dy * dy + dz * dz)
	end
	local g, prev, closed = { [startId] = 0 }, {}, {}
	local open, inOpen = { startId }, { [startId] = true }
	local f = { [startId] = h(startId) }
	while #open > 0 do
		local bi, bf = 1, f[open[1]]
		for i = 2, #open do
			if f[open[i]] < bf then
				bi, bf = i, f[open[i]]
			end
		end
		local cur = table.remove(open, bi)
		inOpen[cur] = nil
		if cur == goalId then
			local pts, id = {}, cur
			while id do
				local nd = nav.nodes[id]
				table.insert(pts, 1, { X = nd.X, Y = nd.Y, Z = nd.Z })
				id = prev[id]
			end
			return { points = pts, length = g[cur] }
		end
		closed[cur] = true
		for _, e in ipairs(nav.edges[cur]) do
			if not closed[e.to] then
				local ng = g[cur] + e.w
				if g[e.to] == nil or ng < g[e.to] then
					g[e.to] = ng
					prev[e.to] = cur
					f[e.to] = ng + h(e.to)
					if not inOpen[e.to] then
						open[#open + 1] = e.to
						inOpen[e.to] = true
					end
				end
			end
		end
	end
	return nil
end

return World
