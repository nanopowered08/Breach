# BreachCodec

Portable pure-Luau decoder for InfiltrationEngine-style mission codes (code versions 0, 1, 2).
BreachEngine milestone **M1**. Written from `BreachEngine_Documentation.md` §4; contains no plugin code.

```
BreachCodec.luau      mission-code decoder — one file, no requires, no Roblox APIs   (BUILT; don't edit)
BreachZstd.luau       pure-Luau Zstandard decompressor (copy of src/zstd.luau); optional, see below
BreachValidator.luau  attribute validator (M2): "engine" and bug-compatible "exporter" modes   (BUILT)
BreachMission.luau    mission model + indexes + stable ids (M3)                                  (BUILT)
BreachStandalone.luau tree <-> list of files, the Standalone on-disk format (M3)                (BUILT)
BreachWorld.luau      cells, links, navigation graph, A*, spatial queries (M4)                   (BUILT)
BreachExpr.luau       expression language: tokenizer, parser, short-circuit evaluator (M5)       (BUILT)
BreachRandom.luau     seeded, host-independent random (M5)                                       (BUILT)
BreachLogic.luau      variable store + replication, reactive bindings, scheduler, 6 components (M5/M6) (BUILT; embeds Expr, Random, CFrame, Script)
BreachScript.luau     StateScript VM: compile, threads, waits, budget, world commands as events (M6)   (BUILT; standalone)
BreachCFrame.luau     portable CFrame math (M6)                                                         (BUILT)
BreachProps.luau      players, zones, rooms, FreeTrigger, ItemSpawn/Deposit, doors, card readers, end zones (M7) (BUILT; standalone, embeds CFrame)
BreachSetup.luau      MissionSetup (SetupSource) data-only parser: constants, tables, strings, Color3 (M8.0)       (BUILT; standalone)
BreachNav.luau        kinematic bot movement: trail-following followers that cannot hit you, goto, doors (M8a)   (BUILT; standalone)
BreachBots.luau       bot model: routes, PatrolWalk/WorkWithBreaks, Inv, despawn, BotStateTracker (M8b)         (BUILT; embeds Random)
BreachSight.luau      what bots see and how fast they notice: cones, line of sight, meters (M8c)                 (BUILT; standalone)
BreachTrespass.luau   Cells rule sets (incl. {expression} rules), disguises, enforcing classes, witnesses (M8c)   (BUILT; standalone)
BreachAlert.luau       alert level 0..3, AlertRaiseCondition, guard reactions (flee+radio, question, anomalies) (M8c)   (BUILT; standalone)
BreachHostage.luau     hostages (aim, follow, flee timer, loud freeze), bodies, BotAltTrigger / BodyAltTrigger (M8d)   (BUILT; standalone)
BreachBehavior.luau    CustomBehavior scripts + conditions, AlarmedBehaviorOverride, RandomBotSpawner (M8e)   (BUILT; standalone)
BreachCombatData.luau  combat data model: spawners, pools, spawn parts, class table, concealed weapons (M9.0)   (BUILT; standalone)
BreachSession.luau     wires all layers: step order, combined event log, signature (M8f)   (BUILT; standalone)
src/body.luau         hand-written source of BreachCodec.luau
src/tables.inc        generated data tables (type ids, property tables, enums)
src/zstd.luau         hand-written source of BreachZstd.luau
src/validator.luau    hand-written source of BreachValidator.luau;  src/attrmap.inc = generated attribute map
src/mission.luau, src/standalone.luau, src/world.luau   sources of the M3/M4 libraries;  src/json.inc = shared JSON (decoder + deterministic encoder), spliced in by build.py
tools/gen_tables.py   plugin source  -> src/tables.inc
tools/build.py        body + tables  -> BreachCodec.luau
tools/gen_vectors.py  independent reference ENCODER -> tests/vectors.luau
tools/gen_zstd_vectors.py  real python-zstandard frames -> tests/zstd_vectors.luau
tools/gen_known.py    AttributesMap.lua -> tests/known_components.luau
tools/gen_attrmap.py  plugin source -> src/attrmap.inc (validator data)
tools/extract.py      SerializationTools.rbxmx -> flat .lua files the generators read
tools/gen_appendix_b.py    plugin source -> Appendix B (docs)
tools/embed.sh        wrap files as a Luau module for hosts without file I/O
tools/addmap.sh       one command: download/copy a mission code, re-embed all maps, print the report
tests/run.luau        1275 checks incl. fuzzing + REAL Operators maps      run:  luau tests/run.luau
tests/localfile.luau  decode real codes from disk and print a report       run:  luau tests/localfile.luau
tests/data/           TheDiplomat.base64 (real map, your upload)
```

## Try it on your own maps (the quick path)

