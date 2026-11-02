# BreachEngine — M8 plan: Bots

| | |
|---|---|
| **Status** | Plan, not code. Written against main doc v0.14 and the three real maps (The Diplomat, The Peacemaker, The Project) |
| **Evidence tags** | **[O]** observed in the real maps · **[R]** from the Mission Exporter docs · **[Play]** observed in play by the project owner: **a requirement**, the engine is built to match it (the data is used to find the wiring, not to overrule play) · **[P]** a proposal / my choice |
| **Goal** | Bots that patrol, see, get taken hostage, follow you without ever bumping you, and take part in the alt-interaction prompts the maps are built around |

---

## 1. What the data says (so the plan is not guesswork)

| | The Diplomat | The Peacemaker | The Project |
|---|---|---|---|
| Placed bots (`Bots/`) | 7 | 57 | 44 |
| `Behavior` | PatrolWalk 4, WorkWithBreaks 3 | PatrolWalk 47, WorkWithBreaks 10 | PatrolWalk 44 |
| Patrol routes (`Nodes/` folders → node parts) | 5 → 96 | 13 → 171 | 26 → 182 |
| Armed | 3 | 39 | 21 |
| `HostageDifficulty` | 2 ×4 | 1 ×2, 2 ×12, 3 ×22, 4 ×3 | 1 ×12, 3, 4 |

**[O]** What is *not* in the maps matters as much: **no `Bodyguard`, no `PassingCivilian`, and no `CustomBehavior` on any placed bot.** "Make a civilian follow you" is therefore not a map-authored behaviour in these three maps; it is an engine feature (a hostage you lead). `CustomBehavior` / `FOLLOW` exists only for `CustomBehaviorCondition` (3) and `AlarmedBehaviorOverride` (3) components.

**[O] `HostageDifficulty` is "how hard to subdue".** 0 for every civilian, employee and workshop worker (unarmed, non-security); 1–4 for armed security (BasicSecurity 1–3, ProSecurity 1–3, MercenarySecurity 1–4, mostly 3).

**[O] Bot interaction is a *trigger on a bot tag and a bot state*, not a touch.** `BotAltTrigger` has `AllowHostages`, `AllowPatroling`, `BotServerTag`/`BotClientTag`, `HoldTime`, `ClientVisible`/`ServerEnabled` expressions, `TitleKey`/`SubtitleKey`, `TriggerVariable`/`TriggerNotification`. `BodyAltTrigger` is the same for an incapacitated body. Real examples in The Project: a `LeadTech` hostage + `Action.UnlockPhone` / `UI.WithFingerprint` (biometric unlock, `ClientVisible = !PhoneUnlocked && ClientHoldingLockedPhone`); a hostage who `Action.RemindMe` of the alarm code. This matches how EPFC plays: lead the hostage to the thing, then use the alternate control that appears for that hostage.

**[O] Bots are counted by state, so states are first-class:** `BotStateTracker` (×10 in The Project) writes `HostageCountVariable`, `IncapacitationCountVariable`, `DeathCountVariable`, `FleeCountVariable`, `ClientKillCountVariable`, `TotalCountVariable` per `BotServerTag`.

**[O] Alert components:** `AlertRaiseCondition` ×7 (Project); `Amount`, `MinValue`, `MaxValue`, `Condition`, `Reason`. `Mission_AlarmRaised` / `Mission_AlertLevel` are the engine variables the maps read.

**[O] Trespass/disguise rules are data, not code.** `MissionSetup` (kept by the decoder as `SetupSource`, 30–116 KB) is a Luau chunk with **zero functions** in all three maps: constant tables and a `return { … }` with `Cells`, `EnforceClass`, `Combat`, `CustomDisguises`, … A data-only table parser is enough.

---

## 2. The follower problem (why Notoriety's civilians hit you, and how this design cannot)

In Notoriety a following civilian ends up *hitting* the player. The usual causes, and what this plan does about each:

