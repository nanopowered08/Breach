--!nonstrict
-- M7 tests: BreachProps. Run via tests/run.luau or alone: `luau tests/props.luau`
local Props = require("../BreachProps")
local Logic = require("../BreachLogic")
local CF = require("../BreachCFrame")

return function(check)
	----------------------------------------------------------------------------------------------- harness
	local counter = 0
	-- A mission node: Part at (x,y,z) with size (sx,sy,sz) and Euler angles (rx,ry,rz).
	local function part(name, attrs, x, y, z, sx, sy, sz, ry)
		counter += 1
		return {
			Name = name, ClassName = "Part", Path = "DebugMission/Props/" .. name .. counter, Id = "n" .. counter, Attrs = attrs or {}, Children = {},
			Props = { CFrame = { Position = { X = x or 0, Y = y or 0, Z = z or 0 }, EulerXYZ = { X = 0, Y = ry or 0, Z = 0 } }, Size = { X = sx or 4, Y = sy or 4, Z = sz or 4 } },
		}
	end
	-- Two cells split at x = 0: A (x < 0) and B (x >= 0); each call returns the same cell object (identity matters for rooms).
	local function stubWorld()
		local a, b = { Id = "A" }, { Id = "B" }
		return { cellAt = function(_, x) if x < 0 then return a end return b end, A = a, B = b }
	end
	local function setup(vars, comps, opts)
		local g = {}
		for k, v in pairs(vars or {}) do g[k] = v end
		return Logic.fromSpec({ Globals = g }, comps or {}, opts)
	end
	local function world(vars, nodes, comps, opts)
		local l = setup(vars, comps, opts)
		local w = stubWorld()
		local sim = Props.fromNodes(nodes, w, l, opts)
		return sim, l, w
	end
	local function near(a, b) return type(a) == "number" and math.abs(a - b) < 1e-6 end

	----------------------------------------------------------------------------------------------- TriggerZone
	do
		local z = part("TriggerZone", { Variable = "InZone", AllPlayersInZoneVariable = "AllIn", PlayersOutsideZoneVariable = "Out", IsGlobal = true }, 10, 0, 0, 4, 4, 4)
		local sim, l = world({}, { z })
		sim:addPlayer("a", 50, 0, 0)
		sim:addPlayer("b", 50, 0, 0)
		check("zone: nobody inside -> 0, outside 2, not all in", l:get("InZone") == 0 and l:get("Out") == 2 and l:get("AllIn") == 0)
		sim:move("a", 10, 0, 0)
		check("zone: a player inside is counted (global)", l:get("InZone") == 1 and l:get("Out") == 1 and l:get("AllIn") == 0)
		sim:move("b", 11.9, 1.9, -1.9)
		check("zone: the box edge is inclusive, and everyone inside sets AllPlayersInZoneVariable", l:get("InZone") == 2 and l:get("AllIn") == 1 and l:get("Out") == 0)
		sim:move("b", 12.1, 0, 0)
		check("zone: just outside is outside", l:get("InZone") == 1)
		sim:move("a", 10, 2.1, 0)
		check("zone: the vertical extent counts too", l:get("InZone") == 0)
		sim:move("a", 10, 0, 0)
	end

	do -- orientation: a long thin zone rotated 90 degrees about Y
		local z = part("TriggerZone", { Variable = "InZone", IsGlobal = true }, 0, 0, 0, 20, 4, 2, math.pi / 2)
		local sim, l = world({}, { z })
		sim:addPlayer("a", 0, 0, 8)
		check("zone: a zone rotated 90° about Y is long along Z, not X", l:get("InZone") == 1)
		sim:move("a", 8, 0, 0)
		check("zone: ... and short along X", l:get("InZone") == 0)
	end

	do -- Active gating
		local z = part("TriggerZone", { Variable = "InZone", IsGlobal = true, Active = "Open" }, 0, 0, 0)
		local sim, l = world({ Open = "0" }, { z })
		sim:addPlayer("a", 0, 0, 0)
		check("zone: an inactive zone does not count", l:get("InZone") == nil or l:get("InZone") == 0)
		l:set("Open", 1)
		check("zone: it recounts the moment Active turns on, without anyone moving", l:get("InZone") == 1)
		l:set("Open", 0)
		check("zone: an inactive zone freezes (ClearOnInactive=false keeps the last count)", l:get("InZone") == 1)

		local z2 = part("TriggerZone", { Variable = "InZone", IsGlobal = true, Active = "Open", ClearOnInactive = true }, 0, 0, 0)
		local sim2, l2 = world({ Open = "1" }, { z2 })
		sim2:addPlayer("a", 0, 0, 0)
		check("zone: counting while active", l2:get("InZone") == 1)
		l2:set("Open", 0)
		check("zone: ClearOnInactive zeroes the variable when Active turns off", l2:get("InZone") == 0)

		local z3 = part("TriggerZone", { Variable = "V", IsGlobal = true, IsSpawned = "Here" }, 0, 0, 0)
		local sim3, l3 = world({ Here = "0" }, { z3 })
		sim3:addPlayer("a", 0, 0, 0)
		check("zone: a prop that is not spawned does nothing", l3:get("V") == nil or l3:get("V") == 0)
	end

	do -- IsLocal: a per-client boolean
		local z = part("TriggerZone", { Variable = "Mine", IsLocal = true }, 0, 0, 0)
		local sim, l = world({}, { z })
		local a, b = sim:addPlayer("a", 0, 0, 0), sim:addPlayer("b", 50, 0, 0)
		check("zone (local): each client sees only its own boolean", a.Replica:get("Mine") == 1 and b.Replica:get("Mine") == 0)
		check("zone (local): it is a client variable, not a global", l:get("Mine") == nil)
		sim:move("b", 0, 0, 0)
		sim:move("a", 50, 0, 0)
		check("zone (local): it follows each player", a.Replica:get("Mine") == 0 and b.Replica:get("Mine") == 1)
	end

	do -- a zone with no variables / bad geometry is harmless
		local sim, l = world({}, { part("TriggerZone", {}, 0, 0, 0) })
		sim:addPlayer("a", 0, 0, 0)
		check("zone: no Variable set is harmless", #l.Errors == 0)
		local noFrame = part("TriggerZone", { Variable = "V" })
		noFrame.Props = nil
		local s2 = world({}, { noFrame })
		check("zone: a zone with no CFrame is a warning", #s2.Warnings == 1)
	end

	----------------------------------------------------------------------------------------------- TriggerRoom
	do
		local r = part("TriggerRoom", { PlayersInRoomVariable = "InRoom", HadPlayerInRoomVariable = "Had", AllPlayersInRoomVariable = "AllRoom", ClientInRoomVariable = "Me" }, -10, 0, 0)
		local sim, l = world({}, { r })
		local a, b = sim:addPlayer("a", 10, 0, 0), sim:addPlayer("b", 10, 0, 0)
		check("room: players in another cell do not count", l:get("InRoom") == 0 and l:get("AllRoom") == 0)
		sim:move("a", -30, 0, 0)
		check("room: a player in the trigger's cell counts (the cell, not a volume)", l:get("InRoom") == 1 and l:get("AllRoom") == 0 and l:get("Had") == 1)
		check("room: ClientInRoomVariable is per client", a.Replica:get("Me") == 1 and b.Replica:get("Me") == 0)
		sim:move("b", -1, 0, 0)
		check("room: everyone in the room sets AllPlayersInRoomVariable", l:get("InRoom") == 2 and l:get("AllRoom") == 1)
		sim:move("a", 10, 0, 0)
		sim:move("b", 10, 0, 0)
		check("room: the count falls to 0 but HadPlayerInRoomVariable is a latch", l:get("InRoom") == 0 and l:get("Had") == 1)
	end

	do -- the real pattern: Active = !TheirOwnVariable, so the first entry latches
		local r = part("TriggerRoom", { PlayersInRoomVariable = "ArmoryEntered", Active = "!ArmoryEntered" }, -10, 0, 0)
		local sim, l = world({}, { r })
		sim:addPlayer("a", 10, 0, 0)
		sim:move("a", -10, 0, 0)
		check("room (real pattern): entering sets the variable", l:get("ArmoryEntered") == 1)
		sim:move("a", 10, 0, 0)
		check("room (real pattern): leaving does not clear it (the trigger deactivated and froze)", l:get("ArmoryEntered") == 1)
		sim:move("a", -10, 0, 0)
		check("room (real pattern): and it stays", l:get("ArmoryEntered") == 1)
	end

	do -- MaxRange
		local r = part("TriggerRoom", { PlayersInRoomVariable = "Near", MaxRange = 5 }, -20, 0, 0)
		local sim, l = world({}, { r })
		sim:addPlayer("a", -20, 0, 3)
		check("room: MaxRange > 0 also limits the distance to the trigger part", l:get("Near") == 1)
		sim:move("a", -20, 0, 9)
		check("room: ... beyond it the player does not count even in the same cell", l:get("Near") == 0)
		local r0 = part("TriggerRoom", { PlayersInRoomVariable = "Any", MaxRange = 0 }, -20, 0, 0)
		local s0, l0 = world({}, { r0 })
		s0:addPlayer("a", -60, 0, 50)
		check("room: MaxRange 0 means no limit (a real map sets 0)", l0:get("Any") == 1)
	end

	----------------------------------------------------------------------------------------------- ItemSpawn
	do
		local item = part("ItemSpawn", { Item = "C4,Mod1,ShapedCharge1", ItemTagString = "Explosives", ItemRemovedVariable = "Taken", KeyItem = true })
		local sim, l = world({}, { item })
		sim:addPlayer("a", 0, 0, 0)
		local ok = sim:pickup("a", item)
		check("item: a pickup succeeds, sets ItemRemovedVariable", ok == true and l:get("Taken") == 1)
		check("item: a comma list gives several items, all carrying the tag and KeyItem", #sim:items("a") == 3 and sim:items("a")[2].Name == "Mod1" and sim:items("a")[1].Tag == "Explosives" and sim:items("a")[1].Key == true)
		check("item: has() matches the name or the tag, without regard to case", sim:has("a", "c4") and sim:has("a", "EXPLOSIVES") and not sim:has("a", "Drill"))
		local again, why = sim:pickup("a", item)
		check("item: it can only be picked up once", again == false and why == "gone")
		sim:addPlayer("b", 0, 0, 0)
		local b2, why2 = sim:pickup("b", item)
		check("item: ... by anyone", b2 == false and why2 == "gone" and #sim:items("b") == 0)
	end

	do
		local a = part("ItemSpawn", { Item = "Hidden", IsSpawned = "Shown" })
		local b = part("ItemSpawn", { Item = "Locked", PickupCondition = "Ready" })
		local c = part("ItemSpawn", { Item = "Late", InitialPickupTime = 5 })
		local d = part("ItemSpawn", { Item = "Ammo Box" })
		local sim, l = world({ Shown = "0", Ready = "0" }, { a, b, c, d })
		sim:addPlayer("p", 0, 0, 0)
		local ok1, why1 = sim:pickup("p", a)
		check("item: IsSpawned false -> not there", ok1 == false and why1 == "not-spawned")
		l:set("Shown", 1)
		check("item: ... until the expression turns true", sim:pickup("p", a) == true)
		local ok2, why2 = sim:pickup("p", b)
		check("item: PickupCondition false blocks the pickup", ok2 == false and why2 == "not-allowed")
		l:set("Ready", 1)
		check("item: ... and true allows it", sim:pickup("p", b) == true)
		local ok3, why3 = sim:pickup("p", c)
		check("item: InitialPickupTime keeps it unavailable at first", ok3 == false and why3 == "too-early")
		l:advance(5)
		check("item: ... until that many seconds have passed", sim:pickup("p", c) == true)
		sim:pickup("p", d)
		check("item: a name with a space is one item (real: '480 MCS')", sim:has("p", "Ammo Box"))
		local bad, why = sim:pickup("p", "NoSuchProp")
		check("item: picking up something that is not an ItemSpawn is a clean failure", bad == false and why == "bad-target")
	end

	----------------------------------------------------------------------------------------------- FreeTrigger
	do
		local t = part("FreeTrigger", { SetVariable = "Searched", HoldTime = 2 })
		local sim, l = world({}, { t })
		sim:addPlayer("a", 0, 0, 0)
		local short, why = sim:interact("a", t, 1)
		check("trigger: holding for less than HoldTime does nothing", short == false and why == "too-short" and l:get("Searched") == nil)
		check("trigger: holding long enough sets SetVariable to 1", sim:interact("a", t, 2) == true and l:get("Searched") == 1)
		check("trigger: not saying how long it was held assumes long enough", sim:interact("a", t) == true)
		local t2 = part("FreeTrigger", { SetVariable = "Tap", HoldTime = 10, TapTrigger = true })
		local s2, l2 = world({}, { t2 })
		s2:addPlayer("a", 0, 0, 0)
		check("trigger: TapTrigger needs no hold", s2:interact("a", t2, 0) == true and l2:get("Tap") == 1)
	end

	do
		local t = part("FreeTrigger", { SetVariable = "Level", SetValue = "Base * 2", HoldTime = 0 })
		local sim, l = world({ Base = "21" }, { t })
		sim:addPlayer("a", 0, 0, 0)
		sim:interact("a", t, 0)
		check("trigger: SetValue is an expression", l:get("Level") == 42)
		local inc = part("FreeTrigger", { IncrementVariable = "Count", HoldTime = 0 })
		local s2, l2 = world({}, { inc })
		s2:addPlayer("a", 0, 0, 0)
		s2:interact("a", inc, 0)
		s2:interact("a", inc, 0)
		s2:interact("a", inc, 0)
		check("trigger: IncrementVariable counts uses", l2:get("Count") == 3)
	end

	do -- visibility, enabling, tool, client-side gating
		local t = part("FreeTrigger", { SetVariable = "Hit", ServerVisible = "Vis", ServerEnabled = "En", Tool = "Crowbar", HoldTime = 0 })
		local sim, l = world({ Vis = "0", En = "0" }, { t })
		sim:addPlayer("a", 0, 0, 0)
		local _, r1 = sim:interact("a", t, 0)
		check("trigger: not visible -> cannot be used", r1 == "not-visible")
		l:set("Vis", 1)
		local _, r2 = sim:interact("a", t, 0)
		check("trigger: visible but not enabled -> disabled (the map shows DisabledSubtitle)", r2 == "disabled")
		l:set("En", 1)
		local _, r3 = sim:interact("a", t, 0)
		check("trigger: a Tool is required", r3 == "missing-tool")
		sim:give("a", "Crowbar")
		check("trigger: ... and having it works", sim:interact("a", t, 0) == true and l:get("Hit") == 1)

		local blank = part("FreeTrigger", { SetVariable = "B", HoldTime = 0 })
		local s2, l2 = world({}, { blank })
		s2:addPlayer("a", 0, 0, 0)
		check("trigger: blank ServerVisible/ServerEnabled mean visible and enabled (23 real triggers leave them blank)", s2:interact("a", blank, 0) == true)

		local cv = part("FreeTrigger", { SetVariable = "C", ClientVisible = "HasBadge", HoldTime = 0 })
		local s3, l3 = world({}, { cv })
		local a, b = s3:addPlayer("a", 0, 0, 0), s3:addPlayer("b", 0, 0, 0)
		l3:setClient("a", "HasBadge", 1)
		l3:replicate()
		check("trigger: ClientVisible is evaluated on the player's own client", s3:interact("a", cv, 0) == true and s3:interact("b", cv, 0) == false)
	end

	do -- client variables
		local t = part("FreeTrigger", { SetClientVariable = "Mine", IncrementClientVariable = "Uses", HoldTime = 0 })
		local sim, l = world({}, { t })
		local a, b = sim:addPlayer("a", 0, 0, 0), sim:addPlayer("b", 0, 0, 0)
		sim:interact("a", t, 0)
		sim:interact("a", t, 0)
		check("trigger: SetClientVariable/IncrementClientVariable change only the interacting client", a.Replica:get("Mine") == 1 and a.Replica:get("Uses") == 2 and b.Replica:get("Mine") ~= 1 and (b.Replica:get("Uses") or 0) == 0)
	end

	----------------------------------------------------------------------------------------------- ItemDeposit
	do
		local dep = part("ItemDeposit", { ItemTagForDeposit = "Battery", DepositedVariable = "Placed", ServerVisible = "!Placed" })
		local sim, l = world({}, { dep })
		sim:addPlayer("a", 0, 0, 0)
		local _, why = sim:interact("a", dep)
		check("deposit: without the item it fails (the map shows MissingToolSubtitle)", why == "missing-tool" and l:get("Placed") == nil)
		sim:give("a", "Car Battery", "Battery")
		check("deposit: the item is matched by its tag", sim:interact("a", dep) == true and l:get("Placed") == 1)
		check("deposit: ... and consumed", #sim:items("a") == 0)
		local _, why2 = sim:interact("a", dep)
		check("deposit: a ServerVisible that turned false (!Placed) hides it", why2 == "not-visible")

		local byName = part("ItemDeposit", { Item = "Cage", DepositedVariable = "CagePlaced" })
		local s2, l2 = world({}, { byName })
		s2:addPlayer("a", 0, 0, 0)
		s2:give("a", "Cage")
		check("deposit: with no tag required it matches Item by name", s2:interact("a", byName) == true and l2:get("CagePlaced") == 1)

		local ce = part("ItemDeposit", { DepositedVariable = "D", ClientEnabled = "CanDo" })
		local s3 = world({}, { ce })
		local p = s3:addPlayer("a", 0, 0, 0)
		local _, why3 = s3:interact("a", ce)
		check("deposit: ClientEnabled gates it per client", why3 == "disabled")
	end

	----------------------------------------------------------------------------------------------- Doors
	do
		-- a door at the origin; LookVector (-Z) points to -Z: a player at z = -3 is on the front side
		local door = part("DoorMetal", { OpenVariable = "DoorOpen", OpenIncrementVariable = "Opens" }, 0, 0, 0)
		local sim, l = world({}, { door })
		sim:addPlayer("a", 0, 0, -3)
		check("door: an unlocked door opens", sim:openDoor("a", door) == true and l:get("DoorOpen") == 1 and l:get("Opens") == 1)
		check("door: OpenVariable and OpenIncrementVariable are written", sim:closeDoor(door) == true and l:get("DoorOpen") == 0)
		sim:openDoor("a", door)
		check("door: opening again counts again", l:get("Opens") == 2)
		check("door: closing an already closed door is a no-op", (function() sim:closeDoor(door) return sim:closeDoor(door) == false end)())

		local f = part("DoorMetal", { LockFront = true }, 0, 0, 0)
		local s2 = world({}, { f })
		s2:addPlayer("front", 0, 0, -3)
		s2:addPlayer("back", 0, 0, 3)
		check("door: sideOf follows the door's LookVector (-Z)", s2:sideOf(f, s2:player("front")) == "front" and s2:sideOf(f, s2:player("back")) == "back")
		local _, r1 = s2:openDoor("front", f)
		check("door: LockFront locks it for a player on the front", r1 == "locked")
		check("door: ... but not for one on the back", s2:openDoor("back", f) == true)

		local lb = part("DoorMetal", { LockBack = "Lockdown" }, 0, 0, 0)
		local s3, l3 = world({ Lockdown = "1" }, { lb })
		s3:addPlayer("front", 0, 0, -3)
		s3:addPlayer("back", 0, 0, 3)
		local _, r2 = s3:openDoor("back", lb)
		check("door: LockBack is an expression too", r2 == "locked" and s3:openDoor("front", lb) == true)
		s3:closeDoor(lb)
		l3:set("Lockdown", 0)
		check("door: ... and unlocks when it turns false", s3:openDoor("back", lb) == true)

		local keyed = part("DoorMetal", { LockFront = true, Access = "MasterKey ArchivesKey" }, 0, 0, 0)
		local s4 = world({}, { keyed })
		s4:addPlayer("a", 0, 0, -3)
		check("door: locked without the key", select(2, s4:openDoor("a", keyed)) == "locked")
		s4:give("a", "ArchivesKey")
		check("door: any key named in Access opens it", s4:openDoor("a", keyed) == true)

		local remote = part("DoorMetal", { LockFront = true, RemoteUnlock = "Card" }, 0, 0, 0)
		local s5, l5 = world({ Card = "0" }, { remote })
		s5:addPlayer("a", 0, 0, -3)
		check("door: locked until RemoteUnlock", select(2, s5:openDoor("a", remote)) == "locked")
		l5:set("Card", 1)
		check("door: RemoteUnlock (a reader's TriggerVariable) unlocks it", s5:openDoor("a", remote) == true)

		local blocked = part("DoorWood", { Blocked = "Barricade", Access = "MasterKey" }, 0, 0, 0)
		local s6, l6 = world({ Barricade = "1" }, { blocked })
		s6:addPlayer("a", 0, 0, -3)
		s6:give("a", "MasterKey")
		check("door: Blocked stops even a key (a barricade)", select(2, s6:openDoor("a", blocked)) == "blocked")
		l6:set("Barricade", 0)
		check("door: ... until the barricade is gone", s6:openDoor("a", blocked) == true)

		local jam = part("DoorMetal", { Jammed = true }, 0, 0, 0)
		local s7 = world({}, { jam })
		s7:addPlayer("a", 0, 0, -3)
		check("door: a Jammed door will not open", select(2, s7:openDoor("a", jam)) == "jammed")

		local auto = part("DoorMetal", { AutoLock = true, Access = "Key" }, 0, 0, 0)
		local s8 = world({}, { auto })
		s8:addPlayer("a", 0, 0, -3)
		s8:openDoor("a", auto)
		s8:closeDoor(auto)
		check("door: an AutoLock door locks itself when closed", select(2, s8:openDoor("a", auto)) == "locked")
		s8:give("a", "Key")
		check("door: ... and its key still opens it", s8:openDoor("a", auto) == true)

		local lv = part("DoorMetal", { LockFront = "On", RemoteUnlock = "Un", LockedVariable = "IsLocked" }, 0, 0, 0)
		local s9, l9 = world({ On = "1", Un = "0" }, { lv })
		check("door: LockedVariable follows the lock expressions", l9:get("IsLocked") == 1)
		l9:set("Un", 1)
		check("door: ... including RemoteUnlock", l9:get("IsLocked") == 0)
		l9:set("Un", 0)
		l9:set("On", 0)
		check("door: ... and unlocking", l9:get("IsLocked") == 0)

		local names = { "DoorWood", "DoorGlassFramed", "DoorMetalElectronic", "DoorArmored", "GarageDoor", "SlidingBlastDoor", "DoubleVaultDoor", "HeavySecurityDoor", "DoorFenceGate" }
		local nodes = {}
		for _, n in ipairs(names) do nodes[#nodes + 1] = part(n, {}, 0, 0, 0) end
		nodes[#nodes + 1] = part("DoorPanelIn", {}, 0, 0, 0)
		nodes[#nodes + 1] = part("WoodChair", {}, 0, 0, 0)
		local s10 = world({}, nodes)
		check("door: the door family is recognised by name (" .. #names .. " names)", #s10:propsOf("Door") == #names + 1, #s10:propsOf("Door"))
	end

	----------------------------------------------------------------------------------------------- CardReader
	do
		local reader = part("CardReader", { ValidCards = "BasicKeycard SecurityKeycard", TriggerVariable = "GateOpen", PowerArea = "Power" })
		local sim, l = world({ Power = "0" }, { reader })
		sim:addPlayer("a", 0, 0, 0)
		local _, r0 = sim:swipe("a", reader, "BasicKeycard")
		check("reader: no power -> nothing", r0 == "no-power")
		l:set("Power", 1)
		local _, r1 = sim:swipe("a", reader, "BasicKeycard")
		check("reader: you must be carrying the card", r1 == "no-card")
		sim:give("a", "MasterKeycard")
		local _, r2 = sim:swipe("a", reader, "MasterKeycard")
		check("reader: a card not in ValidCards is refused", r2 == "wrong-card" and l:get("GateOpen") == nil)
		sim:give("a", "SecurityKeycard")
		check("reader: a valid card sets TriggerVariable", sim:swipe("a", reader, "SecurityKeycard") == true and l:get("GateOpen") == 1)

		local ladder = part("CardReader", { MinimumCard = "SecurityKeycard", TriggerVariable = "T" })
		local s2, l2 = world({}, { ladder })
		s2:addPlayer("a", 0, 0, 0)
		s2:give("a", "BasicKeycard")
		s2:give("a", "MasterKeycard")
		check("reader: with no ValidCards, MinimumCard is a ladder (Basic < Security < Master) [P]", select(2, s2:swipe("a", ladder, "BasicKeycard")) == "wrong-card" and s2:swipe("a", ladder, "MasterKeycard") == true and l2:get("T") == 1)
		local blk = part("CardReader", { ValidCards = "BasicKeycard", TriggerVariable = "T", Blocked = "Down" })
		local s3 = world({ Down = "1" }, { blk })
		s3:addPlayer("a", 0, 0, 0)
		s3:give("a", "BasicKeycard")
		check("reader: Blocked refuses", select(2, s3:swipe("a", blk, "BasicKeycard")) == "blocked")

		-- the real wiring: reader -> variable -> door RemoteUnlock
		local rd = part("CardReader", { ValidCards = "BasicKeycard", TriggerVariable = "GateDoorUnlocked" })
		local dr = part("DoorMetal", { LockFront = true, RemoteUnlock = "GateDoorUnlocked" }, 0, 0, 0)
		local s4 = world({}, { rd, dr })
		s4:addPlayer("a", 0, 0, -3)
		s4:give("a", "BasicKeycard")
		check("reader+door: locked until the card is swiped", select(2, s4:openDoor("a", dr)) == "locked")
		s4:swipe("a", rd, "BasicKeycard")
		check("reader+door: the swipe unlocks the door through the variable", s4:openDoor("a", dr) == true)
	end

	----------------------------------------------------------------------------------------------- MissionEndZone
	do
		local ez = part("MissionEndZone", { PlayersExitedVariable = "Exited", ItemRequired = "HardDrive", ItemSecuredVariable = "Secured", Active = "Go", OpenForAll = 1, AltItem0 = "Files", AltItem0Variable = "FilesSecured" }, 0, 0, 0, 10, 10, 10)
		local sim, l = world({ Go = "0" }, { ez })
		sim:addPlayer("a", 0, 0, 0)
		sim:addPlayer("b", 50, 0, 0)
		check("end zone: an inactive zone lets nobody out", sim:player("a").Exited == false and l:get("Mission_PlayersInGame") == 2)
		sim:give("a", "HardDrive")
		sim:give("a", "Files")
		l:set("Go", 1)
		check("end zone: when it opens, a player standing in it leaves (no movement needed)", sim:player("a").Exited == true and l:get("Exited") == 1)
		check("end zone: the required item is secured", l:get("Secured") == 1)
		check("end zone: alternative items set their own variables", l:get("FilesSecured") == 1)
		check("end zone: Mission_PlayersInGame drops as players leave", l:get("Mission_PlayersInGame") == 1 and l:get("Mission_PlayerTotal") == 2)
		check("end zone: an exited player no longer moves or counts", sim:move("a", 5, 5, 5) == false)
		sim:move("b", 0, 0, 0)
		check("end zone: the second player leaves too (without the item)", l:get("Exited") == 2 and l:get("Mission_PlayersInGame") == 0)

		local noItem = part("MissionEndZone", { PlayersExitedVariable = "E", ItemRequired = "Drive", ItemSecuredVariable = "S" }, 0, 0, 0, 10, 10, 10)
		local s2, l2 = world({}, { noItem })
		s2:addPlayer("a", 0, 0, 0)
		check("end zone: leaving without the required item does not secure it", l2:get("E") == 1 and l2:get("S") == nil)

		local need = part("MissionEndZone", { PlayersExitedVariable = "E", OpenForAll = "0" }, 0, 0, 0, 10, 10, 10)
		local s3, l3 = world({}, { need })
		s3:addPlayer("b", 50, 0, 0)
		s3:addPlayer("a", 0, 0, 0)
		check("end zone: OpenForAll false waits for every live player [P]", s3:player("a").Exited == false and l3:get("E") == nil)
		s3:move("b", 1, 0, 0)
		check("end zone: ... then everyone leaves", l3:get("E") == 2)
	end

	----------------------------------------------------------------------------------------------- folders, conditions, summary
	do
		local function folder(name, attrs, children) counter += 1 return { Name = name, ClassName = "Folder", Path = "DebugMission/Props/" .. name, Id = "f" .. counter, Attrs = attrs or {}, Children = children or {} } end
		local on = folder("BoxesA", { Condition = "Roll == 1" }, { part("FreeTrigger", { SetVariable = "A" }) })
		local off = folder("BoxesB", { Condition = "Roll == 2" }, { part("FreeTrigger", { SetVariable = "B" }) })
		local dis = folder("Disabled", {}, { part("FreeTrigger", { SetVariable = "C" }) })
		local nested = folder("Outer", { Condition = "Roll == 2" }, { folder("Inner", {}, { part("FreeTrigger", { SetVariable = "D" }) }) })
		local root = folder("Props", {}, { on, off, dis, nested, part("TriggerZone", { Variable = "V" }, 0, 0, 0), part("WoodChair"), part("WoodChair"), part("DecorativePipe") })
		local mission = { folder = function(_, name) if name == "Props" then return root end end }
		local l = setup({ Roll = "1" })
		local sim = Props.new(mission, stubWorld(), l)
		local s = sim:summary()
		check("folders: a Folder whose Condition is true keeps its props; false, Disabled and nested-under-false remove them", s.Kinds.FreeTrigger == 1 and s.Kinds.TriggerZone == 1)
		check("folders: everything else is counted as unsupported (decorations)", s.Unsupported == 3 and sim.Unsupported.WoodChair == 2)
		check("folders: a mission with no Props folder is a clean error", select(2, Props.new({ folder = function() return nil end }, nil, l)) ~= nil)
		local bad = folder("Props", {}, { folder("Weird", { Condition = "1 +" }, { part("FreeTrigger", {}) }) })
		local sb = Props.new({ folder = function() return bad end }, stubWorld(), setup({}))
		check("folders: a Condition that does not compile is a warning and the folder is off", #sb.Warnings == 1 and sb:summary().Props == 0)
	end

	----------------------------------------------------------------------------------------------- end to end: a whole no-guards mission
	do
		local nodes = {
			part("TriggerRoom", { PlayersInRoomVariable = "InVault", Active = "!InVault" }, -30, 0, 0),
			part("ItemSpawn", { Item = "Keycard", ItemTagString = "BasicKeycard", ItemRemovedVariable = "GotCard" }, -30, 0, 2),
			part("CardReader", { ValidCards = "BasicKeycard", TriggerVariable = "DoorUnlocked", PowerArea = "Power" }, 4, 0, 0),
			part("DoorMetal", { LockFront = true, RemoteUnlock = "DoorUnlocked", OpenVariable = "DoorOpen" }, 6, 0, 0),
			part("FreeTrigger", { SetVariable = "HackDone", HoldTime = 3, ServerEnabled = "DoorOpen", TitleKey = "Action.Hack" }, 20, 0, 0),
			part("MissionEndZone", { PlayersExitedVariable = "Out", ItemRequired = "Drive", ItemSecuredVariable = "Secured", Active = "HackDone && !Mission_AlarmRaised", OpenForAll = 1 }, 40, 0, 0, 10, 10, 10),
			part("ItemSpawn", { Item = "Drive", ItemRemovedVariable = "GotDrive", PickupCondition = "HackDone" }, 20, 0, 3),
		}
		local comps = { { Type = "MissionCompletionTrigger", Name = "Win", Path = "DebugMission/StateComponents/Win", Attrs = { Condition = "Secured && Out >= Mission_PlayerTotal", Timeout = 2, CompleteVariable = "Done" } } }
		local sim, l = world({ Power = "1" }, nodes, comps)
		sim:addPlayer("p1", 100, 0, 0)
		l:advance(10)
		check("mission: nothing happens by itself", l.Outcome == nil and l:get("GotCard") == nil)
		sim:move("p1", -30, 0, 0)
		check("mission: stepping into the vault room sets InVault", l:get("InVault") == 1)
		check("mission: picking up the keycard", sim:pickup("p1", sim:propsOf("ItemSpawn")[1]) == true and sim:has("p1", "BasicKeycard") and l:get("GotCard") == 1)
		sim:move("p1", 4, 0, -2)
		local _, d1 = sim:openDoor("p1", sim:propsOf("Door")[1])
		check("mission: the door is locked", d1 == "locked")
		check("mission: swiping the card unlocks it", sim:swipe("p1", sim:propsOf("CardReader")[1], "BasicKeycard") == true and l:get("DoorUnlocked") == 1)
		check("mission: and the player opens the door", sim:openDoor("p1", sim:propsOf("Door")[1]) == true and l:get("DoorOpen") == 1)
		sim:move("p1", 20, 0, 0)
		local hack = sim:propsOf("FreeTrigger")[1]
		local _, h1 = sim:interact("p1", hack, 1)
		check("mission: a short press does not hack (HoldTime 3)", h1 == "too-short" and l:get("HackDone") == nil)
		local _, d2 = sim:pickup("p1", sim:propsOf("ItemSpawn")[2])
		check("mission: the drive cannot be taken before the hack (PickupCondition)", d2 == "not-allowed")
		check("mission: a full hold hacks", sim:interact("p1", hack, 3) == true and l:get("HackDone") == 1)
		check("mission: ... which releases the drive", sim:pickup("p1", sim:propsOf("ItemSpawn")[2]) == true and sim:has("p1", "Drive"))
		check("mission: not complete yet", l.Outcome == nil)
		sim:move("p1", 40, 0, 0)
		check("mission: walking into the (now active) end zone leaves the mission with the drive", l:get("Out") == 1 and l:get("Secured") == 1 and sim:player("p1").Exited == true)
		l:advance(1.9)
		check("mission: the completion trigger waits its Timeout", l.Outcome == nil)
		l:advance(0.2)
		check("mission: and the mission completes", l.Outcome ~= nil and l.Outcome.Kind == "Complete" and l:get("Done") == 1)
		local log = {}
		for _, e in ipairs(l:drainEvents()) do if e.Kind == "PropEvent" then log[#log + 1] = e.Action end end
		check("mission: every step left a PropEvent, in order (including the refused door)", table.concat(log, ",") == "Pickup,DoorDenied,Swipe,DoorOpen,Interact,Pickup,Exit", table.concat(log, ","))
	end

	----------------------------------------------------------------------------------------------- real maps
	local okE, emb = pcall(require, "./_embedded")
	if not okE then
		print("(real-map props tests skipped: tests/_embedded.luau not found)")
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
	local built = {}
	for _, entry in ipairs(maps) do
		local label, text = entry[1], entry[2]
		local m = Mission.build(Codec.decode(text, host), { validator = Validator })
		local w = World.build(m)
		local props = function(tag) return CF.new(#tag, 1, 2) end
		local l = Logic.new(m, { seed = 416, world = { cframeOf = props } })
		local sim, err = Props.new(m, w, l)
		check(label .. " [props]: builds", sim ~= nil, err)
		if sim then
			local s = sim:summary()
			local kinds = {}
			for k, v in pairs(s.Kinds) do kinds[#kinds + 1] = k .. " x" .. v end
			table.sort(kinds)
			print(("  %s: %d props live (%s); %d other props (decorations, bots' nodes, ...) not handled yet; %d warnings"):format(label, s.Props, table.concat(kinds, ", "), s.Unsupported, s.Warnings))
			check(label .. " [props]: no warnings and no logic errors", s.Warnings == 0 and #l.Errors == 0, (sim.Warnings[1] and sim.Warnings[1].Message) or (l.Errors[1] and l.Errors[1].Message))
			check(label .. " [props]: it found rooms or zones, triggers and items", (s.Kinds.TriggerZone ~= nil or s.Kinds.TriggerRoom ~= nil) and s.Kinds.ItemSpawn ~= nil and s.Kinds.FreeTrigger ~= nil)
			sim:addPlayer("p1", 0, -500, 0)
			l:advance(60)
			check(label .. " [props]: a player far outside the map for 60 s changes nothing (no outcome, no errors)", l.Outcome == nil and #l.Errors == 0)
			built[label] = { m = m, w = w, sim = sim, l = l }
		end
	end

	-- robustness on real data: use every prop once, nothing may throw and nothing may log a logic error
	for label, b in pairs(built) do
		local sim, l = b.sim, b.l
		local reasons, threw, total = {}, 0, 0
		local pid = "walker"
		sim:addPlayer(pid, 0, -500, 0)
		local function use(fn, ...)
			total += 1
			local ok, res, why = pcall(fn, ...)
			if not ok then
				threw += 1
				print("    threw: " .. tostring(res))
			else
				local key = res == true and "ok" or tostring(why)
				reasons[key] = (reasons[key] or 0) + 1
			end
		end
		for _, p in ipairs(sim:propsOf("ItemSpawn")) do use(sim.pickup, sim, pid, p) end
		for _, p in ipairs(sim:propsOf("FreeTrigger")) do use(sim.interact, sim, pid, p, 10) end
		for _, p in ipairs(sim:propsOf("ItemDeposit")) do use(sim.interact, sim, pid, p) end
		for _, p in ipairs(sim:propsOf("Door")) do use(sim.openDoor, sim, pid, p) end
		for _, p in ipairs(sim:propsOf("CardReader")) do use(sim.swipe, sim, pid, p, "BasicKeycard") end
		local rs = {}
		for k, v in pairs(reasons) do rs[#rs + 1] = k .. " x" .. v end
		table.sort(rs)
		check(label .. " [props]: using all " .. total .. " real props once: nothing throws", threw == 0)
		check(label .. " [props]: ... and the logic core logged no errors", #l.Errors == 0, l.Errors[1] and (l.Errors[1].Where .. " " .. l.Errors[1].Message))
		print(("  %s: %d uses -> %s"):format(label, total, table.concat(rs, ", ")))
		l:advance(30)
		check(label .. " [props]: and 30 s later it is still consistent", #l.Errors == 0)
	end

	-- real wiring: readers -> TriggerVariable -> a door's RemoteUnlock
	for label, b in pairs(built) do
		local sim = b.sim
		local wired = 0
		for _, rd in ipairs(sim:propsOf("CardReader")) do
			local var = rd.Attrs.TriggerVariable
			for _, door in ipairs(sim:propsOf("Door")) do
				local ru = door.Attrs.RemoteUnlock
				if (var ~= nil and var ~= "") and type(ru) == "string" and ru:lower():find(var:lower(), 1, true) then wired += 1 end
			end
		end
		print(("  %s: %d reader->door wirings found through RemoteUnlock"):format(label, wired))
	end

	-- real chains
	local function lower_eq(a, b) return tostring(a):lower() == tostring(b):lower() end
	local function propWith(sim, kind, attr, value)
		for _, p in ipairs(sim:propsOf(kind)) do
			if p.Attrs[attr] ~= nil and lower_eq(p.Attrs[attr], value) then return p end
		end
	end

	if built.TheProject then
		-- a fresh build: the robustness pass above picked up items, which really does set e.g. ArmoryEntered
		local m = built.TheProject.m
		local l = Logic.new(m, { seed = 416, world = { cframeOf = function(tag) return CF.new(#tag, 1, 2) end } })
		local sim = Props.new(m, built.TheProject.w, l)
		sim:addPlayer("p1", 0, -500, 0)
		local exit = propWith(sim, "TriggerZone", "Tag", "StealthExit")
		check("The Project [props]: it has a StealthExit zone that feeds PlayersInStealthExit", exit ~= nil and exit.Attrs.Variable == "PlayersInStealthExit")
		if exit then
			l:set("StealthExitOpen", 1)
			sim:move("p1", exit.Frame[1], exit.Frame[2], exit.Frame[3])
			check("The Project [props]: standing in it counts the player", l:get("PlayersInStealthExit") == 1, l:get("PlayersInStealthExit"))
			check("The Project [props]: ... and the map's own Setup then sees everyone at the stealth exit", l:get("AllPlayersInStealthExit") == 1, l:get("AllPlayersInStealthExit"))
			sim:move("p1", 0, -500, 0)
			check("The Project [props]: leaving the zone drops it again", l:get("PlayersInStealthExit") == 0)
		end
		local armory = propWith(sim, "TriggerRoom", "PlayersInRoomVariable", "ArmoryEntered")
		check("The Project [props]: it has the armory room trigger", armory ~= nil)
		if armory then
			check("The Project [props]: ArmoryEntered starts unset", (l:get("ArmoryEntered") or 0) == 0)
			sim:move("p1", armory.Frame[1], armory.Frame[2], armory.Frame[3])
			check("The Project [props]: walking into the armory room sets ArmoryEntered", l:get("ArmoryEntered") == 1, l:get("ArmoryEntered"))
			sim:move("p1", 0, -500, 0)
			check("The Project [props]: and it latches", l:get("ArmoryEntered") == 1)
		end
	end
end
