--!nonstrict
-- BreachLoader: the one file a Roblox server fetches by hand. Everything else comes through the `require` it supplies.
--
--   local src = game:GetService("HttpService"):GetAsync("https://raw.githubusercontent.com/nanopowered08/Breach/main/loader/BreachLoader.luau")
--   local Breach = loadstring(src)().start({ Repo = "nanopowered08/Breach", Ref = "main" })
--   local Session = Breach.require("breach-codec/BreachSession")
--   Breach.onUpdated(function(info) ... end)      -- new sessions should call Breach.require again
--
-- How it works
--   * Every module runs with its own `require`. A relative path ("../x", "./x", "x") is resolved against the folder of the file
--     that asked, so ".." really goes up one folder, and it can never leave the repo root. Absolute URLs are refused.
--   * `manifest.txt` (made by tools/make_manifest.py) lists every loadable file with its SHA-256. With a manifest, a fetched file
--     must match its hash and "probing" (x, x.luau, x.lua, x/init.luau) is checked against the list instead of the network.
--     Without a manifest the loader probes with real requests and cannot verify or hot-swap.
--   * Every ProbeSeconds (300) the manifest is fetched again. If it changed, the files whose hash changed are fetched and
--     verified, and every loaded module that depends on them is re-run, all into a fresh cache. Only if all of that succeeds is the
--     new cache swapped in (atomic: modules never mix versions). On any error nothing changes and the failed manifest is not retried.
--   * Sessions that already hold old module tables keep them. New Breach.require calls get the new ones.
--
-- Roblox needs: HTTP requests enabled for the game, and ServerScriptService.LoadStringEnabled = true. Server only.

local Loader = {}

local warnFn = warn or print

