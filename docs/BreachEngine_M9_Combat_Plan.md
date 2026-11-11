# BreachEngine — M9 plan: Combat

| | |
|---|---|
| **Status** | Plan, not code. For the owner to approve and tune. Written against docs v0.24, M8 complete (1571 tests) and a survey of *The Blacksite* pre-release |
| **Evidence tags** | **[O]** observed in map data · **[Play]** observed in play by the owner: **a requirement** · **[P]** a guess, to be tuned by the owner (all numbers below are [P] unless tagged otherwise) |
| **Goal** | Lockdown that feels realistic: guards that search before they attack, hostage tricks that work, and a fight with grenades, C4 and bosses, without breaking missions written for InfiltrationEngine |

---

## 1. What we know

**[Play] Lockdown, from the owner**
- Living guards go to the nearest Meadow Map node and hold there.
- A guard near the player, or one just spawned, pathfinds to the player.
- Existing guards do not know where the player is until they hear a noise the player caused; then they look at the player.
- Some guards throw grenades. In The Blacksite some plant and detonate C4. Some are custom-spawned (a boss at the elevator once the player has wiped data off Halcyon's servers).
- The guard class decides who throws grenades, who plants C4, and who gets a health bar (health above 200).
- Some Blacksite guards spot concealed weapons.

**[O] The Blacksite pre-release (map data)**
- 19 `CombatSpawner` entries and 8 reinforcement pools (`StandardPool`, `DetentionCenterPool`, `ShredderPool`, `FinalePool`, ...), switched by globals such as `CombatPhase` and `CombatWaves`. Fields: `SpawnCap`, `TimeBetweenSpawns` (1 to 15 s), `SpawnTags`, `SpawnsBlockedVariable`.
- Each spawner lists `Weapon:Class` pairs, e.g. `K45:SteelCoveGrenadier`, `F57:SteelCoveHeavy`, `S97:SteelCoveBasic`, `Sawblade:SteelCoveShredder`.
- `CustomCombatData` (per bot or spawner): `DamageOutput`, `SlowCombat`, `IsHeavyUnit`, `NoBreachTactics`, `NoRushingTargets`, `HasGrenades`, `ForceHealthDisplay`, `TeamId`. The two Rose allies use `RoseCombatAI` with grenades off.
- `DetectConcealedWeapons` on 8 bot templates (`HighSecurityGuard`, `SteelCoveGuard`, `DoorGuard`, `TurretBoy`); value `SetAlarmedWithAlert`. `ConcealedWeaponDisguise = { TechnicalStaff = true }` in MissionSetup.
- Placed guards have `MaxHealth` 120.
- **Not in the data:** class health, which classes plant C4, grenade numbers. They live in the game engine, so BreachEngine needs its own class table (§4).

## 2. Divergence from InfiltrationEngine (on purpose)

**Two lockdown phases**, opt-in per mission (`MissionSetup.BreachLockdown = "TwoPhase"` [P]); the existing one-phase lockdown stays the default so every current map runs unchanged.

| Phase | Meaning | Guards do |
|---|---|---|
| **Lockdown (Searching)** | An incident happened (broken camera, found body, major trespass) but nobody knows who | Go to nearest Meadow node, sweep, investigate noise and anomaly points. Never know the player's position |
| **Lockdown (Attacking)** | A guard has **seen a weapon** (drawn, or concealed and detected) | Behaviour from §1: hunt, grenades, C4, reinforcements |

Attacking never falls back to Searching on its own. A map script may still write `Mission_AlertLevel` as today.

**Hostage pose** (Searching only, and only outside trespass cells): a player lying on the ground like a hostage is not treated as a threat. A guard who sees them goes over, helps them up (HoldTime 3 s [P]) and escorts them to a safe place; guards may first get suspicious and check (see Open). The escort result can carry into a later mission (a hook, not built in M9). In Attacking, or inside a trespass cell, a prone player is just a player.

## 3. Design

- **Awareness model**: each guard has `knowsPlayer` (a position and a timestamp). A noise inside hearing range sets it; sight with a weapon in view sets it; it decays after `LoseTrackSeconds` 20 [P]. Hearing range = `SoundTravelDistance` from MissionSetup (already parsed) [O], scaled per noise type: shot 1.0, door 0.3, footstep (sprint) 0.2 [P].
- **Weapon state on the player**: new `weapon = "holstered" | "drawn" | "concealed"` next to `Armed`, plus `stance = "lying"`. Seeing `drawn` = Attacking. `concealed` only triggers guards whose template has `DetectConcealedWeapons`, unless the player's disguise is in `ConcealedWeaponDisguise`, then it is safe from non-detectors [P]. Detection time reuses the BreachSight meter, ×2 slower for concealed [P].
- **Movement**: guards use the Meadow graph for "go to nearest node"; combat movement uses the separate named combat graph (`CombatMap`/`CombatFlowMap`, §13.13) where a map has one, otherwise Meadow. Reuse `BreachNav` followers, `Bots:command/hold/resume`.
- **Shooting**: hitscan with an accuracy that rises with time in sight: `hit chance = clamp(0.15 + 0.1 * seconds, 0.15, 0.6)` [P], damage = weapon damage × `DamageOutput` [O field, default 1.0]. Player health 100 [P].
- **Health bars**: a guard shows a bar iff `MaxHealth > 200` or `ForceHealthDisplay` [Play, O].

## 4. Class table (all guesses; the owner will tune)

| Class | Health | Grenades | Plants C4 | Notes |
|---|---|---|---|---|
| SteelCoveBasic | 120 [O placed guards] | no | no | default rifleman |
| SteelCoveHeavy | 250 | no | **yes** (guess) | `IsHeavyUnit`, health bar |
| SteelCoveGrenadier | 150 | yes, every 12 to 20 s, range 6 to 25 | no | throws from cover |
| SteelCoveShredder | 400 | no | no | `Sawblade`, melee rush, health bar |
| Bosses (custom spawned) | 800 | per spawner data | per spawner data | health bar |

`CustomCombatData` on a spawner or bot overrides the table (`HasGrenades`, `ForceHealthDisplay`, `DamageOutput`, ...). Unknown classes get the Basic row. The table is data in one place (`Combat.Classes`) so tuning is a one-line edit.

**Grenade**: fuse 2.0 s, radius 5, damage 60 at centre falling to 0 at the edge. **C4**: planted at a target, arm 3 s, detonation after 8 s, radius 8, damage 120; a player can disarm within 1.5 s [P].

## 5. Spawning and waves

- Parse `CombatSpawner`, `ReinforcementPool`, `LoudSpawns` into the model (M9.0). A spawner is active while its enabling variable (`CombatPhase`-style) is true and `SpawnsBlockedVariable` is false; it spawns every `TimeBetweenSpawns` up to `SpawnCap` alive, drawing `Weapon:Class` pairs from its pool, at `LoudSpawns` positions respecting `Range` (cell hops) and `IgnoreProximity` [R from the docs, §8.3].
- Custom spawns (the elevator boss) are `Bots:spawn` calls from the map's StateScript or `RandomBotSpawner`; nothing special, but they must accept a class and `CustomCombatData`.
- In Searching, reinforcements do not spawn. They start when Attacking begins [P].

## 5a. How it plugs into the existing engine
`BreachAlert` keeps the level 0..3 and gets the phase; `BreachSight` gets weapon detection and prone; `BreachBots` gets classes, health and the combat state; new module **`BreachCombat`** owns awareness, shooting, grenades, C4 and spawners; `BreachSession` adds `combat` to the step order after `alert` and before `hostage`; `BreachHostage` gets the pose and escort. Everything stays pure Luau, deterministic (seeded `BreachRandom`), and covered by the playthrough signature tests.

## 6. Milestones

| | Piece | Done when |
|---|---|---|
| **M9.0** *(done)* | Data model: parse `CombatSpawner`, `ReinforcementPool`, `LoudSpawns`, `CustomCombatData`, `DetectConcealedWeapons`; class table; real Blacksite data in local tests | every Blacksite spawner and pool parses, class lookup tests |
| **M9a** *(done, docs 8.3.3)* | Phase machine (Searching / Attacking), awareness, noise and weapon-seen events, opt-in switch. **Left for M9a.1**: concealed-weapon detection, camera and body incidents as Searching triggers | scripted scenarios: lockdown without a weapon stays Searching, drawn weapon in sight flips to Attacking *(done)* |
| **M9b** | Hostage pose: prone stance, trespass-cell check, guard helps up and escorts, escort event | pose works in Searching, fails in Attacking and in trespass cells |
| **M9c** *(done, docs 8.3.3)* | Combat movement: hold at nearest node, hunt, hearing, lose track | guards hold, then hunt only after noise or sight *(done)* |
| **M9d** *(done, docs 8.3.3: S97, 15 HP per magazine)* | Shooting, health, deaths, health-bar rule | determinism: same seed, same signature |
| **M9e** | Grenades and C4 | throw, fuse, damage falloff, plant, detonate, disarm |
| **M9f** | Spawners, waves, boss custom spawn | a Blacksite-style wave sequence over a fake clock |
| **M9g** | Session integration, playthroughs, docs 8.3.2, HANDOFF | suite green, signatures stable |

## 7. Open (the owner can answer later; defaults above until then)
1. Real class numbers (health, grenade timing, who plants C4).
2. Does a guard seeing a lying player check them first (suspicious pause), or help up straight away?
3. Which noises alert guards, and their ranges.
4. Whether Searching should have its own guard patterns (sweeps) or reuse existing patrol routes.
5. The safe-place destination and what carries over to the next mission.