```sh
cd breach-codec
luau tests/run.luau                    # everything should pass
luau tests/localfile.luau              # decodes TheDiplomat.base64 and prints a report
```
**Easiest way to try a new map** (gist URL or file): `sh tools/addmap.sh <url-or-file>` — it saves the code in
`tests/data/`, re-embeds every map and runs the report. By hand:

To add `TheInterception.base64` (or any code): put it in `tests/data/`, then
- if your Luau host has `io` or runs under Lune, `luau tests/localfile.luau` finds it by name (edit `FILES` at the top for other names);
- if not (the plain `luau` CLI has no file I/O): `sh tools/embed.sh tests/data/*.base64 > tests/_embedded.luau` and run `localfile.luau` again.
`localfile.luau` also copes with files that are one piece per line, or a bare Base64 payload with no header.

## Use

```lua
local Codec = require("./BreachCodec")     -- or load the file however your host loads Luau

local mission, err = Codec.decode(codeString, {
    zstdDecompress = function(bytes) ... end,   -- needed for version-2 codes only
})
if not mission then error(err) end
-- mission.Root, mission.Setup, mission.Settings, mission.Warnings, ...
```

`decode` takes one string (a single paste, or a gist's raw text including its `!!!` comment) or an array of
strings (several pastes, any order). It **never throws**: you get `nil, "BreachCodec: …"`. URLs are refused —
fetch in the host (`Codec.normalizeGistUrl` gives the raw URL) and pass the text.

Full API and output shapes: header comment of `BreachCodec.luau`.

## Validator (M2)

```lua
local V = require("./BreachValidator")
local report = V.validateMission(mission)                          -- engine mode, fills defaults, in place
local attrs, issues = V.validateAttributes("BoolValue", "n", { Type = "AccessPoint", NetworkId = 5 })
V.validateMission(mission, { mode = "exporter", includeDefaults = false, inPlace = false })  -- predict the real exporter
```
`engine` (default): `false` honoured, wrong types reported and replaced by the default, unknown attributes reported but kept.
`exporter`: bug-compatible with the official plugin. On the real map it reproduces the exporter's own output exactly
(526 component nodes, 0 changes, 0 issues). Also: `componentKey`, `entry`, `defaultsFor`, `kindOf`. Rules: main doc §3.4.

## Mission model and Standalone format (M3)

```lua
local Mission    = require("./BreachMission")
local Standalone = require("./BreachStandalone")

local mission = Mission.build(decoded, { validator = require("./BreachValidator") })
mission:byComponent("DelayedStateUpdate")      -- typed BoolValues
mission:folder("Cells"); mission:findPath("Props/Door1"); mission:node("n42")

local files = Standalone.encode(decoded.Root)  -- { {path=..., text=...}, ... }  you write them to disk
local root  = Standalone.decode(files)         -- you read the files from disk; any order is fine
```
Standalone stores child order explicitly and references by stable id (main doc §5.5.1); a round trip of both
real maps is bit-exact. Neither library does file I/O or creates engine objects.

## World layer (M4)

```lua
local World = require("./BreachWorld")
local world = World.build(mission)             -- mission = Mission.build(...)
local cell  = world:cellAt(x, y, z)            -- or a {X=,Y=,Z=} table; first containing cell (or nil)
world:cellsAt(p); world:neighbors(cell); world:hops(a, b, { path = true }); world:route(a, b)
local r = world:findPath({X=..,Y=..,Z=..}, {X=..,Y=..,Z=..})   -- A*: { points = {...}, length = n } or nil
print(world.Diagnostics.cells, world.Diagnostics.navNodes, world.Diagnostics.linksBridgingCells)
```
Cells and the navigation data are read exactly as the real maps store them; **which cells a link joins is a
tunable heuristic** (`World.build(mission, { minHitFraction = 0.5 })`) because the data does not say. See main doc §6.

## Logic core (M5)

```lua
local Logic = require("./BreachLogic")
local logic = Logic.new(mission, { seed = 416, builtins = { Mission_Difficulty = 1 } })
logic:advance(1/60)                       -- the host's Heartbeat; timers tick, timeouts fire, variables settle
logic:get("Name"); logic:set("Name", 1)
for _, ev in ipairs(logic:drainEvents()) do end   -- Notification / MissionComplete / MissionFailed
logic.Outcome; logic.Errors; logic.Warnings; logic.Undeclared; logic.Unsupported
local replica = logic:addClient(userId); logic:replicate()   -- or logic:flush() for raw packets

local Expr = require("./BreachExpr")      -- usable alone
Expr.eval("(Mission_Difficulty == 1 && 6) || 10", { get = function(n) return vars[n] end })
```
StateScript: `Script.compile(src)` lints, `Script.new(program, host)` + `inst:spawn()` runs (see the host interface in main doc §7.7); in the logic core it is just another component, and world commands arrive as `ScriptCommand` events. Run only these tests: `luau tests/logic.luau` (M5), `luau tests/script.luau` (M6), `luau tests/state.luau` (Delayed/Conditional/VariableShuffle), `luau tests/project.luau` (the third real map, *The Project*, plus engine builtin defaults), `luau tests/props.luau` (M7 props), `luau tests/setup.luau` (M8.0 MissionSetup parser), `luau tests/nav.luau` (M8a nav + followers), `luau tests/bots.luau` (M8b bots + patrol), `luau tests/sight.luau` (M8c sight), `luau tests/trespass.luau` (M8c trespass). Design, choices that are guesses, and real-map evidence: main doc §7.2, §7.2.1, §7.6, §13.7.

## Host functions (the only things the library does not do itself)

| Host function | Needed for | Notes |
|---|---|---|
| `zstdDecompress(bytes) -> string` | version-2 codes (all current exports) | Not inside `BreachCodec.luau`. Pass `require("./BreachZstd").decompress` (pure Luau, ~0.1 s for a 480 KB stream) **or** your host's native Zstd. Receives raw bytes (Base64 already removed). |
| `base64Decode`, `jsonDecode` | never | optional overrides; pure-Luau versions are built in |

**Roblox** (by the plugin's own usage of `EncodingService`; not run here):
```lua
local ES = game:GetService("EncodingService")
host.zstdDecompress = function(bytes)
    return buffer.tostring(ES:DecompressBuffer(buffer.fromstring(bytes), Enum.CompressionAlgorithm.Zstd))
end
```
**C++ embedder:** bind libzstd as a C function, e.g. `ZSTD_decompress` with the frame's content size
(`ZSTD_getFrameContentSize`) or streaming, and register it as `host.zstdDecompress`. Cap the output size.
**No native zstd available:** use `BreachZstd.luau`. It is verified against the real zstd library on 55 frames
(levels −5…22, text/binary/structured/JSON/RLE/random data, multi-frame, skippable, no-content-size streaming
frames, checksummed frames) and on the real Operators map. It needs the Luau `buffer` and `bit32` libraries,
rejects dictionaries, and skips (does not verify) the optional XXH64 checksum.

## What is and isn't done

Done: all 26 classes, all 9 attribute types, escapes, colour/string maps, instance tree, `Nil` dropping,
instance references (`Codec.resolveRef`), piece reassembly with consistency checks, gist wrapper, mission
extras (`Setup` from `TableMissionSetup`, `SetupSource`, `Settings`), bounds checking on every read.

Not done: encoding; Zstd dictionaries / checksum verification; filling *engine defaults* (only `Name`, and `Value` for
Bool/StringValue, are filled — everything else stays absent when it wasn't written; defaults are in Appendix B);
turning Euler angles into a rotation matrix (host's math library does that).

## Tests

`luau tests/run.luau` — 219 checks:
* synthetic missions from an independent reference encoder written from the spec (`tools/gen_vectors.py`);
* **a real Operators map** ("The Diplomat", exported by the live plugin): 6,148 instances, 0 warnings, stream consumed exactly;
* 55 Zstd frames made by the real zstd library;
* the world layer: a synthetic 5-cell world (containment, rotation, links, hops, A*, one-way edges, missing folders) and invariants on the real maps;
* the model + Standalone format: unit tests (awkward names, determinism, shuffled files, error cases) and bit-exact round trips of the real maps;
* the validator: 31 unit tests of the rules and quirks + exporter-mode idempotence over the real map;
* ~3,500 mutated/truncated/garbage codes and 400 corrupt Zstd frames (must reject cleanly, never throw).
Speed: The Diplomat (162 KB code → 477 KB stream → 6,148 instances) takes 0.14 s decode + 0.11 s Zstd on desktop Luau.

## Limits to know

* ≤ 5,183 unique strings and ≤ 5,183 unique colours per mission (2-symbol indices). An *encoder* must refuse more.
* Recursion depth capped at 512 (`host.maxDepth`); decompressed size capped at 512 MiB (`host.maxRawSize`).
* Map index 0 means "nil" and is accepted for String/Color3 values (real exports use it).
* Output tables contain `Parent` back-links (cycles): don't serialise them naively.

## Regenerating after a plugin update

```
python3 tools/gen_tables.py <plugin-src> > src/tables.inc
python3 tools/build.py
python3 tools/gen_vectors.py <plugin-src> > tests/vectors.luau
luau tests/run.luau
```
`<plugin-src>` is the directory of extracted ModuleScripts named `SerializationTools__<Path>.lua`
Produce it with: `python3 tools/extract.py SerializationTools.rbxmx <plugin-src>` (the plugin file may be a .txt copy).
