--!nonstrict
-- M8f: seeded playthroughs of the three real maps through BreachSession. Run via tests/run.luau or alone: `luau tests/playthrough.luau`
local Session = require("../BreachSession")
local Logic = require("../BreachLogic")
local Nav = require("../BreachNav")
local Bots = require("../BreachBots")
local Props = require("../BreachProps")
local Sight = require("../BreachSight")
local Trespass = require("../BreachTrespass")
local Alert = require("../BreachAlert")
local Hostage = require("../BreachHostage")
local Behavior = require("../BreachBehavior")

return function(check)
	local okE, emb = pcall(require, "./_embedded")
	if not okE then
		print("(playthrough tests skipped: tests/_embedded.luau not found)")
		return
	end
	local Codec = require("../BreachCodec")
	local Zstd = require("../BreachZstd")
	local Mission = require("../BreachMission")
	local Validator = require("../BreachValidator")
	local World = require("../BreachWorld")
	local Setup = require("../BreachSetup")
	local host = { zstdDecompress = Zstd.decompress }
	local okP, embP = pcall(require, "./_embedded_project")
	local maps = { { "TheDiplomat", emb["TheDiplomat.base64"] }, { "thepeacemaker", emb["thepeacemaker.txt"] } }
	if okP then maps[#maps + 1] = { "TheProject", embP["theproject.txt"] } end
	local M = { Logic = Logic, Nav = Nav, Bots = Bots, Props = Props, Sight = Sight, Trespass = Trespass, Alert = Alert, Hostage = Hostage, Behavior = Behavior }

	local function kinds(log, source, kind)
		local out = {}
		for _, e in ipairs(log) do if (source == nil or e.Source == source) and (kind == nil or e.Kind == kind) then out[#out + 1] = e end end
		return out
	end
	local function indexOf(log, source, kind, pred)
		for i, e in ipairs(log) do if e.Source == source and e.Kind == kind and (not pred or pred(e)) then return i end end
		return nil
	end

	for _, entry in ipairs(maps) do
		local label = entry[1]
		local d = Codec.decode(entry[2], host)
		local mis = Mission.build(d, { validator = Validator })
		local w = World.build(mis)
		local setup = Setup.parse(d.SetupSource)
		-- the real alt triggers; the bot tag is blanked so a placed bot can stand in for the map's tagged (spawned) one
		local function altTriggers()
			local alt = { BotAltTrigger = {}, BodyAltTrigger = {} }
			for ty, list in pairs(alt) do
				for _, c in ipairs(mis:byComponent(ty) or {}) do
					if (c.Path or ""):find("/StateComponents/", 1, true) then
						local a = {}
						for k, v in pairs(c.Attrs) do a[k] = v end
						a.BotServerTag, a.BotClientTag = "", ""
						if label == "thepeacemaker" and a.ClientVisible == "EnteredSecurityCenterClient" then a.ClientVisible = "1" end -- position-driven client flag
						list[#list + 1] = { Type = ty, Name = c.Name, Path = c.Path, Attrs = a }
					end
				end
			end
			return alt
		end

		-- one full playthrough; returns facts + the run signature
		local function attempt(skip)
			local facts = { Skip = skip }
			local skipLeft = skip
			local S = Session.new(M, mis, w, setup, { seed = 416, altTriggers = altTriggers() })
			-- 1. quiet patrol: nobody has been seen, the alert is Calm
			S:run(8)
			local log1 = S:drainLog()
			facts.PatrolEvents = #kinds(log1, "Bots", "BotArrived") + #kinds(log1, "Bots", "BotDeparted")
			facts.QuietAlert = S.Alert:level() == 0 and #kinds(log1, "Alert", "AlertRaised") == 0
			-- 2. a player next to a real bot, with a clear line of sight and in the same cell
			local pick, spot, dirx, dirz
			local order = {}
			for _, b in ipairs(S.Bots:all()) do if b.Timer == math.huge then order[#order + 1] = b end end
			for _, b in ipairs(S.Bots:all()) do if b.Timer ~= math.huge then order[#order + 1] = b end end
			for oi, b in ipairs(order) do
				if oi > 40 or pick then break end
				local bx, by, bz = S.Bots:position(b.Id)
				local fx, fz = S.Bots:facing(b)
				for _, off in ipairs({ { fx, fz }, { -fx, -fz }, { -fz, fx }, { fz, -fx } }) do
					local px, pz = bx + off[1] * 3, bz + off[2] * 3
					if not pick and S.Sight:lineOfSight(px, by + 3, pz, bx, by + 3, bz) and S.Hostage:_cell(px, by, pz) == S.Hostage:_cell(bx, by, bz) then
						if skipLeft > 0 then skipLeft -= 1 else pick, spot, dirx, dirz = b, { px, by, pz }, off[1], off[2] end
					end
				end
			end
			facts.Picked = pick ~= nil
			if not pick then return facts, S:signature() end
			S:addPlayer("p1", spot[1], spot[2], spot[3])
			-- 3. take it hostage at gunpoint and lead it away
			S:aim("p1", pick.Id)
			S:run(3)
			local log2 = S:drainLog()
			facts.Taken = #kinds(log2, "Hostage", "HostageTaken") == 1 and S.Hostage:isHostage(pick.Id)
			local bx0, by0, bz0 = S.Bots:position(pick.Id)
			local steps = 0
			for step = 1, 24 do -- walk away along the open line (clear sight to where the hostage stood, same cell)
				local px, pz = spot[1] + dirx * 0.25 * step, spot[3] + dirz * 0.25 * step
				if not (S.Sight:lineOfSight(px, by0 + 3, pz, bx0, by0 + 3, bz0) and S.Hostage:_cell(px, by0, pz) == S.Hostage:_cell(bx0, by0, bz0)) then break end
				steps = step
				S:movePlayer("p1", px, spot[2], pz)
				S:step(0.05)
			end
			facts.LeadSteps = steps
			S:run(4) -- the hostage catches up to its follow distance
			do
				local mx, _, mz = S.Bots:position(pick.Id)
				facts.Moved = math.sqrt((mx - bx0) ^ 2 + (mz - bz0) ^ 2)
				-- (to use the hostage the player walks up to it)
				local hx0, hy0, hz0 = S.Bots:position(pick.Id)
				for _, off in ipairs({ { dirx, dirz }, { -dirx, -dirz }, { -dirz, dirx }, { dirz, -dirx } }) do
					local px, pz = hx0 + off[1] * 2.5, hz0 + off[2] * 2.5
					if S.Sight:lineOfSight(px, hy0 + 3, pz, hx0, hy0 + 3, hz0) and S.Hostage:_cell(px, hy0, pz) == S.Hostage:_cell(hx0, hy0, hz0) then
						S:movePlayer("p1", px, hy0, pz)
						break
					end
				end
				S:run(1)
			end
			local hx, _, hz = S.Bots:position(pick.Id)
			local pl = S.Hostage:_player("p1")
			facts.LedDistance = math.sqrt((hx - pl.X) ^ 2 + (hz - pl.Z) ^ 2)
			facts.Following = S.Hostage:stateOf(pick.Id) == "Following"
			-- 4. the alt interaction with the map's own trigger
			local l = S.Logic
			local function client(name, v) l:setClient("p1", name, v) l:replicate() end
			local title, setVars
			if label == "TheProject" then
				l:set("HoldingLockedPhone", 1) client("ClientHoldingLockedPhone", 1)
				title = "Action.UnlockPhone"
			elseif label == "thepeacemaker" then
				S.Alert:lockdown("playthrough: the alarm goes up")
				S:run(0.5)
				facts.Frozen = S.Hostage:stateOf(pick.Id) == "Frozen"
				title = "Action.UseFingerprint"
			else
				l:set("GuardInfoFound", 1) l:replicate()
				client("Perk_Intimidation", 2)
				title = "Action.Blackmail"
			end
			local entry
			for _, e in ipairs(S.Hostage:interactables("p1")) do if e.Title == title and e.Enabled then entry = e end end
			facts.AltOffered = entry ~= nil
			if entry then
				local ok = S.Hostage:interact("p1", pick.Id, entry.Trigger, entry.HoldTime)
				facts.AltFired = ok == true
			end
			S:run(0.2)
			facts.AltEvent = #kinds(S:drainLog(), "Hostage", "AltTriggered") == 1
			local sig = S:signature()
			-- 5. a second run: a real guard that enforces its own cell sees an undisguised player in it
			local S2 = Session.new(M, mis, w, setup, { seed = 416 })
			local guard
			for _, b in ipairs(S2.Bots:all()) do
				if b.Timer == math.huge and not guard then
					local x, y, z = S2.Bots:position(b.Id)
					local cell = x and w:cellAt(x, y, z)
					if cell then
						local status, _, rules = S2.Trespass:status("None", cell)
						if status ~= "allowed" and S2.Trespass:enforces(b.Class, status, rules) then guard = { Bot = b, Status = status } end
					end
				end
			end
			facts.HasGuard = guard ~= nil
			if guard then
				local bx, by, bz = S2.Bots:position(guard.Bot.Id)
				local fx, fz = S2.Bots:facing(guard.Bot)
				S2:addPlayer("p1", bx + fx * 8, by, bz + fz * 8)
				S2:run(30)
				local log = S2:drainLog()
				local radio = indexOf(log, "Alert", "BotRadioStarted")
				local lock = indexOf(log, "Alert", "AlertRaised", function(e) return e.Level == 3 end)
				facts.GuardStatus = guard.Status
				facts.GuardLockdown = S2.Alert:level() == 3 and radio ~= nil and lock ~= nil and radio < lock and S2.Logic:get("Mission_AlarmRaised") == 1
				facts.GuardQuestion = #kinds(log, "Alert", "QuestionAsked") >= 1
			end
			return facts, sig .. "##" .. S2:signature()
		end

		-- a bot on a nav island the leader cannot be reached from cannot follow: take the next approachable bot (deterministic)
		local function playthrough()
			local f, s
			for skip = 0, 12 do
				f, s = attempt(skip)
				if f.Moved and f.Moved > 0.5 then break end
			end
			return f, s
		end
		local f1, sig1 = playthrough()
		local f2, sig2 = playthrough()
		check(label .. " [playthrough]: the quiet patrol leaves the alert Calm", f1.QuietAlert == true)
		check(label .. " [playthrough]: a real bot can be approached", f1.Picked == true)
		check(label .. " [playthrough]: the bot is taken hostage at gunpoint (HostageTaken, flag, tracker)", f1.Taken == true)
		check(label .. " [playthrough]: it is led away and keeps up with the leader", f1.LedDistance ~= nil and f1.LedDistance < 14 and (f1.Following == true or label == "thepeacemaker"), f1.LedDistance)
		check(label .. " [playthrough]: the hostage really followed (it moved away from where it stood while the leader walked off)", f1.Moved ~= nil and f1.Moved > 0.5 and f1.LeadSteps >= 1, f1.Moved)
		if label == "thepeacemaker" then
			check(label .. " [playthrough]: the alarm freezes the hostage", f1.Frozen == true)
		end
		check(label .. " [playthrough]: the map's own alt trigger is offered and fires with its real expressions", f1.AltOffered == true and f1.AltFired == true and f1.AltEvent == true)
		if f1.HasGuard then
			if f1.GuardStatus == "major" then
				check(label .. " [playthrough]: a real guard that enforces its cell radios (BotRadioStarted) and then the lockdown lands", f1.GuardLockdown == true)
			else
				check(label .. " [playthrough]: a real guard that enforces a minor trespass asks the player", f1.GuardQuestion == true)
			end
		end
		check(label .. " [playthrough]: the whole run is identical when replayed (" .. #sig1 .. " characters of events)", sig1 == sig2 and #sig1 > 100)
		print(("  %s: patrol events %d, led distance %.1f, guard %s, signature %d chars"):format(label, f1.PatrolEvents or 0, f1.LedDistance or -1, tostring(f1.GuardStatus), #sig1))
	end
end
