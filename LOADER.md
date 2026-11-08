# Loading BreachEngine into Roblox

The game fetches **one** file by hand (`loader/BreachLoader.luau`). That loader supplies a `require` to every module, so the
rest of the engine is pulled straight from this repo.

```lua
local Breach = loadstring(game:GetService("HttpService"):GetAsync(
    "https://raw.githubusercontent.com/nanopowered08/Breach/main/loader/BreachLoader.luau", true))().start({
    Repo = "nanopowered08/Breach", Ref = "main" })
local Session = Breach.require("breach-codec/BreachSession")
```

A ready script is in `wrapper/ServerBootstrap.server.luau` (put it in ServerScriptService).

## Setup checklist
1. Game Settings > Security > **Allow HTTP Requests** on.
2. `ServerScriptService.LoadStringEnabled = true`. Server only.
3. Replace `nanopowered08/Breach` with the real repo name (one variable).

## How requires resolve
`require("../util/b")` inside `lib/a.luau` means `util/b` from the repo root: `..` goes up one folder and can never leave the
repo. Absolute URLs are refused. The loader tries `x`, `x.luau`, `x.lua`, `x/init.luau`.

## manifest.txt and hot-swap
`manifest.txt` lists every loadable file with its SHA-256. **Regenerate it before every push:**

    python3 tools/make_manifest.py            # or: --install-hook to do it on every commit, --check for CI

With a manifest, fetched files must match their hash. Every 5 minutes the server fetches the manifest again. If it changed, it
fetches the changed files, re-runs them and every loaded module that depends on them into a fresh cache, and swaps only if all of
that worked. Any error: the old version stays, and that manifest is not retried until it changes again.
Existing sessions keep the module tables they already hold; new `Breach.require` calls get the new ones. Without a manifest
the loader still works (it probes with real requests) but cannot verify or hot-swap. The bootstrap loader itself needs a server
restart to update.

`raw.githubusercontent.com` caches for a few minutes, so a push can take up to about 10 minutes to show up.

## Tests
    luau loader/tests/loader_test.luau        # offline, fake HTTP, 55 checks

## Licensing note
The mission data used by the engine's tests (InfiltrationEngine-Custom-Missions, incl. The Blacksite) is CC BY-NC-SA 4.0, not
MIT. `tests/data/` and `tests/_embedded*.luau` are in `.gitignore` for that reason; keep them in your local copy only.

## Stale GitHub cache right after a merge
`raw.githubusercontent.com` caches for a few minutes, so a play session started just after a merge can get the new `Init.luau` with the old `manifest.txt` (or the reverse) and fail with `hash mismatch`. For a file loaded in the foreground the loader now refetches the manifest once with a cache-buster: if the fresh manifest still wants the hash it expected, the file is refetched with a cache-buster; if the manifest itself was stale it is adopted, but only when every module already loaded has the same hash in it (no mixed versions). A file that still does not match is refused. Background hot-swaps are unchanged: they just fail and keep the loaded version.
