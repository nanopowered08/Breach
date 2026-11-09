--!nonstrict
--[=[
	BreachProps — the first props layer (BreachEngine M7; main doc §8.1): enough to play a no-guards mission.

	Pure Luau, no Roblox APIs. It sits between three things it does not own: the mission model (the props' attributes and
	geometry), a BreachWorld (cells, for rooms) and a BreachLogic (variables, expressions, time). Players are clients
	of the logic core, so per-client variables and `ClientVisible`/`ClientEnabled` expressions behave as in the game.

	    local sim = Props.new(mission, world, logic)            -- every supported prop under Props/ becomes live
	    sim:addPlayer("p1", x, y, z)                            -- joins as a client of the logic core
	    sim:move("p1", x, y, z)                                 -- zones and rooms recount, variables are written
	    sim:pickup("p1", sim:prop("Keycard"))                   -- ItemSpawn   -> inventory, ItemRemovedVariable
	    sim:interact("p1", sim:prop("Hack"), heldSeconds)       -- FreeTrigger / ItemDeposit
	    sim:swipe("p1", reader, "BasicKeycard")                 -- CardReader  -> TriggerVariable
	    sim:openDoor("p1", door)  sim:closeDoor(door)           -- Doors: locks, Access keys, RemoteUnlock, Blocked
	    sim:exit(...)  (automatic: a player standing in an Active MissionEndZone leaves the mission)

	Supported: TriggerZone, TriggerRoom, FreeTrigger, ItemSpawn, ItemDeposit, MissionEndZone, CardReader, and the door family
	(DoorMetal, DoorWood, DoorGlass…, GarageDoor, …). Everything else under Props/ is counted in sim.Unsupported.
	Props inside a Folder whose `Condition` is false, or inside `Disabled`, do not exist.

	What each prop does is built from the attribute tables and from how the three real maps use them. Anything the data
	does not settle is marked [P] in main doc §8.1.1. Variables are only ever changed through logic:set / setClient, so
	every other component (timers, scripts, triggers) reacts exactly as it would to the game itself.
]=]

local CF = (function()
--@@CFRAME@@
end)()

local Props = {}
Props.VERSION = "0.1.0"

local EPS = 1e-9

--------------------------------------------------------------------------------------------------- helpers

local function isBlank(v)
	return v == nil or v == "" or (type(v) == "string" and not v:match("%S"))
end

local function truthyValue(v)
	return v ~= nil and v ~= 0 and v ~= "" and v ~= false
end

local function bool(v)
	return v == true or v == 1 or v == "true" or v == "1"
end

