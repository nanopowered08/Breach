--!nonstrict
--[==[
	BreachTrespass — is this player allowed here, and who minds? (BreachEngine M8c, part 2; plan §5).

	Pure Luau, deterministic, no Roblox APIs. Built on the MissionSetup `Cells` table (BreachSetup), the world's cells, a
	logic core (for the `{expression}` rules) and BreachSight (who has noticed whom). It produces a STATUS and EVENTS; what the
	game does about them (warnings, alarm) is the alert layer.

	    local tr = Trespass.new(world, setupTable, logic)             -- setupTable = Setup.parse(mission.SetupSource)
	    tr:ruleName(cell) / tr:rulesFor(cell) -> name, rules          -- resolves {expression} rule strings
	    tr:status(disguise, cell) -> "allowed" | "minor" | "major", ruleName, rules
	    tr:enforces(botClass, status, rules) -> bool
	    tr:step(dt)    tr:statusOf(playerId)    tr:witnesses(playerId)    tr:drainEvents()
	    -- TrespassStatus (a player's status changed)   TrespassWitnessed (an enforcing bot has noticed a trespassing player)
	    -- TrespassCleared (the witness lost the player, or the player is no longer trespassing)

	How a cell gets its rules  [O]: a cell part is NAMED after a rule set in `Cells` (55/55, 90/90, 75/75 in the real maps).
	A rule set is a table { Allow, Trespass, MinorTrespass, Enforce, EnforceMinor }, or a `{expression}` string whose value (a
	string literal such as [Vault]) is the name of another rule set, evaluated live (e.g. {KeycardPlaced && [ServerRoomAwesome]
	|| [ServerRoomEvil]}). Names are matched without regard to case. A cell with no rule set uses `Default`, else is public.
	Status of a player wearing disguise D ("None" when none) in a cell:   [P for the combination]
	    Allow[D]                       -> allowed
	    Trespass, or MinorTrespass[D]  -> minor if MinorTrespass[D] else major
	    otherwise                      -> allowed
	Who minds [O names, P rule]: a MAJOR trespass is enforced by bots whose Class is in Enforce, a MINOR one by Class in
	EnforceMinor. A bot "witnesses" it when it has NOTICED the player (BreachSight) while the status is not allowed.
]==]

local Trespass = {}
Trespass.VERSION = "0.1.0"

local MAX_DEPTH = 4

local function lower(s)
	return tostring(s):lower()
end

local function lowerKeys(t)
	local out = {}
	if type(t) == "table" then
		for k, v in pairs(t) do
			out[lower(k)] = v
		end
	end
	return out
end

local function truthy(v)
	return v ~= nil and v ~= false and v ~= 0 and v ~= ""
end

local Sim = {}
Sim.__index = Sim

function Trespass.new(world, setup, logic, opts)
	opts = opts or {}
	local self = setmetatable({
		World = world, Logic = logic, Cells = lowerKeys(setup and setup.Cells), Sight = opts.sight, Bots = opts.bots,
		PlayersFn = opts.players, Events = {}, Players = {}, Witness = {}, Time = 0, Errors = {},
	}, Sim)
	return self
end

-- Wire the live parts after construction (so tests and hosts can build them in any order).
function Sim:attach(sight, bots, playersFn)
	self.Sight, self.Bots, self.PlayersFn = sight, bots, playersFn
end

local function cellName(cell)
	if cell == nil then
		return nil
	end
	if type(cell) == "string" then
		return cell
	end
	if cell.Node and cell.Node.Name then
		return cell.Node.Name
	end
	return cell.Name
end

-- name, rules (a table), or nil when the cell is public (no rules at all)
function Sim:rulesFor(cell)
	local name = cellName(cell)
	local seen = 0
	local entry = name and self.Cells[lower(name)]
	if entry == nil then
		entry = self.Cells["default"]
		name = entry and "Default" or name
	end
	while type(entry) == "string" do
		seen += 1
		if seen > MAX_DEPTH then
			self.Errors[#self.Errors + 1] = "rule chain too deep at '" .. tostring(name) .. "'"
			return name, nil
		end
		local inner = entry:match("^%s*{(.*)}%s*$")
		local target
		if inner and self.Logic then
			local v, err = self.Logic:eval(inner)
			if v == nil then
				self.Errors[#self.Errors + 1] = "cannot evaluate rule '" .. entry .. "': " .. tostring(err)
				return name, nil
			end
			target = tostring(v)
		else
			target = entry
		end
		name = target
		entry = self.Cells[lower(target)]
	end
	if type(entry) == "table" then
		return name, entry
	end
	return name, nil
end

function Sim:ruleName(cell)
	return (self:rulesFor(cell))
end

local function has(set, key)
	if type(set) ~= "table" then
		return false
	end
	local k = lower(key)
	for name, v in pairs(set) do
		if lower(name) == k and truthy(v) then
			return true
		end
	end
	return false
end

-- status, ruleName, rules
function Sim:status(disguise, cell)
	local name, rules = self:rulesFor(cell)
	if not rules then
		return "allowed", name, nil
	end
	local d = (disguise == nil or disguise == "") and "None" or disguise
	if has(rules.Allow, d) then
		return "allowed", name, rules
	end
	local minor = has(rules.MinorTrespass, d)
	if truthy(rules.Trespass) or minor then
		return minor and "minor" or "major", name, rules
	end
	return "allowed", name, rules
end

function Sim:enforces(botClass, status, rules)
	if not rules or botClass == nil or botClass == "" then
		return false
	end
	if status == "major" then
		return has(rules.Enforce, botClass)
	elseif status == "minor" then
		return has(rules.EnforceMinor, botClass)
	end
	return false
end

local function emit(self, kind, extra)
	local ev = { Kind = kind, Time = self.Time }
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

function Sim:statusOf(playerId)
	local st = self.Players[playerId]
	return st and st.Status or "allowed", st and st.Rule, st and st.Cell
end

function Sim:witnesses(playerId)
	local out = {}
	for key, w in pairs(self.Witness) do
		if w.Player == playerId then
			out[#out + 1] = w.Bot
		end
	end
	table.sort(out)
	return out
end

function Sim:step(dt)
	self.Time += dt
	if not self.PlayersFn then
		return
	end
	local players = self.PlayersFn()
	local byId = {}
	for _, pl in ipairs(players) do
		byId[pl.Id] = pl
		local st = self.Players[pl.Id]
		if not st then
			st = { Status = "allowed" }
			self.Players[pl.Id] = st
		end
		local status, rule, rules, cell = "allowed", nil, nil, nil
		if not pl.Exited and self.World and self.World.cellAt then
			cell = self.World:cellAt(pl.X, pl.Y, pl.Z)
			if cell then
				status, rule, rules = self:status(pl.Disguise, cell)
			end
		end
		st.Rules, st.Cell = rules, cell
		if status == "allowed" then
			st.Rule = rule
		end
		local changed = status ~= st.Status or (status ~= "allowed" and rule ~= st.Rule)
		if changed then
			local before = st.Status
			st.Status, st.Rule = status, rule
			emit(self, "TrespassStatus", { Player = pl.Id, Status = status, Before = before, Rule = rule, Disguise = (pl.Disguise == nil or pl.Disguise == "") and "None" or pl.Disguise })
		end
	end
	-- witnesses: an enforcing bot that has NOTICED a trespassing player
	if self.Sight and self.Bots then
		for _, bot in ipairs(self.Bots:all()) do
			for _, pl in ipairs(players) do
				local st = self.Players[pl.Id]
				local key = bot.Id .. "|" .. pl.Id
				local noticed = self.Sight:isNoticedBy(bot.Id, pl.Id)
				local should = noticed and st and st.Status ~= "allowed" and not pl.Exited and self:enforces(bot.Class, st.Status, st.Rules)
				local w = self.Witness[key]
				if should and not w then
					self.Witness[key] = { Bot = bot.Id, Player = pl.Id, Status = st.Status }
					emit(self, "TrespassWitnessed", { Player = pl.Id, Bot = bot.Id, Status = st.Status, Rule = st.Rule, BotClass = bot.Class })
				elseif w and not should then
					self.Witness[key] = nil
					emit(self, "TrespassCleared", { Player = pl.Id, Bot = bot.Id, Status = st.Status })
				elseif w and should and w.Status ~= st.Status then
					w.Status = st.Status
					emit(self, "TrespassWitnessed", { Player = pl.Id, Bot = bot.Id, Status = st.Status, Rule = st.Rule, BotClass = bot.Class })
				end
			end
		end
	end
end

return Trespass
