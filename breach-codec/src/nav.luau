--!nonstrict
--[==[
	BreachNav — kinematic movement for bots and followers (BreachEngine M8a; plan: BreachEngine_M8_Bots_Plan.md §2).

	Pure Luau, deterministic, no Roblox APIs, no randomness. The host moves ACTORS (players); Nav moves AGENTS (bots)
	and never touches physics: an agent has a position and a speed, nothing that can push a player.

	    local nav = Nav.new({ pathfinder = function(from, to) return { {X=,Y=,Z=}, ... } or nil end })
	    nav:addActor("p1", x, y, z)        nav:moveActor("p1", x, y, z)       -- the host moves players
	    nav:addAgent("civ", x, y, z)       nav:follow("civ", "p1")            -- a hostage you lead
	    nav:goto("guard", x, y, z)         nav:stop("guard")                  -- patrol legs
	    nav:step(1 / 20)                   local x, y, z = nav:position("civ")
	    for _, ev in ipairs(nav:drainEvents()) do ... end                     -- Arrived, Waiting, Stuck, Snapped, Yield, ...

	Why a follower cannot hit you (each is a rule here and an assertion in the tests):
	  * it never targets the leader: it follows the leader's TRAIL (breadcrumbs of where the leader really walked), at
	    FollowDistance behind, so it uses the same corridors and doors and cannot cut a corner through you;
	  * it stops at StopDistance and resumes only beyond ResumeDistance (hysteresis, no jitter);
	  * its own motion is never allowed to bring it closer than StopDistance (moves that would are refused);
	  * its speed is capped at MaxSpeedRatio x the leader's speed (a floor lets it start from rest);
	  * if the leader walks INTO it (closer than YieldDistance) it backs away along its trail instead of holding ground;
	  * single file at doors: a closed passage (opts.blocked) makes it wait; repathing is rate limited; a stuck agent is
	    re-attached, then snapped back onto the trail (opts.canSnap can veto while a player is looking).
	Units are studs and seconds; the defaults assume a 16 studs/s walking character.
]==]

local Nav = {}
Nav.VERSION = "0.1.0"

Nav.Defaults = {
	FollowDistance = 6, -- how far behind the leader (along its trail) a follower stands
	StopDistance = 5, -- it stops this close (straight-line) ...
	ResumeDistance = 7.5, -- ... and moves again only beyond this (> StopDistance: hysteresis)
	YieldDistance = 4.5, -- the leader closer than this makes the follower back off
	MinDistance = 2.5, -- the invariant: no follower is ever driven closer than this while it has room (asserted in tests)
	Separation = 3, -- agents keep this far from each other
	MaxSpeedRatio = 1.15, -- follower speed <= ratio x leader speed ...
	CatchUpSpeed = 6, -- ... but may always use at least this (so it can start from rest) ...
	CatchUpGain = 1, -- ... plus this many studs/s per stud of gap beyond ResumeDistance (a far-behind follower hurries, up to AgentMaxSpeed)
	SlotSpacing = 4, -- each further follower of the same leader stands this much further back
	AgentMaxSpeed = 20,
	Accel = 120,
	Decel = 160,
	TrailSpacing = 1.5, -- distance between breadcrumbs
	TrailMaxPoints = 800,
	TeleportDistance = 40, -- a leader jump this far breaks the trail
	RepathHz = 2, -- at most this many path requests per second per agent
	StuckSeconds = 2,
	ArriveTolerance = 1,
	JoinRadius = 3, -- within this of the trail an agent attaches to it (it then blends onto the trail, no snap) ...
	OffsetRate = 6, -- ... closing the sideways gap at this many studs/s
	LeaderSpeedSmoothing = 0.5,
}

local function xyz(p, b, c)
	if type(p) == "table" then
		return p.X or p.x or p[1], p.Y or p.y or p[2], p.Z or p.z or p[3]
	end
	return p, b, c
end

-- The most a follower may do: 1.15 x the leader's speed, or the catch-up speed (which grows with the gap), whichever is larger.
function Nav.speedCap(params, leaderSpeed, gap, agentMax)
	local catch = params.CatchUpSpeed + math.max(0, gap - params.ResumeDistance) * params.CatchUpGain
	return math.min(agentMax or params.AgentMaxSpeed, math.max(params.MaxSpeedRatio * leaderSpeed, catch))
