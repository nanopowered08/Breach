# AGENTS.md

Instructions for AI agents (and humans) working on this repo. Read this first, then `HANDOFF.md` (current state, what to do next)
and `docs/BreachEngine_Documentation.md` (the spec).

## What this is
BreachEngine is a clean-room, portable-Luau engine that runs InfiltrationEngine / *Entry Point: Freelancer's Cut* custom missions
headlessly, plus a Roblox wrapper that loads it from this repo at runtime. M1 to M8 are done (codec through bots, alert, hostages,
behaviours, session). **Next: M9 combat.** The owner plays the game; his gameplay observations are the requirements.

## Layout
```
breach-codec/      the engine: portable pure-Luau libraries, tests, build tools (see its README.md)
  src/*.luau       HAND-WRITTEN SOURCE. Edit these.
  Breach*.luau     BUILT single-file modules. Never edit by hand; they are generated from src/ by tools/build.py
  tests/           *_tests.luau (suites), <name>.luau (runner per suite), run.luau, playthrough_tests.luau
docs/              spec, appendices, M8 plan. Keep them updated with every behaviour change (bump the version line)
loader/            BreachLoader.luau: the one file a Roblox server fetches by hand, plus its offline tests
wrapper/           Roblox-side glue, never in breach-codec
  BreachRoblox/Core.luau        host-agnostic adapter core (pure Luau, tested offline): loads a mission, steps a session, reconciles bots and players
  BreachRoblox/RobloxHost.luau  the Instance-based host: map Parts, bot rigs, players, alert attribute (Roblox only, untestable offline)
  BreachRoblox/Init.luau        entry point: Adapter.start(Breach, options); loaded by the loader like everything else
  ServerBootstrap.server.luau   the Script that goes in ServerScriptService
  tests/                        offline tests for Core: luau wrapper/tests/core.luau
tools/make_manifest.py   regenerates manifest.txt (SHA-256 of every loadable file) for the loader
manifest.txt       GENERATED. Regenerate and commit it with every change to a loadable file
LOADER.md          how the Roblox loading and hot-swap work
```

## Hard rules
1. **breach-codec stays portable**: pure Luau, no Roblox APIs, no `game`, no `task`, no file or network I/O. Roblox specifics live in `wrapper/`.
   Each built module is standalone: no `require` of its siblings (the session gets the module table `M` passed in).
2. **Edit `src/`, then rebuild**: `cd breach-codec && python3 tools/build.py`. A change to a built `Breach*.luau` alone will be overwritten.
3. **Clean-room**: do not copy plugin or game source. Specs come from the docs, real-map data and the owner's observations.
4. **Never commit map data.** The missions in InfiltrationEngine-Custom-Missions (including The Blacksite) are CC BY-NC-SA 4.0; this repo is
   MIT. `breach-codec/tests/data/` and `tests/_embedded*.luau` are gitignored and stay local, and so are mission codes (the Roblox adapter reads one from a local server or a StringValue, never from the repo). Do not paste large chunks of map data into docs either.
5. **Line endings are LF** (`.gitattributes`). The loader hashes exact bytes; `make_manifest.py` refuses CRLF.
6. **Determinism**: same inputs must give the same event log and `signature` (the playthrough tests run everything twice). Use `BreachRandom`
   with explicit seeds, never `math.random` or the clock.

## Workflow
```
cd breach-codec
python3 tools/build.py                 # src/ -> Breach*.luau
luau-analyze BreachX.luau              # lint the module you changed
luau tests/<module>.luau               # fast per-module suite (alert, hostage, behavior, bots, sight, trespass, ...)
timeout 280 luau tests/run.luau        # the whole suite takes ~4 minutes: run it in the background (nohup ... &) or with a timeout
cd .. && python3 tools/make_manifest.py && luau loader/tests/loader_test.luau && luau wrapper/tests/core.luau
```
- Get Luau from https://github.com/luau-lang/luau/releases (`luau`, `luau-analyze` on PATH). The plain CLI has no file I/O, so real-map data is
  embedded with `sh tools/embed.sh tests/data/* > tests/_embedded.luau`.