| Cause | Typical bug | BreachEngine rule |
|---|---|---|
| Follower paths to the **player's own position** | arrives at distance 0, so it walks into you | Followers never target the leader. They target a **follow slot** (point on the leader's recent trail, `followDistance` behind) |
| Arrival radius ≈ 0 and no hysteresis | stop/start jitter, drifting forward | Stop at `stopDistance`, resume only beyond `resumeDistance` (> stop) |
| Physics collision between bot and player | the bot pushes or hits the player | Bots are **kinematic** and in a collision group that does not collide with players; "bumping" is impossible by construction, and is *also* prevented by the rules below so it does not look like clipping |
| Repathing every frame toward a moving target | zig-zag, cutting corners through the player | Follow the leader's **breadcrumb trail** (the same corridors and doors the player used); A* only when the trail breaks (teleport, lift, vault); path requests rate-limited |
| Speed not tied to the leader | overshoots, runs past you | follower speed is a smooth function of the gap and **capped at 1.15 × the leader's speed** |
| Narrow places | both try to pass at once | single file: follower waits until the leader has cleared the door/cell link |
| Leader turns around and walks into the follower | follower holds ground and gets hit | personal space: if the leader closes inside `yieldDistance`, the follower **backs along its trail** (yields), it does not hold or push |
| Stuck | teleports into view, or jitters forever | stuck detector → re-slot → if still stuck, move to the nearest trail point **behind and out of sight**; never a visible snap |

**Defaults [P]** (studs; a Roblox character walks 16 studs/s; all tunable, all in one table): `followDistance 6`, `stopDistance 5`, `resumeDistance 7.5`, `yieldDistance 3.5`, `minDistance 3` (the invariant below), `maxSpeedRatio 1.15`, `repathHz 2`, `trailSpacing 1.5`, `stuckSeconds 2`.

**Invariants the headless tests will assert** (movement is simulated at a fixed 20 Hz, no Roblox needed):

1. **I1** `distance(follower, leader) ≥ minDistance` at every tick after the first, *including when the leader reverses or stops suddenly*.
2. **I2** a stationary leader is never approached closer than `stopDistance`.
3. **I3** follower speed ≤ `maxSpeedRatio × leader speed` (plus a floor so it can start from rest).
4. **I4** at most `repathHz` path requests per second per follower.
5. **I5** on a real route (A* between real cells of all three maps), the follower reaches `followDistance ± 1.5` within `5 s` of the leader stopping.
6. **I6** several followers keep `separation` from each other and from the leader.
7. **I7** adversarial scripts: leader runs, stops, reverses, stands in a doorway, circles the follower, walks through the follower's slot; none violates I1–I6.

Movement is a separate module (`BreachNav`) from behaviour, so these tests exist before any bot AI does.

---

## 3. Hostages and the alt interaction

**Requirements from play [Play]** (the engine matches these; where I need a number, I choose a default and you correct it by feel):

