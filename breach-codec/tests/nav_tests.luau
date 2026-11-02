--!nonstrict
-- M8a tests: BreachNav, the follower invariants (plan §2). Run via tests/run.luau or alone: `luau tests/nav.luau`
local Nav = require("../BreachNav")

local DT = 1 / 20

return function(check)
	local P = Nav.Defaults
	local function near(a, b, tol) return type(a) == "number" and math.abs(a - b) <= (tol or 1e-6) end
	local function dist(ax, az, bx, bz) return math.sqrt((ax - bx) ^ 2 + (az - bz) ^ 2) end
	-- open field: a straight line is always the path
	local function straight(from, to) return { { X = from.X, Y = from.Y or 0, Z = from.Z }, { X = to.X, Y = to.Y or 0, Z = to.Z } } end

	----------------------------------------------------------------------------------------------- defaults are sane
	check("defaults: distances nest (Min < Yield < Stop < Follow < Resume)", P.MinDistance < P.YieldDistance and P.YieldDistance < P.StopDistance and P.StopDistance < P.FollowDistance and P.FollowDistance < P.ResumeDistance)
	check("defaults: speed ratio > 1 and a catch-up floor exist", P.MaxSpeedRatio > 1 and P.CatchUpSpeed > 0 and P.AgentMaxSpeed >= 16)

	----------------------------------------------------------------------------------------------- harness
	-- script: function(t) -> x, z of the leader at time t. Returns metrics after `seconds`.
	local function scenario(nav, followers, leaderId, script, seconds, hooks)
		local m = { minDist = math.huge, minDistAfterAttach = math.huge, selfClosing = 0, overspeed = 0, ticks = 0, maxSpeedRatio = 0, finalDist = nil, events = {}, dists = {} }
		local steps = math.floor(seconds / DT + 0.5)
		local prev = {}
		for _, id in ipairs(followers) do prev[id] = { nav:position(id) } end
		for i = 1, steps do
			local t = i * DT
			local lx, lz = script(t)
			nav:moveActor(leaderId, lx, 0, lz)
			local before = {}
			for _, id in ipairs(followers) do
				local x, _, z = nav:position(id)
				before[id] = dist(x, z, lx, lz)
			end
			if hooks and hooks.before then hooks.before(t, nav) end
			nav:step(DT)
			local actor = nav.Actors[leaderId]
			for _, id in ipairs(followers) do
				local x, y, z = nav:position(id)
				local d2 = dist(x, z, lx, lz)
				m.minDist = math.min(m.minDist, d2)
				if d2 < before[id] - 1e-6 and d2 < P.StopDistance - 1e-6 then m.selfClosing += 1 end
				local moved = dist(x, z, prev[id][1], prev[id][3])
				prev[id] = { x, y, z }
				local cap = nav:agent(id).LastCap or Nav.speedCap(P, actor.Speed, d2, nav:agent(id).MaxSpeed)
				if moved / DT > cap + 0.01 then m.overspeed += 1 end
				m.finalDist = d2
				m.dists[#m.dists + 1] = d2
			end
			m.ticks += 1
			for _, ev in ipairs(nav:drainEvents()) do m.events[#m.events + 1] = ev end
			if hooks and hooks.after then hooks.after(t, nav, m) end
		end
		return m
	end
	local function count(events, kind) local n = 0 for _, e in ipairs(events) do if e.Kind == kind then n += 1 end end return n end

	-- a leader walking `speed` along x from x0, stopping at tStop (stays), optionally reversing at tBack
	local function walker(x0, z0, speed, tStop, tBack, backSpeed)
		return function(t)
			if tBack and t >= tBack then
				local x = (x0 + speed * math.min(t, tStop or t)) - (backSpeed or speed) * (t - tBack)
				return x, z0
			end
			return x0 + speed * math.min(t, tStop or t), z0
		end
	end

	local function newField()
		local nav = Nav.new({ pathfinder = straight })
		nav:addActor("p", 0, 0, 0)
		nav:addAgent("f", -P.FollowDistance, 0, 0)
		nav:follow("f", "p")
		return nav
	end

	----------------------------------------------------------------------------------------------- trails (unit)
	do
		local nav = Nav.new({ pathfinder = straight })
		nav:addActor("p", 0, 0, 0)
		for i = 1, 40 do nav:moveActor("p", i * 0.5, 0, 0) end
		local tr = nav.Trails.p
		check("trail: breadcrumbs are laid at TrailSpacing, not every move", #tr.P < 20 and #tr.P > 8, #tr.P)
		check("trail: the head tracks the leader and SHead is the arc length", near(tr.HeadX, 20) and near(tr.SHead, 20))
		local x = tr:at(10)
		check("trail: at(s) interpolates along the route", near(x, 10, 1e-6))
		local x2 = tr:at(-5)
		check("trail: at(s) clamps to the start", near(x2, 0))
		local x3 = tr:at(99)
		check("trail: at(s) clamps to the head", near(x3, 20))
		local d, s = tr:nearest(8, 3)
		check("trail: nearest() gives the closest point and its arc length", near(d, 3, 1e-6) and near(s, 8, 1e-6))
		nav:moveActor("p", 500, 0, 0)
		check("trail: a jump longer than TeleportDistance starts a new trail", nav.Trails.p.SHead == 0 and nav.Trails.p.Breaks == 1)
		local small = Nav.new({ params = { TrailMaxPoints = 10 } })
		small:addActor("p", 0, 0, 0)
		for i = 1, 100 do small:moveActor("p", i * 2, 0, 0) end
		check("trail: old breadcrumbs are dropped past TrailMaxPoints (arc length keeps counting)", #small.Trails.p.P <= 10 and near(small.Trails.p.SHead, 200))
	end

	----------------------------------------------------------------------------------------------- following: the basics
	do
		local nav = newField()
		local m = scenario(nav, { "f" }, "p", walker(0, 0, 16, 5), 12)
		local d = m.finalDist
		check("follow: it ends up FollowDistance behind a leader who stopped (within 1.5)", math.abs(d - P.FollowDistance) <= 1.5 or (d >= P.StopDistance and d <= P.ResumeDistance), d)
		check("follow: I1' it never closed in by its own motion", m.selfClosing == 0, m.selfClosing)
		check("follow: I2 it never came closer than StopDistance", m.minDist >= P.StopDistance - 1e-6, m.minDist)
		check("follow: I3 its speed never exceeded the cap (1.15 x the leader, or the catch-up floor)", m.overspeed == 0, m.overspeed)
		check("follow: it did actually follow (the leader ended 80 studs away)", select(1, nav:position("f")) > 60, select(1, nav:position("f")))
		check("follow: a stationary leader is not approached closer than StopDistance (hold)", m.minDist >= P.StopDistance - 1e-6)
		-- retraces the leader's route: same z, no sideways drift
		check("follow: it retraces the leader's route exactly (no drift off the trail)", near(select(3, nav:position("f")), 0, 1e-6))
	end

	do -- I5: reaches the follow band within 5 s of the leader stopping, from a standing start far behind
		local nav = Nav.new({ pathfinder = straight })
		nav:addActor("p", 0, 0, 0)
		nav:addAgent("f", -40, 0, 0)
		nav:follow("f", "p")
		local m = scenario(nav, { "f" }, "p", function() return 0, 0 end, 10)
		local ok = false
		for i = 1, #m.dists do
			if i * DT <= 10 and m.dists[i] <= P.ResumeDistance and m.dists[i] >= P.StopDistance - 1e-6 then ok = true end
		end
		check("follow: I5 a follower 40 studs away comes to the follow band of a standing leader", ok, m.finalDist)
		check("follow: ... never passing StopDistance on the way", m.minDist >= P.StopDistance - 1e-6 and m.selfClosing == 0)
		check("follow: ... and used the catch-up speed, not a sprint (<= CatchUpSpeed+tolerance)", m.overspeed == 0)
	end

	do -- hysteresis: a leader who drifts 6 -> 7 studs away does not make it twitch
		local nav = newField()
		scenario(nav, { "f" }, "p", walker(0, 0, 16, 3), 6)
		local x0 = nav:position("f")
		local m = scenario(nav, { "f" }, "p", function(t) return 48 + math.sin(t * 2) * 0.6, 0 end, 4)
		check("follow: small leader wobble inside the band does not move it (hysteresis)", near(nav:position("f"), x0, 0.5), nav:position("f") - x0)
	end

	----------------------------------------------------------------------------------------------- I7: adversarial leaders
	do -- the leader reverses and walks straight back INTO the follower
		local nav = newField()
		local m = scenario(nav, { "f" }, "p", walker(0, 0, 16, 5, 5.5), 14)
		check("reverse: the leader walks back into the follower: it never moved toward the leader (I1')", m.selfClosing == 0, m.selfClosing)
		check("reverse: ... it yielded (backed away along its trail), then side-stepped once it ran out of trail", count(m.events, "Yield") >= 1 and count(m.events, "Sidestep") >= 1)
		check("reverse: ... and the distance stayed at least MinDistance", m.minDist >= P.MinDistance, m.minDist)
	end

	do -- the leader sprints at a stationary follower from close range
		local nav = newField()
		scenario(nav, { "f" }, "p", walker(0, 0, 16, 4), 8)
		local fx = nav:position("f")
		local lx = 64
		local m = scenario(nav, { "f" }, "p", function(t) return math.max(fx - 4, lx - (t - 8) * 16), 0 end, 6, nil)
		-- (the closure above restarts time at 0 for the new scenario call; use an explicit charge instead)
		local nav2 = newField()
		scenario(nav2, { "f" }, "p", walker(0, 0, 16, 4), 8)
		local fx2 = nav2:position("f")
		local startX = 64
		local t0
		local m2 = { minDist = math.huge, selfClosing = 0 }
		local steps = 60
		for i = 1, steps do
			local lx2 = math.max(fx2 - 3, startX - i * DT * 16)
			nav2:moveActor("p", lx2, 0, 0)
			local x, _, z = nav2:position("f")
			local d1 = dist(x, z, lx2, 0)
			nav2:step(DT)
			local x2, _, z2 = nav2:position("f")
			local d2 = dist(x2, z2, lx2, 0)
			m2.minDist = math.min(m2.minDist, d2)
			if d2 < d1 - 1e-6 and d2 < P.StopDistance - 1e-6 then m2.selfClosing += 1 end
		end
		check("charge: a leader sprinting through the follower's spot never gets it to move toward them", m2.selfClosing == 0, m2.selfClosing)
		check("charge: the follower backs off fast enough that the distance never fell below MinDistance (leader stops 3 studs short of where it stood)", m2.minDist >= P.MinDistance - 0.2, m2.minDist)
	end

	do -- cornered: no room behind (the trail is short): it cannot yield, but it must not close in either
		local nav = Nav.new({ pathfinder = straight })
		nav:addActor("p", 0, 0, 0)
		nav:addAgent("f", -3.5, 0, 0)
		nav:follow("f", "p")
		for i = 1, 30 do nav:moveActor("p", -3.5 + i * 0.1, 0, 0) nav:step(DT) end
		local m = { selfClosing = 0 }
		for i = 1, 40 do
			nav:moveActor("p", -0.5 - i * 0.12, 0, 0)
			local x = nav:position("f")
			local d1 = dist(x, 0, -0.5 - i * 0.12, 0)
			nav:step(DT)
			local x2 = nav:position("f")
			if dist(x2, 0, -0.5 - i * 0.12, 0) < d1 - 1e-6 and dist(x2, 0, -0.5 - i * 0.12, 0) < P.StopDistance then m.selfClosing += 1 end
		end
		check("cornered: with nowhere to go the follower still never moves toward the leader", m.selfClosing == 0)
	end

	do -- the leader circles the follower at a deliberately rude 3 studs
		local nav = newField()
		scenario(nav, { "f" }, "p", walker(0, 0, 16, 4), 8)
		local fx = nav:position("f")
		local m = { selfClosing = 0, min = math.huge }
		for i = 1, 200 do
			local a = i * DT * 2
			local lx, lz = fx + math.cos(a) * 3, math.sin(a) * 3
			nav:moveActor("p", lx, 0, lz)
			local x, _, z = nav:position("f")
			local d1 = dist(x, z, lx, lz)
			nav:step(DT)
			local x2, _, z2 = nav:position("f")
			local d2 = dist(x2, z2, lx, lz)
			m.min = math.min(m.min, d2)
			if d2 < d1 - 1e-6 and d2 < P.StopDistance - 1e-6 then m.selfClosing += 1 end
		end
		check("circling: a leader orbiting at 3 studs never makes the follower close in", m.selfClosing == 0, m.selfClosing)
	end

	do -- the leader stands in a doorway: the follower waits behind a closed door and goes single file once it opens
		local open = false
		local nav = Nav.new({ pathfinder = straight, blocked = function(ax, ay, az, bx, by, bz) return not open and ax < 50 and bx >= 50 end })
		nav:addActor("p", 0, 0, 0)
		nav:addAgent("f", -6, 0, 0)
		nav:follow("f", "p")
		local m = scenario(nav, { "f" }, "p", walker(0, 0, 16, 7), 9, { before = function(t) if t > 4 then end end })
		-- the leader walked 112 studs through x = 50 (a door that was open for the leader, shut behind): the follower must be held at the door
		local fx = nav:position("f")
		check("door: a closed passage holds the follower back (it did not walk through)", fx < 50 + 1e-6, fx)
		check("door: ... and it said it was waiting", count(m.events, "Waiting") >= 1)
		open = true
		local m2 = scenario(nav, { "f" }, "p", function() return 112, 0 end, 14)
		check("door: once the door opens it goes through and finishes behind the leader", select(1, nav:position("f")) > 100, select(1, nav:position("f")))
		check("door: ... without ever closing in", m2.selfClosing == 0 and m2.minDist >= P.StopDistance - 1e-6)
	end

	do -- the leader teleports (a lift, a vault): the trail breaks and the follower paths to the new spot
		local reqs = 0
		local nav = Nav.new({ pathfinder = function(a, b) reqs += 1 return straight(a, b) end })
		nav:addActor("p", 0, 0, 0)
		nav:addAgent("f", -6, 0, 0)
		nav:follow("f", "p")
		scenario(nav, { "f" }, "p", walker(0, 0, 16, 3), 5)
		local m = scenario(nav, { "f" }, "p", function() return 300, 0 end, 25)
		check("teleport: the trail breaks and the follower is told (TrailBroken)", count(m.events, "TrailBroken") == 1)
		check("teleport: it walks a path to the leader's new place and settles in the follow band", m.finalDist >= P.StopDistance - 1e-6 and m.finalDist <= P.ResumeDistance + 1e-6, m.finalDist)
		check("teleport: it never closed in on the way", m.selfClosing == 0 and m.minDist >= P.StopDistance - 1e-6)
		check("teleport: I4 it asked for a path rarely (<= RepathHz per second plus one)", reqs <= P.RepathHz * 25 + 2, reqs)
	end

	do -- I4: a leader who keeps changing direction does not make the follower repath every tick
		local reqs = 0
		local nav = Nav.new({ pathfinder = function(a, b) reqs += 1 return straight(a, b) end })
		nav:addActor("p", 0, 0, 0)
		nav:addAgent("f", -50, 0, 0)
		nav:follow("f", "p")
		local T = 20
		scenario(nav, { "f" }, "p", function(t) return math.sin(t * 3) * 20, math.cos(t * 2.3) * 20 end, T)
		check("repath: I4 a jittery leader causes at most RepathHz requests per second", reqs <= P.RepathHz * T + 1, reqs)
	end

	do -- I6: two followers keep apart from each other and from the leader
		local nav = Nav.new({ pathfinder = straight })
		nav:addActor("p", 0, 0, 0)
		nav:addAgent("a", -6, 0, 0)
		nav:addAgent("b", -6, 0, 0.5)
		nav:follow("a", "p")
		nav:follow("b", "p")
		local m = scenario(nav, { "a", "b" }, "p", walker(0, 0, 16, 5), 12)
		local ax, _, az = nav:position("a")
		local bx, _, bz = nav:position("b")
		check("two followers: they separate (>= Separation - 0.5 apart once settled)", dist(ax, az, bx, bz) >= P.Separation - 0.5, dist(ax, az, bx, bz))
		check("two followers: neither ever moved toward the leader inside StopDistance", m.selfClosing == 0 and m.minDist >= P.StopDistance - 1e-6)
		check("two followers: both ended up near the leader", m.finalDist < 15)
	end

	do -- the follower is slower to start than the leader: a leader that runs does not get run past
		local nav = newField()
		local m = scenario(nav, { "f" }, "p", walker(0, 0, 16, 10, 10.1, 16), 14)
		check("run: a running leader is followed without overspeed or closing in", m.overspeed == 0 and m.selfClosing == 0)
	end

	----------------------------------------------------------------------------------------------- stuck and snap
	do
		local nav = Nav.new({ pathfinder = function(from) return { { X = from.X, Y = 0, Z = from.Z } } end })
		nav:addActor("p", 0, 0, 0)
		nav:addAgent("f", -30, 0, 0)
		nav:follow("f", "p")
		for i = 1, 40 do nav:moveActor("p", i * 0.8, 0, 0) nav:step(DT) end
		local m = scenario(nav, { "f" }, "p", function() return 32, 0 end, 12)
		check("stuck: an agent that cannot make progress reports Stuck", count(m.events, "Stuck") >= 2)
		check("stuck: ... and is then snapped back onto the leader's trail, behind them", count(m.events, "Snapped") >= 1)
		local x = nav:position("f")
		check("stuck: ... at a spot behind the leader, never on top of them", dist(x, 0, 32, 0) >= P.StopDistance - 1e-6 and x < 32)
		local veto = Nav.new({ pathfinder = function(from) return { { X = from.X, Y = 0, Z = from.Z } } end, canSnap = function() return false end })
		veto:addActor("p", 0, 0, 0)
		veto:addAgent("f", -30, 0, 0)
		veto:follow("f", "p")
		for i = 1, 40 do veto:moveActor("p", i * 0.8, 0, 0) veto:step(DT) end
		local mv = scenario(veto, { "f" }, "p", function() return 32, 0 end, 12)
		check("stuck: canSnap can veto a snap (a player is looking) - it stays stuck rather than pop into view", count(mv.events, "Snapped") == 0 and count(mv.events, "Stuck") >= 2)
	end

	----------------------------------------------------------------------------------------------- goto (patrol legs)
	do
		local nav = Nav.new({ pathfinder = straight })
		nav:addAgent("g", 0, 0, 0)
		nav:goto("g", 80, 0, 0)
		local arrivedAt
		for i = 1, 200 do
			nav:step(DT)
			for _, ev in ipairs(nav:drainEvents()) do if ev.Kind == "Arrived" then arrivedAt = ev.Time end end
		end
		check("goto: an agent walks to a goal and reports Arrived once", arrivedAt ~= nil and near(nav:position("g"), 80, P.ArriveTolerance + 0.01))
		check("goto: at about its max speed (80 studs in ~4-6 s)", arrivedAt > 3.8 and arrivedAt < 6.5, arrivedAt)
		check("goto: it is idle afterwards", nav:agent("g").Mode == "idle" and nav:agent("g").Speed == 0)

		local bent = Nav.new({ pathfinder = function() return { { X = 0, Y = 0, Z = 0 }, { X = 30, Y = 0, Z = 0 }, { X = 30, Y = 0, Z = 30 } } end })
		bent:addAgent("g", 0, 0, 0)
		bent:goto("g", 30, 0, 30)
		local maxX = 0
		local visitedCorner = false
		for i = 1, 200 do
			bent:step(DT)
			local x, _, z = bent:position("g")
			if near(x, 30, 1.0) and near(z, 0, 1.0) then visitedCorner = true end
			maxX = math.max(maxX, x)
		end
		check("goto: it follows the path's waypoints (goes round the corner, not across it)", visitedCorner and maxX <= 30.001 and near(select(3, bent:position("g")), 30, 1.1))

		local failing = Nav.new({ pathfinder = function() return nil end })
		failing:addAgent("g", 0, 0, 0)
		failing:goto("g", 10, 0, 0)
		failing:step(DT)
		local evs = failing:drainEvents()
		check("goto: no path -> PathFailed, and the agent gives up (idle)", count(evs, "PathFailed") == 1 and failing:agent("g").Mode == "idle")

		local stopped = Nav.new({ pathfinder = straight })
		stopped:addAgent("g", 0, 0, 0)
		stopped:goto("g", 100, 0, 0)
		for _ = 1, 20 do stopped:step(DT) end
		stopped:stop("g")
		local x1 = stopped:position("g")
		for _ = 1, 40 do stopped:step(DT) end
		check("goto: stop() halts it (decelerates to a standstill)", stopped:agent("g").Mode == "idle" and stopped:position("g") - x1 < 6, stopped:position("g") - x1)

		local gate = false
		local door = Nav.new({ pathfinder = straight, blocked = function(ax, _, _, bx) return not gate and ax < 40 and bx >= 40 end })
		door:addAgent("g", 0, 0, 0)
		door:goto("g", 80, 0, 0)
		local waited = 0
		for _ = 1, 100 do door:step(DT) for _, e in ipairs(door:drainEvents()) do if e.Kind == "Waiting" then waited += 1 end end end
		check("goto: a closed door makes it wait in front of it", door:position("g") <= 40 and waited >= 1)
		gate = true
		for _ = 1, 120 do door:step(DT) end
		check("goto: ... and it carries on when the door opens", near(door:position("g"), 80, P.ArriveTolerance + 0.01))
	end

	----------------------------------------------------------------------------------------------- determinism and robustness
	do
		local function signature()
			local nav = Nav.new({ pathfinder = straight })
			nav:addActor("p", 0, 0, 0)
			nav:addAgent("a", -6, 0, 0)
			nav:addAgent("b", -9, 0, 2)
			nav:follow("a", "p")
			nav:follow("b", "p")
			local out = {}
			for i = 1, 400 do
				local t = i * DT
				nav:moveActor("p", math.sin(t) * 40, 0, math.cos(t * 1.3) * 25)
				nav:step(DT)
				if i % 20 == 0 then
					local ax, _, az = nav:position("a")
					local bx, _, bz = nav:position("b")
					out[#out + 1] = ("%.6f,%.6f,%.6f,%.6f"):format(ax, az, bx, bz)
				end
			end
			return table.concat(out, ";")
		end
		check("nav: two runs of the same script are bit-identical", signature() == signature())
	end

	do
		local nav = Nav.new({ pathfinder = straight })
		check("api: unknown ids are clean failures", nav:follow("x", "y") == false and nav:goto("x", 1, 1, 1) == false and nav:moveActor("x", 1, 1, 1) == false and nav:position("x") == nil)
		nav:addAgent("a", 0, 0, 0)
		nav:addActor("p", 5, 0, 5)
		nav:follow("a", "p")
		nav:removeAgent("a")
		nav:step(DT)
		check("api: removing an agent mid-follow is harmless", nav:agent("a") == nil)
		nav:addAgent("c", 0, 0, 0)
		nav:follow("c", "p")
		nav.Actors.p = nil
		nav:step(DT)
		check("api: a follower whose leader vanished goes idle (no error)", nav:agent("c").Mode == "idle")
		-- fuzz: random scripted leaders, random speeds, random params: never throws, never NaN
		local seed = 99
		local function rnd() seed = (seed * 1103515245 + 12345) % 2147483648 return seed / 2147483648 end
		local bad = 0
		for _ = 1, 40 do
			local n = Nav.new({ pathfinder = straight, params = { FollowDistance = 3 + rnd() * 10, StopDistance = 2 + rnd() * 3, ResumeDistance = 8 + rnd() * 5, YieldDistance = 1 + rnd() * 2, Accel = 20 + rnd() * 200 } })
			n:addActor("p", 0, 0, 0)
			n:addAgent("f", -rnd() * 30, 0, rnd() * 10)
			n:follow("f", "p")
			for i = 1, 200 do
				local okp = pcall(function()
					n:moveActor("p", (rnd() - 0.5) * 80, 0, (rnd() - 0.5) * 80)
					n:step(DT)
				end)
				local x, y, z = n:position("f")
				if not okp or x ~= x or z ~= z or y ~= y then bad += 1 end
			end
		end
		check("nav fuzz: 40 random leaders x 200 steps: no throw, no NaN", bad == 0, bad)
	end

	----------------------------------------------------------------------------------------------- real maps: followers on real routes
	local okE, emb = pcall(require, "./_embedded")
	if not okE then
		print("(real-map nav tests skipped: tests/_embedded.luau not found)")
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
		local m = Mission.build(Codec.decode(entry[2], host), { validator = Validator })
		local world = World.build(m)
		local nodes = world._nav.nodes
		local finder = Nav.worldAdapter(world)
		-- deterministic routes between far-apart nodes of the real graph
		local routes = {}
		local n = #nodes
		local k = 0
		while #routes < 6 and k < 400 do
			k += 1
			local a, b = nodes[1 + (k * 37) % n], nodes[1 + (k * 91 + 17) % n]
			local r = world:findPath({ X = a.X, Y = a.Y, Z = a.Z }, { X = b.X, Y = b.Y, Z = b.Z })
			if r and r.length > 80 and #r.points > 6 then routes[#routes + 1] = r.points end
		end
		check(label .. " [nav]: found real routes to walk (" .. #routes .. ")", #routes >= 3, #routes)

		local agg = { selfClosing = 0, overspeed = 0, minStop = math.huge, settled = 0, runs = 0, reqs = 0, reqLimit = 0, events = {} }
		for ri, pts in ipairs(routes) do
			-- the leader walks the route at 16, pauses mid-way for 5 s, and on odd routes turns round and walks 30 studs back
			local segs, total = {}, 0
			for i = 1, #pts - 1 do
				local l = dist(pts[i].X, pts[i].Z, pts[i + 1].X, pts[i + 1].Z)
				segs[#segs + 1] = { pts[i], pts[i + 1], l, total }
				total += l
			end
			local function pointAt(s)
				s = math.max(0, math.min(total, s))
				for _, sg in ipairs(segs) do
					if s <= sg[4] + sg[3] then
						local t = sg[3] > 0 and (s - sg[4]) / sg[3] or 0
						local a, b = sg[1], sg[2]
						return a.X + (b.X - a.X) * t, a.Y + (b.Y - a.Y) * t, a.Z + (b.Z - a.Z) * t
					end
				end
				local l = pts[#pts]
				return l.X, l.Y, l.Z
			end
			local half = math.min(total, 120)
			local reqs = 0
			local nav = Nav.new({ pathfinder = function(a, b) reqs += 1 return finder(a, b) end })
			local lx, ly, lz = pointAt(10)
			nav:addActor("p", lx, ly, lz)
			local fx, fy, fz = pointAt(0)
			nav:addAgent("f", fx, fy, fz)
			nav:follow("f", "p")
			local walkTime = (half - 10) / 16
			local function script(t)
				local s
				if t <= walkTime then s = 10 + 16 * t
				elseif t <= walkTime + 5 then s = half
				elseif ri % 2 == 1 and t <= walkTime + 5 + 30 / 16 then s = half - 16 * (t - walkTime - 5)
				else s = (ri % 2 == 1) and (half - 30) or half end
				local x, y, z = pointAt(s)
				return x, z, y
			end
			local steps = math.floor((walkTime + 5 + 30 / 16 + 8) / DT)
			local prevx, _, prevz = nav:position("f")
			local worstStop = math.huge
			for i = 1, steps do
				local t = i * DT
				local x, z, y = script(t)
				nav:moveActor("p", x, y, z)
				local ax, _, az = nav:position("f")
				local d1 = dist(ax, az, x, z)
				nav:step(DT)
				local bx, by, bz = nav:position("f")
				local d2 = dist(bx, bz, x, z)
				if d2 < d1 - 1e-6 and d2 < P.StopDistance - 1e-6 then agg.selfClosing += 1 end
				local moved = dist(bx, bz, prevx, prevz)
				prevx, prevz = bx, bz
				local cap = nav:agent("f").LastCap or Nav.speedCap(P, nav.Actors.p.Speed, d2, nav:agent("f").MaxSpeed)
				if moved / DT > cap + 0.01 then agg.overspeed += 1 end
				if i * DT > 8 and d2 < worstStop then worstStop = d2 end
			end
			local x, z = script(steps * DT)
			local bx, _, bz = nav:position("f")
			local d = dist(bx, bz, x, z)
			agg.runs += 1
			if d <= P.ResumeDistance + 1 and d >= P.StopDistance - 0.5 then agg.settled += 1 end
			agg.reqs += reqs
			agg.reqLimit += P.RepathHz * (steps * DT) + 2
			agg.minStop = math.min(agg.minStop, worstStop)
		end
		check(label .. " [nav]: I1' on " .. agg.runs .. " real routes (walk, pause, turn back): the follower never moved toward the leader inside StopDistance", agg.selfClosing == 0, agg.selfClosing)
		check(label .. " [nav]: I3 it never exceeded the speed cap", agg.overspeed == 0, agg.overspeed)
		check(label .. " [nav]: I4 total path requests stayed within RepathHz per second per follower", agg.reqs <= agg.reqLimit, agg.reqs .. "/" .. agg.reqLimit)
		check(label .. " [nav]: I5 every run ended with the follower in the follow band", agg.settled == agg.runs, agg.settled .. "/" .. agg.runs)
		check(label .. " [nav]: the closest it ever was (after the first 8 s, including the turn-back that walks into it) stayed above MinDistance", agg.minStop >= P.MinDistance, agg.minStop)
		print(("  %s: %d routes; closest approach after the first 8 s %.2f studs (StopDistance %g, MinDistance %g); %d path requests"):format(label, agg.runs, agg.minStop, P.StopDistance, P.MinDistance, agg.reqs))
	end
end
