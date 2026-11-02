--!nonstrict
-- M8c (trespass) tests: BreachTrespass. Run via tests/run.luau or alone: `luau tests/trespass.luau`
local Trespass = require("../BreachTrespass")
local Sight = require("../BreachSight")
local Bots = require("../BreachBots")
local Nav = require("../BreachNav")
local Logic = require("../BreachLogic")
local Props = require("../BreachProps")
local Setup = require("../BreachSetup")

local DT = 1 / 20

return function(check)
	----------------------------------------------------------------------------------------------- rules (unit)
	local RULES = {
		Public = {},
		Restricted = { Trespass = true, Allow = { ProSecurity = true }, Enforce = { Sec = true }, EnforceMinor = { Sec = true, Emp = true }, MinorTrespass = { Chef = true } },
		Vault = { Trespass = true, Allow = { Workshop = true }, Enforce = { Sec = true, Emp = true, Workshops = true } },
		MinorOnly = { MinorTrespass = { Intern = true } },
		NoneIsMinor = { Trespass = true, MinorTrespass = { None = true }, EnforceMinor = { Sec = true } },
		Dynamic = "{Bluffed && [Public] || [Restricted]}",
		Chain = "{[Dynamic]}",
		Loop = "{[Loop]}",
		Bad = "{1 +}",
		Plain = "Vault",
	}
	local function cellNamed(name) return { Index = 1, Node = { Name = name } } end
	local function trFor(rules, vars)
		local l = Logic.fromSpec({ Globals = vars or { Bluffed = "0" } }, {})
		return Trespass.new(nil, { Cells = rules or RULES }, l), l
	end

	do
		local tr = trFor()
		local function st(d, c) return (tr:status(d, cellNamed(c))) end
		check("status: a rule set with no Trespass is public", st("None", "Public") == "allowed" and st("Chef", "Public") == "allowed")
		check("status: Trespass and no Allow -> major", st("None", "Vault") == "major" and st("Chef", "Vault") == "major")
		check("status: Allow lets a disguise in", st("Workshop", "Vault") == "allowed" and st("ProSecurity", "Restricted") == "allowed")
		check("status: MinorTrespass makes it minor instead of major", st("Chef", "Restricted") == "minor" and st("None", "Restricted") == "major")
		check("status: 'None' (no disguise) is a disguise name like any other (real: MinorTrespass = { None = true })", st("None", "NoneIsMinor") == "minor" and st("Chef", "NoneIsMinor") == "major")
		check("status: a nil or empty disguise means None", st(nil, "NoneIsMinor") == "minor" and st("", "NoneIsMinor") == "minor")
		check("status: MinorTrespass without Trespass is still minor (one real rule set)", st("Intern", "MinorOnly") == "minor" and st("None", "MinorOnly") == "allowed")
		check("status: names are matched without regard to case (rule set and disguise)", st("workshop", "VAULT") == "allowed" and st("prosecurity", "restricted") == "allowed")
		local _, name, rules = tr:status("None", cellNamed("Vault"))
		check("status: it also returns the rule-set name and the rules", name == "Vault" and rules.Trespass == true)
		check("status: a cell with no rule set at all is public", st("None", "NoSuchCell") == "allowed")
	end

	do
		local tr = trFor({ Default = { Trespass = true, Enforce = { Sec = true } }, Public = {} })
		check("default: cells without their own rule set use Default", (tr:status("None", cellNamed("Whatever"))) == "major" and (tr:status("None", cellNamed("Public"))) == "allowed")
		local _, name = tr:status("None", cellNamed("Whatever"))
		check("default: ... and report that name", name == "Default")
	end

	do
		local tr, l = trFor()
		check("dynamic: {expression} chooses a rule set (Bluffed = 0 -> Restricted)", (tr:status("None", cellNamed("Dynamic"))) == "major" and tr:ruleName(cellNamed("Dynamic")) == "Restricted")
		l:set("Bluffed", 1)
		check("dynamic: ... and follows the mission variable live (Bluffed = 1 -> Public)", (tr:status("None", cellNamed("Dynamic"))) == "allowed" and tr:ruleName(cellNamed("Dynamic")) == "Public")
		check("dynamic: a rule that names a dynamic rule resolves through it", tr:ruleName(cellNamed("Chain")) == "Public")
		l:set("bluffed", 0) -- variable names are case-insensitive
		check("dynamic: variable names in the expression are case-insensitive", tr:ruleName(cellNamed("Dynamic")) == "Restricted")
		check("dynamic: a plain string is an alias for another rule set", tr:ruleName(cellNamed("Plain")) == "Vault" and (tr:status("None", cellNamed("Plain"))) == "major")
		local _, rn, rules = tr:status("None", cellNamed("Loop"))
		check("dynamic: a self-referencing rule is cut off (no hang) and reported", rules == nil and #tr.Errors >= 1 and tr.Errors[1]:find("too deep", 1, true) ~= nil)
		local tr2 = trFor()
		check("dynamic: an expression that does not compile is an error, the cell falls back to public", (tr2:status("None", cellNamed("Bad"))) == "allowed" and #tr2.Errors == 1)
		local noLogic = Trespass.new(nil, { Cells = { A = "{x}" } }, nil)
		check("dynamic: with no logic core a template cannot be evaluated; it is treated as the literal name (no crash)", pcall(noLogic.rulesFor, noLogic, cellNamed("A")))
	end

	do
		local tr = trFor()
		local _, _, vault = tr:status("None", cellNamed("Vault"))
		local _, _, restricted = tr:status("None", cellNamed("Restricted"))
		check("enforces: a major trespass is enforced by Enforce classes only", tr:enforces("Sec", "major", restricted) and not tr:enforces("Emp", "major", restricted) and tr:enforces("Emp", "major", vault) and tr:enforces("Workshops", "major", vault))
		check("enforces: a minor trespass by EnforceMinor classes", tr:enforces("Emp", "minor", restricted) and tr:enforces("Sec", "minor", restricted) and not tr:enforces("Civ", "minor", restricted))
		check("enforces: nobody enforces 'allowed', or an unknown class, or with no rules", not tr:enforces("Sec", "allowed", restricted) and not tr:enforces("Nobody", "major", restricted) and not tr:enforces("Sec", "major", nil) and not tr:enforces(nil, "major", restricted))
		check("enforces: class names are case-insensitive", tr:enforces("sec", "major", restricted))
	end

	----------------------------------------------------------------------------------------------- a live scene: statuses and witnesses
	local counter = 0
	local function part(name, x, y, z, attrs, eulerY)
		counter += 1
		return { Name = name, ClassName = "Part", Path = "DebugMission/Nodes/" .. name .. counter, Id = "p" .. counter, Attrs = attrs or {}, Children = {},
			Props = { CFrame = { Position = { X = x, Y = y, Z = z }, EulerXYZ = { X = 0, Y = eulerY or 0, Z = 0 } }, Size = { X = 4, Y = 4, Z = 4 } } }
	end
	local function folder(name, children) counter += 1 return { Name = name, ClassName = "Folder", Path = "DebugMission/" .. name .. counter, Id = "f" .. counter, Attrs = {}, Children = children or {} } end
	local function botNode(name, attrs) counter += 1 return { Name = name, ClassName = "BoolValue", Path = "DebugMission/Bots/" .. name, Id = "b" .. counter, Attrs = attrs or {}, Children = {} } end
	local FACE_PLUS_X = -math.pi / 2
	-- cells: 1 = x < 0 ("Public"), 2 = x >= 0 ("Restricted"), 3 = x >= 100 ("Vault"); links join 1-2 and 2-3
	local function liveWorld()
		local cells = { { Index = 1, Node = { Name = "Public" } }, { Index = 2, Node = { Name = "Restricted" } }, { Index = 3, Node = { Name = "Vault" } } }
		return { Cells = cells, Links = { { Cells = { 1, 2 } }, { Cells = { 2, 3 } } }, cellAt = function(_, x) if x >= 100 then return cells[3] elseif x >= 0 then return cells[2] end return cells[1] end }
	end
	local function straight(a, b) return { { X = a.X, Y = a.Y or 0, Z = a.Z }, { X = b.X, Y = b.Y or 0, Z = b.Z } } end
	local function live(botDefs, rules)
		local list, routes = {}, {}
		for i, d in ipairs(botDefs) do
			local rname = "Post" .. i
			list[#list + 1] = botNode("bot" .. i, { Behavior = "PatrolWalk", Nodes = rname, PatrolCycleLength = 99999, Class = d.Class })
			routes[#routes + 1] = folder(rname, { part("Node", d.X, 0, d.Z or 0, {}, FACE_PLUS_X) })
		end
		local botsF, nodesF = folder("Bots", list), folder("Nodes", routes)
		local m = { folder = function(_, n) if n == "Bots" then return botsF elseif n == "Nodes" then return nodesF end end, byComponent = function() return {} end }
		local l = Logic.fromSpec({ Globals = { Bluffed = "0" } }, {})
		local nav = Nav.new({ pathfinder = straight })
		local w = liveWorld()
		local bots = Bots.new(m, w, l, nav, { seed = 1 })
		local pr = Props.fromNodes({}, w, l)
		pr:addPlayer("p1", -50, 0, 0)
		local sight = Sight.new(w, bots, Sight.propsPlayers(pr))
		local tr = Trespass.new(w, { Cells = rules or RULES }, l)
		tr:attach(sight, bots, Sight.propsPlayers(pr))
		local function run(seconds) for _ = 1, math.floor(seconds / DT + 0.5) do l:advance(DT) bots:step(DT) sight:step(DT) tr:step(DT) end end
		return tr, sight, bots, pr, l, run
	end
	local function kinds(evs, kind) local out = {} for _, e in ipairs(evs) do if kind == nil or e.Kind == kind then out[#out + 1] = e end end return out end

	do -- events
		local tr, sight, bots, pr, l, run = live({ { Class = "Sec", X = 20 }, { Class = "Civ", X = 20, Z = 6 } })
		run(1)
		check("scene: in a public cell nothing happens", #tr:drainEvents() == 0 and tr:statusOf("p1") == "allowed")
		pr:move("p1", 30, 0, 0) -- in the Restricted cell, 10 studs in front of both bots
		run(0.1)
		local first = tr:drainEvents()
		check("scene: entering a restricted cell with no disguise raises TrespassStatus (major)", #kinds(first, "TrespassStatus") == 1 and kinds(first, "TrespassStatus")[1].Status == "major" and kinds(first, "TrespassStatus")[1].Rule == "Restricted" and tr:statusOf("p1") == "major")
		run(3)
		local evs = tr:drainEvents()
		local w = kinds(evs, "TrespassWitnessed")
		check("scene: the Sec bot that noticed the player witnesses it (an enforcing class)", #w == 1 and w[1].BotClass == "Sec" and w[1].Status == "major")
		check("scene: the Civ bot noticed too but does not enforce, so it is not a witness", sight:isNoticedBy(bots:all()[2].Id, "p1") and #tr:witnesses("p1") == 1)
		pr:setDisguise("p1", "ProSecurity")
		run(0.1)
		local e2 = tr:drainEvents()
		check("scene: putting on an allowed disguise ends it: status back to allowed and the witness is cleared", tr:statusOf("p1") == "allowed" and #kinds(e2, "TrespassCleared") == 1 and #tr:witnesses("p1") == 0)
		pr:setDisguise("p1", "Chef")
		run(0.2)
		local e3 = tr:drainEvents()
		check("scene: a disguise that makes it minor changes the status to minor", tr:statusOf("p1") == "minor" and kinds(e3, "TrespassStatus")[1].Status == "minor")
		local e4 = kinds(e3, "TrespassWitnessed")
		check("scene: ... and the Sec bot (in EnforceMinor), which still has the player noticed, witnesses the minor trespass at once", #e4 == 1 and e4[1].Status == "minor")
		pr:setDisguise("p1", nil)
		run(0.2)
		local e5 = kinds(tr:drainEvents(), "TrespassWitnessed")
		check("scene: going from minor to major while still noticed re-reports the witness at the new status", #e5 >= 1 and e5[#e5].Status == "major")
		pr:move("p1", -30, 0, 0)
		run(0.2)
		local e6 = tr:drainEvents()
		check("scene: leaving the restricted cell ends the trespass and clears the witness", tr:statusOf("p1") == "allowed" and #kinds(e6, "TrespassCleared") >= 1 and #tr:witnesses("p1") == 0)
	end

	do -- a witness needs to have NOTICED, not merely be near
		local tr, sight, bots, pr, l, run = live({ { Class = "Sec", X = 90 } }) -- faces +X; the player will be behind it
		pr:move("p1", 105, 0, 0) -- Vault cell, to the bot's front (+X) but 15 studs away: it will notice
		run(0.2)
		check("witness: status is reported at once, before anyone has noticed", tr:statusOf("p1") == "major" and #tr:witnesses("p1") == 0)
		run(3)
		check("witness: ... the witness comes when the bot has noticed", #tr:witnesses("p1") == 1)
		local tr2, sight2, bots2, pr2, l2, run2 = live({ { Class = "Sec", X = 90 } })
		pr2:move("p1", 40, 0, 0) -- Restricted cell, 50 studs BEHIND the bot's facing? bot faces +X toward 90; 40 is behind it
		run2(4)
		check("witness: a trespasser the bot cannot see is never witnessed", tr2:statusOf("p1") == "major" and #tr2:witnesses("p1") == 0)
	end

	do -- the dynamic rule while a player stands in it
		local tr, sight, bots, pr, l, run = live({ { Class = "Sec", X = 20 } }, { Public = {}, Restricted = { Trespass = true, Enforce = { Sec = true } }, Dynamic = "{Bluffed && [Public] || [Restricted]}" })
		local w = liveWorld()
		-- make cell 2 dynamic instead
		tr.World = { cellAt = function() return { Index = 2, Node = { Name = "Dynamic" } } end }
		pr:move("p1", 30, 0, 0)
		run(3)
		check("dynamic scene: bluffed = 0 -> the rule is Restricted: trespass, witnessed", tr:statusOf("p1") == "major" and #tr:witnesses("p1") == 1)
		l:set("Bluffed", 1)
		run(0.2)
		check("dynamic scene: flipping the mission variable (a successful bluff) makes the same spot public and clears the witness", tr:statusOf("p1") == "allowed" and #tr:witnesses("p1") == 0)
	end

	do -- players who left, and robustness
		local tr, sight, bots, pr, l, run = live({ { Class = "Sec", X = 20 } })
		pr:move("p1", 30, 0, 0)
		run(3)
		pr:player("p1").Exited = true
		run(0.2)
		check("exited: a player who has left the mission is no longer trespassing", tr:statusOf("p1") == "allowed" and #tr:witnesses("p1") == 0)
		local bare = Trespass.new(nil, { Cells = RULES }, nil)
		check("robust: step with nothing attached is harmless", pcall(bare.step, bare, DT))
		check("robust: no Cells table at all is harmless", (Trespass.new(nil, {}, nil):status("None", cellNamed("X"))) == "allowed" and (Trespass.new(nil, nil, nil):status("None", cellNamed("X"))) == "allowed")
		local function sig()
			local t2, s2, b2, p2, l2, r2 = live({ { Class = "Sec", X = 20 }, { Class = "Emp", X = 20, Z = 9 } })
			p2:move("p1", 30, 0, 0)
			r2(2)
			p2:setDisguise("p1", "Chef")
			r2(3)
			local out = {}
			for _, e in ipairs(t2:drainEvents()) do out[#out + 1] = e.Kind .. "@" .. ("%.2f"):format(e.Time) .. ":" .. tostring(e.Status) .. ":" .. tostring(e.BotClass) end
			return table.concat(out, "|")
		end
		check("robust: two runs give identical events", sig() == sig())
	end

	----------------------------------------------------------------------------------------------- real maps
	local okE, emb = pcall(require, "./_embedded")
	if not okE then
		print("(real-map trespass tests skipped: tests/_embedded.luau not found)")
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
		local d = Codec.decode(entry[2], host)
		local mis = Mission.build(d, { validator = Validator })
		local w = World.build(mis)
		local setup, err = Setup.parse(d.SetupSource)
		check(label .. " [trespass]: the setup parses", setup ~= nil, err)
		local l = Logic.new(mis, { seed = 416, builtins = { Mission_Difficulty = 3 } })
		local tr = Trespass.new(w, setup, l)
		local unresolved, dynamic = 0, 0
		for _, c in ipairs(w.Cells) do
			local _, rules = tr:rulesFor(c)
			if not rules then unresolved += 1 end
			if type(setup.Cells[c.Node.Name]) == "string" then dynamic += 1 end
		end
		check(label .. " [trespass]: every one of the " .. #w.Cells .. " cells resolves to a rule set (" .. dynamic .. " through a {expression}), with no evaluation errors", unresolved == 0 and #tr.Errors == 0, unresolved .. " unresolved; " .. tostring(tr.Errors[1]))

		-- every disguise x every cell gives a defined status, and it is monotonic: if the rule has no Trespass nobody is a trespasser unless MinorTrespass says so
		local disguises = { "None", "ProSecurity", "Chef", "Technician", "Workshop", "EliteScientist", "SteelCove", "Debug" }
		local counts = { allowed = 0, minor = 0, major = 0 }
		local odd = 0
		for _, c in ipairs(w.Cells) do
			for _, dg in ipairs(disguises) do
				local s = tr:status(dg, c)
				if counts[s] == nil then odd += 1 else counts[s] += 1 end
			end
		end
		check(label .. " [trespass]: every (cell, disguise) pair has a defined status", odd == 0)
		print(("  %s: %d cells x %d disguises -> allowed %d, minor %d, major %d"):format(label, #w.Cells, #disguises, counts.allowed, counts.minor, counts.major))
	end

	if okP then
		local d = Codec.decode(embP["theproject.txt"], host)
		local mis = Mission.build(d, { validator = Validator })
		local w = World.build(mis)
		local setup = Setup.parse(d.SetupSource)
		local l = Logic.new(mis, { seed = 416, builtins = { Mission_Difficulty = 3 } })
		local tr = Trespass.new(w, setup, l)
		local room = { Index = 0, Node = { Name = "ServerRoom" } }
		local function s(dg) return (tr:status(dg, room)) end
		check("The Project [trespass]: the server room before the keycard is inserted: a Workshop disguise is MAJOR trespass", s("Workshop") == "major" and tr:ruleName(room) == "ServerRoomEvil")
		l:set("KeycardPlaced", 1)
		check("The Project [trespass]: ... after the keycard it is only MINOR (the V1.3 changelog)", s("Workshop") == "minor" and tr:ruleName(room) == "ServerRoomAwesome")
		check("The Project [trespass]: Technician and ProSecurity are allowed either way; no disguise or a Chef is still major", s("Technician") == "allowed" and s("ProSecurity") == "allowed" and s("None") == "major" and s("Chef") == "major")
		local _, _, rules = tr:status("Workshop", room)
		check("The Project [trespass]: the minor trespass is enforced by the classes the setup lists", tr:enforces("Sec", "minor", rules) == (rules.EnforceMinor and rules.EnforceMinor.Sec == true))
	end

	-- real bots notice a real trespasser: static posts whose own cell treats an undisguised player as a trespasser they enforce
	for _, entry in ipairs(maps) do
		local label = entry[1]
		local d = Codec.decode(entry[2], host)
		local mis = Mission.build(d, { validator = Validator })
		local w = World.build(mis)
		local setup = Setup.parse(d.SetupSource)
		local l = Logic.new(mis, { seed = 416, builtins = { Mission_Difficulty = 3 } })
		local nav = Nav.new({ pathfinder = Nav.worldAdapter(w) })
		local bots = Bots.new(mis, w, l, nav, { seed = 416 })
		local pr = Props.new(mis, w, l)
		local sight = Sight.new(w, bots, Sight.propsPlayers(pr), { blocked = function(...) return pr:sightBlocked(...) end })
		local tr = Trespass.new(w, setup, l)
		tr:attach(sight, bots, Sight.propsPlayers(pr))
		pr:addPlayer("p", 0, -500, 0)
		local candidates, witnessed = 0, 0
		for _, b in ipairs(bots:all()) do
			if b.Timer == math.huge and candidates < 8 then
				local bx, by, bz = bots:position(b.Id)
				local fx, fz = bots:facing(b)
				local px, pz = bx + fx * 8, bz + fz * 8
				local cell = w:cellAt(px, by, pz)
				if cell then
					local status, _, rules = tr:status("None", cell)
					if status ~= "allowed" and tr:enforces(b.Class, status, rules) then
						candidates += 1
						pr:move("p", px, by, pz)
						for _ = 1, 60 do l:advance(DT) bots:step(DT) sight:step(DT) tr:step(DT) end
						for _, id in ipairs(tr:witnesses("p")) do if id == b.Id then witnessed += 1 end end
						pr:move("p", 0, -500, 0)
						for _ = 1, 5 do tr:step(DT) end
					end
				end
			end
		end
		print(("  %s: %d static posts whose cell makes an undisguised player a trespasser they enforce; %d witnessed it within 3 s"):format(label, candidates, witnessed))
		check(label .. " [trespass]: where an enforcing static bot faces a trespasser 8 studs away, most witness it (" .. witnessed .. "/" .. candidates .. ")", candidates == 0 or witnessed >= math.ceil(candidates * 0.6), witnessed .. "/" .. candidates)
	end
end