-- ---------------------------------------------------------------------------------------------------------------- SHA-256
local K = {
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local band, bxor, bnot, rrotate, rshift = bit32.band, bit32.bxor, bit32.bnot, bit32.rrotate, bit32.rshift

-- Hex SHA-256 of a string. `yieldFn` (optional) is called every 128 blocks so a big file does not hog the thread.
function Loader.sha256(msg, yieldFn)
	local len = #msg
	local bits = len * 8
	local hi = math.floor(bits / 4294967296)
	local lo = bits % 4294967296
	msg = msg .. "\128" .. string.rep("\0", (55 - len) % 64)
		.. string.char(rshift(hi, 24), band(rshift(hi, 16), 255), band(rshift(hi, 8), 255), band(hi, 255),
			rshift(lo, 24), band(rshift(lo, 16), 255), band(rshift(lo, 8), 255), band(lo, 255))
	local h0, h1, h2, h3, h4, h5, h6, h7 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
	local w = table.create(64, 0)
	local blocks = 0
	for i = 1, #msg, 64 do
		local b = { string.byte(msg, i, i + 63) }
		for j = 0, 15 do
			w[j + 1] = b[4 * j + 1] * 16777216 + b[4 * j + 2] * 65536 + b[4 * j + 3] * 256 + b[4 * j + 4]
		end
		for j = 17, 64 do
			local x, y = w[j - 15], w[j - 2]
			local s0 = bxor(rrotate(x, 7), rrotate(x, 18), rshift(x, 3))
			local s1 = bxor(rrotate(y, 17), rrotate(y, 19), rshift(y, 10))
			w[j] = band(w[j - 16] + s0 + w[j - 7] + s1, 0xffffffff)
		end
		local a, bb, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
		for j = 1, 64 do
			local S1 = bxor(rrotate(e, 6), rrotate(e, 11), rrotate(e, 25))
			local ch = bxor(band(e, f), band(bnot(e), g))
			local t1 = band(h + S1 + ch + K[j] + w[j], 0xffffffff)
			local S0 = bxor(rrotate(a, 2), rrotate(a, 13), rrotate(a, 22))
			local maj = bxor(band(a, bb), band(a, c), band(bb, c))
			local t2 = band(S0 + maj, 0xffffffff)
			h, g, f, e, d, c, bb, a = g, f, e, band(d + t1, 0xffffffff), c, bb, a, band(t1 + t2, 0xffffffff)
		end
		h0, h1, h2, h3 = band(h0 + a, 0xffffffff), band(h1 + bb, 0xffffffff), band(h2 + c, 0xffffffff), band(h3 + d, 0xffffffff)
		h4, h5, h6, h7 = band(h4 + e, 0xffffffff), band(h5 + f, 0xffffffff), band(h6 + g, 0xffffffff), band(h7 + h, 0xffffffff)
		blocks += 1
		if yieldFn and blocks % 128 == 0 then yieldFn() end
	end
	return string.format("%08x%08x%08x%08x%08x%08x%08x%08x", h0, h1, h2, h3, h4, h5, h6, h7)
end

-- ----------------------------------------------------------------------------------------------------------------- paths
-- Resolve `rel` as asked for by the file at repo path `fromPath` ("" = the repo root). Returns a repo path without "..".
local function resolve(fromPath, rel)
	if type(rel) ~= "string" or rel == "" then error("require: expected a path string", 0) end
	if string.find(rel, "^%a[%w+.-]*:") or string.find(rel, "\\", 1, true) then
		error("require: only paths inside the repo are allowed: " .. rel, 0)
	end
	local segs = {}
	if string.sub(rel, 1, 1) ~= "/" then
		for seg in string.gmatch(fromPath, "[^/]+") do segs[#segs + 1] = seg end
		segs[#segs] = nil -- the folder of the requiring file
	end
	for seg in string.gmatch(rel, "[^/]+") do
		if seg == "." then
			-- same folder
		elseif seg == ".." then
			if #segs == 0 then error("require: '" .. rel .. "' from '" .. fromPath .. "' goes above the repo root", 0) end
			segs[#segs] = nil
		else
			segs[#segs + 1] = seg
		end
	end
	return table.concat(segs, "/")
end
Loader.resolve = resolve

local function candidates(path)
	return { path, path .. ".luau", path .. ".lua", path .. "/init.luau" }
end

local function parseManifest(text)
	local files, n = {}, 0
	for line in string.gmatch(text, "[^\r\n]+") do
		if string.sub(line, 1, 1) ~= "#" then
			local hash, path = string.match(line, "^(%x+)%s+(.+)$")
			if not hash or #hash ~= 64 then return nil, "bad manifest line: " .. string.sub(line, 1, 80) end
			files[path] = string.lower(hash)
			n += 1
		end
	end
	if n == 0 then return nil, "empty manifest" end
	return files
end

-- ---------------------------------------------------------------------------------------------------------------- loader
local DEFAULTS = {
	Repo = "nanopowered08/Breach",
	Ref = "main", -- "main" or "refs/heads/main" both work on raw.githubusercontent.com
	ManifestPath = "manifest.txt",
	ProbeSeconds = 300,
	Verify = true,
	BustCache = true, -- add ?t=<time> to the manifest request so GitHub's raw cache does not serve an old one
	AutoProbe = true,
}

local function newGen(files)
	return { Files = files, Cache = {}, Sources = {}, Dependents = {}, Loading = {} }
end

function Loader.start(options)
	local opts = {}
	for k, v in pairs(DEFAULTS) do opts[k] = v end
	for k, v in pairs(options or {}) do opts[k] = v end

	local realRequire = require
	local loadstringFn = opts.loadstring or loadstring
	local getFn = opts.get or function(url, nocache)
		return game:GetService("HttpService"):GetAsync(url, nocache)
	end
	local nowFn = opts.now or os.time
	local base = "https://raw.githubusercontent.com/" .. opts.Repo .. "/" .. opts.Ref .. "/"
	local function urlOf(path)
		return base .. string.gsub(path, "[^%w%-%._~/]", function(c) return string.format("%%%02X", string.byte(c)) end)
	end

	local Breach = { Repo = opts.Repo, Ref = opts.Ref }
	local gen = newGen(nil)
	local manifestText, failedText
	local listeners = {}
	local stopped, probing = false, false

	local function yieldFn()
		if opts.yield then opts.yield() elseif task then task.wait() end
	end

	local function manifestUrl()
		local url = urlOf(opts.ManifestPath)
		if opts.BustCache then url ..= "?t=" .. tostring(nowFn()) end
		return url
	end

	-- Hash check with one recovery step. raw.githubusercontent.com caches, and the manifest and the files can come from different moments
	-- (right after a merge: new file, old manifest, or the other way round). On a mismatch in the foreground (never a background swap, which
	-- must simply fail) the manifest is fetched again with a cache-buster:
	--   * the fresh manifest still lists the hash we wanted: the FILE was stale, so fetch it again with a cache-buster;
	--   * the fresh manifest lists another hash: the MANIFEST was stale. It is adopted only if every file already loaded has the same hash in
	--     it, so modules of two versions never mix.
	-- A file that still does not match is refused as before (tampering looks the same as staleness, so it gets exactly one more look).
	local function recover(g, path, got, want)
		local okM, text = pcall(getFn, manifestUrl(), true)
		if not okM or type(text) ~= "string" then return nil end
		local fresh = parseManifest(text)
		if not fresh then return nil end
		local wanted = fresh[path]
		if not wanted then return nil end
		if wanted ~= want then
			for p in pairs(g.Sources) do
				if fresh[p] ~= g.Files[p] then return nil end
			end
			for p in pairs(g.Cache) do
				if fresh[p] ~= g.Files[p] then return nil end
			end
		end
		local src
		if got == wanted then
			src = nil -- the file we already have is the right one; only the manifest was stale
		else
			local okF, again = pcall(getFn, urlOf(path) .. "?t=" .. tostring(nowFn()), true)
			if not okF or type(again) ~= "string" or Loader.sha256(again) ~= wanted then return nil end
			src = again
		end
		if wanted ~= want then
			g.Files = fresh
			manifestText = text
			warnFn("[Breach] the manifest was stale (GitHub cache); adopted the fresh one")
		end
		return true, src
	end

	local function fetchVerified(g, path, background)
		local src = getFn(urlOf(path), false)
		if type(src) ~= "string" then error("no data for " .. path, 0) end
		if g.Files and opts.Verify then
			local want = g.Files[path]
			local got = Loader.sha256(src, background and yieldFn or nil)
			if got ~= want and g == gen and not background then
				local ok, better = recover(g, path, got, want)
				if ok then return better or src end
			end
			if got ~= want then error("hash mismatch for " .. path .. " (manifest " .. tostring(want) .. ", got " .. got .. ")", 0) end
		end
		return src
	end

	local loadResolved

	-- Find which candidate path exists. With a manifest: pure lookup. Without: real requests (the first hit is returned with its source).
	local function pick(g, path, background)
		if g.Files then
			for _, c in ipairs(candidates(path)) do
				if g.Files[c] then return c end
			end
			error("require: '" .. path .. "' is not in the manifest", 0)
		end
		local lastErr
		for _, c in ipairs(candidates(path)) do
			if g.Sources[c] then return c end
			local ok, res = pcall(getFn, urlOf(c), false)
			if ok and type(res) == "string" then
				g.Sources[c] = res
				return c
			end
			lastErr = res
		end
		error("require: could not find '" .. path .. "' (" .. tostring(lastErr) .. ")", 0)
	end

	loadResolved = function(g, want, requester, background)
		local path = pick(g, want, background)
		if requester then
			local set = g.Dependents[path]
			if not set then set = {}; g.Dependents[path] = set end
			set[requester] = true
		end
		local hit = g.Cache[path]
		if hit then return hit.v end
		if g.Loading[path] then error("require cycle through '" .. path .. "'", 0) end
		g.Loading[path] = true
		local ok, res = pcall(function()
			local src = g.Sources[path]
			if not src then
				src = fetchVerified(g, path, background)
				g.Sources[path] = src
			end
			-- prelude on the same line, so error line numbers stay those of the repo file
			local chunk, err = loadstringFn("local require=...; " .. src, "=" .. path)
			if not chunk then error(err, 0) end
			return chunk(function(rel)
				if type(rel) ~= "string" then return realRequire(rel) end -- a Roblox ModuleScript instance
				return loadResolved(g, resolve(path, rel), path, background)
			end)
		end)
		g.Loading[path] = nil
		if not ok then error(res, 0) end
		g.Cache[path] = { v = res }
		return res
	end

	-- Public: load a module by repo path, from the current generation.
	function Breach.require(path)
		return loadResolved(gen, resolve("", path), nil, false)
	end

	function Breach.version()
		return manifestText and string.sub(Loader.sha256(manifestText), 1, 12) or "unversioned"
	end

	function Breach.onUpdated(fn)
		listeners[#listeners + 1] = fn
		return function()
			local i = table.find(listeners, fn)
			if i then table.remove(listeners, i) end
		end
	end

	-- One probe. Returns "unchanged" | "swapped" | "failed" | "offline", plus detail.
	function Breach.probe()
		if probing then return "unchanged", "busy" end
		probing = true
		local status, detail = "unchanged", nil
		local ok, err = pcall(function()
			local fetched, text = pcall(getFn, manifestUrl(), true)
			if not fetched or type(text) ~= "string" then status, detail = "offline", text; return end
			if text == manifestText or text == failedText then return end
			local files, perr = parseManifest(text)
			if not files then failedText = text; status, detail = "failed", perr; warnFn("[Breach] " .. perr); return end
			if not gen.Files then
				-- first manifest we ever got: adopt it for future loads, nothing to diff against
				gen.Files = files
				manifestText = text
				return
			end
			local old = gen
			-- what changed, and everything loaded that depends on it
			local dirty, queue = {}, {}
			local function mark(p) if not dirty[p] then dirty[p] = true; queue[#queue + 1] = p end end
			local changed = {}
			for p, h in pairs(files) do if old.Files[p] ~= h then changed[p] = true end end
			for p in pairs(old.Files) do if not files[p] then changed[p] = true end end
			for p in pairs(changed) do if old.Cache[p] then mark(p) end end
			local qi = 1
			while qi <= #queue do
				for dep in pairs(old.Dependents[queue[qi]] or {}) do mark(dep) end
				qi += 1
			end
			local new = newGen(files)
			for p, v in pairs(old.Cache) do
				if not dirty[p] then new.Cache[p] = v end
			end
			for p, src in pairs(old.Sources) do
				if not changed[p] then new.Sources[p] = src end -- unchanged text, already verified: no refetch
			end
			for p, set in pairs(old.Dependents) do
				local copy = {}
				for r in pairs(set) do copy[r] = true end
				new.Dependents[p] = copy
			end
			local reloaded = {}
			local okSwap, swapErr = pcall(function()
				for p in pairs(dirty) do
					if not new.Cache[p] then loadResolved(new, p, nil, true) end
					reloaded[#reloaded + 1] = p
				end
			end)
			if not okSwap then
				failedText = text
				status, detail = "failed", swapErr
				warnFn("[Breach] hot-swap failed, keeping the loaded version: " .. tostring(swapErr))
				return
			end
			gen = new
			manifestText = text
			failedText = nil
			status = "swapped"
			local list = {}
			for p in pairs(changed) do list[#list + 1] = p end
			table.sort(list); table.sort(reloaded)
			detail = { Changed = list, Reloaded = reloaded, Version = Breach.version() }
			for _, fn in ipairs(table.clone(listeners)) do
				local okCb, cbErr = pcall(fn, detail)
				if not okCb then warnFn("[Breach] onUpdated handler error: " .. tostring(cbErr)) end
			end
		end)
		probing = false
		if not ok then status, detail = "failed", err; warnFn("[Breach] probe error: " .. tostring(err)) end
		return status, detail
	end

	function Breach.stop() stopped = true end

	-- startup: the manifest. If it is missing we run in probing mode (no verification, no hot-swap).
	do
		local fetched, text = pcall(getFn, manifestUrl(), true)
		if fetched and type(text) == "string" then
			local files, perr = parseManifest(text)
			if files then
				gen.Files = files
				manifestText = text
			else
				warnFn("[Breach] " .. perr .. "; continuing without a manifest")
			end
		else
			warnFn("[Breach] no manifest (" .. tostring(text) .. "); continuing without verification or hot-swap")
		end
	end

	if opts.AutoProbe and task then
		task.spawn(function()
			while not stopped do
				task.wait(opts.ProbeSeconds)
				if stopped then break end
				Breach.probe()
			end
		end)
	end

	return Breach
end

return Loader
