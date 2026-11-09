# BreachEngine — Documentation

*A clean-room, InfiltrationEngine-compatible mission engine for Roblox.*

| | |
|---|---|
| **Document version** | 0.26 — **guards flee only from an armed player and radio while they flee** (§8.3.1; `Props:setArmed`) **and detection speed follows the alert level** (Calm 0.9x, Normal 1x, Alert 1.1x; §8.4.1). Earlier, 0.25 — **M9.0 (combat data model) done**: `BreachCombatData.luau` (§8.3.2). Earlier, 0.24 — **M8f (session + seeded playthroughs) done: M8 complete**: `BreachSession.luau` (§8.2.5). 0.23: **M8e (CustomBehavior, spawners) done**: `BreachBehavior.luau` (§8.2.4); `Bots:spawn`, `PassingCivilian`. 0.22: **M8d (hostages, bodies, alt interaction) done**: `BreachHostage.luau` (§8.2.3); `Props:refresh()` capped. 0.21: **M8c part 3 (alert) done**: `BreachAlert.luau` (§8.3.1): the monotonic level, `AlertRaiseCondition`, what a witness/anomaly causes; `Sight:canSeePoint`, `Bots:command/hold/resume` added. 0.20: **M8c part 2 (trespass) done**: `BreachTrespass.luau` (§8.4.2); the cell-to-rules link, found in the data. 0.19: **M8c part 1 (sight) done**: `BreachSight.luau` (§8.4.1); bots got a facing, players a stance, closed doors block sight. 0.18: **M8b done**: `BreachBots.luau` (bots, routes, patrols, loadouts, despawn, state trackers; §8.2.2); the world's cell/nav connectivity corrected from real patrol routes (door edges, `minHitFraction` 0.5 → 0.15; §6.4, §13.14). 0.17: **M8a done**: `BreachNav.luau` (followers that cannot hit you; §8.2.1) and the navigation data explained by the Meadow Map tool's source (§13.13). 0.16: **M8.0 done**: `BreachSetup.luau`, the MissionSetup (`SetupSource`) data parser (§13.12). 0.15: **M8 is planned** (`BreachEngine_M8_Bots_Plan.md`: data survey, anti-collision follower design, hostage/alt-interaction model, milestones M8.0–M8f). 0.14: **M7 done**: `BreachProps.luau` (players, zones, rooms, items, triggers, deposits, doors, readers, end zones; §8.1.1, §13.11). 0.13: **variable names are case-insensitive** (§7.1; found through The Project's lockdown/detonation chain, §13.10). 0.12: third real map, *The Project* (V1.3, a version-0 plain-text map): codec/mission/world/logic run on it unchanged except Appendix A's `EnemyWeaponsWave1-9` (now strings) and engine builtin defaults (§7.6, §13.10). 0.11: M6 extended: `DelayedStateUpdate`, `ConditionalStateUpdate`, `VariableShuffle` implemented (§7.6, §13.9). 0.10: **M6 done** (StateScript VM: §7.4 corrected from 26 real scripts, new §7.4.1, §7.7, §13.8; `BreachCFrame/BreachScript.luau`). 0.9: **M5 done** (logic core: §7.1/§7.2 corrected from ~4,500 real expressions, new §7.2.1/§7.6, §13.7; `BreachExpr/BreachRandom/BreachLogic.luau`). 0.8: third real map (a gist), **§6.4 corrected** (`LinkList` is template residue), §13.6. 0.7: **M4 done** (§6 rewritten from real data; `BreachWorld.luau`). 0.6: **M3 done**: mission model + Standalone format implemented (§5.5.1). 0.5: second real map decoded (§13.5). 0.4: **M2 validator done** (§3.4 corrected and extended; `BreachValidator.luau`). 0.3: §4 validated against a real Operators map (§13), map-index-0 rule. Appendix B corrected in 0.2. Code lives in `breach-codec/` |
| **Written** | 2026-10-14 |
| **Companion files** | `BreachEngine_Appendix_A_Attributes.md` (289 components / 1,746 attributes) · `BreachEngine_Appendix_B_WireFormat.md` (type ids, property tables, enums, alphabet) |
| **Sources** | (1) `SerializationTools.rbxmx` — the Mission Exporter plugin, 56 ModuleScripts + 1 Script, code version 2 / API version 1 · (2) the earlier *InfiltrationEngine — Custom Mission System Reference* (built from GhfjSpero's mission-authoring doc) · (3) your own BreachEngine design notes |

---

## 0. How to read this document

Every claim carries one of these tags, because the whole point of this revision is to separate what is known from what is guessed.

| Tag | Meaning |
|---|---|
| **[V]** | **Verified** — read directly in the SerializationTools source. This is the strongest evidence available to us. |
| **[I]** | **Inferred from code** — follows from reading the plugin, but I did not run it. Worth a test before you rely on it. |
| **[R]** | **Reported** — comes from the authoring documentation. It describes engine behaviour the plugin cannot confirm (the engine itself is not in our hands). |
| **[N]** | **Your notes** — a BreachEngine design decision you recorded earlier. |
| **[P]** | **Proposed** — my suggestion. Yours to accept, change or drop. |
| **[O]** | **Observed** — seen in a real export (the *The Diplomat* map, §13). The strongest evidence after running the real engine. |

**Rule of thumb:** the plugin tells us the *shape* of a mission (what can be stored, how it is encoded, what attributes exist, their types and defaults). It tells us almost nothing about *behaviour* (what a door does when `AutoLock` is true). Behaviour is only **[R]** or **[P]**, and BreachEngine has to implement it by design, not by copying.

---

## 1. Overview

### 1.1 What BreachEngine is

BreachEngine is a from-scratch Roblox game engine whose goal is to **load and run custom missions authored for InfiltrationEngine** (the engine behind *Entry Point: Freelancer's Cut* and *Operators*) **[N]**. Missions are authored in Roblox Studio as a `DebugMission` tree of Parts, Models, Folders and attribute-carrying `BoolValue`s, exported to a text "mission code", and loaded by the engine. BreachEngine reimplements the *consumer* side of that pipeline.

### 1.2 Goals

1. **Load** InfiltrationEngine mission codes (all three code versions) into an in-memory mission model.
2. **Validate** missions the way the exporter does (types, defaults, unknown-attribute handling).
3. **Run** the mission logic: cells and links, pathfinding nodes, props, bots, triggers, state components, StateScripts, alert/combat systems, objectives.
4. Provide a **BreachEngine-native** on-disk map format (§5.5) so maps are diffable, version-controllable and inspectable without Studio **[N]**.
5. Stay **clean-room**: study behaviour and formats, never copy code.

### 1.3 Non-goals

- Reproducing the official campaign missions, assets, or the in-game mission browser.
- Executing arbitrary Lua from mission files (see §3.5 — the format deliberately avoids this).
- Byte-for-byte identical re-export of codes. Round-trip *equivalence* of the mission tree is the target (§4.10 explains why bytes are not stable).

### 1.4 Clean-room and licence posture

You told me you are wary of legal exposure from copying the real engine **[N]**. This document is written to support that:

- It describes **formats and interfaces** (alphabet, field order, attribute names/types/defaults). Those are facts a compatible implementation needs.
- It contains **no plugin code**. The pseudocode in §4.12 is mine.
- The mission-tooling repository is reported to be **CC BY-NC-SA** **[R]**. Copying its code or text into BreachEngine would pull in *NonCommercial* and *ShareAlike* obligations. Write your own decoder from this spec instead of pasting the plugin's.
- Do not ship InfiltrationEngine's **assets** (the `ImportParts` mesh folder, the Prop Preview library, audio, outfits). BreachEngine needs its own prop models. Attribute *names* are interoperability facts; the *models* are creative work.
- I am not a lawyer; if BreachEngine ever goes public or commercial, get real advice.

---

## 2. Validation report — what I got right and wrong

You asked me to validate the claims in the earlier reference document against the plugin source. This is the result. It matters because several of those claims were guesses about things the authoring doc could not see.

### 2.1 Corrections

| # | Earlier claim | Verdict | What the source actually shows |
|---|---|---|---|
| 1 | Only 15 Instance types may appear inside `DebugMission` (Model, Folder, Part, BoolValue, WedgePart, StringValue, Texture, BlockMesh, 3 lights, SpecialMesh, Decal, Fire, Smoke). | **Incomplete [V]** | **26** classes serialise. Missing from the list: `MeshPart`, `UnionOperation`, `Attachment`, `ParticleEmitter`, `Sparkles`, `SurfaceGui`, `ImageLabel`, `BillboardGui`, `Frame`, `Beam`, `Trail`. Anything else becomes a 1-symbol `Nil` and is dropped with its whole subtree. (`ModuleScript` is among the dropped — see §3.5.) |
| 2 | Unions are allowed only if sourced from the `ImportParts` template. | **Partly wrong [V]** | The *reader* prefers a cached mesh in `ReplicatedStorage.Assets.ImportParts` (by numeric asset id) but otherwise calls `InsertService:CreateMeshPartAsync` — the plugin's `ENABLE_ARBITRARY_MESHES` flag is `true`. So arbitrary MeshPart/Union meshes load, at least through the plugin's reader. Whether the live game's reader has the same flag is unknown. |
| 3 | Gist mode is unlocked by "a `ReadDocs` BoolValue attribute = true on Workspace". | **Imprecise [V]** | It is a plain **attribute on `workspace`** whose value must be exactly boolean `true`. The same flag can also come from `workspace` attribute `SerializerFeatures` (a `\|`-separated string such as `ReadDocs\|Readback`) or `SerializerEnableAllFeatures = true`. §4.13. |
| 4 | "Component type is which named class you use." | **Refined [V]** | For a `BoolValue`, the component is identified by its **`Type` attribute**. For any other class (a `Part`, `Model`…), by the instance's **`Name`**. §3.4. |
| 5 | `MissionSetup` is a Lua table authors write; "not exposed as a scripting surface". | **Refined [V]** | The exporter **executes** `require()` on a clone of the `MissionSetup` ModuleScript, **JSON-encodes the result**, and ships that JSON (`TableMissionSetup`) plus the raw source (`StringMissionSetup`). §3.5. |
| 6 | The wire format of a mission code is unknown. | **Now answered [V]** | Fully documented in §4. |
| 7 | (Your notes) A mission may be "3 blobs": logic, map, geometry. | **Wrong [V]** | There is **one** stream: colour map + string map + a single recursive instance tree. The granularity you later found (Cells, Nodes, StateComponents, Geometry, …) is just the *folders inside that tree*. |
| 8 | (Your notes) The codes use proprietary compression. | **Clarified [V]** | From code version 2: **Zstandard** (level 4 by default) then **Base64**, both via Roblox's built-in `EncodingService`. Nothing exotic. |
| 9 | Door variant `PushLeft`. | **Name wrong [V]** | The component is `DoorPushLeft`. There are many more doors than the five listed (see Appendix A: `DoorArmored`, `DoorArmoredElectronic`, `DoorCombatSpawn`, `DoorFenceGate`, `DoorGlass`, `DoorGlassFramed`, `DoorGlassRustic`, `DoorMetalMaglock`, `DoubleVaultDoor`, `HeavySecurityDoor`, `SlidingBlastDoor`, `GarageDoor`, …). |
| 10 | `TriggerThreshold` with `PlayersBeforeThresholdVariable` / `PlayersAfterThresholdVariable`. | **Spelling wrong [V]** | The plugin spells it **`TriggerThreshhold`**, `PlayersBeforeThreshholdVariable`, `PlayersAfterThreshholdVariable` (double *h*). Use the misspelling for compatibility. |
| 11 | `LeverageMove` has `MoveToEndVariable`. | **Name wrong [V]** | `MovedToEndVariable`, plus `MovedFromStartVariable` and `VisibleCondition`. |
| 12 | `CombatSpawner`: `SpawnSquads` = "up to 3 at once"; `SpawnTag`. | **Wrong types/names [V]** | `SpawnSquads` is a **bool**; the count is `SpawnSquadsSize` (expression). The tag attribute is **`SpawnTags`**. Also exist: `AllowDespawn`, `FallbackCondition`, `CurrentWave`, `CustomCombatData`, `CustomShirtId`, `CustomPantsId`. ("Up to 3" cannot be confirmed from the plugin.) |
| 13 | `TimerComponent` attribute list. | **Incomplete [V]** | Also has `Enabled`, `Paused`, `Frequency`. |
| 14 | `MusicController.MusicType` is "vestigial". | **Unconfirmable [V]** | It exists, but its default is written as the **bare identifier** `Stealth` in the generated map — an undefined global in Lua, i.e. **nil** at runtime (so effectively *no default*). Same typo for `Flare.PlacedVariable` (`FlarePlaced`). `PersistOnReload` also exists. |
| 15 | A prop called `Intercom`. | **Not in map [V]** | Only `IntercomCode` and `IntercomPanel` have entries. |
| 16 | `PlaceholderProp`, `PartCollection(s)`, `SpawnFadeInTime`. | **Not in map [V]** | No attribute-map entry. `PlaceholderProp` and `PartCollection` may be recognised by the engine by name without validation, or be Folder/Model-level attributes (Folders skip validation entirely — §3.4). Treat as unverified. |
| 17 | "Vision & Pathfinding Blocker" is one prop. | **Probably two [V]** | Separate entries `VisionBlocker` and `PathfindingBlocker` exist. |
| 18 | The exporter "auto-copies" `DebugMission` from ReplicatedStorage to Workspace. | **Different [V]** | It *finds* `DebugMission` in Workspace first, else ReplicatedStorage, **clones** it, serialises the clone, and — only if none is in Workspace — decodes its own output back into a fresh Workspace copy (a free round-trip self-test). |

### 2.2 Confirmed

- **Segmented codes [V].** Codes are split into pieces of at most **199,999** characters including a 7-character header (so **199,992** payload characters each). The "textbox paste limit" *reason* is [R]; the numbers are [V].
- **Gist export is one unsegmented code [V]** (`total = 1`), with a human-readable comment wrapped in `!!!` (§4.8).
- **Folders are not attribute-validated [V]**, so folder-level randomisation attributes (`Condition`, `PickCount`, `ShuffleContents`…) are unconstrained by the plugin.
- **The great majority of attribute names in the earlier doc are real [V].** I extracted 338 backticked identifiers and checked each against the plugin: **201 matched** an attribute or component name. Of the 137 that did not match, most are not attribute names at all (enum values, profile names, StateScript keywords, folder names, key letters). The real mismatches are the items in §2.1.
- **Cell geometry [V].** The plugin's own helper (`ZoneUtil`) defines "inside a cell" as: the point lies within a `Floor` part's X/Z footprint **above** it *and* within a `Roof` part's footprint **below** it (a cell with no `Floor` child ignores the floor test). This matches the "zone between floor and roof" description.

### 2.3 New findings the earlier document could not have had

| # | Finding | Tag |
|---|---|---|
| N1 | **`false` attribute values are dropped on export** *(real-map evidence, §13.4: consistent)* for any attribute listed in the attribute map: the validator tests `if not attributes[name]`, so boolean `false` is treated as "absent" and is not written; on import the *default* is restored. Consequence: a `bool`-typed attribute whose default is `true` (e.g. `MissionEndZone.HighlightZone`, `WarpPoint.WarpKeepsOffset`, `LeverageMove.Heavy`) **cannot be turned off** through the exporter. Expression-typed attributes can use the number `0` instead (a number is never "absent"). Globals (§3.4) are exempt. | **[I]** — test it |
| N2 | **Attributes only survive on 6 classes** (`Model`, `Folder`, `Part`, `BoolValue`, `MeshPart`, `UnionOperation`). An attribute set on a `WedgePart`, `StringValue`, light, `Decal`… is silently lost. | **[V]** |
| N3 | **Chunking off-by-one.** The chunk loop runs `while first < #code`, so if the payload is *exactly* `199,992·k + 1` characters long, the last character is dropped while the header still advertises `k+1` pieces (probability ≈ 1 in 200,000 per export). | **[I]** |
| N4 | **String and colour maps are capped at 5,183 entries each.** Indices are 2-symbol integers that clamp silently rather than error. A mission with more than 5,183 *unique* strings (names, attribute names, attribute string values, property strings) would corrupt. | **[I]** |
| N5 | **Exports are not byte-stable.** Attribute order comes from an unordered dictionary, so two exports of an unchanged mission can differ (and compress differently). Compare decoded trees, not strings. | **[V]** |
| N6 | **`!!!` in a gist header breaks the comment.** Mission name, author and briefing are pasted raw into a comment terminated by the *first* `!!!`; a briefing containing `!!!` truncates the comment and corrupts the code that follows. | **[I]** |
| N7 | **Loader pipeline is visible** (header → chunk reassembly → version switch → decode; gist URL handling). See §4.8. | **[V]** |
| N8 | **Position range ±186,623 studs**; fractional resolution 1/5,183 stud ≈ 0.0002; **colours are 5,183 levels per channel**; rotations are stored as three normalised Euler angles with 373,247 steps (≈ 0.000017 rad). Re-importing slightly moves things. | **[V]** |
| N9 | **Version 2 is the only version with compression; version 0 does not escape newlines.** | **[V]** |
| N10 | The reader **forces** `TopSurface`/`BottomSurface = SmoothNoOutlines` on every Part, and Part properties like `Reflectance`, `CanTouch`, `CanQuery`, `Massless` are not in the format at all. | **[V]** |

---

## 3. The compatibility target — the mission model

### 3.1 The `DebugMission` root

A mission is one tree whose **root is named `DebugMission`** **[V]**. The exporter looks for it in `Workspace`, then `ReplicatedStorage`; anything outside it is not exported.

The exporter also manages a `CustomMissionSettings` `BoolValue` under the root **[V]**, holding:

| Child | Class | Default | Purpose |
|---|---|---|---|
| `EnforceCellLinks` | BoolValue | `true` | If `false`, the gist header says the mission is **ineligible for the community-missions tab**. |
| `ExportVersion` | StringValue | `"0"` | Auto-incremented on each *Gist* export (trailing integer is bumped; text before it is kept). |
| `MissionName` | StringValue | `""` | Shown in the gist header. |
| `MissionDesc` | StringValue | `""` | Briefing, shown in the gist header. |
| `AuthorName` | StringValue | `""` | Shown in the gist header. |

### 3.2 Top-level folders **[R]**

The plugin does not enforce this list (it only requires a `Cells` child for its zone helper), so this is the authoring convention. BreachEngine should treat them as *named conventions the engine looks up*, not as a schema.

| Folder | Purpose |
|---|---|
| `Cells` (and `Cells/Links`) | Spatial zones and the links between them |
| `Nodes` | Pathfinding node folders (Meadow maps) |
| `Bots` | NPC definitions |
| `Props` | Functional and decorative placed objects (doors live here) |
| `CustomProps` | Author-made decorative models |
| `Geometry`, `Glass`, `ConditionalGeometry`, `Barrier` | Level geometry, breakable glass, spawn/despawn geometry, invisible bounds |
| `LoudSpawns` | Enemy spawn points for the loud phase |
| `MapData` | Minimap floor definitions |
| `CustomItems` | Player inventory items defined by the mission |
| `CombatFlowMap` | Reported as unused |
| `StateComponents` (and `StateComponentTemplates`) | Map-wide logic (§7) |
| `StateComponentsPreprocess`, `BotTemplates`, `BotStorage`, `Disabled` | **[O]** present in a real map but not in the authoring doc. By name: pre-processing components, bot templates for spawners to clone, bot parking, and disabled content. Semantics unverified. |
| `MissionSetup` | ModuleScript, see §3.5 — **not serialised as a script** |

### 3.3 The 26 serialisable classes **[V]**

`Model, Folder, Part, BoolValue, WedgePart, StringValue, MeshPart, UnionOperation, Texture, BlockMesh, PointLight, SpotLight, SurfaceLight, SpecialMesh, Decal, Fire, Smoke, Attachment, ParticleEmitter, Sparkles, SurfaceGui, ImageLabel, BillboardGui, Frame, Beam, Trail`

(The type table has 28 entries: these 26 real classes plus the synthetic `PartNoAttributes` and `Nil`. Ids and per-class properties are in **Appendix B**.) Only a *subset* of each class's properties is stored; the rest take engine defaults on load.

### 3.4 Attributes and validation **[V]**

Attributes are how all logic is expressed. The exporter validates them using the attribute map (**Appendix A**).

**Which entry applies?**

1. If the instance is a `Folder` → **no validation, attributes pass through untouched**.
2. If the instance has attribute `IKnowWhatImDoingDoNotValidate == true`, or any truthy `NoValidation` → passes through (a console warning is printed).
3. If its `Type` attribute is `"StateScript"` or its name is `"StateScriptPart"` → passes through.
4. Otherwise the lookup key is: the **`Type` attribute** if the instance is a `BoolValue`, else the **instance `Name`**.
5. If the key is not in the map → passes through.
6. If the instance has `AltProp` or `AltPropModel` → passes through.

**When it applies (export, "no defaults" mode):**

- For each attribute the map lists: skip if absent **or falsy** (**N1**); skip (with a warning naming object and attribute) if the value fails the type check; skip if equal to the default; otherwise keep.
- For each remaining attribute: keep it if it is one of the **globals** (type-checked; dropped if it doesn't fit); otherwise warn *"Unknown attribute will be discarded"*.

**On import ("with defaults" mode):** every listed attribute missing from the stream is filled with its default. A type-failing value is *intended* to be replaced by the default, **but a fall-through in the original (no `continue` after assigning the default) means the bad value is then written over it, so it is kept [I]** — a real wrong-typed value survives an import. Also: `false` for a listed attribute is treated as absent on import too, so it comes back as the default.

**Three more quirks found while implementing the validator [V]:** (a) a `NETWORK_ID` attribute given as a *string* is always rejected, even "5" (only the number branch returns true); (b) defaults are never validated themselves (e.g. `HackableComputer.NetworkId` defaults to `0`, outside the 1–999 rule); (c) a global attribute that fails its type check is removed even if the component-specific pass had accepted it.

**Implementation [P→done]:** `BreachValidator.luau` offers two modes — **`exporter`** (bug-compatible with all of the above, to predict what the real exporter writes/reads) and **`engine`** (the default: `false` honoured, wrong types reported and replaced by the default, unknown attributes reported but kept).

**Globals** — accepted on every validated entry **[V]**: `GlobalVariables, OnProp, ScriptMove, Index, CanShatter, Tag, TagOffset, StaticTag, HasTopBarrier, Indestructible, NoPropDamage, IsSpawned, Color0–Color5, Material0–Material5, Type, AltProp, AltPropModel, FadeOutCondition, CollisionGroup, TagButton, MultiGlass, BreakAlarm, BlockEMP, EMPHitVariable, PowerCutVariable, LinkComp`.

**Attribute kinds** (the validator's vocabulary) are in Appendix A. The three you will meet constantly:

- `expr` — a boolean, string or number evaluated by the expression language (§7.2).
- `state` — a variable name, **no whitespace allowed**.
- `str` / `int` / `num` / `bool` — as expected.

**Implication for BreachEngine [P]:** reproduce the validator as a separate, testable module with exactly this precedence. Its warnings are a free source of author-facing error messages.

### 3.5 `MissionSetup` — config as data **[V]**

1. On export the plugin `require()`s a **clone** of the `MissionSetup` ModuleScript, giving a Lua table.
2. If `Colors` is missing it warns and substitutes `{}`. Each `Color3` in `Colors` is converted to `{r, g, b}`.
3. The table is **JSON-encoded** into a `StringValue` named `TableMissionSetup`.
4. The raw script source is stored in a `StringValue` named `StringMissionSetup`; each child ModuleScript's source is stored as a child `StringValue` of that, by name.
5. `ModuleScript` is not a serialisable class, so the script itself never appears in the stream.
6. On import, the *runtime* reads `TableMissionSetup`. Only when the plugin itself is importing (Studio, not the game) does it rebuild the `MissionSetup` ModuleScript from the stored source, so authors can edit again.

**What this means for you:**

- The engine never needs to run mission Lua. **Consume the JSON.** [P] — it removes the whole "untrusted code" problem.
- Anything not JSON-representable in `MissionSetup` (functions, metatables, `Color3`s outside `Colors`, `nil` holes in arrays) is lost at export. Expect plain tables, numbers, strings, booleans.
- Field-by-field semantics of `MissionSetup` are **[R]** — see §9.

### 3.6 Instance references **[V]**

A few properties (`BillboardGui.Adornee`, `Beam`/`Trail` `Attachment0/1`) point at other instances. They are stored as a **string of dot-separated 1-based child indices** from `DebugMission` down (e.g. `"3.12.2"`), counting **only serialisable siblings**. On import, resolution is deferred until the root's `Loaded` attribute is set, then each index is followed through `GetChildren()`.

**Consequence: child order is semantic.** Any BreachEngine format that loses sibling order breaks these references (see the decision in §5.5).

---

## 4. The mission code — wire format **[V]**

This section is the interoperability spec for **code version 2** (the latest) and notes where versions 0–1 differ. All of it is derived from the plugin's reader and writer.

### 4.1 Layers

```text
what a person shares:   a Gist URL            or      N pasted pieces
                            │ (HTTP GET, raw)                │
                            ▼                                ▼
   "!!!<comment>!!!" + header + code     header + code-piece, one per paste
                            │ strip comment, parse header, sort pieces, concatenate
                            ▼
                   code  =  Base64( Zstd( stream ) )          ← version 2
                            │ decode, decompress
                            ▼
   stream  =  ColorMap  StringMap  Instance-tree              ← all versions
```

### 4.2 The 72-symbol alphabet and integers

All numbers are **big-endian base-72** written with this alphabet (index 0 first):

```text
bcdfghjkmpqrtvwxy346789!"#$%&'()*+,-./:;<=>?@BCDFGHJKMPQRTVWXY[\]^_`{|}~
```

Width `n` holds `0 … 72ⁿ − 1`: 1→71, 2→5,183, 3→373,247, 4→26,873,855, 5→1,934,917,631, 6→139,314,069,503. Value 0 is the symbol `b`, which is why `b` doubles as the terminator in several places below. Alphabet details are in Appendix B.5.

### 4.3 Primitive encodings

| Name | Symbols | Encoding |
|---|---|---|
| `Bool` | 1 | `b` = true, `c` = false (note: reversed from intuition — `b` is index 0) |
| `ShortestInt` | 1 | 0–71, clamped |
| `ShortInt` | 2 | 0–5,183, clamped, **silent** |
| `Int` | 4 | 0–26,873,855, clamped with a warning |
| `LongInt` | 6 | 0–139,314,069,503, clamped with a warning |
| `SignedInt` | 3 | `value + 186,623`, so −186,623 … +186,623 |
| `Float` | 5 | `SignedInt(floor(x))` then 2 symbols for `round(frac × 5183)` |
| `BoundedFloat` | 3 | `round(x × 373,247)` for `x` in 0…1 |
| `ShortBoundedFloat` | 2 | `round(x × 5,183)` for `x` in 0…1 |
| `Vector2` / `Vector3` | 10 / 15 | 2 / 3 `Float`s |
| `UDim` / `UDim2` | 10 / 20 | `Vector2(Scale, Offset)`; two UDims |
| `Color3` | 6 | 3 `ShortBoundedFloat` (R,G,B) |
| `CFrame` | 24 | position as 3 `Float` (15), then rotation as 3 `BoundedFloat` (9): the **XYZ Euler angles** from `ToEulerAnglesXYZ`, each normalised `(angle + π) / 2π` |
| `FloatRange` | 10 | `Vector2(Min, Max)` |
| `FloatSequence` | 2 + 7k | `ShortInt(k)`, then per keypoint: `ShortBoundedFloat(time)`, `Float(value)`, `Float(envelope)` |
| `ColorSequence` | 2 + 8k | `ShortInt(k)`, then per keypoint: `ShortBoundedFloat(time)`, `Color3` |
| `String` | 4 + len | `Int(byteLength)` followed by the bytes. Version ≥ 1 first escapes: `&`→`&&`, newline→`&n`, CR→`&r`, tab→`&t`. **Length counts bytes after escaping.** |
| `InstanceReference` | 4 + len | a `String` containing the index path (§3.6) |
| enums | 1 | one symbol = the enum table value (Appendix B.4) |

> The plugin's own reader comments say "Vector3: 24 symbols" and "CFrame: 36 symbols". Those comments are stale; the real widths are 15 and 24, which is what the code does.

### 4.4 Raw stream layout

```text
stream     := ColorMap StringMap Instance
ColorMap   := ShortInt(n)  Color3{n}
StringMap  := ShortInt(n)  String{n}
```

Indices into both maps are **1-based**; **index 0 means "nil / absent"** and a decoder must accept it for any `String` property, `Color3` property or `String`/`Color3` attribute **value** (it yields "no value", not an error). **[O]** Real exports contain it: a `UnionOperation` with no `MeshId` attribute is written as `MeshId` → index 0. (The first draft of this spec said index 0 meant nil but the first decoder rejected it; a real map caught that.) An attribute *name* is never 0. Entries are numbered in **first-use order during a depth-first write** (parent's own properties and attributes, then children in order).

### 4.5 Instance records

```text
Instance   := 'c'                                            ; Nil — unsupported class, no body, no children
            | TypeId  PropList  [AttrList]  Instance*  'b'   ; supported class
PropList   := ( PropId  PropValue )*  'b'
AttrList   := ( AttrTypeId  NameIdx:ShortInt  AttrValue )*  'b'      ; only for 6 classes
```

- `TypeId` is 1 symbol (Appendix B.1). `Nil` = 1, `Model` = 2, `Folder` = 3, `Part` = 4, `PartNoAttributes` = 5, `BoolValue` = 6, …
- `PropId` is the **1-based position** of the property in the class's table (Appendix B.3). **Only properties that differ from the default are written.**
- `PropValue` for a `String` property is a `ShortInt` index into the **string map**; for a `Color3` property it is a `ShortInt` index into the **colour map**; for `InstanceReference` it is inline; everything else is inline per §4.3.
- `AttrList` exists only for `Model, Folder, Part, BoolValue, MeshPart, UnionOperation`. A `Part` with **no attributes** is written as `PartNoAttributes` (type 5), which has no `AttrList` at all.
- Attribute values: `String` → `ShortInt` index into the string map; `Color3` → `ShortInt` index into the colour map; `Bool`, `Float`, `LongInt`, `Vector3`, `CFrame` inline. The writer emits `LongInt` for non-negative integers and `Float` for any other number; it never emits `Int` or `SignedInt` (the reader accepts them).
- An unsupported class writes a single `c` and **its children are not written**.
- The record ends with the end-of-children symbol `b`.

### 4.6 What the root contains

Besides what the author built, the writer appends two `StringValue`s to a *clone* of the root before encoding: `TableMissionSetup` (JSON) and `StringMissionSetup` (source; with child StringValues for sub-modules). They are ordinary instances in the stream **[V]**.

### 4.7 Compression (version 2)

`code = Base64( Zstd( stream, level ) )` using Roblox `EncodingService` **[V]**. Default level **4**; the workspace attribute (or feature string) `SerializerCompressionLevel` may set −7…22 (values are rounded then clamped, with a warning) **[V]**. **[O]** In a real export the Base64 is the **standard alphabet (`+` and `/` appear) with `=` padding**, containing no line breaks, and the Zstd frame is a single-segment frame with its content size present, no checksum and no dictionary. Decoders should still tolerate missing padding and whitespace.

### 4.8 Pieces, header, gist wrapper and the loader

**Header (7 symbols)** — present on every piece:

| Field | Type | Meaning |
|---|---|---|
| version | `ShortestInt` | code version (0, 1 or 2) |
| mapId | `ShortInt` | random 0–5,183 chosen per export, so pieces of different missions can't be mixed |
| current | `ShortInt` | 1-based piece number |
| total | `ShortInt` | number of pieces |

**Splitting.** The finished code (after compression) is cut into slices of **199,992 characters**; each piece is `header + slice`, so each paste is ≤ 199,999 characters. (N3 describes an edge-case bug.)

**Gist form.** A single piece with `current = total = 1`, prefixed by a human-readable comment:

```text
!!!<free text: how to play, Mission Name, Creator, Version, Briefing>!!!<header><code>
```

**Loader algorithm** (this is what the plugin's readback button does, and so what BreachEngine's loader should do):

1. If the input starts with `http(s)://`: normalise a `gist.github.com/<user>/<id>` link to `gist.githubusercontent.com/<user>/<id>/raw`, accept `…/raw` and `…/raw/<rev>/<filename>` forms, and `GET` it (Roblox `HttpService`).
2. If the text starts with `!!!`, strip through the **first following `!!!`** (lazy match). Reject if there is none.
3. Parse the 7-symbol header.
4. Keep a state `{version, total, mapId}` from the first piece; reject any later piece with a different version, mapId or total.
5. Store the slice under `current`. When all `1…total` are present, concatenate in order.
6. Select decoding rules by header `version` (§4.9).
7. If version ≥ 2: Base64-decode, then Zstd-decompress. Then decode `stream` (§4.4–4.5).
8. Mark the decoded root loaded (`DebugMission.Loaded = true`) so deferred references resolve.

### 4.9 Versions

| Code version | Escape newlines in strings | Compression |
|---|---|---|
| 0 | no | none |
| 1 | yes | none |
| 2 *(latest)* | yes | Zstd + Base64 |

The version number is in the header, not in the stream. A compliant decoder must switch behaviour per header and **must not assume a mid-stream version**.

### 4.10 Limits and quirks (read before you trust round-trips)

- **Capacity:** ≤ 5,183 unique strings, ≤ 5,183 unique colours (N4); string ≤ 26,873,855 bytes; coordinates within ±186,623 studs.
- **Precision:** see N8. Colour 0.5 decodes to 0.50010. A rotation is three Euler angles, so gimbal-lock orientations may re-encode differently.
- **Attribute order is not stable** (N5), so **never diff codes**; diff decoded trees.
- **Attribute loss rules:** N1 (false dropped), N2 (only 6 classes keep attributes).
- **`Name` is written only if it differs from the class default**, and the defaults are copy-paste oddities: `Frame` defaults to `"ImageLabel"`, `MeshPart` and `UnionOperation` to `"Part"`, `BoolValue` to `"Value"`, `WedgePart` to `"Wedge"`. A decoder must use the table in Appendix B.3, not "class name".
- **Odd defaults that never matter:** `Sparkles.SparkleColor` defaults to `Color3.new(144, 25, 255)` (out of range), so any real value always differs and is always written.
- **Enum fallback:** an enum value not in the table is written as table index **1**.
- **`UnionOperation.MeshId`** is read from an *attribute* named `MeshId`, not a property, because Unions don't expose it.

### 4.11 Test vectors

These were produced by an **independent implementation written from the rules above** and then decoded back with a separate decoder (it round-trips). They are *derived from reading the source, not captured from the game*. Treat them as sanity checks; if the real game disagrees, the game wins.

**Primitives**

| Input | Output |
|---|---|
| `ShortInt(0)` | `bb` |
| `ShortInt(1)` | `bc` |
| `ShortInt(71)` | `b~` |
| `ShortInt(72)` | `cb` |
| `ShortInt(5183)` | `~~` |
| `Float(0)` | `-~~bb` |
| `Float(1.5)` | `.bb.b` (decodes to 1.50010) |
| `Float(-0.5)` | `-~}.b` (decodes to −0.49990) |
| `Float(10)` | `.bpbb` |
| `Color3(1, 0, 0.5)` | `~~bb.b` |
| `String("hi")` | `bbbdhi` |
| `String("a⏎b")` (version ≥ 1) | `bbbga&nb` (length 4 = `a`,`&`,`n`,`b`) |
| `BoundedFloat(0.5)` (identity rotation component) | `.bb` |

**A complete tiny mission — uncompressed stream** (this is the form you get *after* Base64 + Zstd decoding):

A root folder `DebugMission` holding (a) a `Part` named `Floor` at (0, 0.5, 0), size 10×1×10, colour (0.5, 0.5, 0.5), no attributes, and (b) a `BoolValue` named `Trigger1` with `Type = "TriggerZone"` and `IsGlobal = true`.

```text
bc.b.b.bbjbbbtDebugMissionbbbhFloorbbbmTrigger1bbbgTypebbbrTriggerZonebbbmIsGlobalfcbcbbhcbdd-~~bb-~~.b-~~bb.bb.bb.bbfbcg.bpbb.bbbb.bpbbbbjcbfbfbgbhgbjbbbb
```

Reading it:

| Piece | Symbols | Meaning |
|---|---|---|
| `bc` + `.b.b.b` | colour map | 1 colour: R,G,B each `.b` = 2592/5183 ≈ 0.5001 |
| `bj` | string map count | 6 strings |
| `bbbt` `DebugMission` … `bbbm` `IsGlobal` | 6 × `String` | indices 1–6: `DebugMission`, `Floor`, `Trigger1`, `Type`, `TriggerZone`, `IsGlobal` |
| `f` | TypeId 3 | `Folder` |
| `c` `bc` | PropId 1 (Name), ShortInt 1 | name = string #1 `DebugMission` |
| `b` `b` | PropList end, AttrList end | Folder has no other props or attributes |
| `h` | TypeId 5 | `PartNoAttributes` |
| `c` `bd` | Name = string #2 | `Floor` |
| `d` `-~~bb -~~.b -~~bb` `.bb.bb.bb` | PropId 2 (CFrame): X=0, Y=0.5, Z=0; rotation 3 × `.bb` (=0.5 → angle 0) | |
| `f` `bc` | PropId 3 (Color) → colour #1 | |
| `g` `.bpbb .bbbb .bpbb` | PropId 4 (Size): 10, 1, 10 | |
| `b` `b` | PropList end; end-of-children | (no AttrList for `PartNoAttributes`) |
| `j` | TypeId 6 | `BoolValue` |
| `c` `bf` | Name = string #3 | `Trigger1` |
| `b` | PropList end (no `Value` change) | |
| `f` `bg` `bh` | AttrTypeId 3 (String), name idx #4 `Type`, value idx #5 `TriggerZone` | |
| `g` `bj` `b` | AttrTypeId 4 (Bool), name idx #6 `IsGlobal`, value `b` (true) | |
| `b` | AttrList end | |
| `b` `b` | children end for `BoolValue`; children end for root `Folder` | |

### 4.12 Decoder plan **[P]**

Pseudocode of my own, for BreachEngine's `Codec` module (decode first, encode second):

```text
function decodeShare(text):
    if text startswith "http": text = httpGet(normaliseGistUrl(text))
    if text startswith "!!!":  text = afterFirst("!!!", afterOpening)   -- reject if missing
    pieces = {}
    for each piece in input:   -- a gist has exactly one
        h = readHeader(piece)                      -- 7 symbols
        enforce same {version, mapId, total}
        pieces[h.current] = rest(piece)
    require all 1..total present
    code = concat(pieces in order)
    rules = rulesFor(version)                      -- escapeNewlines?, compression?
    raw = rules.compression ? zstdDecompress(base64Decode(code)) : code
    cur = 1
    colours, cur = readColorMap(raw, cur)
    strings, cur = readStringMap(raw, cur, rules)
    root,   cur = readInstance(raw, cur, colours, strings)
    resolveDeferredReferences(root)
    return Mission(root, jsonDecode(root.TableMissionSetup))
```

Implementation notes:

- **Keep decode and validate separate.** The plugin interleaves them (attribute defaults are applied in the reader). A clean engine decodes to a raw tree, then runs the validator (§3.4) as a pass.
- **Bound everything.** Check indices against map sizes, `Int` lengths against remaining input, and recursion depth. A malformed code from a stranger must fail, not crash.
- **Standalone (C++/Rust) builds** need a Zstd decoder (libzstd) and Base64. Inside Roblox, `EncodingService` does both.

### 4.13 Feature flags (workspace attributes) **[V]**

Authors enable plugin features by attributes on `workspace`. Priority: the specific attribute, then the `SerializerFeatures` string, then `SerializerEnableAllFeatures`.

| Flag | Effect |
|---|---|
| `ReadDocs` | must be exactly `true`; adds the *Gist Code* button |
| `Readback` | adds a button that decodes a pasted code/URL back into Studio |
| `APIDev` | adds *Preserialize Preview* (shows the clone after plugin hooks, before encoding) |
| `SerializerCompressionLevel` | Zstd level, −7…22 (default 4) |
| `SerializerCompressionStats` | `true` prints before/after sizes |
| `SerializerNotifsDisabled` | `true` hides on-screen notifications |
| `SerializerFeatures` | `"Flag\|Name=value\|Other=true"`; values may be numbers, quoted strings or booleans |
| `SerializerEnableAllFeatures` | `true` enables everything not explicitly set (`SerializerCompressionLevel` and `SerializerNotifsDisabled` ignore it) |

### 4.14 Plugin extension API **[V]**

Third-party plugins can hook the exporter (API version 1): hook types `PreSerialize`, `PreSerializeMissionSetup`, `APIExtensionLoaded`, `APIExtensionUnloaded`, `SerializerUnloaded`; read-only access to the attribute map and attribute types; a notification channel. Relevant to BreachEngine because community tools (e.g. a prefab system) rewrite the mission *before* encoding, so the stream you receive is already post-processed. Nothing to implement on the consumer side.

---

## 5. BreachEngine architecture

### 5.1 Layers **[P]**

```text
┌───────────────────────────── Client UI ─────────────────────────────┐
│ objectives · notifications · dialogue/locales · hacking tablet · map │
└───────────────┬───────────────────────────────────────┬─────────────┘
                │ replicated variables (Globals)         │ ClientState
┌───────────────▼───────────────────────────────────────▼─────────────┐
│ Simulation:  bots · props · triggers · combat/alert · hacking graph  │
├──────────────────────────────────────────────────────────────────────┤
│ Logic:  variable store · expression evaluator · StateComponents ·    │
│         StateScript VM · randomisation (seeded)                      │
├──────────────────────────────────────────────────────────────────────┤
│ World:  cells · links · nodes (Meadow) · spatial queries             │
├──────────────────────────────────────────────────────────────────────┤
│ Mission:  loader · validator · Mission model (typed tree + setup)    │
├──────────────────────────────────────────────────────────────────────┤
│ Formats:  IE-code codec (§4)   ·   BreachEngine Standalone (§5.5)    │
└──────────────────────────────────────────────────────────────────────┘
```

Rule: **each layer may depend only on the ones below it.** The Formats layer has no engine dependencies, so it can be unit-tested (and reused by a headless tool) without Roblox.

### 5.2 What exists today **[N]**

- `game.ReplicatedStorage.BreachEngine.Locales` — a ModuleScript exposing version information in a `GetStableVersion` / `GetDebugVersion` style.
- A version label (`StarterGui.VersionGui` → `VersionLabel`), shown or hidden with **Ctrl+H**, driven by a LocalScript that reads the Locales data.
- A BreachEngine test map whose geometry you compared against the official *Deposit* template from the tooling repo.

### 5.3 Proposed module layout **[P]**

```text
ReplicatedStorage.BreachEngine
├─ Locales            (exists)    version + localised strings
├─ BreachCodec        IE-code decoder — ONE portable pure-Luau file (built; see breach-codec/)
│                     (encode comes later; tables are generated into the file by tools/gen_tables.py)
├─ Mission/
│   ├─ Model          the typed tree + Setup + Settings
│   ├─ Validator      attribute rules (§3.4)
│   └─ AttributeMap   data, generated from Appendix A
├─ World/             Cells, Links, Nodes, SpatialQuery
├─ Logic/             Variables, Expr, StateComponents/, StateScript/, Random
├─ Sim/               Props/, Bots/, Triggers/, Combat/, Alert/, Hacking/
└─ Client/            UI, Objectives, Notifications, Dialogue
ServerScriptService.BreachEngineServer   (authority; owns Logic + Sim)
```

Data-driven where possible: `AttributeMap` and the codec tables should be **generated files**, not hand-typed. Appendices A and B were generated mechanically for exactly this purpose; regenerate rather than edit.

### 5.4 The in-memory mission **[P]**

```text
Mission
  .Root        : Node tree          -- ClassName, Name, Properties{}, Attributes{}, Children[]
  .Setup       : table              -- from TableMissionSetup JSON (Globals, Internals, Objectives, …)
  .Settings    : table              -- from CustomMissionSettings (name, author, version, EnforceCellLinks)
  .Seed        : integer            -- per-run mission seed (§7.5)
  .Index       : lookup tables      -- by Type/Name (components), by Tag/ServerTag, by NetworkId
```

Decode into this neutral tree; materialise real Roblox instances (or headless equivalents) from it afterwards. That keeps the codec testable and lets Standalone maps (§5.5) feed the same pipeline.

### 5.5 BreachEngine Standalone — on-disk map format **[N]**

*Recorded design.* A map is a directory:

```text
MapName/
├─ DataModel/
│  └─ game/                       ← expandable like Explorer's "game"
│     └─ <Service>/<Instance>/…   ← one filesystem entry per DataModel instance
└─ rbxasset/                      ← identical to "rbxasset://" (see below)
```

Rules as you recorded them:

- Every DataModel instance is a **real filesystem instance**. A `Folder` is a literal directory holding exactly one `Instance.metadata` (or `Instance.property`; the name works either way; still a single file) in **Markdown format**.
- A **non-Folder** instance additionally has a file named **`Contents`** that holds its instance-specific data — script source, etc.
- **Child order is not stored.** It is derived by enumerating the filesystem (`tree` on Linux, `find` elsewhere).
- **Meshes and images live under `rbxasset/`**, never in `Contents`. Because a folder literally named `rbxasset://` may not be creatable on some filesystems, a folder named `rbxasset` is **equivalent** to `rbxasset://`, and any reference to `rbxasset://` resolves into it.

**Things this design leaves open — please decide [P]:**

1. **Child order versus instance references.** §3.6 shows that IE codes reference instances by *child index*. If order is derived from `find`/`tree`, it is **not guaranteed stable** (`find` order is filesystem-dependent; `tree` sorts alphabetically). Three ways out: *(a)* sort by name and make the importer assign names that preserve order (e.g. zero-padded prefix `0007_Door`); *(b)* store an explicit `Order` property in `Instance.metadata`; *(c)* store references by a stable id instead of an index and translate at import. I recommend **(b)+(c)**: explicit order plus resolved references, so the on-disk form doesn't depend on the OS.
2. **Does a non-Folder instance also become a directory** (so a `ModuleScript` or `Model` can have children)? Your note doesn't say; I assume yes.
3. **File names conflict with your headless-runtime sketch**, which uses `instance.meta` and `Data.gz`. Pick one vocabulary for both projects.
4. **Name collisions.** Roblox allows siblings with equal names; a filesystem doesn't. A suffix scheme or the explicit-order file (above) is needed.
5. **Metadata schema.** A minimal Markdown shape, as a suggestion:

```text
# Instance
- ClassName: BoolValue
- Name: Trigger1
- Order: 7
## Properties
- Value: false
## Attributes
- Type: "TriggerZone"
- IsGlobal: true
```

### 5.5.1 The implemented Standalone format (M3) **[done]**

`BreachStandalone.luau` turns a tree into a **list of files** (`{path, text}`) and back; it does no file I/O, so any host (Roblox, C++, Termux) writes and reads the actual files. Decisions taken for the open items above:

| Item | Decision |
|---|---|
| Child order (#1) | **Explicit `Order`** in each `Instance.metadata`; the filesystem's enumeration order is never used |
| Instance references (#1) | Every instance has a stable **`Id`** (`n1`, `n2`, …); references are stored as `{"RefId":"n42"}` and converted back to child-index paths on decode |
| Non-Folder instances are directories too (#2) | **Yes** — every instance is a directory holding `Instance.metadata`, so any instance can have children |
| Name collisions / odd names (#4) | Directory names are sanitised (`[A-Za-z0-9_.-]`, ≤ 80 chars, no trailing dots), made **unique case-insensitively** (`name~2`), never `Contents`/`Instance.metadata`; the real name lives in the metadata. Tested with `A`/`a`, `/`, `..`, empty, newline, quotes, emoji, `CON`, `Contents`, `Instance.metadata` |
| `false` (D5) | Stored literally; no exporter-style dropping |
| Metadata schema (#5) | Markdown, one JSON value per line (below) |
| File names (#3) | `Instance.metadata` and `Contents` (this project's names; the headless-runtime sketch should adopt them) |

```text
DataModel/game/Workspace/DebugMission/Instance.metadata
DataModel/game/Workspace/DebugMission/Props/Door1/Instance.metadata
DataModel/game/Workspace/DebugMission/StringMissionSetup/Contents      <- raw text of a StringValue
```
```text
# Instance
- ClassName: "Part"
- Name: "Floor"
- Id: "n12"
- Order: 3
## Properties
- CFrame: {"EulerXYZ":{"X":0.1,"Y":0.2,"Z":-0.3},"Position":{"X":1.25,"Y":0.5,"Z":-3}}
- Material: "Concrete"
## Attributes
- Tag: "x"
```
Keys are sorted and numbers are written with `%.17g`, so output is **deterministic** and a round trip is **bit-exact**. Awkward keys are written `- ["odd key: x"]: value`. A `StringValue`'s text goes in `Contents` (raw, no escaping) instead of `Value`. Files may be supplied in any order. Verified: both real maps round-trip with every property, attribute, order and number identical.

### 5.5.2 The mission model (M3) **[done]**

`BreachMission.luau` wraps a decoded mission: optionally runs the validator (engine mode), assigns `Id`/`Path`/`RefPath`/`Index` to every node, resolves instance references (`TargetId`), and builds indexes — `byClass`, `byComponent` (a `BoolValue`'s `Type`), `byTag` (`Tag`/`StaticTag`), `byNetworkId`, `folder(name)`, `findPath("Cells/Lobby")`, `node(id)`, `stats()`. Building the model for the 6,148-instance map takes 0.02 s. It never creates engine objects; materialisation is the host's thin layer over it.

### 5.6 Loading pipeline **[P]**

```text
source  ─┬─ IE code / gist URL ──► Codec.decode ─┐
         └─ Standalone folder  ──► Disk.read   ──┴─► raw tree
raw tree ─► Validator (defaults, type checks, warnings)
         ─► Mission model (+ Setup JSON, Settings)
         ─► World.build  (cells, links, nodes)
         ─► Logic.init   (variables, components, StateScripts)
         ─► Sim.spawn    (props, bots)
         ─► client replication → UI
```

---

## 6. Spatial model — cells, links, nodes

*Rewritten in 0.7 from the two real maps; the earlier text was [R] and partly wrong. Implemented by `BreachWorld.luau`.*

### 6.1 Cells **[O]**

- A **cell** is a `Model` (or `Folder`) directly under `Cells`. Its **name is a trespass zone class**, not a unique id: The Diplomat has 55 cells named `InsideHighlyRestricted` ×14, `OutsideHighlyRestricted` ×9, `OutsideRestricted` ×7, `Roof` ×5, `EmployeesAreaInside` ×4, `EmployeesAreaOutside` ×3, `InsideRestricted` ×3, `OutsideEmpTrespass` ×3, and a few of `Default`, `InsideBluffable`, `InsideWeakerWithBluff`, `OutsidePublic`, `SecurityCenter` (the names are the keys of `MissionSetup.Cells`, §8.4).
- Its **volume** is its `Floor` and `Roof` `Part` children (a cell may have several of each; sizes like 23×1×24, floor at y ≈ 12.7, roof at y ≈ 25.3). A point is inside if it is within some `Floor` footprint **above** that floor and within some `Roof` footprint **below** it; a cell with no `Floor` waives the floor test (this is the plugin helper's rule **[V]**, and **[O]** on real maps: for ≥ 90% of cells the cell contains its own first navigation node).
- **Attributes seen on cells:** `Location` (localisation key, e.g. `Location.Bridge`), `Path` (the navigation map, §6.3), `Preposition` (`by`), `ServerTag`. `Cells` itself carries `LinkList`, which is **template residue and must be ignored** (§6.4).
- `GetZone`-style lookup returns the **first** containing cell in folder order **[V]**; shared boundaries make several cells contain the same point, so `BreachWorld` offers `cellAt` (first) and `cellsAt` (all).

### 6.2 Links **[O]**

`Cells/Links` holds `Part`s **named `Link`** (90 in The Diplomat, 22 in The Interception) — flat slabs (`Y` size 1, footprints from under 1 up to ~29 studs on a side, 67 of 90 rotated) placed across a doorway. Attributes: `Move` (all 90 `true`), `Open` (all 90 `true`), `Path` (**NPCs may path across**; `true` on only 25 of 90), `Sound` (1 on all 90) and `OneWay` (`true` on 3, absent on the rest). Link parts do **not** record which cells they join — that is geometric (§6.4).

### 6.3 Navigation data **[O]**

Each cell's `Path` attribute is a JSON string (empty on some cells, e.g. roofs):

```json
{"Node":[[x,y,z],...], "Link":[[2,3],[1,3],[2,1]], "Placed":[[x,y,z],...]}
```
- `Node` — auto navigation nodes, ~9 studs apart.
- **`Link` is an adjacency list, one entry per `Node`**: entry *i* lists the 1-based indices of the nodes adjacent to node *i*. (My first reading — a list of node *pairs* — was wrong and dropped a quarter of the edges; an entry such as `[17,1,23,12]` showed it.) Entries are *mostly* symmetric; asymmetric ones (10 in The Diplomat) are one-way.
- `Placed` — manually placed nodes (281 in The Diplomat). They are **not** referenced by `Link`; their role is unverified, so they are kept but not in the graph.
- The `Nodes` *folder* is something else: named sets of patrol/behaviour points for bots (`Guard/InsidePatrol`, `Snipers`, `Employee/Chef`, `Dynamic/IntercomNode`…), each a 4×0.2×2 `Part` named `Node`.

### 6.4 Which cells does a link join? **[P — heuristic; calibrated against real patrol routes in 0.18, default 0.15]**

The data does not record it, so `BreachWorld` samples a 5×3×5 grid of points inside each link box and joins the cells that contain at least `minHitFraction` of the best cell's hits (**0.15 since 0.18**, 0.50 before; see below and §13.14).

**Correction (0.8):** version 0.7 of this section calibrated that rule against `Cells.LinkList`, a JSON map `GUID → [GUID, …]` (42 nodes, 54 adjacent pairs) that I took to be the authoring plugin's cell graph. A third real map showed it is **byte-identical (6,403 characters) in The Diplomat and The Peacemaker**, two unrelated missions of 55 and 90 cells. It is therefore leftover template data, **not a description of either map**, and the calibration was meaningless. There is **no ground truth in the exported data** for link-to-cell adjacency.

What the heuristic produces (adjacent pairs among cells with a link), for different thresholds:

| `minHitFraction` | The Diplomat (55 cells, 90 links) | The Peacemaker (90 cells, 149 links) |
|---|---|---|
| any touched cell (≈ 0) | 42 cells · 100 pairs · 14 components | 79 · 183 · 13 |
| 0.25 | 39 · 79 · 18 | 79 · 158 · 13 |
| 0.50 (M4 default) | 35 · 70 · 21 | 75 · 117 · 18 |
| 0.75 | 31 · 47 · 26 | 65 · 75 · 32 |
| 0.90–1.0 | 27 · 28 · 33 | 48–49 · 38–40 · 54–55 |

Lower thresholds connect more of the map but make doorways touch more than two cells; higher ones fragment it. **Calibrated in 0.18 (M8b):** the maps' own patrol routes are a ground truth, because a guard's consecutive route nodes must be reachable. With 0.50, only 64% / 83% / 83% of the real legs (Diplomat / Peacemaker / Project) were pathable; The Project's links 34/61-type overlaps (30 vs 75 sample hits, ratio 0.40) lost their second cell. At **0.15** The Project is 100% pathable and the others do not get worse (§13.14). Before 0.18 this section said: nothing here says which is right. Navigation does not depend on it for movement *inside* a cell, and `world.Diagnostics` reports what the heuristic produced. Settling it needs observation of the real engine (for example how far sound or spawn range travels on a known map).

**Copied navigation data [O].** Nine of The Peacemaker's 85 cells with navigation data have *no* node inside their own volume; five of them share an identical 38-node list starting at the same point, and others point at regions far from the cell. Their `Path` attribute was copied from other cells (the author duplicated cells). `BreachWorld` flags these as `NavSuspect`, adds a warning, counts them in `Diagnostics.navSuspectCells` and still keeps their nodes in the graph (the engine presumably uses them as written).

### 6.5 What `BreachWorld` provides

Cells with their boxes, zone class, attributes and nav data; links with their cells; adjacency, BFS `hops`/`route` (optionally only `Open` or only `Path` links); cell and navigation components; and **A\*** over a navigation graph made of every cell's nodes (undirected unless listed one way) plus, for each `Path = true` link, one edge between the nearest node on either side. The graph is deliberately conservative: in The Diplomat it has 424 nodes in 33 components (largest 227), because only 25 links allow NPC pathing. Rotation is read as Roblox Euler XYZ (R = Rx·Ry·Rz) — assumed, with a 90° test that is sign-independent; a Roblox run should confirm for other angles.

## 7. Logic layer

### 7.1 Variables **[R]**

Expressions (§7.2) read **global state** unless an attribute says it is client-scoped.

| Store | Declared in | Replicated | Purpose |
|---|---|---|---|
| **Globals** | `MissionSetup.Globals` | to every client, automatically | shared mission state |
| **Internals** | `MissionSetup.Internals` | no | server-only state; surface via a Global if clients need it |
| **ClientState** | `MissionSetup.ClientState` | per client | objectives that differ per player |

State attributes (kind `state`, Appendix A) are **names of these variables**, validated as no-whitespace strings **[V]**. Components *write* them (`TriggerVariable`, `SetVariable`, `…Variable`) and expressions *read* them.

**[O] Variable names are case-insensitive (found in M6/The Project).** The real maps spell the same variable several ways, and only work if the engine treats them as one: The Project has 12 such groups (`OpenSeasame` / `Openseasame` / `openseasame`; `Bombstarted` defined, `BombStarted` read; and the pair that decides the whole detonation chain, **`PowerBox3`** written by the prop's `PowerArea` and **`Powerbox3`** read by `Loudmusic3 = Powerbox3`); the Peacemaker has `CommanderPCUnlocking` vs `CommanderPcUnlocking`; the Diplomat has none. The Store, Reactor, Replica, CFrame objects and scripts therefore compare names without regard to case; the **first spelling used** is the canonical one (what a packet carries and what `logic.Store.Globals` is keyed by). Undeclared reads are still reported as written. Not established: whether script `#locals` are also case-insensitive (they are case-sensitive here), and instruction names are case-insensitive by construction.

### 7.2 Expression language **[R]**

- **No boolean type.** Everything is a number or string; **`0` and the empty string are false**, anything else true.
- Operators: `!` not; `||` or; `&&` and (both short-circuit); `==`, `~=`, `>`, `>=`, `<`, `<=`; `+ - * /`.
- **There is no `if`.** Branching is `&&`/`||` chains evaluated left to right, stopping once the result is known. Short-circuiting is therefore *load-bearing*, not an optimisation.
- String literals need `[...]`; nested expressions inside string-context attributes use `{...}`.
- `RNG seed min max` combines the per-mission seed with the caller's seed (§7.5).
- **[V]** The plugin only checks that an `expr` attribute is a boolean, string or number. Parse errors are the engine's problem, so BreachEngine's evaluator should *report* them (with component name and attribute) rather than silently yield 0.

**[O] Corrections from the real maps (M5).** Compiling every expression in both maps (39 + 170 Setup entries, 850 + 3,480 expression attributes, plus 42 string-context ones) showed this section was incomplete:

- **`%` exists** (floored, like Lua): `((GuardInfo + 4) % 8) + 1`.
- **`&&` and `||` return an operand, not a boolean** — `cond && 4 || other` means "4 if cond else other", and `Fled && [Notify.Fled]` yields a string. Used throughout both maps.
- **`!=` is valid** as well as `~=` (5 uses of `~=`, 1 of `!=`).
- **Two functions** exist, both written prefix-style: `RNG seed min max` and `FLOOR (expr)` / `FLOOR(expr)`. No others appear in the data, so none are implemented.
- **Variable names may start with a digit** (`!1Searched`, 29 uses).
- **Setup entries are expressions, not values** (§7.1). `ClothesFound = (ClothesLocation == 1 && GuardSearch01) || …` is re-evaluated when its inputs change, and a **self-reference reads the variable's previous value**, which makes a latch: `CommanderPCHackedLoud = CommanderPCHackedLoud`, `Challenge_KeepCalm = (Challenge_KeepCalm == 4 || …) && 4 || StandardChallengeState`.
- **Two attributes typed `expr` in Appendix A are string-context**: `DisabledTitle` / `DisabledSubtitle` hold CustomStrings keys (`UI.AlreadySearched`) or `{template}` text, not expressions.
- **One authoring typo exists**: `Props/TriggerLocalChat.Active` in The Diplomat ends in a stray `)`. BreachExpr rejects it (with column). Whether the real engine tolerates it is unknown.

**[V→done] Implementation:** tokeniser → Pratt parser → AST → evaluator, in `BreachExpr.luau`. Dependencies are **static** (every identifier in the expression — a safe superset of what one evaluation reads) rather than dynamic per evaluation: simpler, deterministic, and short-circuiting still prevents dead branches from running, so `x ~= 0 && 10 / x` never divides by zero and `RNG` on a dead branch is never called.

#### 7.2.1 Choices the data does not settle **[P]**

| Question | Chosen behaviour |
|---|---|
| Precedence (high→low) | `! -` unary · `* / %` · `+ -` · `< <= > >=` · `== ~= !=` · `&&` · `\|\|` (C-like; consistent with every real expression) |
| Value of a failed `&&` | the falsy left operand (`0` or `""`), like Lua |
| `==` across types | `[1] == 1` is false; ordering across types coerces to numbers and reports `type-mismatch` |
| Arithmetic on text | numeric strings coerce; otherwise 0 and a `type-mismatch` report |
| Division / modulo by zero | 0 and a report (never inf/NaN) |
| Undeclared variable | reads as 0 and is counted in `logic.Undeclared` |
| `RNG` | integer in `[min, max]` inclusive from a 32-bit hash of (mission seed, caller seed): reproducible, **not** Entry Point's own sequence |
| `FLOOR 7 / 2` | `(FLOOR 7) / 2` (prefix functions take one primary argument) |

#### Other functions
If a later map uses another function (`CEIL`, `ABS`, …) it will compile as a variable read and show up in `Undeclared`; add it to `Expr.FUNCTIONS` and `evalNode`.

### 7.3 StateComponents

Map-wide `BoolValue`s whose boolean value is irrelevant; behaviour comes from the `Type` attribute **[V]** plus attributes. Names and attribute lists are **[V]** (Appendix A, "logic/state" block); semantics are **[R]** unless marked.

| Family | Components | What they do **[R]** |
|---|---|---|
| Combat | `CombatSpawner`, `CombatWaveSpawner`, `ReinforcementPool`, `SniperSpawner`, `CoverFillSpawner`, `ScriptedBotSpawn` | *when* and *how many* enemies spawn; pool/wave limits |
| Alert & search | `AlertRaiseCondition`, `AlertLowerCondition`, `AlarmedBehaviorOverride`, `SearchPatternCondition`, `StandardRadioAlertReduction` | alert level changes and NPC responses |
| Bot control | `CustomBehaviorCondition`, `BotStateTracker`, `ConditionalBotTag`, `ScriptedTakedown`, `RandomBotSpawner`, `TrackBotsDown` | apply behaviours, count bots by state, tag bots |
| Conversation | `ConversationGenericSocialEngineering`, `ConversationResponseCustomBehavior`, `CustomConversation`, `LocalChat`, `ServerChat`, `AutoConversationTrigger` | dialogue and social engineering |
| Hacking | `CustomHack`, `HackingNodeStatus`, `HackableDoor`, `HackableElevator`, `NetworkRouter`, `TargetLureHack`, `RemoteWeaponNode`, `HackingNodeHighlight` | hacking-network actions |
| Items | `ItemStateTracker`, `ItemSwapCondition`, `BotItemSpawn`, `TrackItemHeldServer` | track and mutate tagged items |
| Variables | `StateUpdate`, `ConditionalStateUpdate`, `DelayedStateUpdate`, `DynamicExpression`, `LerpOperation`, `VariableShuffle`, `StateLock`, `CodeGenerator` | compute and set variables |
| Time | `TimerComponent` | counts `StartValue`→`TargetValue`; outputs seconds and `MM:SS` |
| Mission flow | `MissionCompletionTrigger`, `MissionFailedTrigger`, `Notification`, `MusicController`, `BlackoutScreen`, `GameCredits` | end conditions, UI and audio |
| Intel UI | `IntelCharacterPortrait`, `IntelConnection`, `IntelPrimaryText`, `IntelSidebar`, `IntelSubText` | hacking-tablet intel panel |
| Randomisation | `HiddenShuffle`, `VariableShuffle` | see §7.5 |
| Scripting | `StateScript` (no validation entry) | §7.4 |

Several have verified shapes you can lean on immediately: `MissionCompletionTrigger` = `Condition`, `Timeout`, `CompleteVariable`; `Notification`, `TimerComponent`, `ReinforcementPool` (`PoolName`, `PoolLimit`, `WaveVariable`, `RemainingVariable`, `ActiveVariable`, `WaveResetTime[Decrease/Minimum/Threshold/MaxTime]`) — exact lists in Appendix A.

### 7.4 StateScript **[R]**

A small stack-based scripting language for logic the declarative system can't express; the plugin **does not validate** it (§3.4 rule 3), so syntax errors only surface at runtime. Two trigger modes: **`Run`** (starts when its condition becomes non-zero, halts at zero) and **`TriggerEvent`** (a fresh independent thread on every non-zero change, not halted at zero).

| Group | Instructions |
|---|---|
| Variables | `INIT var val` (once, at creation) · `SET var val` · `INC`/`INCREMENT var` · `DEC`/`DECREMENT var` · `ALLOC var` · `ALLOCARRAY var n` (`var0…var(n-1)`) · `GUID var` |
| Flow | `GOTO label [cond]` (labels are `:label`) · `CALL label args…` · `CALLIF label cond args…` · `RETURN` (empty stack ≡ `KILL`) · `KILL` · `THREAD label args…` |
| Stack | `PUSH val` · `POP var` · `PEEK var` (per run; not persisted across restarts) |
| Waiting | `WAIT time [var]` · `WAITHEARTBEAT [var]` (≈ 1/60 s) · `WAITFOR expr` · `WAITFORCHANGE expr` |
| Math / data | `LERP v1 v2 t out` (numbers and CFrames) · `CFR var [str]` · `CFRANGLES var rad` · `CFRDEGREES var deg` · `CFRINV var [inv]` · `CFRCOPY var propTag` · `SHUFFLE out seed items…` |
| World | `MOVETO propTag cf` (needs `ScriptMove=true` on the prop) · `ANIMATE propTag cf time` · `ANIMATECUBIC …` · `COPYTO propTag cf newTag attr val …` · `DELETE propTag` (most recent only) · `DELETEALL tag` (expensive) · `SPAWNBOT template cf attr val …` · `INITSTATECOMP template attr val …` |

Syntax **[R]**: lines are space-separated `CMD ARG…`; `[ … ]` groups a token or evaluates an expression; `[[ … ]]` is a literal string; a leading `*` forces the whole line through the evaluator (costly; rarely needed); `#Name` is a hashed local or a parameter attribute on the StateScript instance (parameters are **not** pre-parsed as expressions). Debug attributes: `DebugVariable`, `DebugLineVariable`.

**Pitfall to reproduce faithfully [R]:** `*WAITFOR {cond}` preprocesses the condition to a constant and either returns instantly or hangs forever; use `WAITFOR cond`.

**[O] Corrections from the 26 real scripts (M6).** Both maps together contain 26 StateScripts; they use 14 of the 37 documented instructions. Reading them showed:

- **`CALLIF` takes the condition first**, then the label, written with a colon: `CALLIF [RevealSkipped == 1] :KILLLABEL` (the old table said `CALLIF label cond`). Labels are accepted with or without the leading `:` everywhere (`GOTO GuardSpawnLoop`, `CALLIF … :KILLLABEL`).
- **`*` and `{ }`.** A leading `*` means "substitute `{x}` in this line every time it runs" — with nesting, inside-out: `*SPAWNBOT Guard{#Iteration} {Guard{#Iteration}} Nodes Guard{#Iteration}`. A line **without** `*` is parsed once and its braces are left alone **[P]**.
- **`[ … ]` is the full expression language** with `#locals` and **CFrame multiplication**: `ANIMATECUBIC Heli [#HeliPos * #Rot] 15`. `[[ … ]]` is a literal string: `CFR #p [[-119.696, 36.5, -181]]`.
- **`#name` is a thread-local (or a parameter); a name without `#` is a global mission variable** — `SET TruckFinish 1`, `SET BlastDoorFarOpen 1`, `INIT SecurityRoom 0`. Global variables can hold **CFrames** (`CFRCOPY SecurityRoom SecurityRoom` stores a prop's CFrame in a global that another line later passes as a CFrame argument, `{Guard1}` → `SecurityRoom`).
- **`TriggerEvent` is an expression**, not only a name: `TruckSpawnTimer == 80 && LoudArrivalDelay == 0 && !RevealSkipped`. A thread starts on each change to a non-zero value.
- **`Run` and `TriggerEvent` may both be set** (4 of 26 scripts do); they are independent.
- **`MOVETO` takes a third argument** (`MOVETO LoudTruck [#Pos1 * #Rot] 0`); it is passed through. `ANIMATE`/`ANIMATECUBIC` do **not** block (scripts `WAIT` for the same duration right after).
- **`INIT name` with no value occurs** (`INIT WingEntrancePatrol`, a real typo); it gives 0.
- **Scripts depend on other components**: The Diplomat's spawn loop reads `Guard1…Guard18`, which are not in Setup — they must come from the map's `VariableShuffle` component (not implemented yet), so those 18 `SPAWNBOT`s are skipped and reported. Two Peacemaker scripts exchange a CFrame through a global (`PrevCutter`).

**[V→done] Implementation:** compile each script to a flat instruction array (labels → indices); each thread has its own program counter, value stack, call stack and `#locals`; waits go through a small host interface (§7.7). A thread that runs more than `Budget` (default 10,000) instructions without waiting is killed and reported.

#### 7.4.1 Choices the data does not settle **[P]**

| Question | Chosen behaviour |
|---|---|
| `INIT` | sets only if the variable (global or `#local`, parameters count) does not exist yet |
| `CALL label args…` | pushes the arguments on the value stack in order; the callee `POP`s them (last first) |
| `THREAD label args…` | starts at once, with a fresh `#locals`, arguments on its stack; independent of its parent |
| `WAIT t [var]` | `var` receives the time waited; `t ≤ 0` waits one heartbeat (1/60 s) |
| `POP` on an empty stack | reports `stack-empty`, assigns 0, carries on |
| Unresolvable CFrame argument of a world command | that command is skipped and reported (`command-skipped`); the thread survives |
| `CFRCOPY` of a prop the world does not know | reports `missing-prop`, gives the identity |
| `SHUFFLE out seed items…` | writes `out0…out(n-1)` (shuffled) and the count to `out`; seeded from the mission seed |
| `GUID` | `XXXXXXXX-XXXXXXXX`, deterministic per mission seed |
| `DebugLineVariable` / `DebugVariable` | the line the thread last stopped at / the number of live threads |
| `Run` falls | kills the Run thread; a finished script is not restarted while `Run` stays true |
| Unknown instruction, missing label, bad expression | kills **that thread** when reached (the real engine only fails at runtime too); a lint pass reports them at load as Warnings |
| Euler angles | `CFRANGLES/CFRDEGREES` = Roblox `CFrame.Angles`, `R = Rx·Ry·Rz`; `lerp` slerps rotations |

### 7.5 Randomisation **[R]**

- Folder-level (Folders are unvalidated **[V]**): `Condition` (delete folder if false), `PickCount`/`PickSeed`, `ShuffleContents`, `ResolvePriority`.
- `PartCollection` + `ShuffleTarget` (`ShuffleTag`, `Index`): props whose **centre** lies inside a PartCollection volume are grouped and can be relocated to a ShuffleTarget; equal `Index` values keep picks correlated across groups. Mission seed `416` is reported to select index 1 everywhere (useful for tests).
- `RNG seed min max`: reproducible within a run; the per-mission seed changes each run (reported for the hardest difficulty).
- Inventory conditionals: `Item_tag=condition`, including coin-flip splits.
- `HiddenShuffle` (`FrontCount`, `BackCount`, `RevealCount[Variable]`, `RevealAllCondition`, `Fail[Count]Variable`, `Seed`, `HiddenShuffleId`): "find the hidden thing" with guaranteed-not-first and guaranteed-last windows.

**[P]** One `Random` module owns *all* seeded decisions so a seed + mission fully determines a run — that is what makes regression tests possible.

### 7.6 What `BreachLogic` provides **[done — M5]**

`BreachLogic.luau` (one file; embeds `BreachExpr` and `BreachRandom`, also exposed as `Logic.Expr` / `Logic.Random`). No clock of its own: the host calls `advance(dt)`; everything is deterministic for a given mission seed and input sequence.

**Variables and replication.** A `Store` with three scopes (§7.1): *Globals* (replicated), *Internals* (never in a packet), per-client variables (only to their owner). Changes are coalesced and flushed as plain-table packets (`{Full, Globals = {{Name,Value}…}, Client = {…}}`); `logic:flush()` gives raw packets for your own network, `logic:replicate()` delivers to in-process `Replica`s. A `Replica` holds the replicated Globals plus the client's variables and evaluates `Setup.ClientState` entries **on the client**, against that view.

**Reactivity.** Every Setup entry and every component input is a binding `target := expression`, re-run when something it mentions changes, FIFO in document order. A budget (default 100,000 evaluations) stops oscillating logic (`P = Q + 1; Q = P + 1`): it is reported in `logic.Errors` and the engine carries on.

**Time.** Scheduled actions (timer ticks, trigger timeouts) run in time order, each at its own exact time, with variables settled after each, so one `advance(10)` equals ten `advance(1)` and a watcher sees `T >= 3` at t = 3.0. Timers use clean arithmetic (no `0.1 × 10` drift) and are capped per `advance`.

| Component | Behaviour | Source |
|---|---|---|
| `StateUpdate` | `SetVariable` / `SetInternal` := `Watch`, continuously (includes the latch pattern `Watch = a \|\| Target`) | real-map usage **[O]** |
| `Notification` | emits an event on each rising edge of `Condition`; `Key` = the attribute (with `{expr}` filled in), `Text` = `Setup.CustomStrings[Key]` | shape **[V]**, edge rule **[P]** |
| `TimerComponent` | while `Enabled` and not `Paused`: every `Frequency` s (blank = 1) `value += Increment`, stops exactly on `TargetValue`; output = value + `Offset`; `SetFormattedVariable` = `MM:SS`; disabling resets to `StartValue` (`timerOnDisable = "hold"` keeps it); `StartValue` is read when the clock starts | spec table **[R]**, rest **[P]** |
| `ConditionalStateUpdate` | while `Condition` is true `ActiveVariable := Watch`; while false `InactiveVariable := Watch` (if set); re-run when either changes. Real: `DiplomatDeadInStealth := DiplomatKilled` while `!Mission_AlarmRaised`, so it latches once the alarm is up | real-map usage **[O]**, rest **[P]** |
| `DelayedStateUpdate` | `SetVariable := Watch`, `DelayTime` s (an expression) after `Watch` changes. `OnlyMatch=false`: pure delay line, every change arrives in order (the Diplomat's 1 s `ForgeDelay` staircase). `OnlyMatch=true`: applied only if `Watch` still has that value when the delay ends. `DelayTime` 0 applies at once | real-map usage **[O]**, `OnlyMatch` **[P]** |
| `VariableShuffle` | **preprocess**: runs once before Setup, from `StateComponentsPreprocess/`. `Set0`/`Set1` are `\|` lists; a seeded shuffle of `Set1` is dealt round-robin over `Set0`; `Prefix0..key := value`, and if `Prefix1` is set `Prefix1..value := key` (the owner). Numeric strings become numbers; `InternalOnly` puts them in Internals. `Seed` combines with the mission seed | shape **[O]** (see below), dealing rule **[P]** |
| `MissionCompletionTrigger` / `MissionFailedTrigger` | `Condition` must hold for `Timeout` s (dropping it cancels); then sets `CompleteVariable` / `FailedVariable` = 1, emits one event and sets `logic.Outcome`; the first trigger to fire wins | **[P]** |

**[O] What the real maps show about these three.** `VariableShuffle` is *not* in `StateComponents/` but in `StateComponentsPreprocess/` (Diplomat: `NodesShuffle`; Peacemaker: `TechLeadAssign`, `CodenameAssign`). The Diplomat's `Set0` is `1…18` with `Prefix0 = Guard` and `Set1` is seven area names with `HighSecurity` listed twice (a weighting), and its spawn script reads `{Guard1}` → `SecurityRoom`, which is the name of a CFrame variable that same script creates. The Peacemaker reads `RoleTechLead == [SciINDEX]`, so `Prefix1 + value` holds the owner. **[P] Guess:** when `Set1` is shorter than `Set0` the deck is reused round-robin (the Diplomat needs every guard assigned); for the Peacemaker's three roles over six scientists this means a role can have two holders, and `RoleX` holds the last one.

**Engine variables.** Some variables belong to the engine, not the map. The three real maps read exactly seven: `Mission_Difficulty`, `Mission_TacticalDifficulty`, `Mission_PlayerTotal`, `Mission_PlayersInGame`, `Mission_AlarmRaised`, `Mission_AlertLevel`, `Mission_Started`. `Logic.Builtins` supplies **[P]** defaults (one player, calm, just started); a host overrides with `opts.builtins` or disables with `opts.defaultBuiltins = false`. This matters: with them undeclared (= 0), The Project's `AllPlayersInCombatExit = PlayersInCombatExit == Mission_PlayersInGame` is `0 == 0`, and the mission completed itself at t = 1 s.

Only components under `StateComponents/` run (not `Disabled/`, `StateComponentsPreprocess/`, `BotTemplates/`); other component types found there are counted in `logic.Unsupported`. Not done: `DynamicExpression` (no real map uses it, so its meaning is unknown), client-scoped (`…Client…`) attributes, `{…}` templates with dependency tracking (only one-shot `Expr.interpolate`).

### 7.7 What `BreachScript` provides **[done — M6]**

`BreachScript.luau` is the VM (it embeds Expr, CFrame and Random); `BreachLogic.luau` embeds it and adds the `StateScript` component. `BreachCFrame.luau` is the small CFrame library (12-number arrays in Roblox's component order, `isCF` is structural so any copy of the module recognises another's CFrames).

**The `host` interface** (what an embedder implements; `BreachLogic` already does): `Get/Set` mission variables (number, string or CFrame), `Now`, `Schedule/Cancel`, `Watch(deps, evalFn, onValue)` (the reactive hook `WAITFOR` uses), `Emit`, `Report`, `Error`, `Guid`, `Seed`, and optionally `CFrameOf(tag)` for `CFRCOPY`. **World commands are not executed by the VM**: `MOVETO`, `ANIMATE`, `ANIMATECUBIC`, `COPYTO`, `DELETE`, `DELETEALL`, `SPAWNBOT`, `INITSTATECOMP` come out as `{ Kind = "ScriptCommand", Command, Args, Script, Thread, Time }` events, with CFrame arguments resolved — the M7+ world and bot systems consume them.

**`StateScript` in the logic core.** `Run` / `TriggerEvent` as in §7.4; every other attribute except `ScriptSource`, `Run`, `TriggerEvent`, `DebugVariable`, `DebugLineVariable`, `ScriptMove`, `Type` is a parameter (`#GuardCount`, `{#GuardCount}`). CFrame-valued globals live in `logic.Objects` (never replicated, they win over a Store value of the same name). `opts.world.cframeOf` supplies prop CFrames; `opts.scriptBudget` overrides the instruction budget. Lint findings become `logic.Warnings` (with the script line), a thread that dies becomes an `Error` at `path:line`.

Not done: world execution (by design), client-side scripts, `StateScriptPart`, and any instruction the 26 real scripts do not use is implemented from the one-line description only (`SHUFFLE`, `GUID`, `ALLOCARRAY`, `LERP`, `CFRINV`, `COPYTO`, `DELETE*`, `INITSTATECOMP`, `THREAD`, `CALL`, `PUSH/POP/PEEK`, `WAITFORCHANGE`, `WAITHEARTBEAT`).

---

## 8. World entities

Attribute **names, kinds and defaults are [V]** in Appendix A. The behaviour descriptions below are **[R]** — they describe the real engine and are the *requirements* for BreachEngine's implementation, not a spec of it.

### 8.1 Props

Common attributes (all props) **[V]**: `Color0–5`/`Material0–5` (paired; string colours index `MissionSetup.Colors`), `Index`, `OnProp`, `Indestructible`, `HasTopBarrier`, `IsSpawned`/`FadeOutCondition`, `Tag`/`StaticTag`/`TagOffset`, `CanShatter`, `ScriptMove`, `EMPHitVariable`, `PowerCutVariable`, `BlockEMP`.

| Family | Props (names **[V]**) | Notes **[R]** |
|---|---|---|
| Doors | `DoorMetal`, `DoorWood`, `DoorMetalElectronic`, `DoorWoodElectronic`, `DoorPushLeft`, `DoorArmored[Electronic]`, `DoorGlass[Framed/Rustic]`, `DoorMetalMaglock`, `DoorFenceGate`, `DoubleVaultDoor`, `HeavySecurityDoor`, `SlidingBlastDoor`, `GarageDoor`, … | Key attrs: `Access`, `AutoLock`, `DifficultLock`, `DifficultDrill`, `LockFront/LockBack`, `Blocked`, `RemoteUnlock`, `FailsafeUnlock`, `AlarmVariable`, `OpenVariable`, `BotCloseCondition`, `BotRelockCondition`, `PathIgnore{Open,Unlocked,Broken}`, `PathRecover`, `PathReq1/2`, `KeepClosed`, `NoKick`, `EasyKick`, `Jammed` |
| Access control | `CardReader`, `BadgeReader`, `CodeCardReader`, `CodeKeypad`, `HighSecurityCardReader`, `InsertCardReader`, `RFIDWriter`, `BiometricLock`, `KeyBox`, `TimelockCodePanel` | `TriggerVariable` fires on success; wire to a door's `RemoteUnlock` |
| Hacking network | `PowerBox*`, `NetworkSwitch`, `AccessPoint`, `CeilingAccessPoint`, `HackableComputer`, `Laptop`, `ServerRack*`, `SecurityCamera`, `DomeCamera`, `Elevator*` | one graph via `NetworkId` (1–999, **[V]** validated) and `NetworkLink`; `PowerArea` groups props by power zone |
| Safes & storage | `DeskSafe`, `WallSafe`, `FreestandingSafe`, `HiddenWallSafe`, `FilingCabinetLockable`, `SearchableFilingCabinets`, `LootGeneric`, `LootCash[2]`, `DepositBox*` | `HiddenWallSafe` ties into `HiddenShuffle` via `HiddenShuffleId` |
| Interaction | `FreeTrigger`, `ItemSpawn`, `ItemDeposit`, `DisguiseTrigger`, `ClothingRack`, `LaundryBasket`, `IntercomCode`, `IntercomPanel`, `LeverageMove`, `SwitchPanel`, `RewireablePanel`, `AlarmButton` | generic prompts and pickups |
| Movement | `WindowClimb`, `Ladder`, `ClimbablePipe`, `FallingLadder`, `StandingCover`, `CrouchingCover`, `LeaningCover`, `Elevator`, `FloorAccessCover`, `GroundVentCover` | |
| Zones & markers | `MissionEndZone`, `EscapeZone`, `LeaveMissionPoint`, `SpawnLocation`, `RandomBotSpawnLocation`, `DynamicNode`, `PointOfInterest`, `WarpPoint`, `NoDropZone`, `KillZone`, `DespawnZone`, `VisionBlocker`, `PathfindingBlocker`, `MinimapBlock`, `TrespassZoneDisplay` | |
| Triggers | `TriggerZone`, `TriggerRoom`, `TriggerZoneBot`, `TriggerRoomBot`, `TriggerThreshhold`, `TriggerLocalChat`, `TriggerHit`, `TriggerVision`, `TriggerRoomLockPlayerState` | all gated by an `Active`/`Enabled` expression |
| Randomisation helpers | `ShuffleTarget`, `PlaceholderProp` (unverified, §2.1 #16) | |
| Decorative | the remaining placed-model names (`WoodChair`, `TableGlass`, `DecorativePipe`, `ThinBush`, …) | mostly attribute-less; need BreachEngine's **own** models |

**Four trigger semantics worth fixing now [R]:** `TriggerZone` counts players in a marked volume (`IsGlobal` = server-wide count; `IsLocal` = per-client boolean). `TriggerRoom` counts players in the cell the trigger part sits in. `…Bot` variants count NPCs by `ServerTag` (dead, hostage, ragdolled, active). `TriggerThreshhold` counts players on each side of a plane.

#### 8.1.1 What `BreachProps` provides **[done — M7]**

`BreachProps.luau` (standalone; embeds BreachCFrame) sits between the mission model, a `BreachWorld` (cells, for rooms) and a `BreachLogic` (variables, expressions, time). `Props.new(mission, world, logic)` makes every supported prop under `Props/` live and returns a `Sim`. **Players are clients of the logic core**, so per-client variables and `ClientVisible`/`ClientEnabled` are evaluated on the player's own replica. Props only ever change state through `logic:set` / `setClient`, so timers, scripts, triggers and notifications react to them exactly as to the game. (The logic core gained three small hooks for this: `watch`, `after`, `emit`.)

```lua
local sim = Props.new(mission, world, logic)
sim:addPlayer("p1", x, y, z)   sim:move("p1", x, y, z)      -- zones/rooms/end zones recount at once
sim:pickup("p1", prop)  sim:interact("p1", prop, heldSeconds)  sim:swipe("p1", reader, "BasicKeycard")
sim:openDoor("p1", door)  sim:closeDoor(door)               sim:has("p1", "Drive")   sim:propsOf("Door")
```
A prop argument may be the prop object, the mission node, a `Tag`, or a path tail. Every action emits a `PropEvent` (`Pickup`, `Interact`, `Deposit`, `DoorOpen`, `DoorDenied`, `Swipe`, `SwipeDenied`, `Exit`).

| Prop | Behaviour | Basis |
|---|---|---|
| `TriggerZone` | players inside the oriented box (the node's real `CFrame` + `Size`): `Variable` := count (`IsGlobal`, or neither) and/or a per-client 0/1 (`IsLocal`); `AllPlayersInZoneVariable`; `PlayersOutsideZoneVariable`. `Active` off: freezes, or zeroes with `ClearOnInactive`. Recounts when `Active` changes, without anyone moving | attributes **[R]**; Active/Clear **[P]** |
| `TriggerRoom` | players whose `world:cellAt` is the trigger's cell: `PlayersInRoomVariable`, `HadPlayerInRoomVariable` (latch), `AllPlayersInRoomVariable`, `ClientInRoomVariable`; `MaxRange > 0` also limits distance. **Inactive = frozen, not cleared**: the maps gate rooms with `Active = !TheirOwnVariable` so the first entry latches | latch pattern **[O]**, `MaxRange` **[P]** |
| `FreeTrigger` | usable if `ServerVisible` (and `ClientVisible`) and `ServerEnabled`; needs `Tool` and a hold of `HoldTime` (default 0.5 s, `TapTrigger` = 0). Sets `SetVariable` := `SetValue` (blank = 1), `IncrementVariable`, `SetClientVariable`, `IncrementClientVariable`. **A blank `ServerVisible`/`ServerEnabled` means yes** (23 of the 151 placed triggers leave `ServerEnabled` blank and clearly work) | blank rule **[O]**, rest **[P]** |
| `ItemSpawn` | gated by `IsSpawned`, `PickupCondition`, `InitialPickupTime` (seconds since start); gives the `Item` list (comma separated; a name may contain spaces, e.g. `480 MCS`), tagged with `ItemTagString`; sets `ItemRemovedVariable` := 1. One pickup, by anyone. The same variable may also be driven by a room trigger (`ArmoryEntered` is both) | **[O]**/**[P]** |
| `ItemDeposit` | needs an item whose tag equals `ItemTagForDeposit` (else name = `Item`); consumes it; `DepositedVariable` := 1; gated by `ServerVisible`/`ClientVisible`/`ClientEnabled` | **[P]** |
| Doors (`Door*`, `GarageDoor`, vault/blast/security doors) | locked if `LockFront`/`LockBack` (expressions; side = which side of the door's LookVector the player is on), or `AutoLock` after closing; opened regardless by `RemoteUnlock`/`FailsafeUnlock`, or by an item named in `Access`; `Blocked` and `Jammed` stop everything. Writes `OpenVariable`, `OpenIncrementVariable`, `LockedVariable` (live) | attributes **[R]**, semantics **[P]** |
| `CardReader` | needs power (`PowerArea` expression, blank = yes), the card in the inventory and in `ValidCards` (no list: `MinimumCard` on a Basic < Security < Master ladder); sets `TriggerVariable` := 1 (latched). Real wiring: reader `TriggerVariable` = door `RemoteUnlock` | wiring **[O]**, rest **[P]** |
| `MissionEndZone` | while `Active` (blank = yes) and `OpenForAll` (else every live player must be inside), players inside **exit the mission**: `PlayersExitedVariable` += 1, `ItemSecuredVariable` if they hold `ItemRequired`, `AltItemNVariable`; `Mission_PlayersInGame` drops | **[P]** |
| Folders | a Folder with a false `Condition` (e.g. `PowerBoxes2: BoxRNG == 2`) or named `Disabled` removes everything beneath it | **[O]** |

Not done: the other ~4,500 prop nodes of the three maps (decorations, bot paths and props of later milestones), power boxes and `PowerArea` semantics, hacking, search/drill/lockpick/kick/unlock minigames, physical door animation, range checks (the host decides who is close enough to interact), `UpdateFrequency` (recounts are event-driven), `Id`-based photo zones.

### 8.2 Bots (NPCs)

Bots are `BoolValue`s in `Bots/`. The attribute map has **no entry** for them **[V]** (they are not validated; the nearest verified shape is `RandomBotSpawner`, which the authoring doc says shares the Bot attribute surface). Reported attributes **[R]**:

- **Behaviour:** `Behavior` = `PatrolWalk`, `WorkWithBreaks`, `Bodyguard` (needs `BodyguardTarget`), `PassingCivilian`; `Nodes`, `NodesBreak`, `SearchArea`; `PatrolCycleLength`.
- **Identity:** `Class` (free detection group), `Profile` (fixed presets: `BasicSecurity`, `ProSecurity`, `Employee`, `EmployeeWithRadio`), `ClientTag` (objective target), `ServerTag` (general tags, space-separated).
- **Loadout:** `Inv` (`|`-separated, optional `_tag` suffix, optional `=condition`), `Weapon`, `MaxHealth`.
- **Tuning flags:** `DetectionSpeed`, `HeadTracking`, `HostageDifficulty` (0–4), `AvoidInvestigation`, `NoInvestigation`, `NoHostageDownInCombat`, `CivilianHighlight`, `ObjectiveHighlight`, `OnlyHideWhenDead`, `CameraArea`, `PowerArea`, `DespawnBlocked`, `DespawnCondition`.
- **Appearance:** `Outfit` (`CivilianOutfit`, `BlackSuit`, `ManagerOutfit`, `BasicSecurity`, `BasicSecurityLead1`) plus `Custom*` fields and `Seed`.
- **`CustomBehavior`** — newline list run on a bot: `AUTOCLEANUP`, `CROSSARMS [0|1]`, `ENTERCOMBAT`, `END`, `FOLLOW part [tag]`, `MOVETODYNAMIC node`, `SETFASTWALK`, `SETRUNNING`, `SET var state`, `TAKEDOWNIMMUNE [part]`. Priorities `Custom1`–`Custom5`; `Custom3`+ blocks conversation/social engineering.

#### 8.2.1 What `BreachNav` provides **[done: M8a]**

`BreachNav.luau`: kinematic movement for bots and followers. Pure Luau, deterministic, no randomness, no Roblox APIs. The host moves **actors** (players) and calls `step(dt)`; Nav moves **agents** (bots) and never touches physics: an agent has a position and a speed, nothing that can push a player. Paths come from an injected pathfinder (`Nav.worldAdapter(world)` wraps `BreachWorld:findPath`).

```lua
local nav = Nav.new({ pathfinder = Nav.worldAdapter(world), blocked = doorClosedFn, canSnap = notInViewFn })
nav:addActor("p1", x, y, z)   nav:moveActor("p1", x, y, z)      -- the host moves players
nav:addAgent("civ", x, y, z)  nav:follow("civ", "p1")           -- a hostage you lead
nav:goto("guard", x, y, z)    nav:stop("guard")                 -- patrol legs
nav:step(1 / 20)              nav:position("civ")               -- events: Arrived Waiting Yield Sidestep Cornered Stuck Snapped TrailBroken PathFailed
```

**How a follower avoids hitting you** (each rule is code and an automated check; defaults in studs, tunable in `Nav.Defaults`):

| Rule | Mechanism |
|---|---|
| never targets the player | follows the leader's **trail** (breadcrumbs of where they really walked) `FollowDistance` (6) behind: the same corridors and doors, no corner cutting through you |
| no jitter | stops at `StopDistance` (5) or on reaching its place, resumes only beyond `ResumeDistance` (7.5) |
| cannot close in | a move that would bring it closer than `StopDistance` (and closer than it is now) is refused |
| no overspeed | speed <= `Nav.speedCap`: 1.15 x the leader's speed, or a catch-up speed that grows with the gap (6 + 1 per stud beyond `ResumeDistance`, up to 20); a far-behind follower hurries, a near one cannot run you over |
| yields | leader inside `YieldDistance` (4.5): it backs along its trail at the leader's pace; with no trail left it **sidesteps diagonally**; if truly cornered it holds and the leader is the one moving |
| no snapping | attaching to the trail blends in through a decaying sideways offset; total movement per tick never exceeds the speed budget |
| doors | `opts.blocked(a, b)` makes it wait (single file) and `Waiting` is reported |
| paths | rate-limited to `RepathHz` (2) per second per agent; a teleporting leader breaks the trail and it walks a path to the new spot |
| stuck | displacement-based: re-attach, then **snap onto the trail behind the leader**, vetoable with `canSnap` (never pop into view) |
| several followers | queue slots, `SlotSpacing` (4) further back each, so they never stack |

**Verified (76 tests):** unit tests of trails; scripted leaders (walk, stop, reverse straight into the follower, **sprint through it**, circle it at 3 studs, stand in a doorway, teleport, jitter, run); two followers; stuck/snap/veto; `goto` (arrival, bent paths, no path, stop, doors); bit-identical replays; a fuzz; and on **six real routes per map (18)** between far-apart nodes of the real navigation graphs, with the leader walking, pausing and turning back into the follower: it never moved toward the leader inside `StopDistance`, never exceeded its cap, stayed within the repath rate, ended in the follow band, and the **closest it was while the leader walked into it was 3.8 / 4.1 / 4.0 studs** (never below `MinDistance` 2.5).

Not done (later M8 steps): bot behaviours and patrol routes (M8b), vision/alert (M8c), hostage and alt-interaction state machines (M8d, using this movement), door `PathReq` rules for which bots may pass which doors, and a Roblox adapter (feel and the collision group cannot be tuned headless).

#### 8.2.2 What `BreachBots` provides **[done: M8b]**

`BreachBots.luau` (embeds `BreachRandom`) is the bot model: who a bot is, what it carries, which route it walks, when it despawns. Movement goes through a `BreachNav` the host supplies; vision, alert and hostages come later (M8c/M8d).

```lua
local bots = Bots.new(mission, world, logic, nav, { seed = 416 })
-- each frame:   logic:advance(dt)   bots:step(dt)        -- bots steps `nav` itself
bots:drainEvents()   -- BotSpawned BotArrived BotDeparted BotDespawned BotPathFailed
bots:alive()  bots:withTag("Chef")  bots:bot(id)  bots:setFlag(id, "Hostage", true)  Bots.parseInv("A_tag|B=cond")
```

| Topic | Behaviour | Basis |
|---|---|---|
| Which bots exist | `BoolValue`s under `Bots/`; a Folder whose `Condition` is false, or named `Disabled`, removes its bots. **The count depends on `Mission_Difficulty`**: 5 / 7 / 7 (Diplomat), 54 / 54 / 57 (Peacemaker), 37 / 41 / 44 (Project) at difficulty 1 / 2 / 3, i.e. 7 / 57 / 44 placed | **[O]** |
| Routes | `Nodes` and `NodesBreak` name a Folder (or a single part) under `Nodes/`, found at any depth, case-insensitively; a folder's parts **in document order** are the route. A value may list several names separated by spaces (a real Peacemaker bot: `"SecPatrol SecQuarter2"`); the bot walks **one**, chosen once from the seed | names **[O]**, choice **[P]** |
| Shared routes | the k-th bot of a route starts at its k-th node; first departures are staggered by the seed | **[P]** |
| `PatrolWalk` | loops the route, pausing `PatrolCycleLength` seconds at each node (default 1.5; values seen: 0.5, 0.75, 1, 1.3, 1.5, 2, 6, **99999**); **≥ 10,000 or a one-node route = a static post** that never leaves | dwell meaning **[P]**, static **[P]** |
| `WorkWithBreaks` | works the `Nodes` route for `WorkSeconds` (60), then walks to a `NodesBreak` node (seeded) for `BreakSeconds` (20), then back | **[P]** (no map or doc defines the timings) |
| Node attributes | `ActiveVariable` (the node is skipped while false), `Anim` (reported on arrival) | **[P]** |
| `Inv` | `Item[_tag][=condition]` entries separated by a single `\|`; a `\|\|` inside a condition is part of it | **[R]**, checked on all real strings |
| `DespawnCondition` / `DespawnBlocked` | the bot is removed when `DespawnCondition && !DespawnBlocked` becomes true (reactive); e.g. 26 Project bots on `Debug_Despawn` | **[O]** |
| `BotStateTracker` | a component: keeps `Total`, `Hostage`, `Incapacitation`, `Death`, `ClientKill` and `Flee` count variables per `BotServerTag` (blank = all bots); the flags are set by `setFlag` (M8d will set them from play) | **[R]** |
| Other behaviours | `Bodyguard`, `PassingCivilian` are reported in `bots.Skipped`, not guessed (no real map uses them) | |

**Verified (82 tests):** `Inv` parsing; patrol order and exact dwell times; static posts; shared routes and seeded stagger; node `ActiveVariable`; work/break cycle; route resolution (single part, nested, case, multi-name); Disabled and conditional folders; identity fields and tags; despawn and blocking; path failures (retry, then skip the node); trackers; determinism; and on all three real maps every bot that exists at the difficulty is created (counted independently), 300 simulated seconds run with no errors, and the patrols really move: **264 / 2,042 / 1,076 arrivals** in 300 s (Peacemaker's 204 path failures are the one floor-crossing route, §13.14).

Not done: vision and detection (M8c), hostage/body/flee behaviour (M8d), `Bodyguard`/`PassingCivilian`, `RandomBotSpawner`, door `PathReq` restrictions, and `SearchArea` use (stored only).

#### 8.2.3 What `BreachHostage` provides **[done: M8d]**

`BreachHostage.luau` (pure Luau, deterministic) adds hostages, bodies and the alt interaction on top of `BreachBots` and `BreachNav` (following, with the invariants of 8.2.1).

| Part | Behaviour | Status |
|---|---|---|
| Taking | the host calls `aim(player, bot)` while a gun is aimed; the bot becomes a hostage after `HostageDifficulty x 0.5 s` of aim (0 = at once), within `TakeRange` 30 and in line of sight. A `NoHostageDownInCombat` bot cannot be taken while loud (loud stands in for combat). `take()` does it immediately | **[O]** attributes; **[P]** aim time, range, the combat proxy |
| Following | a hostage follows its taker on the trail (the nav follower: never closer than 2.5 studs, never targets the leader) | **[R]** |
| Armed guards | a guard (a `Weapon`, or `HostageDifficulty` > 0) is a hostage for **at most `GuardRetaliateSeconds` (10)** without a gun on it: then it stops being a hostage (`HostageRetaliating`), **radios in first** (`Alert:radioIn`: `BotRadioStarted`, lockdown after `RadioSeconds`) and then fights (combat itself is M9). Aiming at it resets the 10 s like for civilians | **[R]** (owner: about 10 s at most, radio before shooting); **[P]** the armed test, exactly 10 |
| Flee (civilians) | **stealth:** no gun aimed at a civilian hostage for `FleeSeconds` (60) and it flees (Hostage off, Fled on, to the route node farthest from the taker); aiming at it resets the timer. Fled bots cannot be re-taken | **[R]** about a minute and "draw a gun"; **[P]** exact time, the flee spot |
| Loud | when `Mission_AlarmRaised` goes up a hostage **freezes** and ignores the follow command (and does not flee); a hostage taken while loud is frozen at once | **[R]** |
| Bodies | `incapacitate(bot)` (or `bots:setFlag(...Incapacitated)`, noticed on the next step) makes a body: Hostage off, Incapacitated on, stopped. A dead bot is neither. The `BotStateTracker` counts follow the flags | **[R]** states, **[P]** |
| `BotAltTrigger` | `interactables(player)` lists a trigger for a bot with its `BotServerTag` (or `BotClientTag`; blank = any) that is a hostage (`AllowHostages`) or patrolling (`AllowPatroling`), when `ServerEnabled` and the player's `ClientVisible` hold and the bot is within `InteractRange` 10 and in the same cell. `ClientEnabled` false lists it **disabled** with `DisabledTitleKey` / `DisabledSubtitleKey`. `interact(player, bot, trigger, held)` needs `HoldTime`, then sets `TriggerVariable` (to 1) and `TriggerClientVariable`, and emits `TriggerNotification` / `TriggerLocalNotification` | **[O]** attributes and real values; **[P]** range, value 1 |
| `BodyAltTrigger` | the same for an incapacitated body (not a dead one) | **[O]**, **[P]** |

**Verified (76 tests):** aim-time and reset rules, range / line of sight / combat refusals, a 150-stud lead with the follower invariants, the flee timer with resets, tracker counts, loud freezing, bodies, the full alt-trigger life cycle (tag, mode, expressions, hold time, disabled state, client variable, notifications, range), determinism; on the three real maps a real placed bot is taken and led, and the **real** triggers fire with their real expressions: The Project's phone unlock (`Action.UnlockPhone`, `HoldTime` respected, its `TriggerVariable` set), the Peacemaker's Commander fingerprint (offered only after the alarm, on a frozen hostage, sets `CommanderLockdown`), the Diplomat's blackmail (listed but disabled without `Perk_Intimidation >= 2`, then works). In the real-map tests the trigger's bot tag is blanked so a placed bot can stand in for the map's tagged one (no placed bot carries those tags: they are spawned), and the Peacemaker's position-driven `EnteredSecurityCenterClient` is replaced by `1`.

**Found on the way:** the Peacemaker's `Floors/PlayerLocator/TriggerZone` feeds back into its own state once any player exists (`SwitchObjectivesHint`, `HasAWayInCenter`, `InTheirNetwork`, ... keep changing), so the logic core reports "did not settle after 100000 evaluations"; and `Props:refresh()` looped forever on it. `Props:refresh()` is now capped at 24 passes (the rest carries over to the next call, like a game frame). Whether the map really oscillates in the game or our evaluation order differs is open.

**Not done:** the shooting itself after a guard retaliates (M9 combat); taking a hostage by `HostageDifficulty` fights back; spawned bots (`RandomBotSpawner`) carrying the trigger tags; a hostage seen by a guard raising the alert; `Fleeing` hostages raising the alert when seen (default off); the host-side aim/hold UI.

#### 8.2.4 What `BreachBehavior` provides **[done: M8e]**

`BreachBehavior.luau` (pure Luau, deterministic) runs the maps' `CustomBehavior` scripts and the bot spawners, on top of `BreachBots` (which gained `spawn`, `rand` and the `PassingCivilian` behaviour), `BreachNav` and optionally `BreachAlert`.

**The script language** (every command found in the three real maps; the meaning is my reading): `WAIT s`, `WAITFOR expr`, `MOVETODYNAMIC node`, `SET var [value]` (no value = 1), `CHAT key`, `SETFASTWALK`, `SETRUNNING`, `PHONE n`, `CROSSARMS n`, `RADIO n`, `CHECKPOINT`, `ENTERCOMBAT`, `TAKEDOWNIMMUNE`, `FOLLOW target [tag]`, `GOTO label [var]` (jump when the variable is true), `:label`, `END`, `AUTOCLEANUP`. **[O]** the commands and where they are used; **[P]** the semantics. A `MOVETODYNAMIC` node is a Part whose `Id` attribute is the name (the maps' `Props/DynamicNode` parts), a Part by its name, or a Folder (its first part, e.g. `Nodes/LeadSecurityStart`).

| Component | Behaviour | Status |
|---|---|---|
| `CustomBehaviorCondition` | while `Condition` holds, every bot with `BotServerTag` runs the script; of several true conditions the **highest** `Custom` number wins; `LoopApply` restarts the script when it ends (16 of 20 real ones loop); when the condition ends the script stops, speed and poses are reset (AUTOCLEANUP) and the bot goes back to its patrol | **[O]** attributes; **[P]** priority order, cleanup |
| `AlarmedBehaviorOverride` | once `Mission_AlarmRaised` is up, tagged bots run the script instead, once, above every custom condition (the Diplomat's flees to the saferoom and sets `PanicRoomTrigger`); the ones under `Disabled/` are ignored | **[O]**; **[P]** |
| `RandomBotSpawner` | while `SpawningActive` holds, a bot is spawned every random `SpawnTimeMin`..`SpawnTimeMax` seconds (seeded), tagged by `ServerTag` or `Tag`, on the spawner's `Nodes` route. `PassingCivilian` bots walk the route once and despawn at the end | **[O]** attributes; **[P]** the despawn at the route end |
| Left alone | a bot that is a hostage, a body, dead, fled, or commanded by something else (an alert reaction) never starts a script, and a running script lets go when something else takes the bot (`BehaviorFinished` Taken) | **[P]** |

**Verified (73 tests):** the parser, a full condition life cycle (start, walk, SET, WAIT, poses, stop, speed restored), priorities and hand-over, loops, labels, GOTO, WAITFOR, END, the alarm override (and the disabled one ignored), busy bots, ENTERCOMBAT setting the Fighting flag, FOLLOW, spawner timing and despawn, determinism; on the three real maps every script uses only known commands, **every** `MOVETODYNAMIC` node exists, no script runs at the start unless its condition holds, the real conditions that are a bare variable and have a placed bot with their tag all start (Peacemaker 6/6, Project 2/2), and the real Project spawners produce passers-by (8 per minute each on route `Security`).

**Found on the way:** the Diplomat's civilian spawner has **no `Nodes`**, so nothing can be spawned from it (counted in `SpawnFailures`; the real game must pick a civilian route some other way, unknown). No placed Diplomat bot carries the tags of its two behaviour conditions (those bots are spawned, or the tag lives elsewhere), so the Diplomat's conditions are only tested in the controlled scene.

**Not done:** conversations (`CHAT` only emits `BotSay`), `SearchPatternCondition` (no real use), animations behind `PHONE` / `CROSSARMS` / `RADIO` (events only), `ENTERCOMBAT` is only the Fighting flag (combat is M9).

#### 8.2.5 `BreachSession` and the seeded playthroughs **[done: M8f]**

`BreachSession.luau` is a thin host, not a new layer: it wires the tested layers in the one order they were tested in (`logic:advance`, bots, sight, trespass, alert (it drains the trespass events), hostage, behavior) and merges their events into one log tagged by source (`Bots`, `Alert`, `Hostage`, `Behavior`). `S:addPlayer / movePlayer / setDisguise / aim / answer`, `S:step(dt)`, `S:run(seconds)`, `S:drainLog()`, `S:signature()` (a string of the whole run, for replays). The module table is passed in, so the file requires none of its siblings.

**The playthrough** (`tests/playthrough_tests.luau`, run on all three real maps, each twice): 8 s of quiet patrol with the alert Calm, a real bot approached with a clear line of sight, taken hostage at gunpoint, led away (it follows), the map's **own** alt trigger offered and fired with its real expressions (Project phone unlock; Peacemaker Commander fingerprint after the alarm freezes the hostage; Diplomat blackmail with the perk), and in a second session a real guard that enforces its own cell sees an undisguised player: it radios, then the lockdown lands (`BotRadioStarted` before `AlertRaised` level 3, `Mission_AlarmRaised` 1). The two runs of each map produce **identical event signatures** (25 000 to 33 000 characters on the Peacemaker and Project).

**Found on the way:** some placed bots sit on a nav island the leader's position cannot be reached from (the Peacemaker has 20 nav components), so they cannot follow; the test takes the next approachable bot (deterministically). Moving a hostage's leader far away quickly leaves it beyond the 10-stud interaction range, so the player walks up to it first.

**Not done:** a host that drives the session in real time (frames, input), and anything after the alarm: combat (M9), search behaviour, reinforcements.

### 8.3 Alert, combat and reinforcements **[R]**

Alert is a **monotonic** integer (0 calm → 3 lockdown); `AlertRaiseCondition` has `Amount`, `MinValue` (default 1), `MaxValue` (default 3), `Condition`, `Reason` **[V defaults]**. `CombatSpawner` decides *when* and *what*, `ReinforcementPool` decides *how many per wave*; `LoudSpawns`/`FixedSpawns` supply positions (`Enabled`, `IgnoreProximity`, `Range` in cell hops, `SpawnTag`). Enemy types `Swat`, `Palisade`, `Criminal`.

#### 8.3.1 What `BreachAlert` provides **[done: M8c part 3, revised after owner feedback]**

`BreachAlert.luau` (pure Luau, deterministic) keeps the alert state and turns trespass witnesses and anomalies into bot behaviour. It writes `Mission_AlertLevel` and `Mission_AlarmRaised` through the logic core, so the maps' own expressions react.

| Part | Behaviour | Status |
|---|---|---|
| States | Calm (0), Normal (1), Alert (2), Lockdown (3) are the levels. **Fighting** is deprecated and unused by missions; it is kept for engine compatibility as a flag (`setFighting`) meaning guards attack **without** a lockdown being issued; it never changes the level. `stateName()` gives Lockdown > Fighting > the level name | **[R]** |
| Level | `raise(amount, reason, min, max)` = `clamp(level + amount, min, max)`, never lowers by itself; `min == max` sets exactly that level; `lockdown()` = 3. **The maps also write `Mission_AlertLevel` themselves** (scripts such as `SET Mission_AlertLevel 2`, the Peacemaker's `ReduceAlertLevel` / `ResetAlertLevel` bluff, the `StandardRadioAlertReduction` decay): the alert follows those writes up or down (`AlertRaised` / `AlertLowered`, Reason "MapWrite") | **[P]** formula, checked against the real triples; **[O]** map writes |
| `Mission_AlarmRaised` | 1 when level >= `AlarmRaisedAt` (default 3) and then **latched**: it stays 1 even if the level is written back down. Evidence from the three real maps (all uses scanned): every `AlertRaiseCondition` guarded by `!Mission_AlarmRaised` is a (3,3,3) lockdown raise (Diplomat `IncriminatingDocumentsPrinted`, Project `PenthouseWindowBroken`); the Diplomat's `StandardRadioAlertReduction` has `AlertReductionDisabled = Mission_AlarmRaised` (levels decay until the alarm is up, then no more); `Challenge_KeepCalm` tests `Mission_AlertLevel > 0 \|\| Mission_AlarmRaised` (so the alarm is a different, higher thing than level > 0); music priority is `Mission_AlarmRaised * 2` (a 0/1 value); the loud phase (combat spawners, `Mission_AlarmRaisedDelayed`, `...Delayed10`) all hang off it | **[O]** usage, so level 3 is now strongly supported; latching **[P]** |
| `AlertRaiseCondition` | rising edge of `Condition`; `Reason` = CustomStrings key as is or `{expression}` template; components outside `StateComponents/` (e.g. under `Disabled/`) ignored | **[R]** attributes, **[P]** edge rule |
| Major trespass | the witness radios (`RadioSeconds` 4 s), then **lockdown**; killed, incapacitated or despawned first = call cancelled. Bumping a guard never makes it shoot. **A guard flees only when it sees that the player is armed** (`player.Armed`, set from the host: `Props:setArmed`; the Roblox host reads the character attribute `BreachArmed`, else an equipped Tool), and then it **radios while it flees**: `BotRadioStarted` (with `Fleeing = true`) is emitted at once and the call lands `RadioSeconds` after that, wherever the guard is (a guard that arrives first waits at the spot). Against an **unarmed** player it does not run but **still radios for lockdown, where it stands** (`BotRadioStarted` with `Hidden = false`) | **[R]** armed-only flight, simultaneous radio and radio-in-place for an unarmed player (owner, Nov 2026); **[P]** the numbers |
| Hiding spot | used only for an armed player. Candidates are props (`opts.hidingSpots`; default the bot's route nodes). **1** far from the player (`HideMinDistance` 20) but close enough to run back and ask (`HideMaxReturn` 60), **else it does not hide and radios where it stands**; **2** easy to get there and back (distance there + back, doubled when a wall is between), in 10-stud steps; **3** a spot with no line of sight to the player (the player is armed whenever this runs). Higher priorities always win | **[R]** priorities (owner observation), **[P]** numbers |
| Minor trespass | the guard walks up and asks. King Street style (+1 first) vs Bathurst style (only asks) is **not per mission**; the owner thinks it is a tag on the guard bot, name unknown: `params.MinorRaiseTags` (ServerTags) or a `MinorRaisesAlert` bot attribute, else `params.MinorRaisesAlert` (default false) | **[R]** not per mission, **[P]** the tag |
| Answers | `answer(bot, player, response)`: `true`/"bluff" = the guard buys it (silenced `SilenceSeconds`); `"leave"` = you get `LeaveSeconds` (15) to walk out yourself, else you are escorted; `false`/"fail" or no answer in `QuestionSeconds` = failed | "leave": **[P]** owner idea, not observed |
| Failed answer | counts as a **major trespass**, but no lockdown: the guard **escorts** you to the nearest allowed cell (`EscortStarted` ... `EscortFinished` when you are out; `EscortSeconds` 25 and still there = lockdown). Older versions set "Fighting"; `FailedAnswerLockdown = true` gives the radio-lockdown instead | **[R]** escort, older Fighting history |
| Burned place | after an escort the rule (cell) is **banned** for that player (`isBanned`): a guard that sees you there again radios lockdown, no second question | **[P]** owner idea, not observed |
| `AlertLowerCondition` | on the rising edge of `Condition` the level drops to the value of `AlertLevel` (an expression or number: the Peacemaker's bluff `Mission_AlertLevel == 2 && 1 \|\| 0` or `0`); it only lowers, and works from lockdown too, though `Mission_AlarmRaised` stays latched | **[O]** attributes and real values, **[P]** edge rule |
| `StandardRadioAlertReduction` | present only in the Diplomat. While it exists, a calm spell lowers the alert by itself: Alert -> Normal after `ReductionSeconds` (60) if `Mission_Difficulty >= AlertReductionDifficulty`, Normal -> Calm after `ResetSeconds` (60) if `Mission_Difficulty >= AlertResetDifficulty`; never while `AlertReductionDisabled` (real: `Mission_AlarmRaised`) is true. "Calm" = no raise, no guard reacting, no Fighting | **[O]** the three attributes (real values 0, 1, `Mission_AlarmRaised`), **[P]** this reading of the difficulty ones and the times |
| Disguise piercing | a bot whose `Profile` is in `PiercingProfiles` (default `LeadSecurity`) noticing a disguised player = major trespass anywhere | **[R]**, **[P]** default |
| Anomalies | `addAnomaly(kind, x, y, z)`; Body (lockdown), Radio, BrokenGlass, BrokenCamera (+1). Bodies register automatically on `setFlag` Dead/Incapacitated. The first free bot that **sees the point** (`Sight:canSeePoint`) comments, then radios "10-66 at (cell)"; if it dies first another bot can still find it | **[R]** reactions, **[P]** timings |

Bots gained `command(id, state, x, y, z)`, `hold`, `resume` and the `BotReached` event; commanded bots are skipped by the patrol logic.

**Verified (123 tests):** the level semantics, rising edges, reasons, every flow above (major, minor with and without the tag, bluff, leave in time / too late, fail, timeout, escort finished / refused, re-entry lockdown, piercing, anomalies), the three hiding priorities in isolation and a real run to the chosen spot, Fighting not being a level, cancellation, determinism; on the three real maps no condition fires at the start, every real `AlertRaiseCondition` raises what it should, and a real static guard that enforces its cell calls lockdown on an undisguised player.

**Still open:** the real name of the guard tag; what `EnforceClass` tier numbers and `EnforceCellLinks` mean; what `AlertReductionDifficulty` / `AlertResetDifficulty` really mean and the real decay times (guessed), whether an unlatched alarm exists (the Project's `Unalarm = Mission_AlertLevel == 3 && NoAlert`), `AlarmedBehaviorOverride`, `SearchPatternCondition`; props as hiding spots are not extracted from the maps yet (the host passes `hidingSpots`).

#### 8.3.2 What `BreachCombatData` provides **[done: M9.0; plan: `docs/BreachEngine_M9_Combat_Plan.md`]**

A pure data layer: it reads what a mission *declares* about combat and exposes plain tables. It runs nothing (phases, shooting, spawning are M9a and later).

`CombatData.fromMission(mission, setup, { expr = Expr })` returns `{ Spawners, Pools, Spawns, Detectors, ConcealedDisguises, SetupCombatData, Warnings }` (`expr` is optional; with it every expression is compiled into a `...Program` field, and one that does not compile is a warning).

| Piece | Read from | Notes |
|---|---|---|
| **Spawners** | components of Type `CombatSpawner`, `CoverFillSpawner`, `SniperSpawner` | `Active`, `SpawnCap`, `TimeBetweenSpawns` stay expression strings; `Pool`, `Weapons`, `EnemyType`, `Tags` (split on `,;|`), `Squads`, `SquadSize`, `AllowDespawn`, `BlockedVariable`, `FlowMap`, `CustomCombatData`, plus the sniper (`Nodes`, `RespawnRate`, ...) and cover-fill (`CoverTags`, `FillFrequency`, `Inv`, ...) extras. Ordered by path **[O]** |
| **Pools** | components whose Type is `ReinforcementPool` or `ReinforcementPool<digit>` | keyed by `PoolName`; `Limit`, `RemainingVariable`, `ActiveVariable`, wave fields. A duplicate or nameless pool is a warning (first by path wins) **[O]** |
| **Spawns** | the `LoudSpawns` (and `FixedSpawns`) folders, one part each | `Position`, `Enabled` (expression), `IgnoreProximity`, `Range`, `Tag` (= `SpawnTag`) |
| **Detectors** | every bot node under `Bots/` (any depth) or `BotTemplates/` with a non-blank `DetectConcealedWeapons` | `Reaction` (e.g. `SetAlarmedWithAlert`); query with `detectorReaction(model, pathOrName)` **[O]** |
| **Disguises** | `MissionSetup.ConcealedWeaponDisguise` (entries that are `true`) | `disguiseHidesWeapon(model, disguise)` **[O]** |
| **Setup combat data** | `MissionSetup.CustomCombatData` (e.g. `RoseCombatAI`) | |

`EnemyWeapons` is `Weapon:Class` pairs split on `|`, each at its **last** colon (a weapon name may contain a space, e.g. `480 MCS`); duplicates are kept because they read as a weighted draw **[P]**.

**Classes (`CombatData.Classes`, all numbers [P] except where marked).** The map only names a class (`SteelCoveBasic`, `...Heavy`, `...Grenadier`, `...Shredder`); health, grenades and C4 live in the game engine, so BreachEngine has its own table: Basic 120 **[O: placed guards]**, Heavy 250 and plants C4, Grenadier 150 with grenades (every 12 to 20 s, range 6 to 25), Shredder 400. `classInfo(class, customCombatData)` merges a row with `CustomCombatData` (`HasGrenades`, `IsHeavyUnit`, `DamageOutput` default 1.0, `MaxHealth`/`Health`, `ForceHealthDisplay`, `SlowCombat`, `NoBreachTactics`, `NoRushingTargets`, `TeamId`) and never mutates the table. **`ShowsHealthBar` = `ForceHealthDisplay` if set, otherwise health MORE than 200 [owner].** Unknown classes fall back to Basic with `Known = false`.

**BreachSetup additions made for this** (The Blacksite's MissionSetup uses them): `require(script.X)` becomes `{ Type = "Require", Target = "script.X" }` with a warning and is never run; `game:GetService("RunService"):IsStudio()` reads as `false` (warning); `not <boolean>` works.

**Findings in The Blacksite pre-release (not committed data, just facts):** 25 spawners (17 combat, 2 cover fill, 6 sniper), 15 named pools plus one component with Type `ReinforcementPool7`, 36 spawn parts, 8 placed bots with `DetectConcealedWeapons`. One pool name is defined twice (`MantrapShredderPool`) while a spawner asks for `MantrapShredderPool7`, which nothing defines: probably an authoring slip in the pre-release (the digit ended up in the component's Type). BreachEngine keeps the model as written and warns.

### 8.4 Disguise, trespass and detection **[R]**

`MissionSetup.Cells` (the *trespass* table — not the `Cells` folder) defines per-cell `Trespass`, `MinorTrespass`, `Allow`, `Enforce`; `EnforceClass` maps alertness tiers to per-profile see-through thresholds; bluffing changes effective trespass status. *Profiles are fixed presets; classes are free.*

#### 8.4.1 What `BreachSight` provides **[done: M8c part 1]**

`BreachSight.luau` decides what bots see and how fast they notice. It produces **meters and events**; what being noticed *means* (trespass, alert) is built on top of it. Pure Luau, deterministic, no randomness.

```lua
local sight = Sight.new(world, bots, Sight.propsPlayers(propsSim), { blocked = function(ax, ay, az, bx, by, bz) return propsSim:sightBlocked(ax, ay, az, bx, by, bz) end })
sight:step(dt)                        -- after bots:step(dt)
sight:canSee(botId, playerId) -> visible, distance      sight:meter(botId, playerId)   sight:maxMeter(playerId)
sight:noticedBy(playerId)  sight:isNoticed(playerId)    sight:drainEvents()  -- SightSeen SightSuspicious SightNoticed SightLost
```

A bot sees a player when all of these hold (**every number is a default [P]** in `Sight.Defaults`, to be corrected by feel):

| Rule | Default |
|---|---|
| range | `ViewRange` 70 studs x stance factor (crouch 0.6, stand 1, sprint 1.25) |
| field of view | 110° cone about the bot's facing, plus an all-round `PeripheralRadius` of 6 studs |
| facing | a walking bot faces its heading; a bot standing at a node faces that node part's look direction (`CFrame` LookVector) [P] |
| line of sight | walking the segment, consecutive cells must be joined by a link (a wall between unlinked cells blocks; unmapped space is open); two points in the same cell see each other; a **closed door** blocks (`Props:sightBlocked`, an oriented-box test on the door part), an open door and a glass door do not |
| who looks | bots that are not despawned, dead, or incapacitated; players who have not left the mission |

**Noticing.** A per-(bot, player) meter fills at `DetectionSpeed / T(d)` per second, with `T` running from `NoticeNear` 0.6 s (point blank) to `NoticeFar` 4 s (edge of the range); `DetectionSpeed` is the bot's own attribute (real values 0.6 to 1, so a lower value is a slower-to-notice guard). **The alert level scales it** (`AlertSpeed`; the game's players report it, passed on by the owner, Nov 2026): the higher the level the faster guards notice, **Calm 0.9x, Normal 1x, Alert 1.1x** **[R]**; Lockdown was not given, it keeps 1.1x **[P]**. `sight.LevelFn` supplies the level (`BreachSession` wires it to the alert; without it the factor is 1). It multiplies the bot's own `DetectionSpeed`. It falls at 0.5 per second when the player is not seen. A noticing bot keeps the meter full until it has lost the player for `LoseSeconds` (3 s), then drops to the suspicious level and may notice again faster. Events: `SightSeen`, `SightSuspicious` (>= 0.35), `SightNoticed` (1), `SightLost`.

**Verified (68 tests):** the cone edges (inside and outside by 0.02 rad, both sides), range by stance, the peripheral radius, walls via the cell graph, closed/open/glass doors, time to notice at point blank / half range / edge (0.7 s, 2.3 s, 4.0 s) and with `DetectionSpeed` 0.5 and 2, decay, the event sequence and `SightLost`, who may observe, several bots on one player, facing follows movement, determinism. On the real maps (static posts, which give a meaningful "in front"): a player 10 studs in front is noticed within 3 s by **5 of 6** (Peacemaker) and **5 of 5** (Project) bots, a player 30 studs *behind* by **none**, and a player outside the map for 20 s never provokes an event.

Not done: sound (`SoundTravelDistance` is in the setup), lighting, a body or a dropped item being seen, per-profile vision differences, and the use of the sight meters (trespass and alert are the next two steps).

#### 8.4.2 What `BreachTrespass` provides **[done: M8c part 2]**

`BreachTrespass.luau` answers "is this player allowed here, and who minds?". It produces a status and events; what the game does about them is the alert layer. It reads the MissionSetup `Cells` table (BreachSetup), the world's cells, a logic core (for dynamic rules) and BreachSight.

**How a cell gets its rules [O].** A cell part is **named after a rule set** in `Cells`: all 55 / 90 / 75 cells of the three maps match (many cells share a name, e.g. a dozen `InsideHighlyRestricted` rooms). A rule set is a table with `Allow`, `Trespass`, `MinorTrespass` (the real maps use the disguise name `None` here, meaning no disguise), `Enforce`, `EnforceMinor` (one map also has `MinorTrespassBluff`), **or a `{expression}` string** whose value (a string literal such as `[Vault]`) names another rule set, evaluated live from mission variables: `ServerRoom = {KeycardPlaced && [ServerRoomAwesome] || [ServerRoomEvil]}`. Names, disguises and variables are matched without regard to case. A cell with no rule set uses `Default`, else is public. The `Enforce`/`EnforceMinor` keys are exactly the bots' `Class` values (`Sec`, `Emp`, `Civ`, `Workshops`); the `Allow`/`MinorTrespass` keys are disguise names (`ProSecurity`, `Chef`, `Technician`, `Workshop`, `EliteScientist`, `SteelCove`, `Debug`, `None`).

```lua
local tr = Trespass.new(world, Setup.parse(mission.SetupSource), logic)
tr:attach(sight, bots, Sight.propsPlayers(propsSim))      -- props: sim:setDisguise(id, "Chef")
tr:status("Workshop", cell) -> "allowed" | "minor" | "major", ruleName, rules       tr:enforces("Sec", status, rules)
tr:step(dt)   tr:statusOf(id)   tr:witnesses(id)   tr:drainEvents()   -- TrespassStatus, TrespassWitnessed, TrespassCleared
```

| Rule | Basis |
|---|---|
| status of disguise D (nil = `None`): `Allow[D]` -> allowed; else `Trespass` or `MinorTrespass[D]` -> minor if `MinorTrespass[D]` else major; else allowed | names **[O]**, combination **[P]** (one real rule set has `MinorTrespass` without `Trespass`; it is treated as minor) |
| who minds: a **major** trespass by bots whose `Class` is in `Enforce`, a **minor** one by `EnforceMinor` | names **[O]**, rule **[P]** |
| a bot **witnesses** when it has *noticed* the player (BreachSight) while the status is not allowed and it enforces; the witness is cleared when it loses the player or the status ends, and re-reported if the status changes while it still has the player | **[P]** |
| a rule chain is cut at depth 4 and reported; an expression that does not evaluate is an error and the cell falls back to public | |

**Checked against the data, including your V1.3 changelog:** The Project's `ServerRoom` is `ServerRoomEvil` before the keycard is inserted and `ServerRoomAwesome` after. Wearing the Workshop disguise it is **major** trespass before and only **minor** after; Technician and ProSecurity are allowed either way; no disguise or a Chef is major. Across all cells x 8 disguises the maps give: Diplomat 70 allowed / 16 minor / 354 major, Peacemaker 260 / 6 / 454, Project 221 / 13 / 366. In 20 s-scale runs on the real maps, where a static bot of an enforcing class faces an undisguised player 8 studs away in a cell that makes them a trespasser, **5 of 6** (Peacemaker) and **3 of 3** (Project) bots witness it within 3 s (the Diplomat has no static posts).

**Verified (58 tests):** every status combination, case-insensitivity, `None`, `Default`, dynamic and chained and self-referencing and broken rules, enforcement by class, the live event sequence (status changes, witnesses, disguise swaps, minor to major, leaving, a dynamic rule flipping under a standing player, players who left), determinism, and all of the real rule sets.

Not done: the `EnforceClass` thresholds and `EnforceCellLinks` (they belong with alert; see the questions in the plan), `MinorTrespassBluff`, bluffing, and what a witness *causes*.

### 8.5 Objectives, dialogue and strings **[R]**

`MissionSetup.Objectives`: ordered, lowest active wins, with `Active`, `Text`, `Tag`, `Header`, nested `SubState`, and a `Timer` sub-table (`ShowTimer`, `TrackVariable`). `Dialogue` holds arrays of localised-string keys per context, one alternative chosen at random. **All text must be a localised key in `CustomStrings`** (so it can pass Roblox's chat filter), conventionally dot-namespaced (`Speaker.PlayerOverride`). **[P]** BreachEngine's `Locales` module is the natural home for this lookup.

### 8.6 `MissionSetup` field index **[R]**

**[O]** the real map's `MissionSetup` has these top-level keys: `CameraConfig, Cells, ClientState, Colors, CustomDisguises, CustomMissionChallenges, CustomMissionIntel, CustomStrings, Dialogue, EnforceCellLinks, EnforceClass, Globals, HackingMapIntel, Internals, LightingSettings, Objectives, Preplanning, SoundTravelDistance` — note `CustomMissionChallenges`, `CustomMissionIntel`, `Preplanning` and an `EnforceCellLinks` copy that the authoring doc did not list. A second map adds `DebugWatch`, `DialogueTree` and `ExtraLoot` and lacks the `CustomMission*` keys, so **most keys are optional** and the set is open-ended (§13.5). Documented fields: `Globals`, `Internals`, `ClientState`, `ForcedLoadout`, `HackingMapIntel`, `LightingSettings` (preset from the engine's assets — BreachEngine needs its own presets), `SoundTravelDistance`, `Colors` (**[V]** the only field the exporter post-processes), `CameraConfig` (`CamSet`, `OperatorTag`, `RoomTag`), `Cells` (trespass), `EnforceClass`, `Objectives`, `Dialogue`, `CustomStrings`, `CustomDisguises`, `Character` (`Perks`, `Speaker`).

---

## 9. Roadmap **[P]**

Each milestone has an acceptance test that does not require the later ones.

| # | Milestone | Done when |
|---|---|---|
| M0 | **Baseline** *(exists [N])* | Locales + version label + Ctrl+H toggle work |
| M1 | **Codec (decode)** *(DONE: decodes a real Operators map, 6,148 instances, 0 warnings; pure-Luau Zstd included; 122 tests)* | All §4.11 vectors decode; the *Deposit* template (and any other official template you have) decodes without error; version 0, 1, 2 inputs all work; malformed input fails cleanly |
| M2 | **Validator** *(DONE: two modes, 31 tests; reproduces the real exporter's output on The Diplomat exactly — 526 component nodes, 0 changes, 0 issues)* | Re-implemented §3.4 precedence passes a table of hand-made cases (including N1); warnings carry instance path + attribute |
| M3 | **Mission model + Standalone format** *(DONE as portable libraries: `BreachMission.luau`, `BreachStandalone.luau`; the host-specific materialiser — creating Roblox Instances — is deliberately NOT here; it is a thin adapter over the model)* | Model indexes both real maps; Standalone round-trips both **exactly** (6,148-instance map: encode 0.5 s, decode 0.4 s) |
| M4 | **World** *(DONE as portable `BreachWorld.luau`: cells, links, per-cell navigation graph, A*; **link-to-cell matching is a documented heuristic**, see §6.4)* | `cellAt`, link graph, hops/route, A*; 21 tests incl. both real maps |
| M5 | **Logic core** *(DONE as portable `BreachExpr.luau`, `BreachRandom.luau`, `BreachLogic.luau`; 245 tests incl. both real maps; the Diplomat's and Peacemaker's Setup logic and every Peacemaker StateUpdate/Notification/Timer run)* | Expression evaluator with short-circuit semantics; variable store with replication; `StateUpdate`, `Notification`, `TimerComponent`, `MissionCompletionTrigger` running |
| M6 | **StateScript VM** *(DONE as portable `BreachScript.luau` + `BreachCFrame.luau`, wired into `BreachLogic` as the `StateScript` component; 193 tests incl. all 26 real scripts and exact-timing checks)* | Instruction set in §7.4; sample scripts run; instruction budget enforced |
| M7 | **Props I** *(DONE as portable `BreachProps.luau`; 149 tests: every family, a whole synthetic no-guards mission, and every real prop of all three maps used once)* | `TriggerZone/Room`, `FreeTrigger`, `ItemSpawn`, `MissionEndZone`, doors + readers (enough to finish a no-guards mission) |
| M8 | **Bots I** *(PLANNED: see `BreachEngine_M8_Bots_Plan.md`; **M8.0 MissionSetup parser, M8a nav + followers M8b bots + patrol and M8c-sight and M8c-trespass DONE**; split into M8a nav + followers, M8b bots + patrol, M8c sight/alert/trespass, M8d hostages + alt interaction, M8e CustomBehavior, M8f playthrough)* | `PatrolWalk`, node pathing, vision/detection, alert level, `Inv` |
| M9 | **Combat** | `CombatSpawner`, `ReinforcementPool`, loud/combat transition |
| M10 | **Hacking + intel** | `NetworkId` graph, `CustomHack`, tablet UI |
| M11 | **Randomisation** | Seeded `ShuffleContents`, `PickCount`, `PartCollection`/`ShuffleTarget`, `HiddenShuffle` |
| M12 | **Encode + Standalone** | Export your own missions back to an IE code (round-trip *equivalence*) and to the Standalone folder format |

**Testing strategy.** (1) *Golden decode tests*: decode → canonical JSON dump → commit; any decoder change that alters the dump is reviewed. (2) *Round-trip*: decode → encode → decode, compare trees (never strings, N5). (3) *Headless unit tests* for Codec, Validator, Expr, StateScript, Random — none need Roblox. (4) *Seeded replay*: a fixed seed plus a scripted input log must reproduce the same variable history.

---

## 10. Open decisions

| # | Decision | My recommendation |
|---|---|---|
| D1 | Native format vs import-only | Support **IE-code import** (now fully specified) *and* your Standalone format; they feed the same raw tree |
| D2 | Child order and references in Standalone | Explicit order + stable-id references (§5.5 #1) |
| D3 | How to treat `MissionSetup` | Consume the JSON only; never execute mission Lua |
| D4 | Unknown attributes | Warn and keep (more forgiving than the exporter, which discards) so you don't lose data you may later understand |
| D5 | `false` attributes (N1) | Decode literally; **encode** with the same rule as the exporter only if you want byte-for-byte parity; otherwise write real `false` in Standalone |
| D6 | Meshes in Union/MeshPart | Support `rbxassetid` meshes; provide your own `ImportParts`-style cache |
| D7 | Licence posture | Keep decoder/validator independent of the plugin's text (§1.4) |
| D8 | Naming (`Instance.metadata` vs `instance.meta`, `Contents` vs `Data.gz`) | Choose one scheme shared with the headless-runtime project |
| D9 | Misspelt names (`TriggerThreshhold`) | Keep exact spellings for compatibility; add friendly aliases in your *own* format |

---

## 11. Glossary

| Term | Meaning |
|---|---|
| **IE** | InfiltrationEngine, the engine being made compatible with |
| **Mission code** | the text blob (or gist) produced by the exporter |
| **DebugMission** | root instance of a mission tree |
| **Cell / Link** | spatial zone / connection between zones |
| **Meadow map** | per-cell pathfinding node graph |
| **Prop** | a placed functional or decorative object |
| **StateComponent** | map-wide logic object, a `BoolValue` driven purely by attributes |
| **StateScript** | the embedded scripting language |
| **Expression** | the string/number language used in `expr` attributes |
| **Global / Internal / ClientState** | variable stores (§7.1) |
| **Component key** | the `Type` attribute (BoolValues) or `Name` (everything else) used to look up an attribute entry |
| **Raw tree** | the decoded, un-validated instance tree |
| **Standalone** | BreachEngine's on-disk map format (§5.5) |

---

## 12. What I could not verify

Everything below is **not in the plugin**, so it is **[R]** at best and must be learned by observation or designed fresh:

- the engine's runtime behaviour for every component (what `AutoLock` *does*);
- the detection/alert maths, hacking economy, disguise rules;
- the full StateScript grammar and error behaviour (only the instruction names are documented);
- the exact `Cells` / `Links` / `MapData` / `Nodes` folder schemas (they are Folders, hence unvalidated);
- the live game's reader (it may differ from the plugin's — e.g. `ENABLE_ARBITRARY_MESHES`);
- whether the game applies the 5,183-entry cap, or has a different one (the real map uses 1,371 strings, nowhere near it).

When you do observe the real engine, add those findings here with an **[O]** (observed) tag and date.


---

## 13. Validation against a real map **[O]**

*Source: `TheDiplomat.base64`, a mission exported by the live plugin (author `mrwd`, ExportVersion 7), decoded with `BreachCodec.luau` + `BreachZstd.luau`.*

### 13.1 What it confirms about §4

| Check | Result |
|---|---|
| Header `djwbcbc` | version 2, map id 446, piece 1 of 1 — matches §4.8 |
| Payload | 161,748 characters of standard Base64 (with `=` padding) → one Zstd frame → **477,509-byte** stream |
| Zstd frame | single segment, content size present, no checksum, no dictionary |
| Stream grammar (§4.4–4.5) | decodes **6,148 instances**, 1,371 unique strings, with **zero trailing symbols** — the grammar consumed the stream *exactly*, which a wrong rule almost never does |
| Class ids / property tables | every property read type-checked against the stream; all 13 classes that occur (`Part, Model, Texture, BoolValue, WedgePart, Folder, MeshPart, UnionOperation, SpecialMesh, Attachment, Decal, StringValue, Smoke`) decode cleanly |
| Escapes, maps, nested folders | fine; maximum nesting depth 7 |
| Speed | 0.14 s decode + 0.11 s Zstd on desktop Luau |

**One spec gap was found and fixed:** map index 0 = nil (§4.4). Everything else in §4 held on first contact with real data.

### 13.2 What it says about the mission model

- **Class mix:** Part 5,218 · Model 299 · Texture 200 · BoolValue 100 · WedgePart 98 · Folder 82 · MeshPart 60 · UnionOperation 32 · SpecialMesh 21 · Attachment 14 · Decal 13 · StringValue 6 · Smoke 5. (No lights, particle emitters or GUI instances in this one.)
- **Top-level folders:** `Props` (812 children), `Glass` (76), `Disabled` (13), `StateComponents` (17), `ConditionalGeometry` (0), `BotStorage` (0), `Bots` (3), `CustomProps` (18), `CustomItems` (6), `Geometry` (1,826), `MapData` (1), `Nodes` (5), `LoudSpawns` (17), `CombatFlowMap` (0), `Barrier` (31), `BotTemplates` (14), `Cells` (56), `StateComponentsPreprocess` (1), then the exporter-added `CustomMissionSettings`, `TableMissionSetup`, `StringMissionSetup` — in that order (the exporter appends its three at the end, as §4.6 said).
- **100 `BoolValue` components** of 20 types: `DelayedStateUpdate` 13, `CustomHack` 10, `LocalChat` 10, `BotStateTracker` 9, `MusicController` 5, `AlertRaiseCondition` 4, `StateScript` 4, `AlarmedBehaviorOverride` 3, `ItemStateTracker` 3, `CustomBehaviorCondition` 2, and one each of `BotAltTrigger, CombatSpawner, ConditionalBotTag, ConditionalStateUpdate, HackableDoor, RandomBotSpawner, ReinforcementPool, SniperSpawner, StandardRadioAlertReduction, VariableShuffle`. **Every one of these type names exists in the plugin's attribute map** (Appendix A), and **no component carried an attribute outside its map entry** (except `StateScript`, which is exempt by design, §3.4 rule 3) — direct confirmation of how the validator filters.
- **`StateScript` attributes seen:** `ScriptSource` (the script body, 93–851 characters), `Run`, `TriggerEvent`, `DebugVariable`, `DebugLineVariable`, plus author-defined parameters (`GuardCount`). All four scripts carry *both* `Run` and `TriggerEvent`: `Run` is a number/expression (`0` or `1`) and `TriggerEvent` is a name (`DriveTruck`, `PoolTableFlip`, `SpawnBots`). So the two modes of §7.4 are not exclusive attributes — `Run` is the condition for the persistent mode and `TriggerEvent` names the event for the other; how they interact when both are set is unobserved.
- **Settings:** `EnforceCellLinks = true`, `ExportVersion = 7`, `MissionName = "The Diplomat"` — §3.1 confirmed.
- **`MissionSetup`:** 18 top-level keys (§8.6), 7 named colours, 163 custom strings, source 30,207 characters, **no sub-modules**. `Objectives` is a **dictionary keyed by category** — `Mission`, `Stealth`, `Stealth2`, `Combat`, `Intel` — not an array (§8.5 should be read that way). The `MissionSetup` source starts with a licence comment (*"Assets are licensed under Creative Commons BY-NC-SA 4.0"*), i.e. it descends from the official template, and its first returned field is `EnforceCellLinks = true`, followed by `Preplanning = { MissionTitle = "MissionTitle.TheDiplomat", … }` (localisation keys).
- **Most-used attributes:** `Color0` 477, `Color1` 177, `Path`/`Move`/`Open`/`Sound` 141/90/90/90 (the link attributes, §6.2 — **now observed**: 90 `Part`s named `Link`, each in a folder called `Links`), `TakedownImmunity` 90, `PowerArea` 89, `IsSpawned` 77, `WallStrength` 68, `StateValue` 61, `Tag` 58, `Location` 54, `GreyboxMetadata` 41.
- **Names with attributes that are *not* in the attribute map** (so they pass through unvalidated — §3.4 rule 5): `Link`, `Node` (the link and pathfinding-node instances), `FixedSpawn`, `RoundedWall`, `BinderRow`, `CfrRef`, `Light`, restriction zones (`InsideHighlyRestricted`, `OutsideRestricted`, …), and a long tail of decorative props (`PlasticChair`, `PottedPlant`, `PoliceCar`, …). They are real components with attributes the exporter does not police.

### 13.3 What it does *not* settle

Runtime behaviour. A map is data; running this one correctly is the rest of the roadmap. But it is now a **regression fixture** for every later milestone: the validator (M2), the materialiser (M3, expect 6,148 instances) and the world builder (M4, expect 56 cells) all have a concrete real target.

### 13.4 Evidence for the validator rules **[O]**

Running the re-implemented exporter rules over the real map: **6,148 nodes walked, 526 had a map entry and were validated, 0 attributes changed, 0 issues**. That is the idempotence property the real exporter must have (it validated this map itself), and it holds for 526 instances covering the 20 component types in the map, so the type checks, default-dropping and global/unknown handling are right *at least for everything this map exercises*.

It also bears on **N1** (false attributes dropped): the map contains **0** explicit `false` attributes on listed, non-global attributes of validated components, but **3** on global attributes (`OnProp`, `Indestructible`) and **177** on components with no map entry (pass-through). That is exactly the pattern N1 predicts; it is evidence, not proof (an author could simply never have set one).

### 13.5 A second real map **[O]**

*Source: `TheInterception.base64` (author `KitaroKitsune`, ExportVersion `Beta 1.4`), decoded by the same code, on a phone (Termux).*

| Check | Result |
|---|---|
| Header | version 2, map id 4358, 1 of 1, 98,020 payload characters |
| Decode | **3,667 instances, 0 warnings** (stream consumed exactly), 0.13 s |
| Classes | Part 3,053 · Model 191 · Folder 153 · BoolValue 112 · Texture 95 · MeshPart 40 · Attachment 12 · StringValue 6 · SpecialMesh 4 · BlockMesh 1 |
| Non-ASCII text | the briefing contains typographic quotes/apostrophes (multi-byte UTF-8); decoded intact, so the byte-length-prefixed strings (§4.3) are right for non-ASCII |
| `ExportVersion` | `"Beta 1.4"`: free text whose *trailing integer* is the counter, consistent with §3.1 (text before it is kept) |

What it adds to the picture of the mission model:

- **Two maps, one vocabulary.** The same 17 core folders (`Props, Glass, Geometry, MapData, Disabled, StateComponents, ConditionalGeometry, BotStorage, Bots, CustomItems, CustomProps, Barrier, Nodes, LoudSpawns, CombatFlowMap, Cells` plus the exporter's three) appear in both, in a **different order** — folder order is not canonical. `BotTemplates` and `StateComponentsPreprocess` (§3.2) are optional extras of the first map.
- **New component types** not in the first map: `ConversationGenericSocialEngineering` ×3, `CredentialUnlock` ×2, `StateLock` ×1 (all in the attribute map). `ItemStateTracker` is the most common component here (27).
- **The validation opt-out is used in the wild.** 29 instances carry `IKnowWhatImDoingDoNotValidate`; 13 of them are `ToolTrigger` props carrying `LockpickEnabled/Title/Subtitle/XOffset`, `LockpickGun*`, `Keys` and `KeyXOffset` — attributes **absent from the plugin's attribute map**. So the engine understands attributes the exporter's map doesn't list, and authors reach them through the opt-out. **Consequence for BreachEngine [P]:** the validator's `engine` mode (keep and report unknown attributes) is the right default; discarding unknown attributes would break real missions. (Component names/attribute lists in Appendix A are therefore a *floor*, not the full engine vocabulary.)
- **`MissionSetup` is open-ended.** New top-level keys `DebugWatch`, `DialogueTree`, `ExtraLoot`; no `CustomMission*` keys and no `EnforceCellLinks` key. Objective groups here are `Combat, Counter1, Mission, Stealth` — the first map had `Stealth2` — so the group names are **author-chosen**, not a fixed set. 21 named colours, 146 custom strings, 25,310-character setup source.
- **Validator on this map:** the report now runs the exporter-mode validator and prints opt-out notices separately; the regression test expects 0 changes and only opt-out notices.

### 13.6 A third real map, as a gist **[O]**

*Source: `thepeacemaker.txt` — "The Peacemaker" by Benoki9, shared as a Gist, the form players actually use.*

| Check | Result |
|---|---|
| Wrapper | begins `!!!\nHow to play custom missions:\n\n1) Join the game…` and ends `…Briefing: …\n\n!!!` **exactly as the plugin source writes it** (§4.8). The `EnforceCellLinks` warning line is absent (the map enforces cell links) |
| Header | `djwbcbc`-style, here version 2, map id 845, piece 1 of 1; payload 316,552 characters — the largest map so far |
| Decode | **11,971 instances, 0 warnings, 0.18 s**; validator idempotent (0 changes; the only issues are 13 opt-out notices, all on `ItemDeposit`) |
| Classes | Part 9,107 · Model 598 · Decal 554 · Texture 541 · BoolValue 483 · Folder 308 · UnionOperation 108 · MeshPart 100 · WedgePart 81 · SurfaceLight 25 · Attachment 12 · ParticleEmitter 10 · StringValue 10 · ImageLabel 9 · SpecialMesh 9 · PointLight 8 · BillboardGui 7 · SurfaceGui 1 |

- **First real data for six more class tables.** `ParticleEmitter` ×10, `SurfaceLight`, `PointLight`, `ImageLabel`, `BillboardGui` and `SurfaceGui` all decode with the stream consumed exactly. That independently confirms the corrected Appendix B (the `ParticleEmitter` ids were the ones my first generator shifted).
- **The comment's version is not the embedded one.** The comment says `Version: 0.916`; the `ExportVersion` inside the code is `0.65`. The plugin bumps the number *before* encoding, so both should be equal — they are not (and `0.65`→`0.916` is not a bump). The comment is plain text that the author can edit (or another tool wrote it). **Do not use the comment for identity or versioning**; the loader ignores it.
- **New top-level folder** `TerrainData` (2 attributes). New `MissionSetup` keys: `CustomCombatData`, `InternalHash`, `LegendVariants`, `TacticalVariants`, `Variants`; objective groups here are `Combat, Counter1, Intel, Mission, Stealth, Timer`. 650 custom strings; the setup source is 116,253 characters.
- **Components seen** (all in the attribute map; no attribute outside its entry): `LocalChat` 91 · `CustomHack` 26 · `Notification` 25 · `DelayedStateUpdate` 24 · `StateUpdate` 24 · `ConditionalStateUpdate` 22 · `StateScript` 22 · `TimerComponent` 17 · `ConversationGenericSocialEngineering` 16 · `CustomBehaviorCondition` 15 · `BotStateTracker` 12 · `HackingNodeStatus` 12 · `ReinforcementPool` 12 · `HackingNodeHighlight` 10 · `IntelSubText` 10 · `ConditionalBotTag` 9 · `CombatSpawner` 8 · `ItemStateTracker` 8 · `CoverFillSpawner` 7 · and a tail down to single instances (`FileUITrigger`, `HiddenShuffle`, `ScriptedBotSpawn`, `MusicController`, `Intel*`, …).
- **Randomisation is used heavily:** `ShuffleTarget` ×272, `ShuffleTag` ×270, `MatchVariable` ×270, `ResolvePriority` ×284, `PartCollection` ×17 — the machinery of §7.5 is core, not exotic.
- **`PlaceholderProp` is real** (×40 instances, no attribute-map entry) — resolves the open question in §2.1 #16. Other unmapped names with attributes: `Part0/Part1/Part2`, `Hitbox`, `Motor`, `Wheel`, `Ring0` (vehicle or mechanism parts).
- **World:** 90 cells (zone classes `Base` ×80, `TrespassRoom` ×4, `Center` ×3, `MajorTrespassRoom`, `SecCenter`, `None`), 149 links, 807 navigation nodes in 37 components (largest 307) — zone-class names differ a lot between maps, so they are author-defined (§8.4 keys), not a fixed set.

### 13.7 The logic layer against the real maps (M5) **[O]**

| Check | The Diplomat | The Peacemaker |
|---|---|---|
| Setup expressions compiled | 39 / 39 | 170 / 170 (131 Globals, 39 ClientState) |
| Expression attributes compiled | 850, 1 known typo (stray `)`) | 3,480 (+42 string-context `DisabledTitle`/`DisabledSubtitle`), 0 failures |
| Supported components running | 0 (it has none of the four) | StateUpdate ×24, Notification ×25, TimerComponent ×17 |
| Other components under `StateComponents/` | 66 (incl. 13 `DelayedStateUpdate`, 1 `ConditionalStateUpdate`) | 350 |
| Errors building and running 600 simulated seconds | 0 | 0 |
| Variables read but declared nowhere (engine built-ins, or written by later milestones) | 39 | 99 |
| Two runs, same seed | identical event log and final state | identical |
| Client joins | no errors; no Internal leaks; mirrors every Global | same |

The undeclared lists are the to-do list for later milestones (`Mission_AlarmRaised`, bot-state counters, prop-written flags). In an idle run nothing is notified because the notification conditions depend on exactly those variables; the Peacemaker's `MissionEnterDialogue` timer does run (−5 → 1) and the Diplomat's initial values settle (e.g. its `RNG 5342 1 8` guard pick and the derived `ClothesLocation`).

### 13.8 StateScript against the real maps (M6) **[O]**

| Check | The Diplomat | The Peacemaker |
|---|---|---|
| StateScripts (all under `StateComponents/`) | 4 | 22 |
| Compile with no unknown instruction / missing label / syntax problem | yes (1 lint: `INIT WingEntrancePatrol` has no value) | yes |
| Instructions used (14 of 37) | ANIMATE ANIMATECUBIC CFRCOPY GOTO INC INIT SET SPAWNBOT WAIT | ANIMATE ANIMATECUBIC CALLIF CFR CFRCOPY CFRDEGREES INIT KILL MOVETO SET WAIT |
| Build + run with scripts live | 0 Errors | 0 Errors (300 s) |
| `TruckRun` fired by `DriveTruck=1` | ANIMATECUBIC ×2 at t=2.0, ANIMATE at 3.5 / 3.7 / 4.2 / 4.4 (+GarageCar 4.4), then `TruckFinish=1` — matches its WAITs exactly | — |
| `OutOpen` fired by `BlastDoorOutOpen=1` | — | two ANIMATECUBIC, door CFrame = (10.499, −6.6, −97.425) · Rot(0,90°,0) |
| Soft issues | 18 `SPAWNBOT` skipped: `Guard1…Guard18` come from the unimplemented `VariableShuffle` | 3 `MOVETO` skipped until another script sets the `PrevCutter` CFrame |
| Two runs, same seed | identical commands | identical |

### 13.9 The variable components against the real maps **[O]**

| Check | The Diplomat | The Peacemaker |
|---|---|---|
| `DelayedStateUpdate` / `ConditionalStateUpdate` / `VariableShuffle` live | 13 / 1 / 1 (preprocess) | 24 / 22 / 2 (preprocess) |
| Build + run, Errors | 0 (60 s) | 0 (300 s) |
| Effect | `Guard1…Guard18` dealt over 6 areas (HighSecurity ×2 weight); the spawn script emits all **18 `SPAWNBOT`s**, each with its dealt area's CFrame (previously skipped) | `RoleTechLead`/`RoleNetworkSpecialist`/`RoleDummy` name real scientists; codenames 0…5 are a permutation with an owner map; none of it reaches a client (`InternalOnly`) |
| Components under `StateComponents/` still unsupported | 48 of 100 | (see test output) |
| Two runs, same seed | identical | identical end state |

### 13.10 *The Project* (V1.3), a version-0 map **[O]**

A 800 KB plain-text version-0 map (not compressed, newlines not escaped; main doc §4, N9). The author notes that it relies on some engine quirks.

| Check | Result |
|---|---|
| Decode | version 0, 0.07 s, **no codec changes**, 0 warnings |
| Mission model | 10,633 instances, 0 warnings; Setup: 258 Globals, 7 Internals, 1 ClientState, 374 custom strings |
| World | 75 cells, 68 links; 1 warning: 3 cells have nav nodes entirely outside their own volume (cells #10, #14, #26) |
| Expressions | 266 / 266 Setup and 2,202 / 2,202 expression attributes compile |
| StateScripts | 18, all compile clean |
| Logic live | DelayedStateUpdate ×49, Notification ×11, TimerComponent ×10, StateScript ×18, ConditionalStateUpdate ×1, Completion ×2, Failed ×2; 0 Errors, 0 Warnings, 600 s idle run; deterministic; no Internal leak to a client |
| Not yet running | 157 StateComponents in 25 kinds (LocalChat ×57, FileUITrigger ×15, BotStateTracker ×10, ItemStateTracker ×10, MusicController ×9, CustomHack ×8, AlertRaiseCondition ×7, LocationCard ×6, …, `HiddenShuffle` ×2, `LerpOperation` ×1); 134 variables are read but never set |

**Two corrections it forced.** (1) Appendix A typed `EnemyWeaponsWave1…9` as expressions; the real value is a `|`-separated weapon pool like `EnemyWeapons` (`480 MCS|S97|F57`), so they are strings now (`attrmap.inc`, Appendix A). (2) The engine-variable defaults above. Neither is a quirk of the map: both were gaps in this project.

#### 13.10.1 Lockdown and detonation in *The Project* (what the engine now reproduces) **[O]**

Traced from the map's own components and run in `BreachLogic`:

| Event | Behaviour (verified by test) |
|---|---|
| Alarm raised | `Mission_AlarmRaisedDelayed10` follows after **10 s**; then `LoudTimerStart` = 1 |
| Lockdown clock | `SearchTimer` starts at **479** (`StartValue 120` + `Offset 359 * LoudTimerStart`), shown `07:59`, one second per second, stops at 0 after 479 s |
| Detonation | the power box (`PowerBox3`, same variable as `Powerbox3`, see §7.1) sets `Loudmusic3`; **13.4 s** later `BoomBegin` starts a 02:00 clock; **116 s** after that `LoudJoever` is set and `MissionFailedTrigger` (Timeout 0.1 s) fails the mission, i.e. **129.5 s** after the power box. If a lockdown was running its clock is replaced by the 02:00 one |
| At `SearchTimer == 0` | consumed only by an `AlertRaiseCondition` (not implemented yet) and by `SearchMove`; the engine does not fail the mission there |

**Not yet reproduced (reported by the map's player, not found in the data):** that lockdown leaves "only a 10 minute timer before automatic fail", and that entering without dropping items, or with the Combat plan, activates a "10 minute detonation". No Setup variable or implemented component carries either; 479 s + 120 s is 599 s, which would match 10:00 if the lockdown clock's end hands over to the detonation clock, but that hand-over is in something the engine does not run yet (a prop, `AlertRaiseCondition`, or an engine-side loadout check).

### 13.11 Props against the real maps (M7) **[O]**

| | The Diplomat | The Peacemaker | The Project |
|---|---|---|---|
| Props live | 117 | 344 | 302 |
| By kind | CardReader 4, Door 43, FreeTrigger 12, ItemDeposit 10, ItemSpawn 41, MissionEndZone 1, TriggerRoom 6 | Door 94, FreeTrigger 74, ItemDeposit 16, ItemSpawn 102, MissionEndZone 2, TriggerRoom 26, TriggerZone 30 | CardReader 2, Door 58, FreeTrigger 64, ItemDeposit 15, ItemSpawn 96, TriggerRoom 54, TriggerZone 13 |
| Other prop nodes (not yet handled) | 781 | 2,140 | 1,539 |
| Using every prop once | 110 uses: 75 ok, 16 not visible, 8 not spawned, 6 locked, 4 no power, 1 blocked | 286: 151 ok, 78 not visible, 39 not spawned, 6 locked/disabled/not-allowed each | 235: 150 ok, 47 not visible, 12 disabled, 12 not-allowed, 8 locked, 4 not spawned, 2 no power |
| Throws / logic errors | 0 / 0 | 0 / 0 | 0 / 0 |
| Reader → door wirings (`TriggerVariable` in a door's `RemoteUnlock`) | 4 | 0 | 2 |

Real chains verified on The Project: a player in the `StealthExit` zone sets `PlayersInStealthExit`, and the map's own Setup then derives `AllPlayersInStealthExit`; walking into the armory room sets `ArmoryEntered` and it latches. A full synthetic no-guards mission (room → keycard → reader → door → hold-to-hack → gated pickup → end zone → completion trigger) completes with the events in order.

### 13.12 `MissionSetup` (`SetupSource`) against the real maps (M8.0) **[O]**

`BreachSetup.luau` is a strict parser for the Luau subset the chunk uses: `local` constants referenced by name (with `.field`/`[key]` indexing), tables, strings (all escapes, long strings), numbers, comments, `Color3.fromRGB/new`. It never runs code; anything else is an error with line and column.

| | The Diplomat | The Peacemaker | The Project |
|---|---|---|---|
| Chunk size | 30 KB | 116 KB | ~110 KB |
| Parse time | 3 ms | 5 ms | 3 ms |
| Top-level keys | CameraConfig, Cells, ClientState, Colors, CustomDisguises, CustomMissionChallenges, CustomMissionIntel, CustomStrings, Dialogue, EnforceCellLinks, EnforceClass, Globals, HackingMapIntel, Internals, LightingSettings, Objectives, Preplanning, SoundTravelDistance | (same family) | CameraConfig, Cells, ClientState, Colors, CustomDisguises, CustomStrings, DebugWatch, Dialogue, EnforceClass, ExtraLoot, Globals, HackingMapIntel, Internals, LightingSettings, Objectives, SoundTravelDistance |
| Cells | 17 | 10 | 14 |
| Warnings | 0 | 1 (below) | 0 |
| `Globals`, `Internals`, `ClientState`, `CustomStrings` equal the decoder's Setup | **exactly** | **exactly** | **exactly** |

- **Cross-validation.** The chunk contains the same Setup stores the M1 decoder exposes; all four match key for key in all three maps. That checks the decoder and the parser against each other.
- **Invalid escapes are not errors.** The Peacemaker has `"...\ARE YOU KIDDING ME?!"` (line 2492). Lua and Luau read an unknown escape as the character itself, and the map works in game, so the parser does the same and reports a warning.
- **Cells** (what trespass will use, M8c): a table `{ Allow = {class = true}, Enforce = {…}, EnforceMinor = {…}, Trespass = true, MinorTrespass = {disguise = true} }`, **or** a `{expression}` string that picks the rules at run time (`"{IntercomBluffComplete && [InsideHighlyRestricted] || [Roof]}"`, which names another cell). Shared `local` constants such as `ENFORCE_TRESPASS_CLASSES` are resolved.
- **`EnforceClass`** has one entry per alert level (`Alert0…Alert3`) and per disguise level (`Chef0…Chef2`, `Technician`, `Workshop`), each a `{class = count}` table, plus `None`.
- **V1.3 changelog, found in the data:** The Project's `ServerRoomAwesome` has `MinorTrespass = { Workshop = true }`, i.e. only *minor* trespassing in the workshop disguise.

### 13.13 The navigation data, explained by the Meadow Map tool **[O]**

Source: the public *InfiltrationEngine Tools* plugin from the custom-missions repository (`Plugins/src/InfiltrationEngineTools/MeadowMap`, `DoorAccess`, `CombatMap`), pointed out by the project owner. **Read to understand behaviour only; no code was copied.** The repository's README licenses its mission templates and prop models CC BY-NC-SA 4.0 and states no licence for the plugin code, so BreachEngine's own implementation stays independent.

- **How every cell's `Path` is generated.** Per cell: a node 4.5 studs either side of every direct `Props` child whose name matches `Door` (placed 3 studs *below* the door part's centre, i.e. at floor level), and either side of every `Cells/Links` part that has a `Path` attribute (0.5 studs above the link), kept only if inside the cell's zone. Nodes are joined by **line of sight** (a ray from node height + 0.75), so **every saved edge is a straight, walkable segment**, which is what lets `BreachNav` follow path polylines without a mesh.
- **Links are directed.** The saved `Link` is an adjacency list per node, and the reloader adds one-way links; this is the origin of the one-way edges counted in §6.4.
- **`Placed` is only a marker** for hand-placed nodes (saved from any node part with transparency above 0.25), **and is a subset of `Node`**. Checked on the real data: 281 of 281 (Diplomat), 797 of 797 (Peacemaker), 323 of 323 (Project) `Placed` entries also appear in `Node`; M4's treatment of them as already-in-the-graph was right.
- **Graphs are per cell.** Nodes outside their cell are rejected by the tool ("Nodes should not be placed outside of their cell"). Moving a mission after insertion offsets the pathfinding data (the README says to check with the Meadow Map plugin), and cells whose nodes lie entirely outside their volume (3 in The Project, §13.10) are the same symptom.
- **Door restrictions for bots (M8 to-do).** `DoorAccess` writes per-side `PathReq1`/`PathReq2` from this list: `Never`, `Combat`, `BasicKeycard`, `SecurityKeycard`, `MasterKeycard`, `MRKey`, `MasterKey`, `SecurityBadge`, `LeadSecurityBadge`, `ITBadge`, plus `PathRecover`, `PathIgnoreOpen` (and unlocked/broken variants) as per-side bit masks (`value % (2*side) >= side`), alongside `LockFront`/`LockBack`. The keycard names and their order support M7's Basic < Security < Master ladder.
- **Combat uses a separate named graph (M9).** Nodes carry `Id` and `LinkedIds` (JSON), with `BlockedLinks` and a derived `FilteredLinks`; a link is named `idA|idB`.

### 13.14 Why real patrol routes did not path, and what fixed it (M8b) **[O]**

M8b walked every bot's real route through the world's nav graph. Every failure was the same kind: two consecutive route nodes in cells that no link joined (nav splits inside a cell: 0; cells without nodes: 0). Two corrections, found by measuring, not assuming:

1. **Door edges (new).** The Meadow Map tool puts a node at `door.CFrame * (0, -3, ±4.5)` for every direct child of `Props` named `Door…` (§13.13). On the real data **80 of 86 (Diplomat) and 56 of 112 (Project) expected nodes lie within 0.1 studs**, and 38 / 20 door pairs straddle two cells: those doors are the only thing joining the cells, and nothing saved joins them. `World.build` now adds an edge between the two nodes of a door pair (`navEdgesDoorExact`); for doors without matching nodes (The Peacemaker nests its 94 doors in folders, which the tool ignores, so its nodes were placed by hand: 0 exact matches) it joins the nearest node of the cell on each side within 7 studs (`navEdgesDoorNear`), only across two different cells.
2. **`minHitFraction` 0.50 → 0.15** (§6.4).

| Patrol legs pathable | before (M4) | + door edges | + `minHitFraction` 0.15 |
|---|---|---|---|
| The Diplomat (42 legs) | 64% | 100% | **100%** |
| The Peacemaker (361) | 83% | 94% | **94%** (341) |
| The Project (764) | 83% | 85% | **100%** |
| Nav components (Dip / Pea / Proj) | 33 / 37 / 52 | 5 / 24 / 49 | **4 / 20 / 32** |
| Door edges (exact + nearest) | | 39+2 / 0+19 / 22+1 | |

**Known limitation:** the Peacemaker's remaining 20 legs are all on one route, `SecPatrol`, crossing floors (|Δy| ≈ 20) between cells that no link joins at all; its bots report `BotPathFailed` and skip those nodes. Probably a stair/lift transition that is not a link; unresolved.

Found alongside: `Nodes` may list several routes (§8.2.2), and the V1.3 changelog line "all cells are now properly linked" is consistent with the `minHitFraction` result (The Project went from 85% to 100%).
