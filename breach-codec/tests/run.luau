--!nonstrict
-- BreachCodec tests. Run:  luau tests/run.luau   (from the repository root)
local Codec = require("../BreachCodec")
local V = require("./vectors")

local passed, failed = 0, 0
local function check(name, cond, detail)
	if cond then
		passed += 1
	else
		failed += 1
		print("FAIL: " .. name .. (detail and (" -- " .. tostring(detail)) or ""))
	end
end

-- deep compare with float tolerance; `Parent` back-links are ignored
local function same(a, b, path, tol)
	tol = tol or 1.5e-3
	if type(a) == "number" and type(b) == "number" then
		if math.abs(a - b) <= tol then return true end
		return false, path .. ": " .. a .. " ~= " .. b
	end
	if type(a) ~= type(b) then return false, path .. ": type " .. type(a) .. " vs " .. type(b) end
	if type(a) ~= "table" then
		if a == b then return true end
		return false, path .. ": " .. tostring(a) .. " ~= " .. tostring(b)
	end
	for k, v in pairs(b) do
		local ok, why = same(a[k], v, path .. "." .. tostring(k), tol)
		if not ok then return false, why end
	end
	for k in pairs(a) do
		if k ~= "Parent" and b[k] == nil then return false, path .. "." .. tostring(k) .. ": unexpected key" end
	end
	return true
end

local Zstd = require("../BreachZstd")
local host = { zstdDecompress = Zstd.decompress }