- Luau block comments `--[[ ]]` break if the text contains `]]`; use `--[==[ ]==]`.
- New feature = new tests in the module's `*_tests.luau`, hooked into `tests/run.luau`, plus a docs section. The suite count in `HANDOFF.md` must stay true.
- Update `HANDOFF.md` when you finish something (what is done, gotchas, what is next). Keep it short and current.

## Working with the owner
- **Ask before inventing gameplay.** Observed behaviour from the owner or from real-map data is a requirement; everything else is a guess.
  Mark guesses `[P]` in code defaults and docs so they are easy to find and correct. `[R]` marks a rule backed by the owner or by map evidence.
- For a new milestone, write the plan first (as `docs/BreachEngine_M8_Bots_Plan.md` did), get it approved, then build.
- One question at a time; lead with what you found.
- BreachEngine is allowed to **diverge from InfiltrationEngine** where the owner wants more realism (see M9 decisions below).

## M9 (combat): decisions already made
- **Lockdown has two phases** (opt-in; the original one-phase lockdown stays the default so existing missions still run):
  *Searching*: nobody knows who did what (e.g. a broken camera) until a guard **sees someone with a weapon**; then *Attacking*.
- **Hostage pose**: in Searching and in a non-trespass area, a player lying on the ground like a hostage can mislead guards; guards may help
  them up and escort them to a safe place (a possible way to continue into later missions). Not available in Attacking.
- **Lockdown guard behaviour (from play)**: living guards go to the nearest Meadow Map node; guards near the player, or just spawned, pathfind to the
  player; existing guards do not know where the player is until they hear a noise the player caused, then they look at them. Some throw grenades; in
  The Blacksite some plant and detonate C4; some are custom-spawned (e.g. a boss at the elevator after the Halcyon data wipe).
- **Guard class decides** who throws grenades, who plants C4, and who gets a health bar (health > 200; `CustomCombatData.ForceHealthDisplay` overrides).
  The Blacksite pairs weapon and class in each `CombatSpawner` (`K45:SteelCoveGrenadier`, `Sawblade:SteelCoveShredder`, ...), but class health and
  roles are **not in the map data**; they are an engine-side class table that still needs the owner's numbers.
- `DetectConcealedWeapons` is a per-bot-template attribute (value names the reaction, e.g. `SetAlarmedWithAlert`); `ConcealedWeaponDisguise` in
  MissionSetup lists disguises that can carry a concealed weapon.
- Needs new engine state: lying-down stance, concealed versus drawn weapon, trespass zones read from Cells (already supported by `BreachTrespass`).

## Reading `.rbxm` / `.rbxl` files
The plain `luau` CLI cannot read them. Use the Rust `rbx_binary` and `rbx_dom_weak` crates (rbx-dom; needs a recent rustc, around 1.85 or newer) to
dump the instance tree and extract `Source` / `Value` properties of scripts and StringValues (that is where `MissionSetup` lives). Attributes are
stored as binary; decode them, do not scrape them as text. Mission files are in https://github.com/MoonstoneSkies/InfiltrationEngine-Custom-Missions
under `Templates/` (The Blacksite pre-release: `Templates/OfficialMissions/TheBlacksite_PreRelease.rbxm`).

## Roblox loader notes (for wrapper work)
- The game fetches only `loader/BreachLoader.luau`; its `require` resolves relative paths against the file that asked and cannot leave the repo.
- Hot-swap is atomic and ignores failures. Existing sessions keep old module tables; new `Breach.require` calls get new ones. Do not rely on
  module-level state surviving a swap.
- Needs `ServerScriptService.LoadStringEnabled = true` and HTTP requests enabled; server only. See `LOADER.md`.

