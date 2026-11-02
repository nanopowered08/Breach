--!nonstrict
-- Offline tests for BreachLoader: no Roblox, no network. Run:  luau loader/tests/loader_test.luau
-- (loadstring and bit32 are built into the Luau CLI.)
local Loader = require("../BreachLoader")

local passed, failed = 0, 0
local function check(cond, msg)
	if cond then passed += 1 else failed += 1; print("FAIL: " .. msg) end
end
local function errHas(fn, needle, msg)
	local ok, err = pcall(fn)
	check(not ok and string.find(tostring(err), needle, 1, true) ~= nil, msg .. " (got: " .. tostring(err) .. ")")
end

-- SHA-256 against python's hashlib ---------------------------------------------------------------------------------------
local VEC = {
	[0] = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
	[1] = "ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb",
	[55] = "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318",
	[56] = "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a",
	[63] = "7d3e74a05d7db15bce4ad9ec0658ea98e3f06eeecf16b4c6fff2da457ddc2f34",
	[64] = "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb",
	[65] = "635361c48bb9eab14198e76ea8ab7f1a41685d6ad62aa9146d301d4f17eb0ae0",
	[119] = "31eba51c313a5c08226adf18d4a359cfdfd8d2e816b13f4af952f7ea6584dcfb",
	[120] = "2f3d335432c70b580af0e8e1b3674a7c020d683aa5f73aaaedfdc55af904c21c",
	[1000] = "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3",
}
for n, want in pairs(VEC) do
	check(Loader.sha256(string.rep("a", n)) == want, "sha256 of " .. n .. " x 'a'")
