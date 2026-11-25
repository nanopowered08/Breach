# BreachEngine M10: hacking and intel (PLAN, for the owner to correct before any code)

Status: **draft plan, nothing built.** Written from the attribute appendix (docs/BreachEngine_Appendix_A_Attributes.md) and docs section 5/8 only. Tags: **[R]** from the data/docs, **[P]** my guess, **[?]** an open question for the owner. AGENTS.md rule: the plan is agreed before the code.

## 1. What the data says [R]

**The network.** Props carry `NetworkId` (integer 1 to 999, validated) and `NetworkLink` (a string of neighbour ids, "netid-str"). Props with these: `PowerBox*`, `NetworkSwitch`, `AccessPoint`, `CeilingAccessPoint`, `HackableComputer` (default id 0), `Laptop`, `LaptopOld`, `ServerRack*Terminal`, `SecurityCamera`, `DomeCamera`, `Elevator*`, `RFIDWriter`. Components: `HackableDoor`, `HackableElevator`, `NetworkRouter` (id **999**), `RemoteWeaponNode` (id **999**), `HackingNodeStatus`.

**The hacks.** `CustomHack` (10 in The Project, 26 and 8 in the other maps): `NodeId` (which node it hacks), `DeployCost` (20), `DeployTime` (expression, 10), `Priority`, `Difficulty`, `Suspicion` (1), `PrimaryHack`, `Visible` (expr), `PauseCondition` (expr), `ProgressVariable`, `DeployedVariable`, `DeployedOnceVariable`, `IsDeployedVariable`, `BlockDeallocation`, `ForceDeploy`, `DisableReason`, `RequiresInput`, `ScriptedBehavior` (text), plus name/subtitle/description string keys and an icon id. `TargetLureHack` has no attributes of its own.

**Node state.** `HackingNodeStatus`: `DisabledVariable`, `CompromisedVariable` (map variables the engine writes). A node prop may have `NodeStatusVariable`. `HackingNodeHighlight`: an objective highlight (`NodeId`, `Active`, `IncludeTraversal`, `HackDesc`, `ObjectiveType`).

**Computers.** `HackableComputer` / `Laptop`: `PasswordDifficulty`, `PasswordUnlockedVariable`, `PasswordLockedCondition`, `ManualPasswordVariable/List/Revealed`, `PhysicalAccessBlocked`, `NetworkNameTag`, `MultiHackTitle`, `HideUnavailablePrimaryHacks`, `ScreenText`, `PowerArea`.

**Intel.** UI components `IntelCharacterPortrait`, `IntelConnection` (Link0/Link1), `IntelPrimaryText`, `IntelSidebar`, `IntelSubText`; `MissionSetup.HackingMapIntel` and `CustomMissionIntel`; objective group `Intel`.

## 2. What is NOT known [?]

1. **The economy.** `DeployCost` 20: of what? A shared bandwidth pool the player has (and how big, does it refill), or a per-hack price? `BlockDeallocation` suggests a pool you can take back from.
2. **Reachability.** Is a node hackable only when it is connected through `NetworkLink`s to a node the player is physically plugged into (a computer), with `NetworkRouter` 999 as the gateway? What does `RemoteWeaponNode` 999 do (a weapon that is hacked remotely)?
3. **`Difficulty`, `Suspicion`, `Priority`**: does a hack raise the alert (Suspicion points to the Alert layer) and what does Difficulty do (longer time? a mini game)?
4. **Passwords**: is a minigame needed or only the variable `PasswordUnlockedVariable` set after `PasswordDifficulty` seconds?
5. What a deployed hack **does** beyond writing its variables: is everything done by the map's own StateScript reading `DeployedVariable` (very likely, in which case the engine only runs the hack lifecycle and the graph), or does the engine have built-in effects for `HackableDoor` (unlock), `HackableElevator`, cameras (disable) and `TargetLureHack` (lure a guard)?
6. `ScriptedBehavior` text: its grammar.

## 3. Proposed design [P]

One pure module **`BreachHacking`** (`src/hacking.luau`), like the other layers: deterministic, no Roblox APIs, driven by the Session step. It owns: (a) the **graph** built from `NetworkId`/`NetworkLink` of every prop and component in the mission; (b) the **hack lifecycle** for each `CustomHack`; (c) the **node status** variables.

```lua
local H = Hacking.new({ logic = logic, props = props, mission = mission, alert = alert }, { seed, params })
H:graph()                         -> { nodes = { [id] = { Id, Kind, Names, Links } } }, warnings (dangling links, duplicate ids)
H:reachable(fromId)               -> set of node ids reachable through links      [P: the reachability rule]
H:available(playerId)             -> list of hacks the player may start now (Visible, not blocked, node reachable, enough bandwidth)
H:start(playerId, hackName)       -> true | false, reason     (NoSuchHack | NotVisible | Paused | NotReachable | NoBandwidth | Disabled | Already)
H:cancel(playerId, hackName)
H:step(dt)                        -- deploys: progress += dt / DeployTime, PauseCondition pauses it, at 1: DeployedVariable = 1, DeployedOnceVariable = 1, ProgressVariable follows
H:bandwidth(playerId)             -> used, total                                  [P: pool model]
events: HackStarted, HackProgress {Fraction}, HackPaused, HackDeployed, HackCancelled, HackRefused {Why}, NodeDisabled, NodeCompromised, SuspicionRaised {Hack, Points}
```

Variable writes use `Logic:set`, so the map's own script reacts (the same way as everything else).

## 4. Milestones (each with tests, a small suite per piece)

| Step | What | Test |
|---|---|---|
| **M10a** | The graph: build it from props and components, warnings for dangling links, duplicate ids, id 0 nodes, `reachable()` | synthetic networks; real maps when the local data exists (count nodes and components per map) |
| **M10b** | Hack lifecycle: `start/cancel/step`, `DeployTime`/`Visible`/`PauseCondition` as expressions, the five variables, `Priority` order | fake clock; a hack that is paused and resumed; variables seen by a Logic watcher |
| **M10c** | Node status: `HackingNodeStatus` variables, disabled and compromised nodes, `NodeStatusVariable` on props | hack a node, see its variable |
| **M10d** | Economy and alert: bandwidth pool, `Suspicion` into the Alert layer, `Difficulty` | answers to open questions 1 and 3 first |
| **M10e** | Passwords and `PhysicalAccessBlocked` (variables only, no minigame) | |
| **M10f** | Intel: evaluate the `Intel*` components' `Visible` expressions, expose a tablet model (a plain table the host draws) | the Intel UI components of the three maps, read-only |
| **M10g** | Session integration, docs section, HANDOFF | suite green, signatures stable |

## 5. What I need from the owner before M10b

Answers (or "guess it") to section 2, especially 1 (economy), 2 (reachability / the 999 nodes) and 5 (does the engine do effects or only the variables). Without them I will implement M10a and M10f (pure data) and the lifecycle of M10b with the guesses flagged **[P]** in `Params`.