-- "A B", "A,B" or "A|B" -> { "a", "b" } (lower-case: item and variable names are matched without regard to case)
local function names(v, sep)
	local out = {}
	if type(v) ~= "string" then
		return out
	end
	for piece in v:gmatch(sep or "[^%s,|]+") do
		out[#out + 1] = piece
	end
	return out
end

local function lower(s)
	return tostring(s):lower()
end

local function frameOf(node)
	local p = node.Props and node.Props.CFrame
	if not p then
		return nil
	end
	local pos, e = p.Position or {}, p.EulerXYZ or {}
	local f = CF.angles(e.X or 0, e.Y or 0, e.Z or 0)
	f[1], f[2], f[3] = pos.X or 0, pos.Y or 0, pos.Z or 0
	return f
end

local function sizeOf(node)
	local s = node.Props and node.Props.Size or {}
	return s.X or 1, s.Y or 1, s.Z or 1
end

-- Is the world point inside the node's oriented box?
local function inBox(prop, x, y, z)
	local inv = prop.Inverse
	local lx = inv[1] + inv[4] * x + inv[5] * y + inv[6] * z
	local ly = inv[2] + inv[7] * x + inv[8] * y + inv[9] * z
	local lz = inv[3] + inv[10] * x + inv[11] * y + inv[12] * z
	return math.abs(lx) <= prop.SX / 2 + EPS and math.abs(ly) <= prop.SY / 2 + EPS and math.abs(lz) <= prop.SZ / 2 + EPS
end

local DOOR_EXACT = { GarageDoor = true, DoubleVaultDoor = true, HeavySecurityDoor = true, SlidingBlastDoor = true }
local function isDoorName(name)
	return DOOR_EXACT[name] or name:match("^Door%u") ~= nil or name:match("^Door$") ~= nil or name:match("%uDoor$") ~= nil
end

local KIND_BY_NAME = {
	TriggerZone = "TriggerZone", TriggerRoom = "TriggerRoom", FreeTrigger = "FreeTrigger", ItemSpawn = "ItemSpawn",
	ItemDeposit = "ItemDeposit", MissionEndZone = "MissionEndZone", CardReader = "CardReader",
}
-- Card ladder used only when a reader lists no ValidCards [P]
local CARD_LEVEL = { BasicKeycard = 1, SecurityKeycard = 2, MasterKeycard = 3 }

--------------------------------------------------------------------------------------------------- the simulation

local Sim = {}
Sim.__index = Sim

-- Expression helpers: blank means `blank` (the maps leave ServerEnabled blank on triggers that obviously work, so blank = on)
function Sim:flag(src, blank)
	if src == nil or isBlank(src) then
		return blank
	end
	if type(src) == "boolean" then
		return src
	end
	local v = self.Logic:eval(src)
	if v == nil then
		return blank
	end
	return truthyValue(v)
end

function Sim:clientFlag(player, src, blank)
	if src == nil or isBlank(src) then
		return blank
	end
	local v = player.Replica:eval(src)
	if v == nil then
		return blank
	end
	return truthyValue(v)
end

function Sim:spawned(prop)
	return self:flag(prop.Attrs.IsSpawned, true)
end

function Sim:setVar(name, value)
	if not isBlank(name) then
		self.Logic:set(name, value)
	end
end

function Sim:incVar(name)
	if not isBlank(name) then
		self.Logic:set(name, (tonumber(self.Logic:get(name)) or 0) + 1)
	end
end

function Sim:setClientVar(player, name, value)
	if not isBlank(name) then
		self.Logic:setClient(player.Id, name, value)
	end
end

function Sim:emit(action, prop, player, extra)
	local ev = { Kind = "PropEvent", Action = action, Prop = prop and prop.Name, Path = prop and prop.Path, Player = player and player.Id }
	for k, v in pairs(extra or {}) do
		ev[k] = v
	end
	self.Logic:emit(ev)
end

function Sim:livePlayers()
	local out = {}
	for _, id in ipairs(self.Order) do
		local p = self.Players[id]
		if not p.Exited then
			out[#out + 1] = p
		end
	end
	return out
end

--------------------------------------------------------------------------------------------------- players

function Sim:addPlayer(id, x, y, z)
	if self.Players[id] then
		return self.Players[id]
	end
	local replica = self.Logic:addClient(id)
	local player = { Id = id, Pos = { x or 0, y or 0, z or 0 }, Items = {}, Exited = false, Replica = replica, Stance = "stand" }
	self.Players[id] = player
	self.Order[#self.Order + 1] = id
	if self.ManageBuiltins then
		local n = #self.Order
		self.Logic:set("Mission_PlayerTotal", n)
		self.Logic:set("Mission_PlayersInGame", #self:livePlayers())
	end
	self:refresh()
	return player
end

function Sim:player(id)
	return self.Players[id]
end

-- The disguise a player wears ("ProSecurity", "Chef", ...; nil or "None" for none): used by BreachTrespass.
function Sim:setDisguise(id, disguise)
	local p = self.Players[id]
	if not p then
		return false
	end
	p.Disguise = (disguise ~= "None" and disguise ~= "") and disguise or nil
	return true
end

-- "stand" (default), "crouch" or "sprint": changes how far and how fast a player is noticed (BreachSight).
function Sim:setStance(id, stance)
	local p = self.Players[id]
	if not p or (stance ~= "stand" and stance ~= "crouch" and stance ~= "sprint") then
		return false
	end
	p.Stance = stance
	return true
end

-- Is the player carrying a drawn weapon? Guards flee only from an armed player (BreachAlert) [R]. Set by the host (BreachRoblox:
-- the character attribute "BreachArmed", else an equipped Tool [P]); false by default.
function Sim:setArmed(id, armed)
	local p = self.Players[id]
	if not p then
		return false
	end
	p.Armed = armed and true or false
	return true
end

-- Does a CLOSED door lie across the segment a -> b? (an open door and a glass door do not block sight) [P: glass]
function Sim:sightBlocked(ax, ay, az, bx, by, bz)
	for _, d in ipairs(self.All) do
		if d.Kind == "Door" and not d.Open and d.Inverse and not d.Name:find("Glass", 1, true) then
			local inv = d.Inverse
			local function toLocal(x, y, z)
				return inv[1] + inv[4] * x + inv[5] * y + inv[6] * z, inv[2] + inv[7] * x + inv[8] * y + inv[9] * z, inv[3] + inv[10] * x + inv[11] * y + inv[12] * z
			end
			local x0, y0, z0 = toLocal(ax, ay, az)
			local x1, y1, z1 = toLocal(bx, by, bz)
			local hx, hy, hz = d.SX / 2, d.SY / 2, d.SZ / 2
			local t0, t1 = 0, 1
			local hit = true
			for _, axis in ipairs({ { x0, x1 - x0, hx }, { y0, y1 - y0, hy }, { z0, z1 - z0, hz } }) do
				local o, dir, h = axis[1], axis[2], axis[3]
				if math.abs(dir) < 1e-9 then
					if o < -h or o > h then
						hit = false
						break
					end
				else
					local ta, tb = (-h - o) / dir, (h - o) / dir
					if ta > tb then
						ta, tb = tb, ta
					end
					t0, t1 = math.max(t0, ta), math.min(t1, tb)
					if t0 > t1 then
						hit = false
						break
					end
				end
			end
			if hit then
				return true
			end
		end
	end
	return false
end

function Sim:move(id, x, y, z)
	local p = self.Players[id]
	if not p or p.Exited then
		return false
	end
	p.Pos = { x, y, z }
	self:refresh()
	return true
end

function Sim:cellOf(id)
	local p = self.Players[id]
	return p and self.World and self.World:cellAt(p.Pos[1], p.Pos[2], p.Pos[3]) or nil
end

-- Items. An item is { Name, Tag, Key }; has() matches name OR tag, without regard to case.
function Sim:give(id, name, tag, key)
	local p = self.Players[id]
	if not p then
		return false
	end
	p.Items[#p.Items + 1] = { Name = name, Tag = tag, Key = key }
	return true
end

function Sim:find(player, what)
	local w = lower(what)
	for i, it in ipairs(player.Items) do
		if lower(it.Name) == w or (not isBlank(it.Tag) and lower(it.Tag) == w) then
			return it, i
		end
	end
	return nil
end

function Sim:has(id, what)
	local p = self.Players[id]
	return p ~= nil and self:find(p, what) ~= nil
end

function Sim:items(id)
	local p = self.Players[id]
	return p and p.Items or {}
end

--------------------------------------------------------------------------------------------------- lookup

-- A prop object, a mission node, a Tag, or a path (or its tail, e.g. "Floors/TriggerZone") -> the prop object, or nil.
function Sim:prop(what)
	if type(what) == "table" then
		if what.Kind then
			return what
		end
		for _, p in ipairs(self.All) do
			if p.Node == what or (what.Id ~= nil and p.Id == what.Id) then
				return p
			end
		end
		return nil
	end
	local w = lower(what)
	for _, p in ipairs(self.All) do
		if lower(p.Tag or "") == w then
			return p
		end
	end
	for _, p in ipairs(self.All) do
		if lower(p.Path) == w or lower(p.Path):sub(-#w - 1) == "/" .. w then
			return p
		end
	end
	return nil
end

function Sim:propsOf(kind)
	local out = {}
	for _, p in ipairs(self.All) do
		if p.Kind == kind then
			out[#out + 1] = p
		end
	end
	return out
end

--------------------------------------------------------------------------------------------------- zones, rooms, end zones

function Sim:inZone(prop, player)
	return inBox(prop, player.Pos[1], player.Pos[2], player.Pos[3])
end

function Sim:inRoom(prop, player)
	if not self.World then
		return false
	end
	local pc = self.World:cellAt(player.Pos[1], player.Pos[2], player.Pos[3])
	if pc == nil or pc ~= prop.Cell then
		return false
	end
	local range = tonumber(prop.Attrs.MaxRange)
	if range and range > 0 then -- [P] a positive MaxRange also limits the distance to the trigger part
		local dx, dy, dz = player.Pos[1] - prop.Frame[1], player.Pos[2] - prop.Frame[2], player.Pos[3] - prop.Frame[3]
		return dx * dx + dy * dy + dz * dz <= range * range
	end
	return true
end

-- Counts for a zone-like prop: who is inside, out of how many live players.
function Sim:census(prop, test)
	local inside, live = {}, self:livePlayers()
	for _, p in ipairs(live) do
		if test(self, prop, p) then
			inside[#inside + 1] = p
		end
	end
	return inside, #live
end

function Sim:refreshZone(prop)
	local a = prop.Attrs
	local active = self:flag(a.Active, true) and self:spawned(prop)
	local global = bool(a.IsGlobal) or not bool(a.IsLocal)
	if not active then
		if bool(a.ClearOnInactive) then
			self:setVar(a.Variable, 0)
			self:setVar(a.AllPlayersInZoneVariable, 0)
			self:setVar(a.PlayersOutsideZoneVariable, 0)
			if bool(a.IsLocal) then
				for _, id in ipairs(self.Order) do
					self:setClientVar(self.Players[id], a.Variable, 0)
				end
			end
		end
		return
	end
	local inside, total = self:census(prop, Sim.inZone)
	if global then
		self:setVar(a.Variable, #inside)
	end
	if bool(a.IsLocal) then
		local set = {}
		for _, p in ipairs(inside) do
			set[p.Id] = true
		end
		for _, id in ipairs(self.Order) do
			self:setClientVar(self.Players[id], a.Variable, set[id] and 1 or 0)
		end
	end
	self:setVar(a.AllPlayersInZoneVariable, (total > 0 and #inside == total) and 1 or 0)
	self:setVar(a.PlayersOutsideZoneVariable, total - #inside)
end

function Sim:refreshRoom(prop)
	local a = prop.Attrs
	-- [P] an inactive room trigger FREEZES (it neither counts nor clears): the maps gate rooms with `!TheirOwnVariable`
	-- so that the first entry latches; clearing on inactive would flip it straight back.
	if not (self:flag(a.Active, true) and self:spawned(prop)) then
		return
	end
	local inside, total = self:census(prop, Sim.inRoom)
	self:setVar(a.PlayersInRoomVariable, #inside)
	if #inside > 0 then
		self:setVar(a.HadPlayerInRoomVariable, 1)
	end
	self:setVar(a.AllPlayersInRoomVariable, (total > 0 and #inside == total) and 1 or 0)
	if not isBlank(a.ClientInRoomVariable) then
		local set = {}
		for _, p in ipairs(inside) do
			set[p.Id] = true
		end
		for _, id in ipairs(self.Order) do
			self:setClientVar(self.Players[id], a.ClientInRoomVariable, set[id] and 1 or 0)
		end
	end
end

function Sim:secure(prop, player)
	local a = prop.Attrs
	local required = names(a.ItemRequired)
	local ok = #required == 0
	for _, item in ipairs(required) do
		if self:find(player, item) then
			ok = true
		end
	end
	if ok then
		self:setVar(a.ItemSecuredVariable, 1)
	end
	for i = 0, 2 do
		local alt = a["AltItem" .. i]
		if not isBlank(alt) and self:find(player, alt) then
			self:setVar(a["AltItem" .. i .. "Variable"], 1)
		end
	end
end

function Sim:refreshEnd(prop)
	local a = prop.Attrs
	if not (self:flag(a.Active, true) and self:spawned(prop)) then
		return
	end
	local inside, total = self:census(prop, Sim.inZone)
	if #inside == 0 then
		return
	end
	-- [P] OpenForAll false: players leave only once every live player is in the zone
	if not (self:flag(a.OpenForAll, true) or #inside == total) then
		return
	end
	for _, p in ipairs(inside) do
		self:secure(prop, p)
		p.Exited = true
		self.ExitedCount += 1
		self:incVar(a.PlayersExitedVariable)
		self:emit("Exit", prop, p, { Exited = self.ExitedCount })
	end
	if self.ManageBuiltins then
		self.Logic:set("Mission_PlayersInGame", #self:livePlayers())
	end
end

local REFRESH = { TriggerZone = Sim.refreshZone, TriggerRoom = Sim.refreshRoom, MissionEndZone = Sim.refreshEnd }

-- Recount every zone, room and end zone (after a move, an exit, or an Active change).
local MAX_REFRESH_PASSES = 24 -- [P]

function Sim:refresh()
	if self.Refreshing then
		self.Dirty = true
		return
	end
	self.Refreshing = true
	-- A map can contain a zone whose output feeds back into its own state (The Peacemaker's Floors/PlayerLocator/TriggerZone
	-- flips while a player stands in some spots), which never settles. Like a game frame, stop after MaxRefreshPasses and let the
	-- next refresh carry on: such a loop then advances one step per call instead of hanging the host.
	local passes = 0
	repeat
		passes += 1
		self.Dirty = false
		for _, prop in ipairs(self.All) do
			local fn = REFRESH[prop.Kind]
			if fn then
				fn(self, prop)
			end
		end
	until not self.Dirty or passes >= MAX_REFRESH_PASSES
	self.Refreshing = false
	self.Logic:replicate()
end

--------------------------------------------------------------------------------------------------- interaction

local function fail(reason)
	return false, reason
end

function Sim:visibleTo(prop, player)
	local a = prop.Attrs
	return self:spawned(prop) and self:flag(a.ServerVisible, true) and self:clientFlag(player, a.ClientVisible, true)
end

function Sim:hasTool(player, spec)
	if isBlank(spec) then
		return true
	end
	for _, item in ipairs(names(spec)) do
		if self:find(player, item) then
			return true
		end
	end
	return false
end

function Sim:freeTrigger(prop, player, held)
	local a = prop.Attrs
	if not self:visibleTo(prop, player) then
		return fail("not-visible")
	end
	if not self:flag(a.ServerEnabled, true) then
		return fail("disabled")
	end
	if not self:hasTool(player, a.Tool) then
		return fail("missing-tool")
	end
	local need = bool(a.TapTrigger) and 0 or (tonumber(a.HoldTime) or 0.5)
	if held ~= nil and held + EPS < need then
		return fail("too-short")
	end
	if not isBlank(a.SetVariable) then
		local v = 1
		if not isBlank(a.SetValue) then
			v = self.Logic:eval(a.SetValue) or 1
		end
		self:setVar(a.SetVariable, v)
	end
	self:incVar(a.IncrementVariable)
	if not isBlank(a.SetClientVariable) then
		self:setClientVar(player, a.SetClientVariable, isBlank(a.SetValue) and 1 or (player.Replica:eval(a.SetValue) or 1))
	end
	if not isBlank(a.IncrementClientVariable) then
		self:setClientVar(player, a.IncrementClientVariable, (tonumber(player.Replica:get(a.IncrementClientVariable)) or 0) + 1)
	end
	self.Logic:replicate()
	self:emit("Interact", prop, player)
	self:refresh()
	return true
end

function Sim:deposit(prop, player)
	local a = prop.Attrs
	if not self:visibleTo(prop, player) then
		return fail("not-visible")
	end
	if not self:clientFlag(player, a.ClientEnabled, true) then
		return fail("disabled")
	end
	local want = not isBlank(a.ItemTagForDeposit) and a.ItemTagForDeposit or (not isBlank(a.Item) and a.Item or nil)
	if want then
		local it, index = self:find(player, want)
		if not it then
			return fail("missing-tool")
		end
		table.remove(player.Items, index)
	end
	self:setVar(a.DepositedVariable, 1)
	self:emit("Deposit", prop, player, { Item = want })
	self:refresh()
	return true
end

function Sim:pickup(id, prop)
	prop = self:prop(prop)
	local player = self.Players[id]
	if not (player and prop and prop.Kind == "ItemSpawn") then
		return fail("bad-target")
	end
	local a = prop.Attrs
	if prop.Picked then
		return fail("gone")
	end
	if not self:spawned(prop) then
		return fail("not-spawned")
	end
	local after = tonumber(a.InitialPickupTime) or 0
	if self.Logic.Time + EPS < after then
		return fail("too-early")
	end
	if not self:flag(a.PickupCondition, true) then
		return fail("not-allowed")
	end
	prop.Picked = true
	for _, name in ipairs(names(a.Item, "[^,]+")) do
		self:give(id, name:match("^%s*(.-)%s*$"), not isBlank(a.ItemTagString) and a.ItemTagString or nil, bool(a.KeyItem))
	end
	self:setVar(a.ItemRemovedVariable, 1)
	self:emit("Pickup", prop, player, { Item = a.Item })
	self:refresh()
	return true
end

-- A held interaction on a FreeTrigger or ItemDeposit. `held` = seconds the button was held (nil = long enough).
function Sim:interact(id, prop, held)
	prop = self:prop(prop)
	local player = self.Players[id]
	if not (player and prop) or player.Exited then
		return fail("bad-target")
	end
	if prop.Kind == "FreeTrigger" then
		return self:freeTrigger(prop, player, held)
	elseif prop.Kind == "ItemDeposit" then
		return self:deposit(prop, player)
	elseif prop.Kind == "ItemSpawn" then
		return self:pickup(id, prop)
	end
	return fail("not-interactable")
end

--------------------------------------------------------------------------------------------------- doors and readers

-- Which side of the door is a player on? Roblox LookVector is -Z of the door's frame. [P] "front" = on the LookVector side.
function Sim:sideOf(door, player)
	door = self:prop(door)
	local f = door.Frame
	local dx, dy, dz = player.Pos[1] - f[1], player.Pos[2] - f[2], player.Pos[3] - f[3]
	local lx, ly, lz = -f[6], -f[9], -f[12]
	return (dx * lx + dy * ly + dz * lz) >= 0 and "front" or "back"
end

function Sim:doorLockReason(door, side)
	local a = door.Attrs
	if self:flag(a.Blocked, false) then
		return "blocked"
	end
	if bool(a.Jammed) then
		return "jammed"
	end
	if self:flag(a.RemoteUnlock, false) or self:flag(a.FailsafeUnlock, false) then
		return nil
	end
	local lockExpr = a.LockBack
	if side == "front" then
		lockExpr = a.LockFront
	end
	if door.AutoLocked or self:flag(lockExpr, false) then
		return "locked"
	end
	return nil
end

function Sim:isLocked(door, side)
	door = self:prop(door)
	return self:doorLockReason(door, side or "front") == "locked"
end

function Sim:openDoor(id, door, side)
	door = self:prop(door)
	local player = self.Players[id]
	if not (player and door and door.Kind == "Door") then
		return fail("bad-target")
	end
	if door.Open then
		return true
	end
	side = side or self:sideOf(door, player)
	local reason = self:doorLockReason(door, side)
	if reason == "locked" and self:hasTool(player, door.Attrs.Access) and not isBlank(door.Attrs.Access) then
		reason = nil -- a key from `Access` opens a locked door
	end
	if reason then
		self:emit("DoorDenied", door, player, { Reason = reason })
		return fail(reason)
	end
	door.Open = true
	self:setVar(door.Attrs.OpenVariable, 1)
	self:incVar(door.Attrs.OpenIncrementVariable)
	self:emit("DoorOpen", door, player)
	return true
end

function Sim:closeDoor(door)
	door = self:prop(door)
	if not (door and door.Kind == "Door") or not door.Open then
		return false
	end
	door.Open = false
	self:setVar(door.Attrs.OpenVariable, 0)
	if self:flag(door.Attrs.AutoLock, false) then
		door.AutoLocked = true -- [P] an AutoLock door locks itself when it closes; RemoteUnlock / Access still open it
	end
	self:emit("DoorClose", door, nil)
	return true
end

function Sim:swipe(id, reader, card)
	reader = self:prop(reader)
	local player = self.Players[id]
	if not (player and reader and reader.Kind == "CardReader") then
		return fail("bad-target")
	end
	local a = reader.Attrs
	if not self:flag(a.PowerArea, true) then
		return fail("no-power")
	end
	if self:flag(a.Blocked, false) then
		return fail("blocked")
	end
	if not self:find(player, card) then
		return fail("no-card")
	end
	local valid = names(a.ValidCards)
	local ok = false
	if #valid > 0 then
		for _, v in ipairs(valid) do
			if lower(v) == lower(card) then
				ok = true
			end
		end
	else
		ok = (CARD_LEVEL[card] or 0) >= (CARD_LEVEL[a.MinimumCard] or 0)
	end
	if not ok then
		self:emit("SwipeDenied", reader, player, { Card = card })
		return fail("wrong-card")
	end
	self:setVar(a.TriggerVariable, 1) -- [P] a successful swipe latches the variable; the map's own logic resets it if it wants
	self:emit("Swipe", reader, player, { Card = card })
	return true
end

--------------------------------------------------------------------------------------------------- build

local function collect(logic, root, warn)
	local out = {}
	local function walk(node, ok, path)
		for _, ch in ipairs(node.Children or {}) do
			local childOk = ok
			if ch.ClassName ~= "Part" and ch.ClassName ~= "MeshPart" then
				if ch.Name == "Disabled" then
					childOk = false
				else
					local cond = ch.Attrs and ch.Attrs.Condition
					if cond ~= nil and not isBlank(cond) then
						local v = logic:eval(cond)
						if v == nil then
							warn((ch.Path or ch.Name) .. ".Condition", "could not evaluate; treated as false")
						end
						childOk = ok and truthyValue(v)
					end
				end
			end
			if childOk and (ch.ClassName == "Part" or ch.ClassName == "MeshPart") then
				out[#out + 1] = ch
			end
			walk(ch, childOk)
		end
	end
	walk(root, true)
	return out
end

local function newProp(sim, node)
	local kind = KIND_BY_NAME[node.Name]
	if not kind and isDoorName(node.Name) then
		kind = "Door"
	end
	if not kind then
		return nil
	end
	local frame = frameOf(node)
	local sx, sy, sz = sizeOf(node)
	local prop = {
		Kind = kind, Node = node, Name = node.Name, Path = node.Path or node.Name, Id = node.Id, Attrs = node.Attrs or {},
		Tag = node.Attrs and node.Attrs.Tag, Frame = frame, SX = sx, SY = sy, SZ = sz,
	}
	if frame then
		prop.Inverse = CF.inverse(frame)
		if kind == "TriggerRoom" and sim.World then
			prop.Cell = sim.World:cellAt(frame[1], frame[2], frame[3])
		end
	end
	return prop
end

-- nodes: an array of mission nodes ({ Name, ClassName, Path, Id, Attrs, Props = { CFrame, Size } }).
function Props.fromNodes(nodes, world, logic, opts)
	opts = opts or {}
	local sim = setmetatable({
		Logic = logic, World = world, Players = {}, Order = {}, All = {}, Unsupported = {}, Warnings = {}, ExitedCount = 0,
		ManageBuiltins = opts.manageBuiltins ~= false,
	}, Sim)
	for _, node in ipairs(nodes) do
		local prop = newProp(sim, node)
		if prop then
			if (prop.Kind == "TriggerZone" or prop.Kind == "MissionEndZone") and not prop.Frame then
				sim.Warnings[#sim.Warnings + 1] = { Where = prop.Path, Message = "no CFrame; the zone can never contain a player" }
			else
				sim.All[#sim.All + 1] = prop
			end
		else
			sim.Unsupported[node.Name] = (sim.Unsupported[node.Name] or 0) + 1
		end
	end
	-- Active changes recount (zones/rooms/end zones are gated by an expression); locks keep their LockedVariable up to date
	for _, prop in ipairs(sim.All) do
		local a = prop.Attrs
		if prop.Kind == "TriggerZone" or prop.Kind == "TriggerRoom" or prop.Kind == "MissionEndZone" then
			if not isBlank(a.Active) then
				logic:watch(a.Active, function()
					sim:refresh()
				end, prop.Path .. ".Active")
			end
			if not isBlank(a.IsSpawned) then
				logic:watch(a.IsSpawned, function()
					sim:refresh()
				end, prop.Path .. ".IsSpawned")
			end
		elseif prop.Kind == "Door" and not isBlank(a.LockedVariable) then
			local lf = isBlank(a.LockFront) and "0" or tostring(a.LockFront)
			local lb = isBlank(a.LockBack) and "0" or tostring(a.LockBack)
			local remote = isBlank(a.RemoteUnlock) and "0" or tostring(a.RemoteUnlock)
			logic:watch(("((%s) || (%s)) && !(%s)"):format(lf, lb, remote), function(v)
				sim:setVar(a.LockedVariable, truthyValue(v) and 1 or 0)
			end, prop.Path .. ".LockedVariable")
		end
	end
	logic:settle()
	return sim
end

function Props.new(mission, world, logic, opts)
	local root = mission:folder("Props")
	if not root then
		return nil, "BreachProps: the mission has no Props folder"
	end
	local warnings = {}
	local nodes = collect(logic, root, function(where, msg)
		warnings[#warnings + 1] = { Where = where, Message = msg }
	end)
	local sim = Props.fromNodes(nodes, world, logic, opts)
	for _, w in ipairs(warnings) do
		sim.Warnings[#sim.Warnings + 1] = w
	end
	return sim
end

-- Counts for reports and tests.
function Sim:summary()
	local kinds, n = {}, 0
	for _, p in ipairs(self.All) do
		kinds[p.Kind] = (kinds[p.Kind] or 0) + 1
		n += 1
	end
	local unsupported = 0
	for _, c in pairs(self.Unsupported) do
		unsupported += c
	end
	return { Props = n, Kinds = kinds, Unsupported = unsupported, Players = #self.Order, Exited = self.ExitedCount, Warnings = #self.Warnings }
end

return Props