end
check(Loader.sha256("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "sha256 abc")
check(Loader.sha256(string.rep("a", 1000000)) == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0", "sha256 million a")

-- path resolution -----------------------------------------------------------------------------------------------------
local R = Loader.resolve
check(R("lib/a.luau", "../util/b") == "util/b", "'..' goes up one folder")
check(R("lib/a.luau", "./c") == "lib/c", "'./' stays")
check(R("lib/a.luau", "c") == "lib/c", "bare name is relative")
check(R("a/b/c/d.luau", "../../x/../y") == "a/y", "several '..'")
check(R("", "lib/a") == "lib/a", "from the root")
check(R("lib/a.luau", "/top/x") == "top/x", "leading slash = from root")
errHas(function() R("lib/a.luau", "../../x") end, "above the repo root", "cannot leave the repo")
errHas(function() R("a.luau", "..") end, "above the repo root", "cannot leave from the root")
errHas(function() R("a.luau", "https://evil.example/x") end, "only paths inside the repo", "absolute URL refused")

-- a fake repo ---------------------------------------------------------------------------------------------------------------
local repo, requests = {}, {}
local function setFiles(t) for k, v in pairs(t) do repo[k] = v end end
local served = {} -- what the fake server answers, may differ from repo to test hash mismatches
local function manifestFor(files)
	local lines = { "# breach-manifest v1" }
	local names = {}
	for p in pairs(files) do names[#names + 1] = p end
	table.sort(names)
	for _, p in ipairs(names) do lines[#lines + 1] = Loader.sha256(files[p]) .. "  " .. p end
	return table.concat(lines, "\n") .. "\n"
end
local base = "https://raw.githubusercontent.com/nanopowered08/Breach/main/"
local offline, noManifest = false, false
local function fakeGet(url, nocache)
	requests[#requests + 1] = url
	if offline then error("HttpService is offline", 0) end
	local path = string.gsub(string.sub(url, #base + 1), "%?t=%d+$", "")
	if path == "manifest.txt" then
		if noManifest then error("HTTP 404", 0) end
		return repo["manifest.txt"]
	end
	local body = served[path] or repo[path]
	if not body then error("HTTP 404 " .. path, 0) end
	return body
end
local function countOf(path)
	local n = 0
	for _, u in ipairs(requests) do
		if string.find(u, base .. path, 1, true) == 1 then n += 1 end
	end
	return n
end

local files = {
	["lib/a.luau"] = 'local b = require("../util/b"); local c = require("./c"); return { name = "a", b = b, c = c }',
	["util/b.luau"] = 'return { name = "b", v = 1 }',
	["lib/c.luau"] = 'return { name = "c" }',
	["solo.luau"] = 'return { name = "solo" }',
	["lib/escape.luau"] = 'return require("../../x")',
	["lib/cycle1.luau"] = 'return require("./cycle2")',
	["lib/cycle2.luau"] = 'return require("./cycle1")',
	["lib/abs.luau"] = 'return require("https://evil.example/x")',
	["pkg/init.luau"] = 'return { name = "pkg" }',
	["legacy/old.lua"] = 'return { name = "old" }',
	["lib/lineno.luau"] = '\n\nerror("boom")',
}
setFiles(files)
repo["manifest.txt"] = manifestFor(files)

local function start()
	requests = {}
	return Loader.start({ get = fakeGet, AutoProbe = false })
end

-- loading ---------------------------------------------------------------------------------------------------------------------
do
	local B = start()
	local a = B.require("lib/a")
	check(a.name == "a" and a.b.name == "b" and a.c.name == "c", "a loads b via '..' and c via './'")
	check(B.require("lib/a") == a, "module cache returns the same table")
	check(B.require("pkg").name == "pkg", "init.luau candidate")
	check(B.require("legacy/old").name == "old", ".lua candidate")
	check(B.require("solo.luau").name == "solo", "exact path with extension")
	errHas(function() B.require("lib/escape") end, "above the repo root", "escape from a module is refused")
	errHas(function() B.require("lib/cycle1") end, "cycle", "cycle detected")
	errHas(function() B.require("lib/abs") end, "only paths inside the repo", "absolute URL from a module is refused")
	errHas(function() B.require("nope/missing") end, "not in the manifest", "unknown file")
	errHas(function() B.require("lib/lineno") end, "lib/lineno.luau:3: boom", "error lines match the repo file")
	check(countOf("lib/a.luau") == 1, "a.luau fetched once")
end

-- hash verification ---------------------------------------------------------------------------------------------------------
do
	served["solo.luau"] = 'return { name = "TAMPERED" }'
	local B = start()
	errHas(function() B.require("solo") end, "hash mismatch", "tampered file refused")
	served["solo.luau"] = nil
end

-- no manifest: probing mode -------------------------------------------------------------------------------------------------
do
	noManifest = true
	local B = start()
	local a = B.require("lib/a")
	check(a.b.name == "b" and a.c.name == "c", "probing mode resolves '..' too")
	check(countOf("lib/a.luau") == 1 and countOf("lib/a.luau.luau") == 0, "probing stops at the first hit")
	check(B.require("pkg").name == "pkg", "probing finds init.luau")
	check(B.probe() == "offline", "probe without a manifest reports offline")
	noManifest = false
end

-- hot swap ------------------------------------------------------------------------------------------------------------------------
do
	local B = start()
	local old = B.require("lib/a")
	local oldC, oldSolo = B.require("lib/c"), B.require("solo")
	local events = {}
	B.onUpdated(function(info) events[#events + 1] = info end)

	check(B.probe() == "unchanged", "same manifest = unchanged")

	-- 1. change a leaf: its dependent reloads, unrelated modules are kept
	files["util/b.luau"] = 'return { name = "b", v = 2 }'
	setFiles(files)
	repo["manifest.txt"] = manifestFor(files)
	requests = {}
	local status, detail = B.probe()
	check(status == "swapped", "changed leaf swaps (" .. tostring(status) .. " " .. tostring(detail) .. ")")
	check(countOf("util/b.luau") == 1 and countOf("lib/a.luau") == 0 and countOf("lib/c.luau") == 0, "only the changed file is refetched")
	local new = B.require("lib/a")
	check(new ~= old and new.b.v == 2, "new a sees new b")
	check(old.b.v == 1, "old a keeps old b")
	check(B.require("lib/c") == oldC and B.require("solo") == oldSolo, "unrelated modules are the same tables")
	check(#events == 1 and events[1].Changed[1] == "util/b.luau", "onUpdated fired once with the changed path")
	local reloaded = table.concat(events[1].Reloaded, ",")
	check(reloaded == "lib/a.luau,util/b.luau", "reloaded the changed file and its dependent only (" .. reloaded .. ")")

	-- 2. a broken update: nothing changes, and it is not retried
	files["util/b.luau"] = 'return { name = "b", v = '
	setFiles(files)
	repo["manifest.txt"] = manifestFor(files)
	requests = {}
	local s2 = B.probe()
	check(s2 == "failed", "syntax error = failed")
	check(B.require("lib/a") == new and B.require("util/b").v == 2, "failed swap keeps the loaded version")
	check(#events == 1, "no event for a failed swap")
	requests = {}
	check(B.probe() == "unchanged" and countOf("util/b.luau") == 0, "the same failed manifest is not retried")

	-- 3. a server that serves different bytes than the manifest promises
	files["util/b.luau"] = 'return { name = "b", v = 3 }'
	setFiles(files)
	repo["manifest.txt"] = manifestFor(files)
	served["util/b.luau"] = 'return { name = "b", v = 666 }'
	check(B.probe() == "failed", "hash mismatch on swap = failed")
	check(B.require("util/b").v == 2, "still on the loaded version")
	served["util/b.luau"] = nil

	-- 4. the next good manifest swaps again (a new manifest text clears the failure memory)
	files["util/b.luau"] = 'return { name = "b", v = 4 }'
	setFiles(files)
	repo["manifest.txt"] = manifestFor(files)
	check(B.probe() == "swapped" and B.require("lib/a").b.v == 4, "recovers on the next good manifest")

	-- 5. removing a loaded file fails (a loaded module needs it), adding an unloaded one is fine
	files["extra.luau"] = 'return 1'
	setFiles(files)
	repo["manifest.txt"] = manifestFor(files)
	check(B.probe() == "swapped", "a new unloaded file swaps")
	local without = {}
	for p, v in pairs(files) do if p ~= "util/b.luau" then without[p] = v end end
	repo["manifest.txt"] = manifestFor(without)
	check(B.probe() == "failed" and B.require("util/b").v == 4, "removing a needed file fails and keeps the old")

	-- 6. offline
	offline = true
	check(B.probe() == "offline", "offline probe is reported, nothing breaks")
	offline = false
end

print(string.format("loader tests: %d passed, %d failed", passed, failed))
if failed > 0 then error("tests failed") end
