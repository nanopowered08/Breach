--!nonstrict
-- Tests for BreachRoblox.Core (adapter v0.1). Everything here runs against fakes, so it needs no map data and no Roblox.
-- The last block builds a real session from the local mission data when it is present (tests/_embedded*.luau stay out of git).
local Core = require("../BreachRoblox/Core")

return function(check)
	-------------------------------------------------------------------------------- the seed
	do
		local function rnd() return 777 end
		local s, src = Core.resolveSeed(1234, 5, rnd)
		check("seed: the BreachSeed attribute wins", s == 1234 and src == "BreachSeed")
		s, src = Core.resolveSeed("99", 5, rnd)
		check("seed: a numeric string works in the attribute", s == 99 and src == "BreachSeed")
		s, src = Core.resolveSeed(nil, 5, rnd)
		check("seed: no attribute: the Seed option", s == 5 and src == "Seed option")
		s, src = Core.resolveSeed(nil, nil, rnd)
		check("seed: neither: a fresh random one", s == 777 and src == "random")
		s, src = Core.resolveSeed(0, nil, rnd)
		check("seed: zero is a valid seed", s == 0 and src == "BreachSeed")
		local ign
		s, src, ign = Core.resolveSeed("abc", 7, rnd)
		check("seed: a bad attribute is ignored (and reported), the option is used", s == 7 and src == "Seed option" and ign == "abc")
		s, src, ign = Core.resolveSeed(-3, nil, rnd)
		check("seed: a negative attribute is ignored", s == 777 and src == "random" and ign == -3)
		s = Core.resolveSeed(1.5, nil, rnd)
		check("seed: a fraction is ignored", s == 777)
		s = Core.resolveSeed(4294967296, nil, rnd)
		check("seed: 2^32 is out of range", s == 777)
		s = Core.resolveSeed(0/0, nil, rnd)
		check("seed: NaN is ignored", s == 777)
	end

	-------------------------------------------------------------------------------- fakes
	local function fakeSession(bots)
		local S = { bots = bots or {}, pos = {}, vars = { Mission_AlertLevel = 0 }, log = {}, steps = {}, calls = {}, players = {} }
		S.Bots = {
			alive = function() return S.bots end,
			position = function(_, id) local p = S.pos[id] if p then return p[1], p[2], p[3] end end,
			facing = function() return 0, 1 end,
		}
		S.Logic = { get = function(_, name) return S.vars[name] end }
		S.Props = {
			player = function(_, id) return S.players[id] end,
			setStance = function(_, id, stance) S.calls[#S.calls + 1] = "stance " .. id .. " " .. stance return true end,
		}
		function S:step(dt) self.steps[#self.steps + 1] = dt end
		function S:drainLog() local l = self.log self.log = {} return l end
		function S:addPlayer(id, x, y, z) self.players[id] = { X = x, Y = y, Z = z } self.calls[#self.calls + 1] = "add " .. id end
		function S:movePlayer(id, x, y, z) self.players[id].X = x self.calls[#self.calls + 1] = "move " .. id end
		function S:setDisguise(id, d) self.calls[#self.calls + 1] = "disguise " .. id .. " " .. tostring(d) end
		return S
	end
	local function recorder()
		local H = { created = {}, updates = {}, removed = {}, alerts = {}, events = {} }
		function H:createBot(info) self.created[#self.created + 1] = info end
		function H:updateBot(id, x, y, z, fx, fz, state) self.updates[#self.updates + 1] = { id, x, y, z, fx, fz, state } end
		function H:removeBot(id) self.removed[#self.removed + 1] = id end
		function H:alertChanged(level, before) self.alerts[#self.alerts + 1] = { level, before } end
		function H:event(ev) self.events[#self.events + 1] = ev end
		return H
	end
	local function bot(id, name, state) return { Id = id, Name = name or ("Bot" .. id), Class = "Sec", Outfit = "O", Weapon = "W", Profile = "P", State = state or "Idle" } end

	-------------------------------------------------------------------------------- bots appear, move, disappear
	do
		local S = fakeSession({ bot(1), bot(2) })
		S.pos[1] = { 1, 2, 3 }
		S.pos[2] = { 4, 5, 6 }
		local H = recorder()
		local A = Core.new(S, H)
		A:step(0.05)
		check("bots: a rig is created once per new bot", #H.created == 2 and H.created[1].Id == 1 and H.created[2].Name == "Bot2")
		check("bots: the create info carries class, weapon and position", H.created[1].Class == "Sec" and H.created[1].Weapon == "W" and H.created[1].X == 1 and H.created[1].Z == 3)
		check("bots: every bot is updated every step with position, facing and state", #H.updates == 2 and H.updates[1][2] == 1 and H.updates[1][6] == 1 and H.updates[2][7] == "Idle")
		A:step(0.05)
		check("bots: no second create on the next step", #H.created == 2 and #H.updates == 4)
		S.pos[1] = { 9, 9, 9 }
		S.bots[2].State = "Walking"
		A:step(0.05)
		check("bots: new position and state are passed on", H.updates[5][2] == 9 and H.updates[6][7] == "Walking")
		S.bots = { S.bots[2] }
		A:step(0.05)
		check("bots: a bot that is gone is removed once", #H.removed == 1 and H.removed[1] == 1)
		A:step(0.05)
		check("bots: and not again", #H.removed == 1)
		S.bots = { S.bots[1], bot(1) }
		A:step(0.05)
		check("bots: a bot id that comes back is created again", #H.created == 3 and H.created[3].Id == 1)
		local noPos = fakeSession({ bot(7) })
		local H2 = recorder()
		Core.new(noPos, H2):step(0.05)
		check("bots: a bot without a position is skipped, not a crash", #H2.created == 0 and #H2.updates == 0)
		check("bots: stats count the shown bots", A:stats().Bots == 2, A:stats().Bots)
	end

	-------------------------------------------------------------------------------- time
	do
		local S = fakeSession()
		local A = Core.new(S, recorder(), { maxDt = 0.1 })
		A:step(5)
		A:step(0.02)
		A:step(-1)
		A:step(nil)
		check("step: a long frame is cut to maxDt", S.steps[1] == 0.1)
		check("step: a normal frame is passed through", S.steps[2] == 0.02)
		check("step: a negative or missing dt becomes 0", S.steps[3] == 0 and S.steps[4] == 0)
		check("step: time and frames add up", math.abs(A:stats().Time - 0.12) < 1e-9 and A:stats().Frames == 4)
		local S2 = fakeSession()
		Core.new(S2, recorder()):step(1)
		check("step: the default cut is 0.1 s", S2.steps[1] == 0.1)
	end

	-------------------------------------------------------------------------------- events and alert
	do
		local S = fakeSession()
		local H = recorder()
		local A = Core.new(S, H)
		S.log = { { Kind = "A" }, { Kind = "B" } }
		A:step(0.05)
		check("events: every logged event reaches the host in order", #H.events == 2 and H.events[1].Kind == "A" and H.events[2].Kind == "B")
		A:step(0.05)
		check("events: the log is drained, so nothing repeats", #H.events == 2 and A:stats().Events == 2)
		check("alert: the first reading is reported (from nil)", #H.alerts == 1 and H.alerts[1][1] == 0 and H.alerts[1][2] == nil)
		A:step(0.05)
		check("alert: no change, no call", #H.alerts == 1)
		S.vars.Mission_AlertLevel = 2
		A:step(0.05)
		check("alert: a change reports new and old level", #H.alerts == 2 and H.alerts[2][1] == 2 and H.alerts[2][2] == 0)
		S.vars.Mission_AlertLevel = "oops"
		A:step(0.05)
		check("alert: a non-number is ignored", #H.alerts == 2)
		local bare = Core.new(fakeSession({ bot(1) }), {})
		bare.Session.pos[1] = { 0, 0, 0 }
		bare.Session.log = { { Kind = "X" } }
		local ok, err = pcall(bare.step, bare, 0.05)
		check("host: a host with no methods is fine", ok, err)
	end

	-------------------------------------------------------------------------------- players
	do
		local S = fakeSession()
		local A = Core.new(S, recorder())
		A:syncPlayers({ { Id = "a", X = 1, Y = 2, Z = 3, Stance = "stand" } })
		check("players: a new player is added and given a stance", S.calls[1] == "add a" and S.calls[2] == "stance a stand")
		A:syncPlayers({ { Id = "a", X = 5, Y = 2, Z = 3, Stance = "crouch" }, { Id = "b", X = 0, Y = 0, Z = 0 } })
		check("players: a known player moves, a second one joins", S.calls[3] == "move a" and S.calls[4] == "stance a crouch" and S.calls[5] == "add b")
		check("players: no stance given means no stance call", S.calls[6] == nil)
		A:syncPlayers({ { Id = "b", X = 1, Y = 0, Z = 0, Disguise = "Guard" } })
		check("players: a disguise is passed on", S.calls[#S.calls] == "disguise b Guard")
		check("players: a player who left is marked exited", S.players.a.Exited == true and S.players.b.Exited == nil)
		check("players: stats count only the present players", A:stats().Players == 1)
		A:syncPlayers({ { Id = "a", X = 0, Y = 0, Z = 0 } })
		check("players: someone who rejoins is added again", S.calls[#S.calls - 1] == "add a" or S.calls[#S.calls] == "add a")
		check("players: an empty or nil list is fine", pcall(A.syncPlayers, A, nil) and pcall(A.syncPlayers, A, {}))
	end

	-------------------------------------------------------------------------------- loadMission with stubbed modules
	do
		local made = {}
		local M = {
			Codec = { decode = function(code, host) made.code = code made.host = host return { SetupSource = "S", MapId = 42 } end },
			Zstd = { decompress = function() end },
			Mission = { build = function(d, o) made.validator = o.validator return { name = "mission" } end },
			Validator = {},
			Setup = { parse = function(src) made.setupSrc = src return { setup = true } end },
			World = { build = function(m) return { world = true, mission = m } end },
			Session = { new = function(mods, mis, world, setup, opts) made.opts = opts return { session = true, mods = mods } end },
		}
		local session, info = Core.loadMission(M, "CODE", { seed = 7, difficulty = 2 })
		check("load: the stages run in order and hand over their results", session and session.session and info.MapId == 42 and info.Mission.name == "mission" and made.setupSrc == "S")
		check("load: the zstd function and validator are passed to the codec and the builder", made.host.zstdDecompress == M.Zstd.decompress and made.validator == M.Validator)
		check("load: seed and difficulty reach the session", made.opts.seed == 7 and made.opts.difficulty == 2)
		local s2 = Core.loadMission(M, "CODE")
		check("load: defaults for seed and difficulty", s2 and made.opts.seed == 416 and made.opts.difficulty == 3)

		local nilS, e1 = Core.loadMission(M, "")
		check("load: an empty code is a decode error", nilS == nil and e1:find("^decode:") ~= nil, e1)
		local _, e2 = Core.loadMission(M, 5)
		check("load: a non-string code is a decode error", e2 and e2:find("^decode:") ~= nil)
		local bad = setmetatable({ Codec = { decode = function() error("bad checksum") end } }, { __index = M })
		local _, e3 = Core.loadMission(bad, "X")
		check("load: a decode failure names the stage and the reason", e3 and e3:find("decode: ") and e3:find("bad checksum"), e3)
		local badBuild = setmetatable({ Mission = { build = function() return nil, "no root" end } }, { __index = M })
		local _, e4 = Core.loadMission(badBuild, "X")
		check("load: a build that returns nothing reports the stage and its message", e4 and e4 == "build: no root", e4)
		local badSetup = setmetatable({ Setup = { parse = function() return nil, "line 6" end } }, { __index = M })
		local _, e5 = Core.loadMission(badSetup, "X")
		check("load: a setup error", e5 == "setup: line 6", e5)
		local badSession = setmetatable({ Session = { new = function() return nil, "no nodes" end } }, { __index = M })
		local _, e6 = Core.loadMission(badSession, "X")
		check("load: a session error", e6 == "session: no nodes", e6)
	end

	-------------------------------------------------------------------------------- props and doors
	do
		local function propPart(name, x, y, z, ey, sx, sy, sz, attrs, children)
			return { ClassName = "Part", Name = name, Path = "M/Props/" .. name, Attrs = attrs or {}, Children = children or {},
				Props = { CFrame = { Position = { X = x, Y = y, Z = z }, EulerXYZ = { X = 0, Y = ey, Z = 0 } }, Size = { X = sx, Y = sy, Z = sz } } }
		end
		local folder = { Name = "Props", ClassName = "Folder", Children = {
			propPart("SlidingBlastDoor", 1, 2, 3, 1.57, 10.4, 7.4, 0.9),
			propPart("DoorMetal", 10, 0, 0, 3.14, 10, 7, 0.6, { DoubleDoor = true }),
			propPart("DoorWood", 20, 0, 0, 0, 5, 7, 1, { DoubleDoor = false }),
			propPart("ItemSpawn", 0, 0, 0, 0, 1, 1, 1),
			propPart("ItemSpawn", 5, 0, 0, 0, 1, 1, 1),
			{ ClassName = "Folder", Name = "Group", Children = {
				propPart("Table", 30, 0, 0, 0, 4, 3, 2, nil, { propPart("Chair", 31, 0, 0, 0, 1, 1, 1) }),
			} },
			{ ClassName = "Model", Name = "Table", Children = {}, Props = {} },
			{ ClassName = "Part", Name = "NoCFrame", Children = {}, Props = { Size = { X = 1, Y = 1, Z = 1 } } },
		} }
		local mission = { folder = function(_, name) if name == "Props" then return folder end end }
		local lib = { SlidingBlastDoor = true, DoorMetal = true, DoorWood = true, Table = true, Chair = true }
		local placements, skipped, total = Core.propPlacements(mission, function(n) return lib[n] == true end)
		check("props: placeholders in the library are placed, others are counted", #placements == 5 and skipped.ItemSpawn == 2 and total == 7, #placements .. "/" .. tostring(total))
		check("props: nested folders and parts inside parts are found, in order", placements[4].Name == "Table" and placements[5].Name == "Chair")
		check("props: position, euler angles and size carry over", placements[1].X == 1 and placements[1].Y == 2 and placements[1].Z == 3 and placements[1].Ry == 1.57 and placements[1].SizeX == 10.4 and placements[1].SizeZ == 0.9)
		check("props: a DoubleDoor is two leaves, everything else one", placements[2].Leaves == 2 and placements[1].Leaves == 1 and placements[3].Leaves == 1)
		check("props: a Model or a part without a CFrame is not a placeholder", total == 7)
		local none, sk, tot = Core.propPlacements({ folder = function() return nil end }, function() return true end)
		check("props: no Props folder gives nothing", #none == 0 and next(sk) == nil and tot == 0)
		local n2 = Core.propPlacements(nil, function() return true end)
		check("props: no mission gives nothing", #n2 == 0)
		local noLib = Core.propPlacements(mission, function() return false end)
		check("props: an empty library places nothing", #noLib == 0)
	end

	-------------------------------------------------------------------------------- a real session (only when local mission data is present)
	local okE, emb = pcall(require, "../../breach-codec/tests/_embedded")
	if not okE then
		print("(adapter real-session test skipped: breach-codec/tests/_embedded.luau not found)")
		return
	end
	local function req(name) return require("../../breach-codec/" .. name) end
	local M = {
		Codec = req("BreachCodec"), Zstd = req("BreachZstd"), Mission = req("BreachMission"), Validator = req("BreachValidator"), World = req("BreachWorld"),
		Setup = req("BreachSetup"), Session = req("BreachSession"), Logic = req("BreachLogic"), Nav = req("BreachNav"), Bots = req("BreachBots"),
		Props = req("BreachProps"), Sight = req("BreachSight"), Trespass = req("BreachTrespass"), Alert = req("BreachAlert"), Hostage = req("BreachHostage"),
		Behavior = req("BreachBehavior"),
	}
	for _, name in ipairs({ "TheDiplomat.base64", "thepeacemaker.txt" }) do
		local code = emb[name]
		local session, info = Core.loadMission(M, code, { seed = 416 })
		check(name .. ": the real mission loads through the adapter", session ~= nil, info)
		if session then
			local H = recorder()
			local A = Core.new(session, H)
			A:syncPlayers({ { Id = "p1", X = 0, Y = 5, Z = 0, Stance = "stand" } })
			for _ = 1, 600 do A:step(0.1) end
			local s = A:stats()
			check(name .. ": the adapter ran 60 s of mission time", math.abs(s.Time - 60) < 1e-6 and s.Frames == 600)
			check(name .. ": every bot got a rig and each one is moved", #H.created > 0 and #H.updates >= #H.created, #H.created)
			local numeric = true
			for i = 1, math.min(50, #H.updates) do
				local u = H.updates[i]
				if type(u[2]) ~= "number" or u[2] ~= u[2] then numeric = false end
			end
			check(name .. ": positions are real numbers", numeric)
			check(name .. ": the alert level was read", type(s.Alert) == "number")
		end
	end
end