-- ---------------------------------------------------------------- full-mission decodes
local function verify(label, m, err, version)
	check(label .. ": decodes", m ~= nil, err)
	if not m then return end
	if version then check(label .. ": version", m.Version == version, m.Version) end
	local ok, why = same(m.Root, V.expected, "Root")
	check(label .. ": tree equals expected", ok, why)
	check(label .. ": no warnings", #m.Warnings == 0, table.concat(m.Warnings, "; "))
end

for _, c in ipairs(V.single) do
	local m, err = Codec.decode(c.code, host)
	verify(c.name, m, err, c.version)
end
verify("gist wrapper", Codec.decode(V.gist, host))
verify("3 pieces, shuffled", Codec.decode({ V.pieces[3], V.pieces[1], V.pieces[2] }, host))
verify("v2 2 pieces", Codec.decode(V.pieces_v2, host))

-- ---------------------------------------------------------------- mission-level extraction
local m = assert(Codec.decode(V.single[2].code, host))
check("MapId from header", m.MapId == 1234, m.MapId)
check("Setup.Colors converted", m.Setup and m.Setup.Colors and math.abs(m.Setup.Colors.Sky.B - 0) < 1e-9 and m.Setup.Colors.Sky.R == 1)
check("Setup number", m.Setup and m.Setup.SoundTravelDistance == 1.5)
check("Setup utf8 survives JSON \\u escapes", m.Setup and m.Setup.Objectives[1].Text == "caf\u{E9} \u{1F600}", m.Setup and m.Setup.Objectives[1].Text)
check("SetupSource keeps newline/tab/&", m.SetupSource == "local M = {}\n\treturn M -- a & b &&\r\n", m.SetupSource)
check("SetupModules", m.SetupModules.Helpers == "return 1")
check("Settings", m.Settings and m.Settings.MissionName == "Test Mission" and m.Settings.EnforceCellLinks == true and m.Settings.ExportVersion == "7")

-- instance references: Beam -> Attachments; Nil sibling must not shift indices
local rig
for _, c in ipairs(m.Root.Children) do if c.Name == "Rig" then rig = c end end
local beam = rig.Children[3]
check("Beam found", beam and beam.ClassName == "Beam")
local a0 = Codec.resolveRef(m.Root, beam.Props.Attachment0.Ref)
local a1 = Codec.resolveRef(m.Root, beam.Props.Attachment1.Ref)
check("ref 0 -> Attachment A0", a0 and a0.ClassName == "Attachment" and a0.Name == "A0", beam.Props.Attachment0.Ref)
check("ref 1 -> Attachment A1", a1 and a1.ClassName == "Attachment" and a1.Name == "A1")
check("unsupported-class sibling dropped", #m.Root.Children == 10 and m.Root.Children[4].Name == "Props", #m.Root.Children)
check("map index 0 decodes to an absent property", m.Root.Children[3].Name == "Cut" and m.Root.Children[3].Props.MeshId == nil)
check("Parent links", rig.Parent == m.Root)

-- ---------------------------------------------------------------- the worked example in the docs (section 4.11)
local d = assert(Codec.decodeStream(V.doc_body, 1))
check("doc example: root", d.Root.Name == "DebugMission" and d.Root.ClassName == "Folder")
local floor, trig = d.Root.Children[1], d.Root.Children[2]
check("doc example: Floor", floor.ClassName == "Part" and floor.Name == "Floor" and math.abs(floor.Props.Size.X - 10) < 1e-3 and math.abs(floor.Props.CFrame.Position.Y - 0.5) < 1e-3)
check("doc example: colour 0.5", math.abs(floor.Props.Color.R - 0.5) < 1e-3)
check("doc example: Trigger1 attrs", trig.ClassName == "BoolValue" and trig.Attrs.Type == "TriggerZone" and trig.Attrs.IsGlobal == true)

-- ---------------------------------------------------------------- host / header errors
local r, e = Codec.decode(V.single[3].code)
check("v2 without host.zstdDecompress errors clearly", r == nil and e:find("zstdDecompress"), e)
r, e = Codec.decode("https://gist.github.com/u/abc")
check("URL input refused with hint", r == nil and e:find("URL"), e)
r, e = Codec.decode({ V.pieces[1], V.pieces[2] })
check("missing piece detected", r == nil and e:find("missing piece 3"), e)
r, e = Codec.decode({ V.pieces[1], V.pieces_v2[1] })
check("mixed missions rejected", r == nil, e)
r, e = Codec.decode("fbbbcbc" .. "x") -- version symbol 'f' = 3
check("unsupported version rejected", r == nil and e:find("unsupported code version"), e)
r, e = Codec.decode("!!!no end of comment")
check("unterminated comment rejected", r == nil and e:find("comment"), e)

-- ---------------------------------------------------------------- helpers
check("gist URL -> raw", Codec.normalizeGistUrl("https://gist.github.com/alice/0123abcd") == "https://gist.githubusercontent.com/alice/0123abcd/raw")
check("raw gist URL kept", Codec.normalizeGistUrl("https://gist.githubusercontent.com/alice/0123/raw/rev/f.txt") == "https://gist.githubusercontent.com/alice/0123/raw/rev/f.txt")
check("non-gist URL refused", Codec.normalizeGistUrl("https://example.com/x") == nil)
check("base64 foobar", Codec.base64Decode("Zm9vYmFy") == "foobar")
check("base64 padding", Codec.base64Decode("Zm9vYg==") == "foob" and Codec.base64Decode("Zm9vYg") == "foob" and Codec.base64Decode("Zm8=") == "fo")
check("base64 whitespace", Codec.base64Decode("Zm9v\nYmFy ") == "foobar")
check("base64 binary", Codec.base64Decode("AP8=") == "\0\255")
check("base64 bad char", Codec.base64Decode("Zm9v!") == nil)
local big = string.rep("A", 100000)
check("base64 large", #Codec.base64Decode(big) == 75000)
local j = Codec.jsonDecode('{"a":[1,2,{"b":null,"c":"x\\n\\u00e9"}],"d":-1.5e2,"e":true}')
check("json", j and j.a[2] == 2 and j.a[3].c == "x\n\u{E9}" and j.d == -150 and j.e == true and j.a[3].b == nil)
check("json rejects trailing", Codec.jsonDecode("{} x") == nil)

-- ---------------------------------------------------------------- hostile input: must never throw or hang
local seed = 12345
local function rnd(n) seed = (seed * 1103515245 + 12345) % 2147483648; return seed % n end
local good = V.single[2].code
local alphabet = "bcdfghjkmpqrtvwxy346789!#$%&'()*+,-./:;<=>?@BCDFGHJKMPQRTVWXY[]^_{|}~"
local nthrow, nok, nerr = 0, 0, 0
local function attempt(s)
	local ok, res, err = pcall(Codec.decode, s, host)
	if not ok then nthrow += 1 elseif res then nok += 1 else nerr += 1 end
end
for cut = 8, #good - 1, 7 do attempt(good:sub(1, cut)) end              -- truncations
for _ = 1, 3000 do                                                       -- point mutations
	local p = 8 + rnd(#good - 8)
	local k = 1 + rnd(#alphabet)
	attempt(good:sub(1, p - 1) .. alphabet:sub(k, k) .. good:sub(p + 1))
end
for _ = 1, 500 do                                                         -- random garbage with a valid header
	local t = {}
	for i = 1, 20 + rnd(400) do local k = 1 + rnd(#alphabet); t[i] = alphabet:sub(k, k) end
	attempt("bbbbcbcbc" .. table.concat(t))
end
check("fuzz: decode never throws", nthrow == 0, nthrow)
print(("fuzz: %d decoded, %d rejected cleanly, %d threw"):format(nok, nerr, nthrow))

-- a hostile stream claiming a huge string map must be rejected before allocating
local evil = "bcbbbbb" .. "~~" -- map count 5183 with no data behind it
local ee, eerr = Codec.decodeStream(evil, 1)
check("absurd map count rejected", ee == nil and eerr ~= nil, eerr)


-- ---------------------------------------------------------------- Zstd (BreachZstd) vs frames from the real zstd library
do
	local cases = require("./zstd_vectors")
	local zbad = 0
	for _, c in ipairs(cases) do
		local bytes = Codec.base64Decode(c.b64)
		local raw, err = Zstd.decompress(bytes)
		local ok = raw ~= nil and #raw == c.len
		if ok then
			local h = 0
			for i = 1, #raw do h = (h * 31 + raw:byte(i)) % 4294967296 end
			ok = h == c.hash
		end
		if not ok then zbad += 1 end
		check("zstd: " .. c.name, ok, err)
	end
	-- hostile frames: never throw, never hang
	local good = Codec.base64Decode(cases[#cases - 1].b64)
	local zthrow, zrej, zok = 0, 0, 0
	for i = 1, 400 do
		local p = 1 + rnd(#good)
		local bad = good:sub(1, p - 1) .. string.char(rnd(256)) .. good:sub(p + 1)
		if i % 4 == 0 then bad = bad:sub(1, 1 + rnd(#bad - 1)) end
		local ok, r, e = pcall(Zstd.decompress, bad, 8 * 1024 * 1024)
		if not ok then zthrow += 1 elseif r then zok += 1 else zrej += 1 end
	end
	check("zstd fuzz: never throws", zthrow == 0, zthrow)
	print(("zstd fuzz: %d decoded, %d rejected cleanly, %d threw"):format(zok, zrej, zthrow))
	local rleCase
	for _, c in ipairs(cases) do if c.name == "rle L1" then rleCase = c end end
	local bomb, berr = Zstd.decompress(Codec.base64Decode(rleCase.b64), 1000) -- declares 200,000 bytes
	check("zstd output cap enforced", bomb == nil and berr ~= nil and berr:find("maximum"), berr)
	check("zstd rejects non-zstd", Zstd.decompress("hello world") == nil)
end

-- ---------------------------------------------------------------- a REAL Operators map ("The Diplomat", exported by the live plugin)
do
	local okEmb, emb = pcall(require, "./_embedded")
	if okEmb and type(emb) == "table" and emb["TheDiplomat.base64"] then
		local rm, rerr = Codec.decode(emb["TheDiplomat.base64"], host)
		check("real map decodes", rm ~= nil, rerr)
		if rm then
			local n = 0
			local function walk(x) n += 1 for _, c in ipairs(x.Children) do walk(c) end end
			walk(rm.Root)
			check("real map: version 2, map id 446", rm.Version == 2 and rm.MapId == 446)
			check("real map: 6,148 instances, root DebugMission", n == 6148 and rm.Root.Name == "DebugMission", n)
			check("real map: no warnings (stream consumed exactly)", #rm.Warnings == 0, table.concat(rm.Warnings, "; "))
			check("real map: settings", rm.Settings and rm.Settings.MissionName == "The Diplomat" and rm.Settings.AuthorName == "mrwd")
			check("real map: Setup JSON present", rm.Setup ~= nil and rm.Setup.CustomStrings ~= nil)
		end
	else
		print("(real-map test skipped: tests/_embedded.luau not found)")
	end
end


-- ---------------------------------------------------------------- BreachValidator (M2)
do
	local V = require("../BreachValidator")
	local function has(issues, kind, attr)
		for _, i in ipairs(issues) do if i.kind == kind and i.attribute == attr then return true end end
		return false
	end
	local function eq(a, b) return same(a, b, "attrs", 0) end
	local AP = "AccessPoint" -- { NetworkId = NETWORK_ID default 1, PowerArea = EXPRESSION "", NetworkLink = NETWORK_ID_STRING "", TriggerInvestigation = EXPRESSION true }

	-- pass-through rules
	local a = { Foo = 1 }
	check("validator: Folder passes through", V.validateAttributes("Folder", "AccessPoint", a) == a)
	check("validator: unknown component passes through", V.validateAttributes("Part", "NoSuchThing", a) == a)
	check("validator: StateScript passes through", V.validateAttributes("BoolValue", "x", { Type = "StateScript", Foo = 1 }) ~= nil and select(1, V.validateAttributes("BoolValue", "x", { Type = "StateScript", Foo = 1 })).Foo == 1)
	check("validator: AltProp passes through", V.validateAttributes("Part", AP, { AltProp = "x", Bogus = 1 }).Bogus == 1)
	local o, oi = V.validateAttributes("Part", AP, { NoValidation = true, Bogus = 1 })
	check("validator: opt-out passes through + reports", o.Bogus == 1 and has(oi, "opt-out", nil))
	check("validator: BoolValue keyed by Type, Part keyed by Name",
		V.componentKey("BoolValue", "whatever", { Type = AP }) == AP and V.componentKey("Part", AP, {}) == AP and V.componentKey("BoolValue", "x", {}) == nil)

	-- engine mode
	local e1 = V.validateAttributes("BoolValue", "n", { Type = AP })
	check("validator/engine: defaults filled", e1.NetworkId == 1 and e1.PowerArea == "" and e1.NetworkLink == "" and e1.TriggerInvestigation == true and e1.Type == AP)
	local e2, e2i = V.validateAttributes("BoolValue", "n", { Type = AP, NetworkId = 1, PowerArea = "x", TriggerInvestigation = false }, { includeDefaults = false })
	check("validator/engine: false is honoured, defaults dropped", eq(e2, { Type = AP, PowerArea = "x", TriggerInvestigation = false }), e2.NetworkId)
	check("validator/engine: no issues for that", #e2i == 0)
	local e3, e3i = V.validateAttributes("BoolValue", "n", { Type = AP, NetworkId = 1000 })
	check("validator/engine: bad value replaced by default + reported", e3.NetworkId == 1 and has(e3i, "type", "NetworkId"))
	local e4, e4i = V.validateAttributes("BoolValue", "n", { Type = AP, NetworkId = "5" })
	check("validator/engine: numeric-string network id accepted", e4.NetworkId == "5" and not has(e4i, "type", "NetworkId"))
	local e5, e5i = V.validateAttributes("BoolValue", "n", { Type = AP, Bogus = 7 })
	check("validator/engine: unknown attribute kept + reported", e5.Bogus == 7 and has(e5i, "unknown", "Bogus"))
	local e6, e6i = V.validateAttributes("BoolValue", "n", { Type = AP, Tag = 5, OnProp = true })
	check("validator/globals: bad global removed + reported, good kept", e6.Tag == nil and e6.OnProp == true and has(e6i, "type", "Tag"))

	-- exporter mode (bug-compatible)
	local x1, x1i = V.validateAttributes("BoolValue", "n", { Type = AP, NetworkId = 1, PowerArea = "x", TriggerInvestigation = false }, { mode = "exporter", includeDefaults = false })
	check("validator/exporter: `false` dropped, default dropped (N1)", eq(x1, { Type = AP, PowerArea = "x" }))
	check("validator/exporter: N1 is reported", has(x1i, "falsy-dropped", "TriggerInvestigation"))
	local x2 = V.validateAttributes("BoolValue", "n", { Type = AP, TriggerInvestigation = false }, { mode = "exporter", includeDefaults = true })
	check("validator/exporter: false comes back as the default on import", x2.TriggerInvestigation == true)
	local x3 = V.validateAttributes("BoolValue", "n", { Type = AP, NetworkId = 1000 }, { mode = "exporter", includeDefaults = true })
	check("validator/exporter: wrong-typed value is KEPT on import (fall-through bug)", x3.NetworkId == 1000)
	local x4 = V.validateAttributes("BoolValue", "n", { Type = AP, NetworkId = 1000 }, { mode = "exporter", includeDefaults = false })
	check("validator/exporter: wrong-typed value dropped on export", x4.NetworkId == nil)
	local x5, x5i = V.validateAttributes("BoolValue", "n", { Type = AP, NetworkId = "5" }, { mode = "exporter", includeDefaults = false })
	check("validator/exporter: numeric-string network id rejected (original quirk)", x5.NetworkId == nil and has(x5i, "type", "NetworkId"))
	local x6 = V.validateAttributes("BoolValue", "n", { Type = AP, Bogus = 7 }, { mode = "exporter" })
	check("validator/exporter: unknown attribute discarded", x6.Bogus == nil)
	local x7 = V.validateAttributes("BoolValue", "n", { Type = AP, OnProp = false }, { mode = "exporter", includeDefaults = false })
	check("validator/exporter: global false is kept", x7.OnProp == false)

	-- kinds
	local k1 = V.validateAttributes("Part", "CardReader", { TriggerVariable = "has space" })
	check("validator: STATE_VALUE rejects whitespace", has(select(2, V.validateAttributes("Part", "CardReader", { TriggerVariable = "has space" })), "type", "TriggerVariable") and k1.TriggerVariable == "")
	local hv = V.validateAttributes("Part", "HackableComputer", { MonitorOffset = { X = 0, Y = 0, Z = 0 }, NetworkId = 5 }, { includeDefaults = false })
	check("validator: Vector3 default compared by value", hv.MonitorOffset == nil and hv.NetworkId == 5)
	check("validator: bare-identifier defaults are nil (as in the plugin)", V.entry("MusicController").MusicType[2] == nil and V.entry("Flare").PlacedVariable[2] == nil)
	check("validator: kindOf resolves component and global attributes", V.kindOf(AP, "NetworkId") == "NETWORK_ID" and V.kindOf(AP, "Tag") == "STRING" and V.kindOf(AP, "Nope") == nil)
	local d = V.defaultsFor(AP)
	check("validator: defaultsFor", d.NetworkId == 1 and d.TriggerInvestigation == true and d.PowerArea == "")

	-- the real map: exporter-mode validation must reproduce the real exporter's output exactly
	local okEmb2, emb2 = pcall(require, "./_embedded")
	if okEmb2 and emb2["TheDiplomat.base64"] then
		local rm = assert(Codec.decode(emb2["TheDiplomat.base64"], host))
		local r = V.validateMission(rm, { mode = "exporter", includeDefaults = false, inPlace = false })
		check("validator on real map: 6,148 nodes walked", r.nodes == 6148, r.nodes)
		check("validator on real map: 526 component nodes validated", r.validated == 526, r.validated)
		check("validator on real map: exporter-mode is idempotent (0 changes)", r.changed == 0, r.changed)
		check("validator on real map: 0 issues", #r.issues == 0, #r.issues > 0 and (r.issues[1].path .. " " .. tostring(r.issues[1].attribute)) or nil)
		local r2 = V.validateMission(rm, { mode = "engine", includeDefaults = true, inPlace = false })
		check("validator on real map: engine mode reports nothing and fills defaults", #r2.issues == 0 and r2.changed > 0, r2.changed)
	end
end


-- ---------------------------------------------------------------- second real map ("The Interception" by KitaroKitsune), if present
do
	local okE, e3 = pcall(require, "./_embedded")
	if okE and e3["TheInterception.base64"] then
		local rm, rerr = Codec.decode(e3["TheInterception.base64"], host)
		check("real map 2 decodes", rm ~= nil, rerr)
		if rm then
			local n = 0
			local function walk(x) n += 1 for _, c in ipairs(x.Children) do walk(c) end end
			walk(rm.Root)
			check("real map 2: version 2, map id 4358", rm.Version == 2 and rm.MapId == 4358)
			check("real map 2: 3,667 instances, no warnings", n == 3667 and #rm.Warnings == 0, n)
			check("real map 2: settings (incl. non-ASCII briefing)", rm.Settings and rm.Settings.MissionName == "The Interception" and rm.Settings.AuthorName == "KitaroKitsune" and rm.Settings.MissionDesc:find("\226\128\153") ~= nil)
			local V2 = require("../BreachValidator")
			local vr = V2.validateMission(rm, { mode = "exporter", includeDefaults = false, inPlace = false })
			local bad = 0
			for _, i in ipairs(vr.issues) do if i.kind ~= "opt-out" then bad += 1 end end
			check("real map 2: validator changes nothing; only opt-out notices", vr.changed == 0 and bad == 0, ("changed %d, non-opt-out issues %d"):format(vr.changed, bad))
		end
	end
end


-- ---------------------------------------------------------------- M3: BreachMission (model + indexes)
do
	local V3 = require("../BreachValidator")
	local Mission = require("../BreachMission")
	local Standalone = require("../BreachStandalone")

	local function strip(n)
		local out = { ClassName = n.ClassName, Name = n.Name, Props = n.Props, Attrs = n.Attrs, Children = {} }
		for i, c in ipairs(n.Children) do out.Children[i] = strip(c) end
		return out
	end

	-- synthetic mission
	local dm = assert(Codec.decode(V.single[2].code, host))
	local mm = Mission.build(dm, { validator = V3 })
	check("mission: root id/path", mm.Root.Id == "n1" and mm.Root.Path == "DebugMission" and mm.Root.RefPath == "")
	local ids, dup = {}, 0
	for _, nd in ipairs(mm.Nodes) do if ids[nd.Id] then dup += 1 end ids[nd.Id] = true end
	check("mission: ids unique, nodes indexed", dup == 0 and #mm.Nodes == mm:stats().nodes and mm:node("n1") == mm.Root)
	check("mission: byClass / folder / findPath", #mm:byClass("Part") >= 3 and mm:folder("Props").ClassName == "Model" and mm:findPath("Props/Door1").Attrs.Type == "DoorMetal")
	check("mission: byComponent keyed by Type", #mm:byComponent("DoorMetal") == 1 and #mm:byComponent("TriggerZone") == 0)
	local beam
	for _, nd in ipairs(mm:byClass("Beam")) do beam = nd end
	check("mission: instance reference gets TargetId", beam and mm:node(beam.Props.Attachment0.TargetId).Name == "A0" and mm:node(beam.Props.Attachment1.TargetId).Name == "A1")
	check("mission: byTag", #mm:byTag("x") == 1 and #mm:byTag("rig") == 1)
	check("mission: no unresolved refs", mm.UnresolvedRefs == 0)

	-- standalone: synthetic round trip, ordering, awkward names
	local function roundtrip(label, root, expectFiles)
		local files = Standalone.encode(root)
		local back, err = Standalone.decode(files)
		check(label .. ": decodes", back ~= nil, err)
		if back then
			local ok, why = same(strip(back), strip(root), "root", 0)
			check(label .. ": tree identical (exact numbers, order, refs)", ok, why)
		end
		return files, back
	end
	local fresh = assert(Codec.decode(V.single[2].code, host))
	local files1 = roundtrip("standalone synthetic", fresh.Root)
	local files2 = Standalone.encode(fresh.Root)
	local same_ = #files1 == #files2
	for i = 1, #files1 do if files1[i].path ~= files2[i].path or files1[i].text ~= files2[i].text then same_ = false end end
	check("standalone: encoding is deterministic", same_)
	-- shuffled files decode identically (order is explicit, not filesystem-derived)
	local shuffled = {}
	for i = #files1, 1, -1 do shuffled[#shuffled + 1] = files1[i] end
	local sb = assert(Standalone.decode(shuffled))
	check("standalone: file order is irrelevant", select(1, same(strip(sb), strip(fresh.Root), "root", 0)))

	local weird = { ClassName = "Folder", Name = "Root", Props = {}, Attrs = {}, Children = {} }
	local names = { "A", "a", "A/b", "Contents", "Instance.metadata", "..", "", "x\ny", "quote\"s \\ back", "caf\u{E9} \u{1F600}", "CON", "trail.", "A" }
	for i, nm in ipairs(names) do
		local c = { ClassName = "StringValue", Name = nm, Props = { Value = (i % 2 == 0) and "line1\nline2\t\"q\" \\ end" or "" }, Attrs = {}, Children = {} }
		weird.Children[i] = c
	end
	weird.Children[1].Attrs = { ["odd key: with colon"] = true, normal = false, num = 0.1 + 0.2, big = 1e300, neg = -2.5e-7, int = 42 }
	weird.Children[2].ClassName = "Part"
	weird.Children[2].Props = { Size = { X = 1 / 3, Y = 2, Z = 3 }, Color = { R = 0.5, G = 0.25, B = 1 } }
	local wf = roundtrip("standalone awkward names", weird)
	local seen, clash = {}, 0
	for _, f in ipairs(wf) do
		local dir = f.path:match("^(.*)/[^/]+$")
		local key = (dir .. "/" .. f.path:match("[^/]+$")):lower()
		if seen[key] then clash += 1 end
		seen[key] = true
	end
	check("standalone: no case-insensitive path collisions", clash == 0, clash)

	-- errors
	local good = Standalone.encode(fresh.Root)
	local function without(pathPattern) local o = {} for _, f in ipairs(good) do if not f.path:find(pathPattern) then o[#o + 1] = f end end return o end
	check("standalone: missing parent metadata rejected", select(1, Standalone.decode(without("Props/Instance%.metadata$"))) == nil)
	local dupFiles = {}
	for i, f in ipairs(good) do dupFiles[i] = { path = f.path, text = f.text } end
	dupFiles[2].text = dupFiles[1].text:gsub("DebugMission", "Other") -- same Id as the root
	check("standalone: duplicate id rejected", select(1, Standalone.decode(dupFiles)) == nil)
	local badRef = {}
	for i, f in ipairs(good) do badRef[i] = { path = f.path, text = f.text:gsub('"RefId":"n%d+"', '"RefId":"n99999"') } end
	check("standalone: dangling RefId rejected", select(1, Standalone.decode(badRef)) == nil)
	check("standalone: empty input rejected", select(1, Standalone.decode({})) == nil)

	-- real maps
	for _, mapName in ipairs({ "TheDiplomat.base64", "TheInterception.base64", "thepeacemaker.txt" }) do
		local okE, e4 = pcall(require, "./_embedded")
		if okE and e4[mapName] then
			local d = assert(Codec.decode(e4[mapName], host))
			local t0 = os.clock()
			local built = Mission.build(d, { validator = V3 })
			local tb = os.clock() - t0
			local st = built:stats()
			check(mapName .. ": model builds, no unresolved refs", st.nodes > 1000 and built.UnresolvedRefs == 0)
			local cellKids = built:folder("Cells") and #built:folder("Cells").Children
			check(mapName .. ": Cells folder indexed", cellKids and cellKids > 0)
			local types = 0
			for _, c in pairs(st.components) do types += c end
			local cnt = 0
			for _, nd in ipairs(built:byClass("BoolValue")) do if nd.Attrs.Type ~= nil then cnt += 1 end end
			check(mapName .. ": component index covers every typed BoolValue", types == cnt, ("%d vs %d"):format(types, cnt))
			-- standalone round trip on the pristine tree
			local d2 = assert(Codec.decode(e4[mapName], host))
			local t1 = os.clock()
			local rf = Standalone.encode(d2.Root)
			local te = os.clock() - t1
			local t2 = os.clock()
			local rb, rerr = Standalone.decode(rf)
			local td = os.clock() - t2
			check(mapName .. ": standalone round trip", rb ~= nil, rerr)
			if rb then
				local ok, why = same(strip(rb), strip(d2.Root), "root", 0)
				check(mapName .. ": standalone round trip is EXACT", ok, why)
			end
			print(("%s: model %.2fs, standalone encode %.2fs (%d files), decode %.2fs"):format(mapName, tb, te, #rf, td))
			if mapName == "TheDiplomat.base64" then
				check("Diplomat: 56 cells, 13 DelayedStateUpdate, 5,218 Parts", cellKids == 56 and #built:byComponent("DelayedStateUpdate") == 13 and #built:byClass("Part") == 5218)
				check("Diplomat: validator ran inside build with no issues", built.Validation and #built.Validation.issues == 0)
			end
		end
	end
end


-- ---------------------------------------------------------------- M4: BreachWorld (cells, links, navigation)
do
	local V4 = require("../BreachValidator")
	local Mission4 = require("../BreachMission")
	local World = require("../BreachWorld")

	local function vec(x, y, z) return { X = x, Y = y, Z = z } end
	local function part(name, cx, cy, cz, sx, sy, sz, attrs, ry)
		return { ClassName = "Part", Name = name, Props = { CFrame = { Position = vec(cx, cy, cz), EulerXYZ = vec(0, ry or 0, 0) }, Size = vec(sx, sy, sz) }, Attrs = attrs or {}, Children = {} }
	end
	local function cell(name, cx, nodes, links, extra)
		local kids = { part("Floor", cx, 0, 0, 10, 1, 10), part("Roof", cx, 10, 0, 10, 1, 10) }
		local pj = Codec.jsonEncode({ Node = nodes, Link = links, Placed = {} })
		local m = { ClassName = "Model", Name = name, Props = {}, Attrs = { Location = "Location." .. name, Path = pj }, Children = kids }
		return m
	end
	local cells = { ClassName = "Folder", Name = "Cells", Props = {}, Attrs = {}, Children = {
		cell("A", 0, { { 0, 0.5, 0 }, { 3, 0.5, 0 } }, { { 2 }, { 1 } }),
		cell("B", 10, { { 8, 0.5, 0 }, { 12, 0.5, 0 } }, { { 2 }, { 1 } }),
		cell("C", 20, { { 17, 0.5, 0 }, { 22, 0.5, 0 } }, { { 2 }, { 1 } }),
		cell("D", 100, {}, {}),
		{ ClassName = "Model", Name = "Broken", Props = {}, Attrs = {}, Children = {} },
		{ ClassName = "Folder", Name = "Links", Props = {}, Attrs = {}, Children = {
			part("Link", 5, 5, 0, 4, 1, 3, { Path = true, Open = true, Move = true, Sound = 1 }),
			part("Link", 15, 5, 0, 4, 1, 3, { Path = false, Open = true, Move = true, Sound = 1 }),
		} },
	} }
	-- a rotated cell (90 degrees about Y): a 20 x 4 footprint becomes 4 x 20 in world space
	local rot = { ClassName = "Model", Name = "R", Props = {}, Attrs = {}, Children = {
		part("Floor", 50, 0, 0, 20, 1, 4, {}, math.pi / 2), part("Roof", 50, 10, 0, 20, 1, 4, {}, math.pi / 2) } }
	cells.Children[#cells.Children + 1] = rot
	local root = { ClassName = "Folder", Name = "DebugMission", Props = {}, Attrs = {}, Children = { cells } }
	local wm = Mission4.build({ Root = root, Warnings = {} }, {})
	local w = World.build(wm)
	local A, B, C, D = w.Cells[1], w.Cells[2], w.Cells[3], w.Cells[4]
	check("world: cells found, Links folder and floorless model excluded", #w.Cells == 5 and A.Zone == "A" and w.Cells[5].Zone == "R")
	check("world: floorless cell warned about", #w.Warnings == 1 and w.Warnings[1]:find("Broken") ~= nil, w.Warnings[1])
	check("world: cell attributes", A.Location == "Location.A" and #A.Floors == 1 and #A.Roofs == 1 and #A.Nav.Nodes == 2)
	check("world: cellAt inside / above / below", w:cellAt(0, 3, 0) == A and w:cellAt(0, 20, 0) == nil and w:cellAt(0, -5, 0) == nil)
	check("world: cellAt accepts a point table", w:cellAt(vec(10, 3, 0)) == B)
	check("world: shared boundary is in two cells, cellAt takes the first", #w:cellsAt(5, 3, 0) == 2 and w:cellAt(5, 3, 0) == A)
	check("world: rotated cell footprint", w:cellAt(50, 3, 8) == w.Cells[5] and w:cellAt(58, 3, 0) == nil)
	check("world: links join the cells they overlap", #w.Links == 2 and #w.Links[1].Cells == 2 and #w.Links[2].Cells == 2)
	check("world: neighbors", #w:neighbors(A) == 1 and w:neighbors(A)[1] == B and #w:neighbors(B) == 2 and #w:neighbors(D) == 0)
	check("world: hops/route", w:hops(A, C) == 2 and w:hops(A, D) == nil and w:route(A, C)[2] == B and #w:route(A, A) == 1)
	check("world: route honours link flags", w:hops(A, C, { path = true }) == nil and w:hops(A, B, { path = true }) == 1 and w:hops(A, C, { open = true }) == 2)
	check("world: components", w.Diagnostics.cellComponents == 3 and w:components({ path = true }) == 4) -- {A,B,C} {D} {R}; with path links only: {A,B} {C} {D} {R}
	local p1 = w:findPath(vec(0, 0.5, 0), vec(12, 0.5, 0))
	check("world: A* across a Path link", p1 ~= nil and #p1.points == 4 and math.abs(p1.length - 12) < 1e-6, p1 and p1.length)
	check("world: A* refuses to cross a non-Path link", w:findPath(vec(0, 0.5, 0), vec(22, 0.5, 0)) == nil)
	check("world: diagnostics", w.Diagnostics.cells == 5 and w.Diagnostics.links == 2 and w.Diagnostics.navNodes == 6 and w.Diagnostics.navEdgesInter == 1)
	local noCells = World.build(Mission4.build({ Root = { ClassName = "Folder", Name = "DebugMission", Props = {}, Attrs = {}, Children = {} }, Warnings = {} }, {}))
	check("world: mission without Cells yields an empty world, not an error", #noCells.Cells == 0 and noCells.Warnings[1]:find("no Cells") ~= nil and noCells:cellAt(0, 0, 0) == nil)

	-- adjacency-list nav format incl. one-way entries and Placed nodes kept separate
	local c2 = { ClassName = "Folder", Name = "Cells", Props = {}, Attrs = {}, Children = {
		{ ClassName = "Model", Name = "N", Props = {}, Attrs = { Path = Codec.jsonEncode({ Node = { { 0, 0, 0 }, { 1, 0, 0 }, { 2, 0, 0 } }, Link = { { 2 }, { 1, 3 }, {} }, Placed = { { 9, 9, 9 } } }) },
			Children = { part("Floor", 0, 0, 0, 10, 1, 10), part("Roof", 0, 10, 0, 10, 1, 10) } } } }
	local w2 = World.build(Mission4.build({ Root = { ClassName = "Folder", Name = "DebugMission", Props = {}, Attrs = {}, Children = { c2 } }, Warnings = {} }, {}))
	check("world: nav adjacency lists (2 undirected + 1 one-way), Placed separate", w2.Diagnostics.navNodes == 3 and w2.Diagnostics.navEdgesIntra == 2 and w2.Diagnostics.navOneWayEdges == 1 and #w2.Cells[1].Nav.Placed == 1)

	-- real maps
	for _, mapName in ipairs({ "TheDiplomat.base64", "TheInterception.base64", "thepeacemaker.txt" }) do
		local okE, e5 = pcall(require, "./_embedded")
		if okE and e5[mapName] then
			local rd = assert(Codec.decode(e5[mapName], host))
			local rmi = Mission4.build(rd, { validator = V4 })
			local t0 = os.clock()
			local rw = World.build(rmi)
			local tw = os.clock() - t0
			local dg = rw.Diagnostics
			check(mapName .. ": world has cells and links, nothing touches no cell", dg.cells > 10 and dg.links > 10 and dg.linksTouchingNoCell == 0, ("cells %d links %d orphan %d"):format(dg.cells, dg.links, dg.linksTouchingNoCell))
			local withNav, located, flagged = 0, 0, 0
			for _, c in ipairs(rw.Cells) do
				if #c.Nav.Nodes > 0 then
					withNav += 1
					local inside = false
					for _, p in ipairs(c.Nav.Nodes) do
						for _, x in ipairs(rw:cellsAt(p)) do if x == c then inside = true break end end
						if inside then break end
					end
					if inside then located += 1 end
					if c.NavSuspect then flagged += 1 end
					if inside == (c.NavSuspect == true) then located = -1e9 end -- flag must be exactly "no own node inside"
				end
			end
			check(mapName .. ": NavSuspect flags exactly the cells with no own node inside", located + flagged == withNav, ("%d + %d vs %d"):format(located, flagged, withNav))
			check(mapName .. ": at least 85% of cells with navigation data are self-consistent", withNav > 0 and flagged / withNav <= 0.15, ("%d of %d suspect"):format(flagged, withNav))
			check(mapName .. ": suspect cells are reported as a warning", (flagged == 0) == (#rw.Warnings == 0 or not rw.Warnings[#rw.Warnings]:find("outside their own volume")))
			if mapName == "thepeacemaker.txt" then
				check("peacemaker: exactly 9 cells carry copied Path data", flagged == 9, flagged)
			end
			-- A* inside the biggest navigation component
			local nav = rw._nav
			local comp, sizes = {}, {}
			for i = 1, #nav.nodes do
				if not comp[i] then
					local id = i
					local stack, count = { i }, 0
					comp[i] = id
					while #stack > 0 do
						local a = table.remove(stack)
						count += 1
						for _, e in ipairs(nav.edges[a]) do if not comp[e.to] then comp[e.to] = id stack[#stack + 1] = e.to end end
					end
					sizes[id] = count
				end
			end
			local bigId, bigN = nil, 0
			for id, n in pairs(sizes) do if n > bigN then bigId, bigN = id, n end end
			local members = {}
			for i = 1, #nav.nodes do if comp[i] == bigId then members[#members + 1] = i end end
			local a, b = nav.nodes[members[1]], nav.nodes[members[#members]]
			local r = rw:findPath(a, b)
			local straight = math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2 + (a.Z - b.Z) ^ 2)
			check(mapName .. ": A* finds a route inside the biggest nav component, no shorter than a straight line", r ~= nil and r.length >= straight - 1e-6 and #r.points >= 2, r and ("%.1f vs %.1f"):format(r.length, straight) or "no path")
			print(("%s: world %.2fs  cells %d links %d (bridging %d)  cell components %d  nav nodes %d, edges %d + %d link edges (%d one-way), nav components %d (largest %d nodes)"):format(mapName, tw, dg.cells, dg.links, dg.linksBridgingCells, dg.cellComponents, dg.navNodes, dg.navEdgesIntra, dg.navEdgesInter, dg.navOneWayEdges, dg.navComponents, bigN))
			if mapName == "TheDiplomat.base64" then
				check("Diplomat: 55 cells, 90 links, 424 navigation nodes", dg.cells == 55 and dg.links == 90 and dg.navNodes == 424, ("%d/%d/%d"):format(dg.cells, dg.links, dg.navNodes))
			end
		end
	end
end


-- ---------------------------------------------------------------- third real map, GIST form ("The Peacemaker" by Benoki9)
do
	local okE, e6 = pcall(require, "./_embedded")
	if okE and e6["thepeacemaker.txt"] then
		local text = e6["thepeacemaker.txt"]
		check("peacemaker: is a gist (starts with the !!! comment)", text:sub(1, 3) == "!!!")
		local piece = assert(Codec.parsePiece(text))
		check("peacemaker: gist header parsed (v2, map 845, 1/1)", piece.Version == 2 and piece.MapId == 845 and piece.Current == 1 and piece.Total == 1)
		local gm, gerr = Codec.decode(text, host)
		check("peacemaker decodes", gm ~= nil, gerr)
		if gm then
			local n = 0
			local function walk(x) n += 1 for _, c in ipairs(x.Children) do walk(c) end end
			walk(gm.Root)
			check("peacemaker: 11,971 instances, no warnings", n == 11971 and #gm.Warnings == 0, n)
			check("peacemaker: settings", gm.Settings.MissionName == "The Peacemaker" and gm.Settings.AuthorName == "Benoki9")
			local V6 = require("../BreachValidator")
			local vr = V6.validateMission(gm, { mode = "exporter", includeDefaults = false, inPlace = false })
			local bad = 0
			for _, i in ipairs(vr.issues) do if i.kind ~= "opt-out" then bad += 1 end end
			check("peacemaker: validator changes nothing, only opt-out notices", vr.changed == 0 and bad == 0, ("changed %d, other issues %d"):format(vr.changed, bad))
			local Mission6, World6 = require("../BreachMission"), require("../BreachWorld")
			local wd = World6.build(Mission6.build(gm, { validator = V6 })).Diagnostics
			check("peacemaker: 90 cells, 149 links, 807 navigation nodes", wd.cells == 90 and wd.links == 149 and wd.navNodes == 807, ("%d/%d/%d"):format(wd.cells, wd.links, wd.navNodes))
		end
	end
end

-- M5: expression language, variable store + replication, logic components
require("./logic_tests")(check)
-- M6: CFrame, StateScript VM, StateScript in the logic core
require("./script_tests")(check)
-- M6.1: ConditionalStateUpdate, DelayedStateUpdate, VariableShuffle
require("./state_tests")(check)
-- The Project: a third real map (version 0, ~800 KB) + engine builtin defaults
require("./project_tests")(check)
-- M7: props (zones, rooms, items, triggers, doors, readers, end zones)
require("./props_tests")(check)
-- M8.0: MissionSetup parser
require("./setup_tests")(check)
-- M8a: BreachNav (kinematic agents, trail following, anti-collision invariants)
require("./nav_tests")(check)
-- M8b: bots, routes, patrols, loadouts, despawn, state trackers
require("./bots_tests")(check)
-- M8c part 1: sight (cones, line of sight, detection meters)
require("./sight_tests")(check)
-- M8c part 2: trespass (Cells rule sets, disguises, enforcing classes, witnesses)
require("./trespass_tests")(check)

-- M8c part 3: alert (level, AlertRaiseCondition, trespass reactions, anomalies)
require("./alert_tests")(check)

-- M8d: hostages, bodies, alt interaction
require("./hostage_tests")(check)

-- M8e: CustomBehavior scripts, conditions, spawners
require("./behavior_tests")(check)
require("./combatdata_tests")(check)

-- M9a: lockdown phases, awareness
require("./combat_tests")(check)

-- M11.0: shuffle survey
require("./shuffle_tests")(check)

-- M8f: seeded playthroughs through BreachSession
require("./playthrough_tests")(check)

print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then error("tests failed") end
