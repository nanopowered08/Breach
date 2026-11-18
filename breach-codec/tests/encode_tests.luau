--!nonstrict
-- Tests for BreachEncode (M12: the mission-code encoder). Synthetic trees plus the codec's own vectors; real maps when tests/_embedded.luau exists.
local Codec = require("../BreachCodec")
local Encode = require("../BreachEncode")
local Zstd = require("../BreachZstd")
local V = require("./vectors")

return function(check)
	local host = { zstdDecompress = Zstd.decompress }

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
			if k ~= "Parent" then
				local ok, why = same(a[k], v, path .. "." .. tostring(k), tol)
				if not ok then return false, why end
			end
		end
		for k in pairs(a) do
			if k ~= "Parent" and b[k] == nil then return false, path .. "." .. tostring(k) .. ": unexpected key" end
		end
		return true
	end

	local function roundTrip(label, tree, opts)
		local pieces, info = Encode.encode(tree, opts)
		check(label .. ": encodes", pieces ~= nil, info)
		if not pieces then return nil end
		local m, err = Codec.decode(pieces, host)
		check(label .. ": the code decodes", m ~= nil, err)
		if not m then return nil end
		local ok, why = same(m.Root, tree, "Root")
		check(label .. ": decode(encode(tree)) equals the tree", ok, why)
		local real = {}
		for _, w in ipairs(m.Warnings) do if w ~= "mission has no TableMissionSetup" then real[#real + 1] = w end end -- a bare test tree has no setup
		check(label .. ": no warnings", #real == 0, table.concat(real, "; "))
		-- a fixed point: the decoded tree encodes to exactly the same code (all quantisation already happened)
		local again = Encode.encode(m, opts)
		local a, b = table.concat(pieces), again and table.concat(again)
		check(label .. ": encode(decode(encode(t))) is the same code", a == b)
		return m, pieces
	end

	-- 1) the codec's own expected tree (Part with CFrame, Color, Size, Material, enums, attributes of every kind)
	roundTrip("vectors tree, version 2", V.expected)
	roundTrip("vectors tree, version 1", V.expected, { Version = 1 })

	-- 2) every class, every property, filled from a sample by value type
	local SAMPLE = {
		Float = 2.5, Int = 7, ShortInt = 300, ShortestInt = 5, LongInt = 123456, SignedInt = -42,
		BoundedFloat = 0.25, ShortBoundedFloat = 0.5, Bool = true, String = "text & more\nline2\ttab",
		Color3 = { R = 0.25, G = 0.5, B = 0.75 }, Vector2 = { X = 1.5, Y = -2.5 }, Vector3 = { X = 1, Y = -2.25, Z = 3.5 },
		UDim = { Scale = 0.5, Offset = 10 }, UDim2 = { X = { Scale = 0.5, Offset = 10 }, Y = { Scale = 1, Offset = -4 } },
		FloatRange = { Min = 1, Max = 3.5 },
		FloatSequence = { { Time = 0, Value = 1, Envelope = 0 }, { Time = 1, Value = 4.5, Envelope = 0.5 } },
		ColorSequence = { { Time = 0, Color = { R = 1, G = 0, B = 0 } }, { Time = 1, Color = { R = 0, G = 0, B = 1 } } },
		CFrame = { Position = { X = 1.5, Y = -2, Z = 30.25 }, EulerXYZ = { X = 0.5, Y = -1.25, Z = 3 } },
		InstanceReference = { Ref = "Root/Some Thing" },
	}
	local classes = { "Model", "Folder", "Part", "BoolValue", "WedgePart", "StringValue", "MeshPart", "UnionOperation", "Texture", "BlockMesh", "PointLight",
		"SpotLight", "SurfaceLight", "SpecialMesh", "Decal", "Fire", "Smoke", "Attachment", "ParticleEmitter", "Sparkles", "SurfaceGui", "ImageLabel",
		"BillboardGui", "Frame", "Beam", "Trail" }
	local root = { ClassName = "Folder", Name = "Root", Props = {}, Attrs = {}, Children = {} }
	-- property names and types come from the first decode of a code that uses them: build them from the wire tables through a probe
	local PROBE = {}
	for _, c in ipairs(classes) do PROBE[c] = true end
	-- The property lists are internal to the modules; learn them by encoding an empty node and asking for warnings with a bogus property
	local function propsOf(class)
		local node = { ClassName = class, Name = "x", Props = { __probe = 1 }, Attrs = {}, Children = {} }
		local _, info = Encode.encode(node)
		return info and info.Warnings
	end
	check("an unknown property is reported, not written", (propsOf("Part") or {})[1] ~= nil and string.find(propsOf("Part")[1], "__probe", 1, true) ~= nil)

	-- enum names by property (the wire tables list them; use known members)
	local ENUMPICK = { Material = "Concrete", NormalId = "Front", PartType = "Cylinder", MeshType = "FileMesh", RenderFidelity = "Precise",
		CollisionFidelity = "Hull", TextureMode = "Wrap", ParticleEmitterShape = "Sphere", ParticleEmitterShapeInOut = "Inward",
		ParticleEmitterShapeStyle = "Surface", ParticleOrientation = "VelocityParallel", ResamplerMode = "Pixelated", SurfaceGuiSizingMode = "PixelsPerStud" }
	-- (name, type) per class, written out here once so the test does not depend on module internals
	local SPEC = {
		Model = {}, Folder = {},
		Part = { { "CFrame", "CFrame" }, { "Color", "Color3" }, { "Size", "Vector3" }, { "Anchored", "Bool" }, { "CanCollide", "Bool" }, { "Transparency", "ShortBoundedFloat" }, { "Material", "Material" }, { "CastShadow", "Bool" }, { "Shape", "PartType" }, { "AssemblyLinearVelocity", "Vector3" }, { "AssemblyAngularVelocity", "Vector3" } },
		BoolValue = { { "Value", "Bool" } }, StringValue = { { "Value", "String" } },
		WedgePart = { { "CFrame", "CFrame" }, { "Color", "Color3" }, { "Size", "Vector3" }, { "Anchored", "Bool" }, { "Transparency", "ShortBoundedFloat" }, { "Material", "Material" } },
		MeshPart = { { "CFrame", "CFrame" }, { "MeshId", "String" }, { "TextureID", "String" }, { "RenderFidelity", "RenderFidelity" }, { "CollisionFidelity", "CollisionFidelity" } },
		UnionOperation = { { "CFrame", "CFrame" }, { "MeshId", "String" } },
		Texture = { { "Color3", "Color3" }, { "OffsetStudsU", "Float" }, { "StudsPerTileV", "Float" }, { "Texture", "String" }, { "ZIndex", "Int" }, { "Face", "NormalId" } },
		BlockMesh = { { "Scale", "Vector3" }, { "Offset", "Vector3" } },
		PointLight = { { "Brightness", "Float" }, { "Color", "Color3" }, { "Enabled", "Bool" }, { "Range", "Float" }, { "Shadows", "Bool" } },
		SpotLight = { { "Angle", "Float" }, { "Face", "NormalId" }, { "Range", "Float" } },
		SurfaceLight = { { "Angle", "Float" }, { "Face", "NormalId" } },
		SpecialMesh = { { "MeshId", "String" }, { "MeshType", "MeshType" }, { "Offset", "Vector3" }, { "Scale", "Vector3" }, { "VertexColor", "Vector3" }, { "TextureId", "String" } },
		Decal = { { "Color3", "Color3" }, { "Texture", "String" }, { "Transparency", "ShortBoundedFloat" }, { "ZIndex", "Int" }, { "Face", "NormalId" } },
		Fire = { { "Color", "Color3" }, { "Heat", "Float" }, { "SecondaryColor", "Color3" }, { "Size", "Float" } },
		Smoke = { { "Opacity", "Float" }, { "RiseVelocity", "Float" } },
		Attachment = { { "CFrame", "CFrame" }, { "Visible", "Bool" } },
		ParticleEmitter = { { "Color", "ColorSequence" }, { "Size", "FloatSequence" }, { "Transparency", "FloatSequence" }, { "Orientation", "ParticleOrientation" }, { "Rotation", "FloatRange" }, { "Shape", "ParticleEmitterShape" }, { "ShapeInOut", "ParticleEmitterShapeInOut" }, { "ShapeStyle", "ParticleEmitterShapeStyle" }, { "SpreadAngle", "Vector2" }, { "Acceleration", "Vector3" } },
		Sparkles = { { "SparkleColor", "Color3" }, { "TimeScale", "Float" } },
		SurfaceGui = { { "Face", "NormalId" }, { "MaxDistance", "Int" }, { "SizingMode", "SurfaceGuiSizingMode" } },
		ImageLabel = { { "Position", "UDim2" }, { "Size", "UDim2" }, { "Rotation", "Float" }, { "AnchorPoint", "Vector2" }, { "BackgroundColor3", "Color3" }, { "Image", "String" }, { "ResampleMode", "ResamplerMode" } },
		BillboardGui = { { "Adornee", "InstanceReference" }, { "StudsOffset", "Vector3" }, { "Size", "UDim2" }, { "MaxDistance", "Int" } },
		Frame = { { "Position", "UDim2" }, { "BackgroundTransparency", "ShortBoundedFloat" }, { "ZIndex", "Int" } },
		Beam = { { "Color", "ColorSequence" }, { "Texture", "String" }, { "TextureMode", "TextureMode" }, { "Attachment0", "InstanceReference" }, { "Width0", "Float" } },
		Trail = { { "Color", "ColorSequence" }, { "WidthScale", "FloatSequence" }, { "Lifetime", "Float" } },
	}
	for _, class in ipairs(classes) do
		local props = {}
		for _, e in ipairs(SPEC[class]) do
			local v = ENUMPICK[e[2]] or SAMPLE[e[2]]
			props[e[1]] = v
		end
		local node = { ClassName = class, Name = (class ~= "BlockMesh") and ("n_" .. class) or nil, Props = props, Attrs = {}, Children = {} } -- a BlockMesh has no Name
		if class == "Model" or class == "Folder" or class == "Part" or class == "BoolValue" or class == "MeshPart" or class == "UnionOperation" then
			node.Attrs = { Tag = "x y", Count = 3 }
		end
		if class == "BoolValue" and not props.Value then props.Value = false end
		if class == "StringValue" and props.Value == nil then props.Value = "" end
		root.Children[#root.Children + 1] = node
	end
	roundTrip("every class and property type", root)

	-- 3) attributes of every type, odd strings, default names, nesting
	local weird = {
		ClassName = "Model", Name = "Model", Props = {}, Attrs = {
			["with space"] = 1, ["Zero"] = 0, ["Big"] = 4000000, ["Huge"] = 70000000000, ["Neg"] = -7, ["NegBig"] = -150000,
			["Half"] = 0.5, ["Pi"] = 3.14159, ["Yes"] = true, ["No"] = false, ["Empty"] = "", ["Amp"] = "a&b&&c", ["NL"] = "x\ny\r\nz\tw",
			["Uni"] = "caf\195\169 \226\130\172", ["Col"] = { R = 0.1, G = 0.2, B = 0.3 }, ["Vec"] = { X = 1, Y = -2, Z = 3.5 },
			["CF"] = { Position = { X = 1, Y = 2, Z = 3 }, EulerXYZ = { X = 0, Y = 1, Z = -1 } },
		},
		Children = {
			{ ClassName = "Folder", Name = "Folder", Props = {}, Attrs = {}, Children = {
				{ ClassName = "Part", Name = "Part", Props = { Anchored = true }, Attrs = { A = 1 }, Children = {} },
				{ ClassName = "StringValue", Name = "Setup", Props = { Value = "line1\nline2 & done" }, Attrs = {}, Children = {} },
			} },
		},
	}
	local m = roundTrip("attributes and strings", weird)
	if m then
		check("big whole number attributes survive exactly", m.Root.Attrs.Big == 4000000 and m.Root.Attrs.Huge == 70000000000 and m.Root.Attrs.NegBig == -150000)
		check("strings keep &, newlines, tabs and UTF-8", m.Root.Attrs.Amp == "a&b&&c" and m.Root.Attrs.NL == "x\ny\r\nz\tw" and m.Root.Attrs.Uni == "caf\195\169 \226\130\172")
	end

	-- 4) pieces, map id, comment
	local one = Encode.encode(weird, { MapId = 4321 })
	local many, info = Encode.encode(weird, { MapId = 4321, MaxPieceLength = 40, Comment = "my map" })
	check("MaxPieceLength splits the payload into several pieces", many ~= nil and #many > 1 and #one == 1, info)
	if many then
		local r = {}
		for i = #many, 1, -1 do r[#r + 1] = many[i] end
		local dm, err = Codec.decode(r, host)
		check("pieces in any order decode to the same mission", dm ~= nil and same(dm.Root, weird, "Root"), err)
		check("the map id and piece numbers are in the header", dm ~= nil and dm.MapId == 4321 and Codec.parsePiece(many[2]).Current == 2 and Codec.parsePiece(many[2]).Total == #many)
		check("a comment is written before the first piece", string.sub(many[1], 1, 12) == "!!!my map!!!")
	end
	check("encodeString returns one code", type(Encode.encodeString(weird)) == "string")
	check("encodeString refuses a code that needs several pieces", Encode.encodeString(weird, { MaxPieceLength = 40 }) == nil)

	-- 5) the Zstd store frame and Base64, byte lengths around the block limits
	local function bytes(n)
		local t = {}
		local x = 12345
		for i = 1, n do
			x = (x * 1103515245 + 12345) % 2147483648
			t[i] = string.char(x % 256)
		end
		return table.concat(t)
	end
	for _, n in ipairs({ 0, 1, 127, 128, 131071, 131072, 131073, 300000 }) do
		local s = bytes(n)
		local back, err = Zstd.decompress(Encode.zstdStore(s))
		check("zstd store frame round trips " .. n .. " bytes", back == s, err)
	end
	for n = 0, 11 do
		local s = bytes(n)
		check("base64 round trips " .. n .. " bytes", Codec.base64Decode(Encode.base64Encode(s)) == s)
	end
	check("base64 matches a known value", Encode.base64Encode("Man") == "TWFu" and Encode.base64Encode("Ma") == "TWE=" and Encode.base64Encode("M") == "TQ==")
	check("a zstd frame starts with the Zstd magic (so a base64 code starts KLUv/)", string.sub(Encode.base64Encode(Encode.zstdStore("x")), 1, 5) == "KLUv/")

	-- 6) determinism and errors (none of these may throw)
	check("the same tree always encodes to the same code", (table.concat((Encode.encode(weird)))) == (table.concat((Encode.encode(weird)))))
	local function bad(label, tree, opts)
		local ok, a, b = pcall(Encode.encode, tree, opts)
		check("error: " .. label, ok and a == nil and type(b) == "string", b)
	end
	bad("an unknown class", { ClassName = "Script", Name = "s", Props = {}, Attrs = {}, Children = {} })
	bad("a bad MapId", weird, { MapId = 99999 })
	bad("an unsupported version", weird, { Version = 0 })
	bad("a Float out of range", { ClassName = "Part", Name = "p", Props = { Size = { X = 1e9, Y = 1, Z = 1 } }, Attrs = {}, Children = {} })
	bad("an invalid enum name", { ClassName = "Part", Name = "p", Props = { Material = "Unobtainium" }, Attrs = {}, Children = {} })
	bad("an attribute of a type the format cannot store", { ClassName = "Part", Name = "p", Props = {}, Attrs = { f = print }, Children = {} })
	bad("NaN", { ClassName = "Part", Name = "p", Props = {}, Attrs = { n = 0 / 0 }, Children = {} })
	bad("no ClassName", { Name = "x" })
	local _, winfo = Encode.encode({ ClassName = "Texture", Name = "t", Props = {}, Attrs = { a = 1 }, Children = {} })
	check("attributes on a class that cannot carry them are reported", winfo ~= nil and #winfo.Warnings == 1)

	-- 6b) a seeded stress test: random trees of every class, random values of every type, random attributes. Each must round trip and be a fixed point.
	do
		local seed = 987654321
		local function rnd() seed = (seed * 1103515245 + 12345) % 2147483648 return seed / 2147483648 end
		local function ri(a, b) return a + math.floor(rnd() * (b - a + 1)) end
		local function pick(t) return t[ri(1, #t)] end
		local ENUMS_FUZZ = {
			Material = { "Asphalt", "Concrete", "Neon", "Plaster", "Rubber", "SmoothPlastic", "WoodPlanks" }, NormalId = { "Top", "Bottom", "Left", "Right", "Front", "Back" },
			PartType = { "Ball", "Cylinder", "Block", "Wedge", "CornerWedge" }, MeshType = { "Brick", "FileMesh", "Head", "Wedge" }, RenderFidelity = { "Automatic", "Precise", "Performance" },
			CollisionFidelity = { "Default", "Hull", "Box", "PreciseConvexDecomposition" }, TextureMode = { "Stretch", "Wrap", "Static" },
			ParticleEmitterShape = { "Box", "Sphere", "Cylinder", "Disc" }, ParticleEmitterShapeInOut = { "Outward", "Inward", "InAndOut" },
			ParticleEmitterShapeStyle = { "Volume", "Surface" }, ParticleOrientation = { "FacingCamera", "VelocityParallel", "VelocityPerpendicular" },
			ResamplerMode = { "Default", "Pixelated" }, SurfaceGuiSizingMode = { "FixedSize", "PixelsPerStud" },
		}
		local function rfloat()
			local k = ri(1, 6)
			if k == 1 then return 0 elseif k == 2 then return ri(-1000, 1000) elseif k == 3 then return (rnd() - 0.5) * 360000 elseif k == 4 then return (rnd() - 0.5) * 2 else return (rnd() - 0.5) * 2000 end
		end
		local function rstr()
			local t = {}
			for i = 1, ri(0, 24) do
				t[i] = pick({ "a", "Z", " ", "&", "\n", "\t", "\r", "9", "_", "\195\169", "\226\130\172", "!", "\"", "{", "|" })
			end
			return table.concat(t)
		end
		local function rcolor() return { R = rnd(), G = rnd(), B = rnd() } end
		local function rangle()
			local k = ri(1, 8)
			if k == 1 then return math.pi elseif k == 2 then return -math.pi elseif k == 3 then return 0 else return (rnd() * 2 - 1) * math.pi end
		end
		local function rvec3() return { X = rfloat(), Y = rfloat(), Z = rfloat() } end
		local function rudim() return { Scale = rfloat(), Offset = rfloat() } end
		local function rvalue(t)
			if ENUMS_FUZZ[t] then return pick(ENUMS_FUZZ[t]) end
			if t == "Float" then return rfloat() elseif t == "Int" then return ri(0, 72 ^ 4 - 1) elseif t == "String" then return rstr()
			elseif t == "Bool" then return rnd() < 0.5 elseif t == "ShortBoundedFloat" or t == "BoundedFloat" then return rnd()
			elseif t == "Color3" then return rcolor() elseif t == "Vector3" then return rvec3() elseif t == "Vector2" then return { X = rfloat(), Y = rfloat() }
			elseif t == "UDim2" then return { X = rudim(), Y = rudim() } elseif t == "FloatRange" then return { Min = rfloat(), Max = rfloat() }
			elseif t == "FloatSequence" then
				local out = {} for i = 1, ri(0, 4) do out[i] = { Time = rnd(), Value = rfloat(), Envelope = rfloat() } end return out
			elseif t == "ColorSequence" then
				local out = {} for i = 1, ri(0, 4) do out[i] = { Time = rnd(), Color = rcolor() } end return out
			elseif t == "CFrame" then return { Position = rvec3(), EulerXYZ = { X = rangle(), Y = rangle(), Z = rangle() } }
			elseif t == "InstanceReference" then return { Ref = rstr() } end
			error("fuzz: no sample for " .. t)
		end
		local function rattr()
			local k = ri(1, 9)
			if k == 1 then return ri(0, 100000) elseif k == 2 then return -ri(1, 150000) elseif k == 3 then return ri(0, 72 ^ 6 - 1) elseif k == 4 then return rfloat()
			elseif k == 5 then return rnd() < 0.5 elseif k == 6 then return rstr() elseif k == 7 then return rcolor() elseif k == 8 then return rvec3()
			else return { Position = rvec3(), EulerXYZ = { X = rangle(), Y = rangle(), Z = rangle() } } end
		end
		local ATTR_CLASSES = { Model = true, Folder = true, Part = true, BoolValue = true, MeshPart = true, UnionOperation = true }
		local function rnode(depth)
			local class = pick(classes)
			local props = {}
			for _, e in ipairs(SPEC[class]) do
				if rnd() < 0.7 then props[e[1]] = rvalue(e[2]) end
			end
			local node = { ClassName = class, Name = (class ~= "BlockMesh") and pick({ rstr(), class, "Name" .. ri(1, 50) }) or nil, Props = props, Attrs = {}, Children = {} }
			if class == "BoolValue" then props.Value = props.Value or false end
			if class == "StringValue" then props.Value = props.Value or "" end
			if ATTR_CLASSES[class] then
				for i = 1, ri(0, 4) do node.Attrs["k" .. ri(1, 30) .. rstr()] = rattr() end
			end
			if depth < 3 then
				for i = 1, ri(0, 3) do node.Children[#node.Children + 1] = rnode(depth + 1) end
			end
			return node
		end
		local bad, firstBad = 0, nil
		local total = 0
		for i = 1, 300 do
			local tree = { ClassName = "Folder", Name = "Fuzz" .. i, Props = {}, Attrs = {}, Children = {} }
			for j = 1, ri(1, 6) do tree.Children[#tree.Children + 1] = rnode(1) end
			local pieces, info = Encode.encode(tree)
			local ok, why = pieces ~= nil, info
			if ok then
				local m, err = Codec.decode(pieces, host)
				if not m then ok, why = false, err
				else
					ok, why = same(m.Root, tree, "Root")
					if ok then
						local again = Encode.encode(m)
						if not again or table.concat(again) ~= table.concat(pieces) then ok, why = false, "not a fixed point" end
					end
				end
			end
			total += 1
			if not ok then bad += 1 firstBad = firstBad or ("tree " .. i .. ": " .. tostring(why)) end
		end
		check("stress: " .. total .. " random trees all round trip and are fixed points", bad == 0, firstBad)
	end

	-- 6c) format limits: at most 5183 distinct strings and 5183 distinct colours per code; the error says so
	do
		local many = { ClassName = "Folder", Name = "Many", Props = {}, Attrs = {}, Children = {} }
		for i = 1, 5200 do many.Children[i] = { ClassName = "Folder", Name = "folder number " .. i, Props = {}, Attrs = {}, Children = {} } end
		local a, err = Encode.encode(many)
		check("more than 5183 distinct strings is refused with a clear message", a == nil and type(err) == "string" and string.find(err, "5183", 1, true) ~= nil, err)
		local colors = { ClassName = "Folder", Name = "Colors", Props = {}, Attrs = {}, Children = {} }
		for i = 1, 5200 do colors.Children[i] = { ClassName = "Part", Name = "Part", Props = { Color = { R = (i % 72) / 71, G = math.floor(i / 72) / 72, B = (i * 7 % 100) / 100 } }, Attrs = {}, Children = {} } end
		local b, err2 = Encode.encode(colors)
		check("more than 5183 distinct colours is refused with a clear message", b == nil and type(err2) == "string" and string.find(err2, "5183", 1, true) ~= nil, err2)
		-- a big but legal tree encodes in reasonable time and round trips
		local big = { ClassName = "Folder", Name = "Big", Props = {}, Attrs = {}, Children = {} }
		for i = 1, 6000 do
			big.Children[i] = { ClassName = "Part", Name = "Part", Props = { CFrame = { Position = { X = i * 1.5, Y = 3, Z = -i }, EulerXYZ = { X = 0, Y = 1, Z = 0 } }, Size = { X = 4, Y = 1, Z = 4 } }, Attrs = { Id = i % 4000 }, Children = {} }
		end
		local t0 = os.clock()
		local pieces = Encode.encode(big)
		local dt = os.clock() - t0
		check("6000 parts encode in under 5 seconds", pieces ~= nil and dt < 5, dt)
		local mb = pieces and Codec.decode(pieces, host)
		check("6000 parts round trip", mb ~= nil and #mb.Root.Children == 6000 and same(mb.Root, big, "Root"))
	end

	-- 7) real maps, when the local data exists
	local okE, emb = pcall(require, "./_embedded")
	if okE and type(emb) == "table" then
		local n = 0
		for name, code in pairs(emb) do
			if type(code) == "string" then
				local m0 = Codec.decode(code, host)
				if m0 then
					n += 1
					local pieces, ie = Encode.encode(m0, { MapId = m0.MapId })
					check("real map " .. name .. ": encodes", pieces ~= nil, ie)
					if pieces then
						local m1, err = Codec.decode(pieces, host)
						check("real map " .. name .. ": decode(encode(map)) equals the map", m1 ~= nil and same(m1.Root, m0.Root, "Root", 1e-9), err)
						local again = m1 and Encode.encode(m1, { MapId = m0.MapId })
						check("real map " .. name .. ": fixed point", again ~= nil and table.concat(again) == table.concat(pieces))
					end
				end
			end
		end
		if n == 0 then print("(real-map encode tests: no map code found in tests/_embedded.luau)") end
	else
		print("(real-map encode tests skipped: tests/_embedded.luau not found)")
	end
end
