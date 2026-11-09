# BreachEngine — M11 plan: Randomisation (the physical room layout)

| | |
|---|---|
| **Status** | Plan, not code. For the owner to approve (merging this PR is the approval). Written against docs v0.26 and the HANDOFF survey of *The Blacksite* pre-release |
| **Evidence tags** | **[O]** observed in map data · **[R]** documented requirement or owner observation · **[P]** a guess, to be tuned · **[V]** unverified |
| **Goal** | When the engine loads it reads the seed (adapter: `BreachSeed`, PR "adapter-seed") and the rooms end up where the game puts them for that seed, so The Blacksite is drawn, navigated and played as laid out in the game, not as the unshuffled staging layout |

---

## 1. What we know

- **[O] The Blacksite is a shuffled layout.** `UseHashShuffle = true`, 103 `PartCollection` and 529 `ShuffleTarget` placeholders. Sections are authored at staging positions and moved into shuffle targets when the mission starts. Today BreachEngine draws and navigates the staging layout (a big separate block and floating platforms off to the side).
- **[R] Mechanism** (docs 7.5): props whose **centre** lies inside a `PartCollection` volume are grouped and can be relocated to a `ShuffleTarget` (`ShuffleTag`, `Index`); equal `Index` values keep picks correlated across groups. Seed `416` is reported to select index 1 everywhere: **an oracle for tests**.
- **[R] Folder level** (Folders are unvalidated): `Condition` (delete the folder if false), `PickCount`/`PickSeed`, `ShuffleContents`, `ResolvePriority`. `HiddenShuffle` (x2 in the Blacksite) is a state component.
- **[O] Related attributes seen in maps:** `ShuffleTarget`, `ShuffleTag`, `MatchVariable`, `ResolvePriority` all appear hundreds of times; their exact meaning is not documented anywhere I can read (**[V]**).
- **[R] A cell's Meadow map moves with its `PartCollection`** at mission init (Cish's Meadow Map docs), the leading suspect for the BotPathFailed flood (about 675 in 5 simulated minutes). Unconfirmed.
- **Already done:** one `Random` module owns every seeded decision; `VariableShuffle`, `RNG` and `SHUFFLE` are seeded and tested. This plan adds the **geometry** half.

## 2. Design

All of it stays portable Luau (no Roblox APIs) inside the engine; the adapter only supplies the seed and redraws.

1. A new module `BreachShuffle` builds a **layout** once, from the mission, the seed and the variables: for every `PartCollection` it decides which `ShuffleTarget` it goes to, and returns a rigid transform (CFrame delta) per collection. Same seed + same mission = same layout, always.
2. The layout is applied **before** anything reads positions: `BreachWorld.build` (geometry, barriers, nodes), the Meadow map nodes, props and door placeholders, bot spawn points and logic markers inside a collection volume all move with their collection. Nothing is moved twice.
3. Groups: per `ShuffleTag`, collections compete for that tag's targets; targets with the same `Index` give correlated picks across groups **[R]**; `ResolvePriority` orders ties **[P]**.
4. The adapter prints the layout (`[Breach] layout: 103 collections -> 529 targets (seed N)`) and the engine reports collections it could not place as warnings, never errors.

## 3. Milestones (each its own PR, with tests)

| # | What | Done when |
|---|---|---|
| **M11.0** | **Survey, no behaviour change.** `BreachShuffle.survey(mission)`: lists every `PartCollection` and `ShuffleTarget` with all its attributes, grouped by tag and index, plus the folder-level attributes; the adapter prints a summary | the Blacksite summary shows what `MatchVariable` and `ResolvePriority` really hold, so the rules in 2.3 can be settled from data |
| **M11.1** | **Deterministic layout.** `BreachShuffle.layout(mission, seed)` and the transform applied in `BreachWorld.build`, props, Meadow map, spawns | seed 416 gives index 1 everywhere **[R]**; the same seed twice gives the same layout; different seeds give different ones; BotPathFailed is measured before and after |
| **M11.2** | **Folder level:** `Condition`, `PickCount`/`PickSeed`, `ShuffleContents`, `ResolvePriority` | folders are removed or reordered per seed; tested with synthetic missions |
| **M11.3** | **`HiddenShuffle`** state component (`FrontCount`, `BackCount`, `RevealCount[Variable]`, `RevealAllCondition`, `Fail[Count]Variable`, `Seed`, `HiddenShuffleId`) | guaranteed-not-first and guaranteed-last windows hold over thousands of seeds |

Acceptance for the whole milestone: the owner looks at the Blacksite in Studio with seed 416 and says it is laid out like the game.

## 4. Tests

Synthetic missions (a few collections and targets with known tags and indexes) cover the rules with no map data. The real-map checks stay in the local-only suites (`tests/_embedded.luau`): seed 416 -> index 1, every collection placed, every bot's spawn still on its Meadow map.

## 5. The rest of the roadmap, and the order I suggest

- **M9 (combat) is not finished**: only M9.0 (the data model) is done; M9a onwards (phases, spawners, grenades) is still open.
- **M10 Hacking + intel** (`NetworkId` graph, `CustomHack` x26, `HackingNodeStatus` x12 in the Blacksite, tablet UI) and **M12 Encode + Standalone** (export a mission back to an IE code with round-trip *equivalence*, and to the Standalone folder format) each get their own plan when their turn comes, as M9 and this one did.
- **Order** (the HANDOFF's, updated): M11.0 -> M11.1 (the Blacksite looks right) -> door access in `BreachNav` (second suspect for path failures) -> M9a -> M10 -> M12.

## 6. Open (one question)

**Do you know what `MatchVariable` does on a `ShuffleTarget`?** If not, no problem: M11.0 prints it from the Blacksite data and I propose the rule from that, for you to confirm.