end

local function hdist(ax, az, bx, bz)
	local dx, dz = ax - bx, az - bz
	return math.sqrt(dx * dx + dz * dz)
end

--------------------------------------------------------------------------------------------------- trails

local Trail = {}
Trail.__index = Trail

local function newTrail(x, y, z)
	-- points[i] = { x, y, z, s }; s is the arc length from the start of the trail's life (never reset when old points are dropped)
	return setmetatable({ P = { { x, y, z, 0 } }, HeadX = x, HeadY = y, HeadZ = z, SHead = 0, Breaks = 0 }, Trail)
end

function Trail:push(x, y, z, spacing, maxPoints)
	local last = self.P[#self.P]
	local d = math.sqrt((x - last[1]) ^ 2 + (z - last[3]) ^ 2)
	self.HeadX, self.HeadY, self.HeadZ = x, y, z
	self.SHead = last[4] + d
	if d >= spacing then
		self.P[#self.P + 1] = { x, y, z, self.SHead }
		if #self.P > maxPoints then
			table.remove(self.P, 1)
		end
	end
end

-- The point at arc length s (clamped to the stored trail).
function Trail:at(s)
	local P = self.P
	if s <= P[1][4] then
		return P[1][1], P[1][2], P[1][3]
	end
	local last = P[#P]
	if s >= self.SHead then
		return self.HeadX, self.HeadY, self.HeadZ
	end
	if s >= last[4] then
		local span = self.SHead - last[4]
		local t = span > 0 and (s - last[4]) / span or 1
		return last[1] + (self.HeadX - last[1]) * t, last[2] + (self.HeadY - last[2]) * t, last[3] + (self.HeadZ - last[3]) * t
	end
	local lo, hi = 1, #P
	while hi - lo > 1 do
		local mid = (lo + hi) // 2
		if P[mid][4] <= s then
			lo = mid
		else
			hi = mid
		end
	end
	local a, b = P[lo], P[hi]
	local span = b[4] - a[4]
	local t = span > 0 and (s - a[4]) / span or 0
	return a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t
end

-- Nearest point of the trail to (x, z): returns distance and its arc length.
function Trail:nearest(x, z)
	local best, bs = math.huge, 0
	local P = self.P
	local function seg(ax, az, as, bx, bz, bs2)
		local dx, dz = bx - ax, bz - az
		local len2 = dx * dx + dz * dz
		local t = len2 > 0 and math.max(0, math.min(1, ((x - ax) * dx + (z - az) * dz) / len2)) or 0
		local px, pz = ax + dx * t, az + dz * t
		local d = hdist(x, z, px, pz)
		if d < best then
			best, bs = d, as + (bs2 - as) * t
		end
	end
	for i = 1, #P - 1 do
		seg(P[i][1], P[i][3], P[i][4], P[i + 1][1], P[i + 1][3], P[i + 1][4])
	end
	local last = P[#P]
	seg(last[1], last[3], last[4], self.HeadX, self.HeadZ, self.SHead)
	return best, bs
end

function Trail:start()
	return self.P[1][4]
end

--------------------------------------------------------------------------------------------------- the simulation

local Sim = {}
Sim.__index = Sim

function Nav.new(opts)
	opts = opts or {}
	local params = {}
	for k, v in pairs(Nav.Defaults) do
		params[k] = v
	end
	for k, v in pairs(opts.params or {}) do
		params[k] = v
	end
	return setmetatable({
		Params = params, Pathfinder = opts.pathfinder, Blocked = opts.blocked, CanSnap = opts.canSnap, Walkable = opts.walkable,
		Time = 0, Actors = {}, Agents = {}, Order = {}, Events = {}, Trails = {}, Followers = {},
	}, Sim)
end

function Sim:emit(kind, agent, extra)
	local ev = { Kind = kind, Agent = agent and agent.Id, Time = self.Time }
	for k, v in pairs(extra or {}) do
		ev[k] = v
	end
	self.Events[#self.Events + 1] = ev
end

function Sim:drainEvents()
	local e = self.Events
	self.Events = {}
	return e
end

--------------------------------------------------------------------------------------------------- actors (players)

function Sim:addActor(id, x, y, z)
	self.Actors[id] = { Id = id, X = x, Y = y or 0, Z = z, Speed = 0 }
	self.Trails[id] = newTrail(x, y or 0, z)
	return self.Actors[id]
end

-- The host moves an actor (call before step(); Nav estimates its speed from the displacement per step).
function Sim:moveActor(id, x, y, z)
	local a = self.Actors[id]
	if not a then
		return false
	end
	local p = self.Params
	local moved = hdist(a.X, a.Z, x, z)
	if moved > p.TeleportDistance then
		self.Trails[id] = newTrail(x, y or 0, z) -- a jump breaks the trail; followers re-approach with a path
		a.Speed = 0
		self.Trails[id].Breaks = (self.Trails[id].Breaks or 0) + 1
		for _, ag in ipairs(self.Order) do
			if ag.Leader == id then
				ag.Attached = false
				ag.Path = nil
				self:emit("TrailBroken", ag, { Actor = id })
			end
		end
	else
		self.Trails[id]:push(x, y or 0, z, p.TrailSpacing, p.TrailMaxPoints)
	end
	a.X, a.Y, a.Z = x, y or a.Y, z
	return true
end

--------------------------------------------------------------------------------------------------- agents

function Sim:addAgent(id, x, y, z, opts)
	opts = opts or {}
	local ag = {
		Id = id, X = x, Y = y or 0, Z = z, Speed = 0, MaxSpeed = opts.MaxSpeed or self.Params.AgentMaxSpeed,
		Mode = "idle", Path = nil, PathIndex = 1, Leader = nil, Attached = false, TrailS = 0, Holding = false,
		Waiting = false, RepathAt = -1e9, PathRequests = 0, StuckTimer = 0, StuckX = x, StuckZ = z, StuckStrikes = 0,
	}
	self.Agents[id] = ag
	self.Order[#self.Order + 1] = ag
	return ag
end

function Sim:removeAgent(id)
	local ag = self.Agents[id]
	if not ag then
		return
	end
	self:leave(ag)
	self.Agents[id] = nil
	for i, a in ipairs(self.Order) do
		if a == ag then
			table.remove(self.Order, i)
			break
		end
	end
end

function Sim:agent(id)
	return self.Agents[id]
end

function Sim:position(id)
	local a = self.Agents[id] or self.Actors[id]
	if not a then
		return nil
	end
	return a.X, a.Y, a.Z
end

function Sim:follow(agentId, actorId)
	local ag, actor = self.Agents[agentId], self.Actors[actorId]
	if not (ag and actor) then
		return false
	end
	self:leave(ag)
	ag.Mode, ag.Leader, ag.Attached, ag.Path, ag.Holding = "follow", actorId, false, nil, false
	ag.Speed = 0
	local list = self.Followers[actorId] or {}
	self.Followers[actorId] = list
	list[#list + 1] = ag
	return true
end

-- remove an agent from its leader's queue
function Sim:leave(ag)
	local list = ag.Leader and self.Followers[ag.Leader]
	if list then
		for i, a in ipairs(list) do
			if a == ag then
				table.remove(list, i)
				break
			end
		end
	end
end

function Sim:slotOf(ag)
	local list = self.Followers[ag.Leader]
	if list then
		for i, a in ipairs(list) do
			if a == ag then
				return i
			end
		end
	end
	return 1
end

function Sim:stopFollow(agentId)
	local ag = self.Agents[agentId]
	if ag then
		self:leave(ag)
		ag.Mode, ag.Leader, ag.Attached, ag.Path = "idle", nil, false, nil
	end
end

function Sim:goto(agentId, x, y, z)
	local ag = self.Agents[agentId]
	if not ag then
		return false
	end
	self:leave(ag)
	ag.Mode, ag.Leader, ag.Attached, ag.Goal = "goto", nil, false, { x, y or ag.Y, z }
	ag.Path, ag.PathIndex, ag.Final = nil, 1, false
	ag.RepathAt = -1e9
	return true
end

function Sim:stop(agentId)
	local ag = self.Agents[agentId]
	if ag then
		ag.Mode, ag.Path, ag.Goal, ag.Leader = "idle", nil, nil, nil
	end
end

-- Ask the pathfinder, at most RepathHz times a second per agent. Returns "ok", "failed" or "limited" (no request made).
function Sim:requestPath(ag, tx, ty, tz)
	local p = self.Params
	if self.Time < ag.RepathAt + 1 / p.RepathHz - 1e-9 then
		return "limited"
	end
	ag.RepathAt = self.Time
	ag.PathRequests += 1
	local pts = self.Pathfinder and self.Pathfinder({ X = ag.X, Y = ag.Y, Z = ag.Z }, { X = tx, Y = ty, Z = tz })
	if not pts or #pts == 0 then
		ag.Path = nil
		self:emit("PathFailed", ag, { X = tx, Z = tz })
		return "failed"
	end
	local path = {}
	for _, pt in ipairs(pts) do
		local x, y, z = xyz(pt)
		path[#path + 1] = { x, y, z }
	end
	ag.Path, ag.PathIndex = path, 1
	return "ok"
end

--------------------------------------------------------------------------------------------------- movement primitives

local function blockedBetween(self, ag, bx, by, bz)
	return self.Blocked ~= nil and self.Blocked(ag.X, ag.Y, ag.Z, bx, by, bz, ag) == true
end

-- Move `dist` studs toward (tx, tz) and report whether it moved. Never overshoots.
local function moveToward(ag, tx, ty, tz, dist)
	local dx, dz = tx - ag.X, tz - ag.Z
	local d = math.sqrt(dx * dx + dz * dz)
	if d < 1e-9 then
		return 0
	end
	local step = math.min(dist, d)
	local t = step / d
	ag.X, ag.Z = ag.X + dx * t, ag.Z + dz * t
	ag.Y = ag.Y + (ty - ag.Y) * t
	return step
end

local function accelerate(ag, target, dt, p)
	if target > ag.Speed then
		ag.Speed = math.min(target, ag.Speed + p.Accel * dt)
	else
		ag.Speed = math.max(target, ag.Speed - p.Decel * dt)
	end
end

-- Would moving the agent to (nx, nz) bring it closer than `floor` to the actor, closer than it is now? (refused)
local function closesIn(ag, actor, nx, nz, floor)
	local before = hdist(ag.X, ag.Z, actor.X, actor.Z)
	local after = hdist(nx, nz, actor.X, actor.Z)
	return after < before - 1e-9 and after < floor
end

--------------------------------------------------------------------------------------------------- following

function Sim:stepFollow(ag, dt)
	local p = self.Params
	local actor = self.Actors[ag.Leader]
	local trail = self.Trails[ag.Leader]
	if not actor then
		ag.Mode = "idle"
		return
	end
	local d = hdist(ag.X, ag.Z, actor.X, actor.Z)
	local extra = (self:slotOf(ag) - 1) * p.SlotSpacing -- later followers of the same leader queue up behind the first
	local followD, stopD, resumeD = p.FollowDistance + extra, p.StopDistance + extra, p.ResumeDistance + extra
	local cap = Nav.speedCap(p, actor.Speed, d - extra, ag.MaxSpeed)
	ag.LastCap = cap
	ag.Waiting = false

	-- 1. the leader is inside the personal space: back away along the trail (never hold ground, never move toward)
	if d < p.YieldDistance and not ag.Attached then
		-- not on the trail yet: back straight away from the leader (if the ground allows)
		accelerate(ag, cap, dt, p)
		local ux, uz = (ag.X - actor.X) / math.max(d, 1e-6), (ag.Z - actor.Z) / math.max(d, 1e-6)
		if d < 1e-6 then
			ux, uz = 1, 0
		end
		local nx, nz = ag.X + ux * ag.Speed * dt, ag.Z + uz * ag.Speed * dt
		if not (self.Walkable and not self.Walkable(nx, ag.Y, nz)) then
			ag.X, ag.Z = nx, nz
		else
			ag.Speed = 0
		end
		ag.Holding = true
		return
	end
	if d < p.YieldDistance and ag.Attached then
		accelerate(ag, cap, dt, p)
		local back = ag.TrailS - ag.Speed * dt
		local nx, ny, nz
		local canBack = back >= trail:start()
		if canBack then
			nx, ny, nz = trail:at(back)
			nx, nz = nx + (ag.OX or 0), nz + (ag.OZ or 0)
			canBack = hdist(nx, nz, actor.X, actor.Z) >= d - 1e-9 and not (self.Walkable and not self.Walkable(nx, ny, nz))
		end
		if canBack then
			ag.TrailS, ag.X, ag.Y, ag.Z = back, nx, ny, nz
			if not ag.Yielding then
				ag.Yielding = true
				self:emit("Yield", ag, { Distance = d })
			end
		else
			-- no trail to back along (or it leads toward the leader): step away DIAGONALLY (away + sideways), if the ground allows
			local ux, uz = (ag.X - actor.X) / math.max(d, 1e-6), (ag.Z - actor.Z) / math.max(d, 1e-6)
			if d < 1e-6 then
				ux, uz = 1, 0
			end
			local moved = false
			for _, sign in ipairs({ 1, -1 }) do
				local dx, dz = ux + sign * -uz, uz + sign * ux
				local len = math.sqrt(dx * dx + dz * dz)
				local sx, sz = ag.X + dx / len * ag.Speed * dt, ag.Z + dz / len * ag.Speed * dt
				if hdist(sx, sz, actor.X, actor.Z) >= d - 1e-9 and not (self.Walkable and not self.Walkable(sx, ag.Y, sz)) then
					ag.X, ag.Z = sx, sz
					ag.Attached = false -- off the trail now; it re-attaches (or paths) once the leader has passed
					moved = true
					break
				end
			end
			if moved then
				ag.OX, ag.OZ = 0, 0
				if not ag.Sidestepping then
					ag.Sidestepping = true
					self:emit("Sidestep", ag, { Distance = d })
				end
			else
				ag.Speed = 0
				self:emit("Cornered", ag, { Distance = d })
			end
		end
		ag.Holding = true
		return
	end
	ag.Yielding, ag.Sidestepping = false, false

	-- 2. hysteresis: hold inside StopDistance, move again only beyond ResumeDistance
	if d <= stopD then
		ag.Holding = true
	elseif d >= resumeD then
		ag.Holding = false
	end
	if ag.Holding then
		accelerate(ag, 0, dt, p)
		return
	end

	-- 3. not on the trail yet (or the trail broke): walk a path to the point FollowDistance behind the leader
	local sTarget = math.max(trail:start(), trail.SHead - followD)
	if not ag.Attached then
		local dist, s = trail:nearest(ag.X, ag.Z)
		if dist <= p.JoinRadius then
			local tx, _, tz = trail:at(s)
			ag.Attached, ag.TrailS, ag.Path = true, s, nil
			ag.OX, ag.OZ = ag.X - tx, ag.Z - tz -- the sideways gap to the trail; decays smoothly (no teleport onto the trail)
		else
			local tx, ty, tz = trail:at(sTarget)
			if ag.Path == nil or hdist(ag.Path[#ag.Path][1], ag.Path[#ag.Path][3], tx, tz) > 4 then
				self:requestPath(ag, tx, ty, tz)
			end
			self:stepPath(ag, dt, cap, actor, stopD)
			if ag.Path and not ag.Path[ag.PathIndex] then
				ag.Path = nil
			end
			return
		end
	end

	-- 4. on the trail: retrace the leader's own route (no corner cutting), speed set by the gap along the trail
	local gap = trail.SHead - ag.TrailS
	local want = math.min(cap, math.max(0, (gap - followD) * 3))
	accelerate(ag, want, dt, p)
	-- the movement this tick is split between advancing along the trail and closing the sideways gap; together they never
	-- exceed the speed budget (triangle inequality), so blending onto the trail never makes the agent faster than its cap
	local budget = ag.Speed * dt
	local ox, oz = ag.OX or 0, ag.OZ or 0
	local om = math.sqrt(ox * ox + oz * oz)
	local offStep = math.min(om, p.OffsetRate * dt, budget * 0.5)
	local advance = math.min(budget - offStep, math.max(0, trail.SHead - followD - ag.TrailS))
	if advance <= 1e-9 and offStep <= 1e-9 then
		ag.Holding = true -- it has reached its place: hold until the leader is ResumeDistance away
		return
	end
	local nox, noz = ox, oz
	if om > 0 then
		local k = (om - offStep) / om
		nox, noz = ox * k, oz * k
	end
	local nx, ny, nz = trail:at(ag.TrailS + advance)
	nx, nz = nx + nox, nz + noz
	if closesIn(ag, actor, nx, nz, stopD) then
		ag.Speed = 0
		return
	end
	if blockedBetween(self, ag, nx, ny, nz) then
		ag.Speed, ag.Waiting = 0, true
		if not ag.WaitedEmitted then
			ag.WaitedEmitted = true
			self:emit("Waiting", ag, {})
		end
		return
	end
	ag.WaitedEmitted = false
	ag.TrailS = ag.TrailS + advance
	ag.X, ag.Y, ag.Z = nx, ny, nz
	ag.OX, ag.OZ = nox, noz
	if trail.SHead - followD - ag.TrailS <= 0.02 then
		ag.Holding = true
	end
end

--------------------------------------------------------------------------------------------------- following a path (goto, and approaching a trail)

function Sim:stepPath(ag, dt, cap, actor, stopD)
	local p = self.Params
	local path = ag.Path
	if not path then
		accelerate(ag, 0, dt, p)
		return
	end
	accelerate(ag, cap, dt, p)
	local budget = ag.Speed * dt
	while budget > 1e-9 and path[ag.PathIndex] do
		local wp = path[ag.PathIndex]
		if hdist(ag.X, ag.Z, wp[1], wp[3]) <= 1e-6 then
			ag.PathIndex += 1
		else
			local d = hdist(ag.X, ag.Z, wp[1], wp[3])
			local step = math.min(budget, d)
			local t = step / d
			local nx, nz = ag.X + (wp[1] - ag.X) * t, ag.Z + (wp[3] - ag.Z) * t
			local ny = ag.Y + (wp[2] - ag.Y) * t
			if actor and closesIn(ag, actor, nx, nz, stopD or p.StopDistance) then
				ag.Speed = 0
				return
			end
			if blockedBetween(self, ag, nx, ny, nz) then
				ag.Speed, ag.Waiting = 0, true
				if not ag.WaitedEmitted then
					ag.WaitedEmitted = true
					self:emit("Waiting", ag, {})
				end
				return
			end
			ag.WaitedEmitted = false
			ag.X, ag.Y, ag.Z = nx, ny, nz
			budget -= step
		end
	end
end

function Sim:stepGoto(ag, dt)
	local p = self.Params
	local g = ag.Goal
	if not g then
		ag.Mode = "idle"
		return
	end
	ag.Waiting = false
	local function arrive()
		ag.Mode, ag.Path, ag.Goal, ag.Final, ag.Speed = "idle", nil, nil, false, 0
		self:emit("Arrived", ag, { X = g[1], Z = g[3] })
	end
	if hdist(ag.X, ag.Z, g[1], g[3]) <= p.ArriveTolerance then
		arrive()
		return
	end
	if not ag.Final then
		if ag.Path == nil then
			local status = self:requestPath(ag, g[1], g[2], g[3])
			if status == "failed" then
				ag.Mode, ag.Goal, ag.Speed = "idle", nil, 0
			end
			if ag.Path == nil then
				return
			end
		end
		self:stepPath(ag, dt, ag.MaxSpeed, nil)
		if ag.Path and not ag.Path[ag.PathIndex] then
			-- the path ends at the nearest graph node, not at the goal itself: finish with a direct approach (no re-pathing)
			ag.Final, ag.Path = true, nil
		end
		return
	end
	accelerate(ag, ag.MaxSpeed, dt, p)
	local gx, gy, gz = g[1], g[2], g[3]
	if blockedBetween(self, ag, gx, gy, gz) then
		ag.Speed, ag.Waiting = 0, true
		return
	end
	moveToward(ag, gx, gy, gz, ag.Speed * dt)
	if hdist(ag.X, ag.Z, g[1], g[3]) <= p.ArriveTolerance then
		arrive()
	end
end

--------------------------------------------------------------------------------------------------- separation and stuck handling

function Sim:separate(dt)
	-- Only followers keep apart (a queue of hostages must not stack). Patrolling bots pass through each other and must never
	-- shove a guard standing at a static post.
	local sep = self.Params.Separation
	local movers = {}
	for _, ag in ipairs(self.Order) do
		if ag.Mode == "follow" then
			movers[#movers + 1] = ag
		end
	end
	for i, a in ipairs(movers) do
		for j = i + 1, #movers do
			local b = movers[j]
			local dx, dz = a.X - b.X, a.Z - b.Z
			local d = math.sqrt(dx * dx + dz * dz)
			if d < sep and d > 1e-6 then
				-- push the pair apart symmetrically, only along the line between them (no tangential swirl)
				local push = (sep - d) * 0.5
				local ux, uz = dx / d, dz / d
				if not (self.Walkable and (not self.Walkable(a.X + ux * push, a.Y, a.Z + uz * push) or not self.Walkable(b.X - ux * push, b.Y, b.Z - uz * push))) then
					a.X, a.Z = a.X + ux * push, a.Z + uz * push
					b.X, b.Z = b.X - ux * push, b.Z - uz * push
				end
			end
		end
	end
end

function Sim:checkStuck(ag, dt, wantsToMove)
	local p = self.Params
	if not wantsToMove or ag.Waiting then
		ag.StuckTimer, ag.StuckX, ag.StuckZ = 0, ag.X, ag.Z
		return
	end
	ag.StuckTimer += dt
	if ag.StuckTimer < p.StuckSeconds then
		return
	end
	local moved = hdist(ag.X, ag.Z, ag.StuckX, ag.StuckZ)
	ag.StuckTimer, ag.StuckX, ag.StuckZ = 0, ag.X, ag.Z
	if moved >= 0.5 then
		ag.StuckStrikes = 0
		return
	end
	ag.StuckStrikes += 1
	self:emit("Stuck", ag, { Strikes = ag.StuckStrikes })
	ag.Attached, ag.Path = false, nil -- first remedy: start again (a fresh path / re-attach)
	if ag.StuckStrikes >= 2 and ag.Mode == "follow" then
		local trail = self.Trails[ag.Leader]
		local actor = self.Actors[ag.Leader]
		local s = math.max(trail:start(), trail.SHead - p.FollowDistance * 1.5)
		local nx, ny, nz = trail:at(s)
		if hdist(nx, nz, actor.X, actor.Z) >= p.StopDistance and (not self.CanSnap or self.CanSnap(ag, nx, ny, nz)) then
			ag.X, ag.Y, ag.Z, ag.TrailS, ag.Attached, ag.Speed, ag.StuckStrikes, ag.OX, ag.OZ = nx, ny, nz, s, true, 0, 0, 0, 0
			self:emit("Snapped", ag, { X = nx, Z = nz })
		end
	end
end

--------------------------------------------------------------------------------------------------- step

-- The unit direction an agent last moved in (x, z); nil until it has moved. Used for facing.
function Sim:heading(id)
	local ag = self.Agents[id]
	if ag and ag.HX then
		return ag.HX, ag.HZ
	end
	return nil
end

function Sim:step(dt)
	local before = {}
	for _, ag in ipairs(self.Order) do
		before[ag] = { ag.X, ag.Z }
	end
	self:stepInner(dt)
	for _, ag in ipairs(self.Order) do
		local b = before[ag]
		local dx, dz = ag.X - b[1], ag.Z - b[2]
		local d = math.sqrt(dx * dx + dz * dz)
		if d > 0.02 then
			ag.HX, ag.HZ = dx / d, dz / d
		end
	end
end

function Sim:stepInner(dt)
	local sm = self.Params.LeaderSpeedSmoothing
	for _, a in pairs(self.Actors) do
		local inst = a.StepX and hdist(a.X, a.Z, a.StepX, a.StepZ) / dt or 0
		if inst * dt > self.Params.TeleportDistance then
			inst = 0 -- a teleport is not a speed
		end
		a.Speed = a.Speed * sm + inst * (1 - sm)
		a.StepX, a.StepZ = a.X, a.Z
	end
	for _, ag in ipairs(self.Order) do
		if ag.Mode == "follow" then
			self:stepFollow(ag, dt)
			local actor = self.Actors[ag.Leader]
			local resumeD = self.Params.ResumeDistance + (self:slotOf(ag) - 1) * self.Params.SlotSpacing
			self:checkStuck(ag, dt, actor ~= nil and not ag.Holding and hdist(ag.X, ag.Z, actor.X, actor.Z) > resumeD)
		elseif ag.Mode == "goto" then
			self:stepGoto(ag, dt)
			self:checkStuck(ag, dt, ag.Mode == "goto")
		else
			accelerate(ag, 0, dt, self.Params)
		end
	end
	self:separate(dt)
	self.Time += dt
end

--------------------------------------------------------------------------------------------------- adapter for BreachWorld

-- A pathfinder (and a walkable test) for a BreachWorld: A* over its navigation graph.
function Nav.worldAdapter(world)
	local function pathfinder(from, to)
		local r = world:findPath(from, to)
		return r and r.points or nil
	end
	return pathfinder
end

return Nav
