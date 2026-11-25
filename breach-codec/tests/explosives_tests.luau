--!nonstrict
-- M9e (grenades and C4) tests: BreachExplosives. Run via tests/run.luau or alone: `luau tests/explosives.luau`
local Explosives = require("../BreachExplosives")

local DT = 0.05

return function(check)
	local function kinds(evs, kind) local out = {} for _, e in ipairs(evs) do if kind == nil or e.Kind == kind then out[#out + 1] = e end end return out end

	-- a tiny world: players and bots are tables the test moves around
	local function world(opts)
		opts = opts or {}
		local W = { players = {}, bots = {}, pdmg = {}, bdmg = {} }
		W.playersFn = function() return W.players end
		W.botsObj = {
			all = function() return W.bots end,
			position = function(_, id) for _, b in ipairs(W.bots) do if b.Id == id then return b.X, b.Y, b.Z end end end,
		}
		W.ex = Explosives.new({
			players = W.playersFn, bots = W.botsObj,
			damagePlayer = function(id, amount, by) W.pdmg[#W.pdmg + 1] = { Id = id, Damage = amount, By = by } end,
			damageBot = function(id, amount, by) W.bdmg[#W.bdmg + 1] = { Id = id, Damage = amount, By = by } end,
		}, opts)
		W.run = function(seconds) for _ = 1, math.floor(seconds / DT + 0.5) do W.ex:step(DT) end end
		return W
	end

	do -- the grenade fuse
		local W = world()
		W.players[1] = { Id = "p1", X = 0, Y = 0, Z = 0 }
		local id = W.ex:throwGrenade({ Kind = "Bot", Id = "g1" }, 0, 0, 0)
		check("grenade: throwing it reports GrenadeThrown", #kinds(W.ex:drainEvents(), "GrenadeThrown") == 1 and id == 1)
		W.run(1.9)
		check("grenade: it has not gone off before the fuse (2 s)", #kinds(W.ex:drainEvents(), "Explosion") == 0 and #W.ex:active() == 1)
		W.run(0.2)
		local evs = W.ex:drainEvents()
		check("grenade: it explodes once the fuse is over, and is gone", #kinds(evs, "Explosion") == 1 and #W.ex:active() == 0)
		check("grenade: the explosion carries its radius", kinds(evs, "Explosion")[1].Radius == 5 and kinds(evs, "Explosion")[1].Type == "Grenade")
	end

	do -- damage falls off linearly to nothing at the edge
		local W = world()
		for i, x in ipairs({ 0, 2.5, 4.9, 5, 6 }) do W.players[i] = { Id = "p" .. i, X = x, Y = 0, Z = 0 } end
		W.ex:throwGrenade({ Kind = "Bot", Id = "g1" }, 0, 0, 0)
		W.run(2.1)
		local byId = {}
		for _, d in ipairs(W.pdmg) do byId[d.Id] = d.Damage end
		check("grenade: 60 damage at the centre", byId.p1 and math.abs(byId.p1 - 60) < 1e-9, byId.p1)
		check("grenade: half way (2.5 of 5) it is 30", byId.p2 and math.abs(byId.p2 - 30) < 1e-9, byId.p2)
		check("grenade: just inside the edge it is almost nothing", byId.p3 and byId.p3 > 0 and byId.p3 < 1.3, byId.p3)
		check("grenade: at the edge and beyond nothing happens", byId.p4 == nil and byId.p5 == nil)
		check("grenade: ExplosionHit is reported per player", #kinds(W.ex:drainEvents(), "ExplosionHit") == 3)
		check("grenade: the damage call carries who did it", W.pdmg[1].By == "g1")
	end

	do -- who is hurt
		local W = world()
		W.players[1] = { Id = "p1", X = 1, Y = 0, Z = 0 }
		W.bots[1] = { Id = "b1", State = "Idle", Flags = {}, X = 1, Y = 0, Z = 0 }
		W.bots[2] = { Id = "b2", State = "Dead", Flags = {}, X = 1, Y = 0, Z = 0 }
		W.bots[3] = { Id = "b3", State = "Idle", Flags = { Incapacitated = true }, X = 1, Y = 0, Z = 0 }
		W.ex:throwGrenade({ Kind = "Bot", Id = "g1" }, 0, 0, 0)
		W.run(2.1)
		check("grenade: a guard's grenade hurts players, not guards (no friendly fire)", #W.pdmg == 1 and #W.bdmg == 0)
		local W2 = world()
		W2.players[1] = { Id = "p1", X = 1, Y = 0, Z = 0 }
		W2.bots[1] = { Id = "b1", State = "Idle", Flags = {}, X = 1, Y = 0, Z = 0 }
		W2.bots[2] = { Id = "b2", State = "Dead", Flags = {}, X = 1, Y = 0, Z = 0 }
		W2.bots[3] = { Id = "b3", State = "Idle", Flags = { Incapacitated = true }, X = 1, Y = 0, Z = 0 }
		W2.ex:throwGrenade({ Kind = "Player", Id = "p1" }, 0, 0, 0)
		W2.run(2.1)
		check("grenade: a player's grenade hurts the living guards only", #W2.bdmg == 1 and W2.bdmg[1].Id == "b1" and #W2.pdmg == 0)
		local W3 = world({ params = { FriendlyFire = true } })
		W3.players[1] = { Id = "p1", X = 1, Y = 0, Z = 0 }
		W3.bots[1] = { Id = "b1", State = "Idle", Flags = {}, X = 1, Y = 0, Z = 0 }
		W3.ex:throwGrenade({ Kind = "Bot", Id = "b9" }, 0, 0, 0)
		W3.run(2.1)
		check("grenade: with FriendlyFire on, both are hurt", #W3.pdmg == 1 and #W3.bdmg == 1)
		local W4 = world()
		W4.players[1] = { Id = "p1", X = 0, Y = 0, Z = 0 }
		W4.ex:throwGrenade({ Kind = "Bot", Id = "g1" }, 0, 0, 0, 0.5)
		W4.run(2.1)
		check("grenade: a damage scale (class DamageOutput) multiplies the damage", W4.pdmg[1] and math.abs(W4.pdmg[1].Damage - 30) < 1e-9)
	end

	do -- C4: arm at 3 s, detonate at 8 s
		local W = world()
		W.players[1] = { Id = "p1", X = 0, Y = 0, Z = 4 }
		W.ex:plantC4({ Kind = "Bot", Id = "h1" }, 0, 0, 0)
		check("c4: planting reports C4Planted, not yet armed", #kinds(W.ex:drainEvents(), "C4Planted") == 1 and W.ex:active()[1].Armed == false)
		W.run(2.9)
		check("c4: not armed before 3 s", #kinds(W.ex:drainEvents(), "C4Armed") == 0)
		W.run(0.2)
		check("c4: armed after 3 s, once", #kinds(W.ex:drainEvents(), "C4Armed") == 1 and W.ex:active()[1].Armed == true)
		W.run(4.8)
		check("c4: still there before 8 s", #W.ex:active() == 1 and #W.pdmg == 0)
		W.run(0.3)
		check("c4: detonates 8 s after it was planted", #W.ex:active() == 0 and #W.pdmg == 1)
		check("c4: 120 at the centre falling linearly over radius 8 (4 studs away: 60)", math.abs(W.pdmg[1].Damage - 60) < 1e-9, W.pdmg[1].Damage)
	end

	do -- disarming
		local W = world()
		W.players[1] = { Id = "p1", X = 1, Y = 0, Z = 0 }
		local id = W.ex:plantC4({ Kind = "Bot", Id = "h1" }, 0, 0, 0)
		check("disarm: an unknown C4 is refused", select(2, W.ex:startDisarm("p1", 999)) == "NoSuchC4")
		check("disarm: an unknown player is refused", select(2, W.ex:startDisarm("nobody", id)) == "Gone")
		W.players[1].X = 10
		check("disarm: too far away is refused", select(2, W.ex:startDisarm("p1", id)) == "TooFar")
		W.players[1].X = 1
		check("disarm: in range it starts", W.ex:startDisarm("p1", id) == true and #kinds(W.ex:drainEvents(), "C4DisarmStarted") == 1)
		W.run(1.4)
		check("disarm: it takes 1.5 s: not done at 1.4", #W.ex:active() == 1)
		W.run(0.2)
		local evs = W.ex:drainEvents()
		check("disarm: done after 1.5 s: C4Disarmed and the C4 is gone", #kinds(evs, "C4Disarmed") == 1 and #W.ex:active() == 0)
		W.run(10)
		check("disarm: a disarmed C4 never goes off", #W.pdmg == 0 and #kinds(W.ex:drainEvents(), "Explosion") == 0)

		local W2 = world()
		W2.players[1] = { Id = "p1", X = 1, Y = 0, Z = 0 }
		local id2 = W2.ex:plantC4({ Kind = "Bot", Id = "h1" }, 0, 0, 0)
		W2.ex:startDisarm("p1", id2)
		W2.run(1.0)
		W2.players[1].X = 20
		W2.run(0.1)
		local evs2 = W2.ex:drainEvents()
		check("disarm: walking away cancels it", #kinds(evs2, "C4DisarmCancelled") == 1 and kinds(evs2, "C4DisarmCancelled")[1].Why == "TooFar")
		W2.players[1].X = 1
		W2.ex:startDisarm("p1", id2)
		W2.run(1.4)
		check("disarm: a new attempt starts from zero", #W2.ex:active() == 1)
		W2.run(0.2)
		check("disarm: ... and can still finish", #W2.ex:active() == 0)

		local W3 = world()
		W3.players[1] = { Id = "p1", X = 1, Y = 0, Z = 0 }
		local id3 = W3.ex:plantC4({ Kind = "Bot", Id = "h1" }, 0, 0, 0)
		W3.run(7.0)
		W3.ex:startDisarm("p1", id3)
		W3.run(1.1)
		check("disarm: too late (the C4 goes off at 8 s before 1.5 s are up)", #W3.pdmg == 1)
	end

	do -- ids, order, determinism
		local function trace()
			local W = world()
			W.players[1] = { Id = "p1", X = 1, Y = 0, Z = 0 }
			W.ex:throwGrenade({ Kind = "Bot", Id = "g1" }, 0, 0, 0)
			W.ex:plantC4({ Kind = "Bot", Id = "h1" }, 2, 0, 0)
			W.ex:throwGrenade({ Kind = "Bot", Id = "g2" }, 1, 0, 1)
			W.run(9)
			local t = {}
			for _, e in ipairs(W.ex:drainEvents()) do t[#t + 1] = e.Kind .. "@" .. string.format("%.2f", e.Time) .. ":" .. tostring(e.Id or "") end
			return table.concat(t, "|"), #W.pdmg
		end
		local a, na = trace()
		local b = trace()
		check("explosives: two runs give the same events", a == b and na == 3, na)
		local W = world()
		local i1, i2 = W.ex:throwGrenade("x", 0, 0, 0), W.ex:plantC4("x", 0, 0, 0)
		check("explosives: ids count up and active() lists them in order", i1 == 1 and i2 == 2 and W.ex:active()[1].Kind == "Grenade" and W.ex:active()[2].Kind == "C4")
	end
end
