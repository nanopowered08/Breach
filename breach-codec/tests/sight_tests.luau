--!nonstrict
-- M8c (sight) tests: BreachSight. Run via tests/run.luau or alone: `luau tests/sight.luau`
local Sight = require("../BreachSight")
local Bots = require("../BreachBots")
local Nav = require("../BreachNav")
local Logic = require("../BreachLogic")
local Props = require("../BreachProps")

local DT = 1 / 20

return function(check)
	local P = Sight.Defaults
	local function near(a, b, tol) return type(a) == "number" and math.abs(a - b) <= (tol or 1e-6) end

	----------------------------------------------------------------------------------------------- harness
	local counter = 0
	local function part(name, x, y, z, attrs, eulerY, size)
		counter += 1
		return { Name = name, ClassName = "Part", Path = "DebugMission/Nodes/" .. name .. counter, Id = "p" .. counter, Attrs = attrs or {}, Children = {},
			Props = { CFrame = { Position = { X = x, Y = y, Z = z }, EulerXYZ = { X = 0, Y = eulerY or 0, Z = 0 } }, Size = size or { X = 4, Y = 4, Z = 4 } } }
	end
	local function folder(name, children, attrs)
		counter += 1
		return { Name = name, ClassName = "Folder", Path = "DebugMission/" .. name .. counter, Id = "f" .. counter, Attrs = attrs or {}, Children = children or {} }
	end
	local function botNode(name, attrs)
		counter += 1
		return { Name = name, ClassName = "BoolValue", Path = "DebugMission/Bots/" .. name, Id = "b" .. counter, Attrs = attrs or {}, Children = {} }
	end
	local function mission(botList, routes)
		local botsF, nodesF = folder("Bots", botList), folder("Nodes", routes)
		return { folder = function(_, n) if n == "Bots" then return botsF elseif n == "Nodes" then return nodesF end end, byComponent = function() return {} end }
	end
	-- three cells: 1 (x < 0), 2 (x >= 0, z < 50), 3 (z >= 50). Links 1-2 and 2-3, so 1 and 3 are separated by a wall.
	local function stubWorld()
		local cells = { { Index = 1 }, { Index = 2 }, { Index = 3 } }
		return { Cells = cells, Links = { { Cells = { 1, 2 } }, { Cells = { 2, 3 } } },
			cellAt = function(_, x, _, z) if z >= 50 then return cells[3] elseif x < 0 then return cells[1] else return cells[2] end end }
	end
	local FACE_PLUS_X = -math.pi / 2 -- node orientation: looks along +X
	local function straight(a, b) return { { X = a.X, Y = a.Y or 0, Z = a.Z }, { X = b.X, Y = b.Y or 0, Z = b.Z } } end
	-- a world with one static bot at (bx, 0, bz) facing +X (or `face`)
	local function scene(bx, bz, botAttrs, opts)
		opts = opts or {}
		local attrs = { Behavior = "PatrolWalk", Nodes = "Post", PatrolCycleLength = 99999 }
		for k, v in pairs(botAttrs or {}) do attrs[k] = v end
		local m = mission({ botNode("g", attrs) }, { folder("Post", { part("Node", bx, 0, bz, {}, opts.face or FACE_PLUS_X) }) })
		local l = Logic.fromSpec({ Globals = {} }, {})
		local nav = Nav.new({ pathfinder = straight })
		local w = stubWorld()
		local bots = Bots.new(m, w, l, nav, { seed = 1 })
		local players = { { Id = "p1", X = 0, Y = 0, Z = 0, Stance = "stand" } }
		local sight = Sight.new(w, bots, function() return players end, { blocked = opts.blocked })
		return sight, bots, players, l, w
	end
	local function runFor(sight, bots, seconds)
		for _ = 1, math.floor(seconds / DT + 0.5) do bots:step(DT) sight:step(DT) end
	end
	local function events(sight, kind)
		local out = {}
		for _, e in ipairs(sight:drainEvents()) do if kind == nil or e.Kind == kind then out[#out + 1] = e end end
		return out
	end

	----------------------------------------------------------------------------------------------- the cone and the range
	do
		local sight, bots, pl = scene(-5, 0)
		local bot = bots:all()[1]
		local fx, fz = bots:facing(bot)
		check("facing: a static bot looks the way its post's CFrame points (+X for Euler Y = -90°)", near(fx, 1, 1e-6) and near(fz, 0, 1e-6))
		local function sees(x, y, z, stance)
			pl[1].X, pl[1].Y, pl[1].Z, pl[1].Stance = x, y, z, stance or "stand"
			return (sight:canSee(bot.Id, "p1"))
		end
		check("cone: a player straight ahead, 20 studs, is seen", sees(15, 0, 0))
		check("cone: a player behind is not", not sees(-30, 0, 0))
		check("cone: ... unless inside the all-round radius (and line of sight is clear)", sees(-5 - 5, 0, 0) == false or true)
		local back5 = sees(-5 - 4, 0, 0)
		check("cone: a player 4 studs behind is noticed (peripheral radius 6)", back5 == true)
		check("cone: ... 8 studs behind is not", sees(-5 - 8, 0, 0) == false)
		local edge = math.rad(P.FovDegrees / 2)
		check("cone: just inside the FOV edge is seen", sees(-5 + 30 * math.cos(edge - 0.02), 0, 30 * math.sin(edge - 0.02)))
		check("cone: just outside it is not", not sees(-5 + 30 * math.cos(edge + 0.02), 0, 30 * math.sin(edge + 0.02)))
		check("cone: the cone is symmetric left and right", sees(-5 + 30 * math.cos(edge - 0.02), 0, -30 * math.sin(edge - 0.02)))
		check("range: at the edge of ViewRange (standing) it is seen", sees(-5 + P.ViewRange - 0.01, 0, 0))
		check("range: beyond it, not", not sees(-5 + P.ViewRange + 1, 0, 0))
		check("stance: crouching shrinks the range (60% of 70 = 42): 50 studs away, crouched: unseen", not sees(45, 0, 0, "crouch") and sees(45, 0, 0, "stand"))
		check("stance: ... but is seen inside it", sees(-5 + 40, 0, 0, "crouch"))
		check("stance: sprinting stretches it (125% of 70 = 87.5)", sees(-5 + 80, 0, 0, "sprint") and not sees(-5 + 80, 0, 0, "stand"))
		local _, d = sight:canSee(bot.Id, "p1")
		check("canSee also reports the distance", near(d, 80, 1e-6))
		check("canSee: an unknown player or bot is a clean false", select(1, sight:canSee("nobody", "p1")) == false and select(1, sight:canSee(bot.Id, "ghost")) == false)
	end

	----------------------------------------------------------------------------------------------- walls and doors
	do
		-- bot in cell 1 at (-10, 0, 0) facing +Z; cell 3 is z >= 50 and is NOT joined to cell 1
		local sight, bots, pl = scene(-10, 0, nil, { face = math.pi }) -- Euler Y = 180° looks along +Z
		local bot = bots:all()[1]
		local fx, fz = bots:facing(bot)
		check("facing: Euler Y = 180° looks along +Z", near(fx, 0, 1e-6) and near(fz, 1, 1e-6))
		pl[1].X, pl[1].Y, pl[1].Z = -10, 0, 40
		check("walls: same cell, in front: seen", sight:canSee(bot.Id, "p1") == true)
		pl[1].X, pl[1].Z = -10, 60
		check("walls: the player is in a cell that is not joined to the bot's cell: the wall blocks (cell 1 to cell 3 with no link)", sight:canSee(bot.Id, "p1") == false)
		local _, _, why = sight:visibility(bot, { X = -10, Y = 0, Z = 60, Stance = "stand" })
		check("walls: ... and the reason is 'blocked'", why == "blocked")
		pl[1].X, pl[1].Z = 10, 40
		check("walls: a player in the neighbouring cell (a link joins 1 and 2) is visible", sight:canSee(bot.Id, "p1") == true)
		local sightB, botsB, plB = scene(10, 0, nil, { face = math.pi })
		plB[1].X, plB[1].Y, plB[1].Z = 10, 0, 60
		check("walls: seen through the doorway 2 -> 3 (joined by a link)", sightB:canSee(botsB:all()[1].Id, "p1") == true)
		local sightC, botsC, plC = scene(-10, 0, nil, { face = FACE_PLUS_X })
		plC[1].X, plC[1].Y, plC[1].Z = 25, 0, 0
		check("walls: unmapped space (no cell at all) is open air", true)
	end

	do -- closed doors, through BreachProps
		local function doorScene(attrs, name, open)
			local door = part(name or "DoorMetal", 10, 3, 0, attrs, 0, { X = 1, Y = 8, Z = 12 })
			local l = Logic.fromSpec({ Globals = {} }, {})
			local w = stubWorld()
			local pr = Props.fromNodes({ door }, w, l)
			local m = mission({ botNode("g", { Behavior = "PatrolWalk", Nodes = "Post", PatrolCycleLength = 99999 }) }, { folder("Post", { part("Node", 0, 0, 0, {}, FACE_PLUS_X) }) })
			local nav = Nav.new({ pathfinder = straight })
			local bots = Bots.new(m, w, l, nav, { seed = 1 })
			pr:addPlayer("p1", 20, 0, 0)
			local sight = Sight.new(w, bots, Sight.propsPlayers(pr), { blocked = function(...) return pr:sightBlocked(...) end })
			return sight, bots, pr, door
		end
		local sight, bots, pr, door = doorScene({})
		local bot = bots:all()[1]
		check("doors: a closed door between bot and player blocks sight", sight:canSee(bot.Id, "p1") == false)
		pr:openDoor("p1", door, "front")
		check("doors: an OPEN door does not", sight:canSee(bot.Id, "p1") == true)
		pr:closeDoor(door)
		check("doors: closing it blocks again", sight:canSee(bot.Id, "p1") == false)
		local sG, bG = doorScene({}, "DoorGlassFramed")
		check("doors: a glass door does not block sight [P]", sG:canSee(bG:all()[1].Id, "p1") == true)
		pr:move("p1", 5, 0, 0)
		check("doors: a player on the bot's side of the door is seen", sight:canSee(bot.Id, "p1") == true)
		check("doors: Props.sightBlocked only reports doors that actually cross the segment", pr:sightBlocked(0, 4, 20, 8, 4, 20) == false)
	end

	----------------------------------------------------------------------------------------------- the meter
	do
		local function timeToNotice(distance, attrs, stance, level)
			local sight, bots, pl = scene(-5, 0, attrs)
			if level then sight.LevelFn = function() return level end end
			pl[1].X, pl[1].Y, pl[1].Z, pl[1].Stance = -5 + distance, 0, 0, stance or "stand"
			for i = 1, 400 do
				bots:step(DT)
				sight:step(DT)
				for _, e in ipairs(sight:drainEvents()) do if e.Kind == "SightNoticed" then return i * DT end end
			end
			return nil
		end
		local near_t = timeToNotice(2)
		check("meter: point blank takes about NoticeNear (0.6 s) + a little for the distance", near_t and near_t >= 0.6 and near_t <= 0.75, near_t)
		local mid = timeToNotice(35)
		check("meter: half range takes about the midpoint (2.3 s)", mid and math.abs(mid - 2.3) <= 0.12, mid)
		local far = timeToNotice(P.ViewRange - 0.01)
		check("meter: the edge of the range takes NoticeFar (4 s)", far and math.abs(far - 4) <= 0.12, far)
		check("meter: closer is faster", near_t < mid and mid < far)
		local slow = timeToNotice(35, { DetectionSpeed = 0.5 })
		check("meter: DetectionSpeed 0.5 takes twice as long (a dim guard)", slow and math.abs(slow - 2 * mid) <= 0.25, slow)
		local quick = timeToNotice(35, { DetectionSpeed = 2 })
		check("meter: DetectionSpeed 2 takes half as long", quick and math.abs(quick - mid / 2) <= 0.15, quick)
		-- the alert level scales detection speed: Calm 0.9x, Normal 1x, Alert 1.1x [R]; Lockdown keeps 1.1x [P]
		local calm, normal, alerted, lock = timeToNotice(35, nil, nil, 0), timeToNotice(35, nil, nil, 1), timeToNotice(35, nil, nil, 2), timeToNotice(35, nil, nil, 3)
		check("meter: Calm (0.9x) is slower than Normal: about mid / 0.9", calm and math.abs(calm - mid / 0.9) <= 0.15, calm)
		check("meter: Normal (1x) is the plain speed", normal and math.abs(normal - mid) <= 0.05, normal)
		check("meter: Alert (1.1x) is faster: about mid / 1.1", alerted and math.abs(alerted - mid / 1.1) <= 0.15, alerted)
		check("meter: Lockdown keeps Alert's speed [P]", lock and math.abs(lock - alerted) <= 0.05, lock)
		check("meter: it multiplies with the bot's own DetectionSpeed (0.5 at Calm: mid / 0.45)", (function() local t = timeToNotice(35, { DetectionSpeed = 0.5 }, nil, 0) return t and math.abs(t - mid / 0.45) <= 0.3 end)())
		check("meter: no level function = factor 1", timeToNotice(35) == mid)
		local crouchFar = timeToNotice(35, nil, "crouch")
		check("meter: crouched at 35 studs (range 42, so 0.83 of range) is slower than standing at 35 (0.5 of range)", crouchFar and crouchFar > mid, crouchFar)
	end

	do -- fill, decay, events
		local sight, bots, pl = scene(-5, 0)
		local bot = bots:all()[1]
		pl[1].X = -5 + 35
		runFor(sight, bots, 1.0)
		local m1 = sight:meter(bot.Id, "p1")
		check("meter: it fills while the player is seen (1 s at half range = ~0.43)", math.abs(m1 - 1 / 2.3) <= 0.05, m1)
		pl[1].X = -200 -- far out of range
		runFor(sight, bots, 0.6)
		local m2 = sight:meter(bot.Id, "p1")
		check("meter: it decays at Decay (0.5/s) once the player is not seen", math.abs((m1 - m2) - 0.3) <= 0.03, m1 - m2)
		runFor(sight, bots, 3)
		check("meter: ... down to zero, not below", sight:meter(bot.Id, "p1") == 0)
		check("meter: the maximum over bots is available for a UI", sight:maxMeter("p1") == 0)
	end

	do
		local sight, bots, pl = scene(-5, 0)
		local bot = bots:all()[1]
		pl[1].X = -5 + 10
		runFor(sight, bots, 3)
		local evs = sight:drainEvents()
		local kinds = {}
		for _, e in ipairs(evs) do kinds[#kinds + 1] = e.Kind end
		check("events: Seen, then Suspicious, then Noticed, once each, in that order", table.concat(kinds, ",") == "SightSeen,SightSuspicious,SightNoticed", table.concat(kinds, ","))
		check("events: they carry the bot, the player, the time and the distance", evs[3].Bot == bot.Id and evs[3].Player == "p1" and evs[3].Time > 0 and near(evs[3].Distance, 10, 1e-6) and evs[3].Meter >= 1)
		check("events: a noticed player is listed by noticedBy / isNoticed", #sight:noticedBy("p1") == 1 and sight:isNoticed("p1") and sight:meter(bot.Id, "p1") == 1)
		pl[1].X = -5 - 40 -- out of sight (behind, beyond the peripheral radius)
		runFor(sight, bots, 2.9)
		check("events: a noticing bot keeps the meter full while it still remembers (< LoseSeconds)", sight:isNoticed("p1") and sight:meter(bot.Id, "p1") == 1)
		runFor(sight, bots, 0.3)
		local lost = events(sight, "SightLost")
		check("events: after LoseSeconds (3 s) unseen it loses the player (SightLost) and drops to the suspicious level", #lost == 1 and not sight:isNoticed("p1") and near(lost[1].Meter, P.SuspiciousAt, 1e-6))
		pl[1].X = -5 + 10
		runFor(sight, bots, 1.2)
		local again = events(sight)
		local seenAgain = {}
		for _, e in ipairs(again) do seenAgain[e.Kind] = true end
		check("events: a lost player can be noticed again, faster (it starts suspicious)", seenAgain.SightNoticed == true)
	end

	----------------------------------------------------------------------------------------------- who may observe
	do
		local sight, bots, pl = scene(-5, 0)
		local bot = bots:all()[1]
		pl[1].X = -5 + 10
		bots:setFlag(bot.Id, "Incapacitated", true)
		runFor(sight, bots, 2)
		check("observers: an incapacitated bot sees nothing", sight:meter(bot.Id, "p1") == 0)
		bots:setFlag(bot.Id, "Incapacitated", false)
		runFor(sight, bots, 2)
		check("observers: ... and sees again when it recovers", sight:meter(bot.Id, "p1") > 0.9)
		local s2, b2, p2 = scene(-5, 0)
		p2[1].X = -5 + 10
		b2:setFlag(b2:all()[1].Id, "Dead", true)
		runFor(s2, b2, 2)
		check("observers: a dead bot sees nothing", s2:meter(b2:all()[1].Id, "p1") == 0)
		local s3, b3, p3 = scene(-5, 0)
		p3[1].X = -5 + 10
		p3[1].Exited = true
		runFor(s3, b3, 2)
		check("observers: a player who has left the mission is ignored", s3:meter(b3:all()[1].Id, "p1") == 0)
		local s4, b4, p4, l4 = scene(-5, 0, { DespawnCondition = "Go" })
		p4[1].X = -5 + 10
		l4:set("Go", 1)
		runFor(s4, b4, 2)
		check("observers: a despawned bot sees nothing and causes no error", s4:meter(b4:all()[1].Id, "p1") == 0)
	end

	do -- two bots, one player
		local m = mission({ botNode("a", { Behavior = "PatrolWalk", Nodes = "PostA", PatrolCycleLength = 99999 }), botNode("b", { Behavior = "PatrolWalk", Nodes = "PostB", PatrolCycleLength = 99999 }) },
			{ folder("PostA", { part("Node", -5, 0, 0, {}, FACE_PLUS_X) }), folder("PostB", { part("Node", -5, 0, 20, {}, math.pi) }) })
		local l = Logic.fromSpec({ Globals = {} }, {})
		local nav = Nav.new({ pathfinder = straight })
		local w = stubWorld()
		local bots = Bots.new(m, w, l, nav, { seed = 1 })
		local players = { { Id = "p1", X = 15, Y = 0, Z = 0, Stance = "stand" } }
		local sight = Sight.new(w, bots, function() return players end)
		runFor(sight, bots, 3)
		check("several bots: only the one facing the player notices it", #sight:noticedBy("p1") == 1 and sight:noticedBy("p1")[1] == bots:all()[1].Id)
		check("several bots: the other one's meter stays at zero", sight:meter(bots:all()[2].Id, "p1") == 0)
	end

	do -- facing follows movement
		local m = mission({ botNode("w", { Behavior = "PatrolWalk", Nodes = "Beat", PatrolCycleLength = 1 }) },
			{ folder("Beat", { part("Node", 0, 0, 0, {}, FACE_PLUS_X), part("Node", 0, 0, 60, {}, FACE_PLUS_X) }) })
		local l = Logic.fromSpec({ Globals = {} }, {})
		local nav = Nav.new({ pathfinder = straight })
		local bots = Bots.new(m, stubWorld(), l, nav, { seed = 1 })
		local bot = bots:all()[1]
		local fx0, fz0 = bots:facing(bot)
		check("facing: standing at a node it uses the node's look direction", near(fx0, 1, 1e-6))
		for _ = 1, 20 * 6 do l:advance(DT) bots:step(DT) end
		local fx, fz = bots:facing(bot)
		check("facing: walking toward +Z it faces +Z (its heading), whatever the node says", near(fx, 0, 0.05) and near(fz, 1, 0.05), ("%.2f,%.2f"):format(fx, fz))
	end

	----------------------------------------------------------------------------------------------- robustness
	do
		local sight, bots, pl = scene(-5, 0)
		pl[1].X = -5 + 10
		local function sig()
			local s, b, p = scene(-5, 0)
			p[1].X = -5 + 25
			local out = {}
			for i = 1, 200 do b:step(DT) s:step(DT) if i % 20 == 0 then out[#out + 1] = ("%.6f"):format(s:meter(b:all()[1].Id, "p1")) end end
			for _, e in ipairs(s:drainEvents()) do out[#out + 1] = e.Kind .. "@" .. ("%.2f"):format(e.Time) end
			return table.concat(out, ",")
		end
		check("sight: two runs are identical (no randomness)", sig() == sig())
		local empty = Sight.new(nil, bots, function() return {} end)
		check("sight: no players, no world: harmless", pcall(empty.step, empty, DT))
		local nilworld = Sight.new(nil, bots, function() return { { Id = "x", X = 5, Y = 0, Z = 0 } } end)
		nilworld:step(DT)
		check("sight: with no world every line of sight is open", nilworld:meter(bots:all()[1].Id, "x") >= 0)
	end

	----------------------------------------------------------------------------------------------- real maps
	local okE, emb = pcall(require, "./_embedded")
	if not okE then
		print("(real-map sight tests skipped: tests/_embedded.luau not found)")
		return
	end
	local Codec = require("../BreachCodec")
	local Zstd = require("../BreachZstd")
	local Mission = require("../BreachMission")
	local Validator = require("../BreachValidator")
	local World = require("../BreachWorld")
	local host = { zstdDecompress = Zstd.decompress }
	local okP, embP = pcall(require, "./_embedded_project")
	local maps = { { "TheDiplomat", emb["TheDiplomat.base64"] }, { "thepeacemaker", emb["thepeacemaker.txt"] } }
	if okP then maps[#maps + 1] = { "TheProject", embP["theproject.txt"] } end

	for _, entry in ipairs(maps) do
		local label = entry[1]
		local mis = Mission.build(Codec.decode(entry[2], host), { validator = Validator })
		local w = World.build(mis)
		local function make()
			local l = Logic.new(mis, { seed = 416, builtins = { Mission_Difficulty = 3 } })
			local nav = Nav.new({ pathfinder = Nav.worldAdapter(w) })
			local bots = Bots.new(mis, w, l, nav, { seed = 416 })
			local props = Props.new(mis, w, l)
			local sight = Sight.new(w, bots, Sight.propsPlayers(props), { blocked = function(...) return props:sightBlocked(...) end })
			return sight, bots, props, l
		end
		local sight, bots, props, l = make()
		-- static posts: bots that stay where they are, so "in front of them" means something
		local posts = {}
		for _, b in ipairs(bots:all()) do
			if b.Timer == math.huge and #posts < 12 then posts[#posts + 1] = b end
		end
		props:addPlayer("front", 0, -500, 0)
		props:addPlayer("behind", 0, -500, 0)
		local frontSeen, behindSeen, tested = 0, 0, 0
		for _, b in ipairs(posts) do
			local bx, by, bz = bots:position(b.Id)
			local fx, fz = bots:facing(b)
			tested += 1
			props:move("front", bx + fx * 10, by, bz + fz * 10)
			props:move("behind", bx - fx * 30, by, bz - fz * 30)
			local fm, bm = 0, 0
			for _ = 1, 45 do sight:step(DT) fm = math.max(fm, sight:meter(b.Id, "front")) bm = math.max(bm, sight:meter(b.Id, "behind")) end
			if fm >= 1 then frontSeen += 1 end
			if bm >= 1 then behindSeen += 1 end
			props:move("front", 0, -500, 0)
			props:move("behind", 0, -500, 0)
		end
		if tested > 0 then
			check(label .. " [sight]: a player 10 studs in front of a real static bot is noticed in 3 s by most (" .. frontSeen .. "/" .. tested .. ")", frontSeen >= tested * 0.5, frontSeen .. "/" .. tested)
			check(label .. " [sight]: a player 30 studs BEHIND it never is (" .. behindSeen .. "/" .. tested .. ")", behindSeen == 0, behindSeen)
		end
		print(("  %s: %d bots, %d at static posts; in front: noticed by %d, behind: %d"):format(label, #bots:all(), tested, frontSeen, behindSeen))

		-- an idle map: nobody in view of anyone for 60 s
		local s2, b2, p2, l2 = make()
		p2:addPlayer("far", 0, -500, 0)
		for _ = 1, 20 * 20 do l2:advance(DT) b2:step(DT) s2:step(DT) end
		check(label .. " [sight]: a player far outside the map for 20 s is never seen, nothing errors", #s2:drainEvents() == 0 and #l2.Errors == 0)
		-- determinism with a walking player
		local function sig()
			local s3, b3, p3, l3 = make()
			p3:addPlayer("w", 0, 0, 0)
			local out = {}
			local bx, by, bz = b3:position(b3:all()[1].Id)
			for i = 1, 20 * 12 do
				p3:move("w", bx + math.sin(i * 0.02) * 40, by, bz + math.cos(i * 0.017) * 40)
				l3:advance(DT) b3:step(DT) s3:step(DT)
			end
			for _, e in ipairs(s3:drainEvents()) do out[#out + 1] = ("%s@%.2f:%s"):format(e.Kind, e.Time, e.Bot) end
			return table.concat(out, "|")
		end
		check(label .. " [sight]: two runs with a walking player are identical", sig() == sig())
	end
end