- **Loud:** hostages **cannot be moved.**
- **Stealth:** hostages **can be moved**, but **flee if you do not draw a gun within about a minute.**
- Making a bot interact with something in EPFC/InfiltrationEngine: **make it follow you, then use the alternate control** that appears for it (e.g. `[F] Hostage — Use Biometric Lock` in The Deposit's vault). In Notoriety the bot has to touch the prop.

**Proposed model [P]** (a state machine per bot; the numbers in the tuning table are parameters, not constants):

```
Calm ──taken hostage (gun aimed, within range, in sight; difficulty rules)──▶ Hostage
Hostage.stealth: Following  (leader = the player who took it)         ── fleeTimer++ while no gun is aimed at it
                 aimed at ⇒ fleeTimer resets;  fleeTimer ≥ hostageFleeSeconds [Play: about a minute] ⇒ Fleeing
Hostage.loud (alert ≥ loudThreshold):  Frozen/kneeling — follow command rejected [Play]
Fleeing ─▶ runs to a flee node away from players; FleeCountVariable++; may raise alert on being seen
Any ─▶ Incapacitated (takedown/ pacify) ─▶ Body (BodyAltTrigger applies)     Any ─▶ Dead
```

- `HostageDifficulty` **[O correlation]** feeds *taking* a hostage: 0 never resists (civilians); higher values need longer aim/stand-off or fight back **[P]**; `NoHostageDownInCombat` (a real attribute) is honoured. The exact numbers need to be measured, see §6.
- **Alt interaction** is a candidate list, exactly like M7's prop interactions: for a player near a bot, a `BotAltTrigger` is *available* when the bot has the `BotServerTag`, is a hostage (`AllowHostages`) or patrolling (`AllowPatroling`), `ServerEnabled` and the player's `ClientVisible` are true. After `HoldTime` it sets `TriggerVariable` / emits `TriggerNotification`. `BodyAltTrigger` does the same for bodies. **No bot-touches-prop logic exists anywhere**; because a following hostage stays at the follow slot, range is naturally satisfied.
- API sketch: `bots:interactables(playerId) -> { {bot, trigger, title, subtitle, holdTime} }`, `bots:interact(playerId, bot, trigger, held)`; the same shape as `Props` so a UI can list both.

---

## 4. Architecture

All portable Luau, no Roblox APIs, deterministic (fixed 20 Hz step, one seeded RNG), same style as M1–M7. The host feeds time and player state and reads bot state to render.

| Module | Job | Depends on |
|---|---|---|
| **`BreachSetup`** (M8.0) | data-only parser for the `SetupSource` chunk (local constants, nested tables, strings, numbers, booleans, comments); exposes `Cells`, `EnforceClass`, `Combat`, … | none |
| **`BreachNav`** | kinematic agents on the M4 nav graph: path request, smoothing (string-pulling), steering, **trail following**, separation, stuck handling; the §2 invariants | `BreachWorld` |
| **`BreachBots`** | bot model from `Bots/` nodes (`Behavior`, `Nodes`, `NodesBreak`, `Inv`/`Weapon`, `Class`, `Profile`, `ServerTag`/`ClientTag`, `DespawnCondition`, …), behaviours `PatrolWalk` / `WorkWithBreaks`, the state machine of §3, `BotStateTracker` | Nav, Logic, Props (for doors) |
| **`BreachSight`** | vision cone and range, detection meter (`DetectionSpeed`), line-of-sight through cells/doors (a host callback `los(a, b)` overrides the headless approximation), trespass/disguise from `EnforceClass` and the `Cells` table | Setup, World |
| **`BreachAlert`** | monotonic alert 0–3, `AlertRaiseCondition`, `Mission_AlarmRaised` / `Mission_AlertLevel`, `Reason` events | Logic |
| Components | `BotStateTracker`, `AlertRaiseCondition`, `BotAltTrigger`, `BodyAltTrigger`; later `CustomBehaviorCondition`, `AlarmedBehaviorOverride`, `FOLLOW` and friends | Bots |

Patrol routes: a bot's `Nodes` value names a folder under `Nodes/` (**[O]** e.g. `Nodes = DownstairsPatrol`); its node parts carry a `CFrame` (and attributes such as `TakdownImmunity`); `PatrolCycleLength` sets the dwell/cycle, `NodesBreak` the break route for `WorkWithBreaks`, `SearchArea` where it investigates.

---

## 5. Milestones

Each has an acceptance test that needs nothing later.

| # | Name | Done when |
|---|---|---|
| **M8.0** | **MissionSetup parser** — **DONE** (`BreachSetup.luau`, 74 tests) | `BreachSetup` parses all three `SetupSource` chunks; tables match the Setup the Logic core already exposes where they overlap *(exactly, all four stores, all three maps)*; malformed input fails cleanly; fuzz |
| **M8a** | **Nav and followers** (`BreachNav`) — **DONE** (76 tests; main doc §8.2.1) | §2 invariants I1–I7 pass on scripted leaders over **routes between real cells of all three maps**, plus synthetic corridors/doorways; deterministic replay |
| **M8b** | **Bots + patrol** — **DONE** (`BreachBots.luau`, 82 tests; main doc §8.2.2, §13.14) | every placed bot of the three maps instantiates (7 / 57 / 44); `PatrolWalk` and `WorkWithBreaks` follow their real `Nodes` routes and timings on a scripted clock; `Inv` / `Weapon` parsed (`_tag`, `=condition`); `DespawnCondition` honoured; `BotStateTracker` counts |
| **M8c** | **Sight, trespass, alert** (in that order). *Sight DONE* (`BreachSight.luau`, 68 tests; main doc §8.4.1). *Trespass DONE* (`BreachTrespass.luau`, 58 tests; §8.4.2). *Alert DONE* (`BreachAlert.luau`, 123 tests; §8.3.1) | detection fills at `DetectionSpeed`; line of sight is blocked by closed doors; trespass classification from the real `Cells`/`EnforceClass`; `AlertRaiseCondition` raises the monotonic alert; `Mission_AlarmRaised` flips; seeded replays identical |
| **M8d** | **DONE** (`BreachHostage.luau`, 66 tests; docs 8.2.3). **Hostages, bodies, alt interaction** | the §3 state machine with the `[Play]` rules; `BotAltTrigger` / `BodyAltTrigger` interact end to end (lead a hostage, hold, variable set); follower invariants still hold while leading a hostage through a door; **a no-guards-left scenario can be finished with a hostage-gated step** |
| **M8e** | **DONE** (`BreachBehavior.luau`, 73 tests; docs 8.2.4). **CustomBehavior** | `FOLLOW`, `SETRUNNING`, `SETFASTWALK`, `MOVETODYNAMIC`, `SET`, `ENTERCOMBAT`, … driven by `CustomBehaviorCondition` / `AlarmedBehaviorOverride` |
| **M8f** | **DONE** (`BreachSession.luau`, `tests/playthrough_tests.luau`; docs 8.2.5) | **Playthrough** | seeded scripted run of a real map section per map: guards patrol, one sees the player, alert rises, a hostage is taken and led, the alt trigger fires; replay identical |

Order matters: **M8a before M8b** (the invariants are cheap to test and costly to retrofit), **M8.0 before M8c** (trespass needs the table).

---

## 6. Details I will default (tell me if it feels wrong)

Your rules fix the *behaviour*; these are the numbers and edge cases around them that I have to pick something for. Each gets a default marked `[P]` in one tuning table, so correcting one is a one-line change, not a redesign.

1. **Flee timer.** Default 60 s from the moment the hostage is taken; **aiming a gun at the hostage resets it** (that is "pull a gun"); it runs while no gun is aimed at them. Does it differ for civilians vs guards? Default: no.
2. **Loud.** Default: "Loud" = the alarm has been raised. Hostages there are frozen (kneeling) and ignore the follow command; the alt triggers still work on them if the map allows (`AllowHostages`).
3. **Taking a hostage.** Default: gun aimed, within range, in sight; `HostageDifficulty` 0 always complies, higher values need longer to subdue and may fight back.
4. **Following feel.** Default: 6 studs behind on your trail, single file through doors, never ahead of you.
5. **Alt-interaction range.** Default: the `[F]` prompt appears when the hostage is within follow distance + a margin and in the same cell.
6. **Alert values** (`Amount`/`MinValue`/`MaxValue`): default "raise by `Amount`, clamped to `[MinValue, MaxValue]`", checked against the three maps' values when M8c is built.
7. **Detection.** Default vision cone 90° / range 80 studs, `DetectionSpeed` as seconds-to-notice multiplier; crouching halves the range.

---

## 7. Risks

- **Door restrictions (new, from the Meadow Map tooling, main doc §13.13).** Doors carry per-side `PathReq1/2` (`Never`, `Combat`, keycards, keys, badges) plus recover/ignore masks that decide which bots may path through them; M8b must read them. The nav graph itself is a per-cell line-of-sight graph of door/link nodes, so path segments are straight and walkable.
- **Pathing on a heuristic world (resolved in M8b).** Real patrol legs were only 64–83% pathable; door edges and `minHitFraction` 0.15 raised that to 100% / 94% / 100% (main doc §13.14). One Peacemaker route that crosses floors remains unpathable.
- **Pathing on a heuristic world (original risk text).** M4's link-to-cell matching is a documented heuristic (§6.4); some patrol routes may cross links the matcher got wrong. Mitigation: M8b's per-route test reports unreachable node pairs, and the three maps' reports go into the doc.
- **No Roblox to look at.** Feel (the §2 numbers) cannot be tuned headless; the invariants guarantee *no collision*, not *good motion*. The adapter should expose the defaults so they can be tuned in play.
- **Scope.** M8 as the roadmap states it (patrol, pathing, vision, alert, `Inv`) is already large. Hostages/alt interaction are your requirements and data-backed, so they are in (M8d), but `CustomBehavior` (M8e) and conversations (`LocalChat` ×57, `ConversationGenericSocialEngineering`) are not needed to finish a stealth mission and can slip.
- **Unknown engine quirks.** The maps rely on some (variable-name case-insensitivity was one). Each milestone ends with a pass over the real maps for new mismatches, as in M5–M7.

---

## 8. What I would do first

1. **M8.0** (small, unblocks trespass, finishes the `SetupSource` question for good).
2. **M8a** (the follower invariants and the nav core), because it is the part you flagged and it is testable now.
3. Then M8b onward in order; after M8a I would show you the follower invariant results and the tuning table so you can say whether the distances feel right.
