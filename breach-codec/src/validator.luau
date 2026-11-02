--!nonstrict
--[[
	BreachValidator — attribute validation for InfiltrationEngine-style missions (BreachEngine M2).

	Pure Luau, no requires, no Roblox APIs. Works on the plain tables produced by BreachCodec.
	Written from BreachEngine_Documentation.md §3.4; contains no plugin code. The attribute table it
	uses is generated from the plugin by tools/gen_attrmap.py.

	TWO MODES
	  "engine"   (default)  What a running engine should do with a mission:
	               * explicit `false` values are honoured,
	               * a value of the wrong type is reported and replaced by the default,
	               * unknown attributes are reported but KEPT.
	  "exporter"            Bug-compatible re-implementation of the official exporter, to predict what it would
	                        write or read (useful for an encoder / round-trip tests):
	               * `false` counts as "absent" for attributes listed in the map (so a default-true bool can't
	                 be turned off),
	               * unknown attributes are discarded,
	               * when reading with defaults, a wrong-typed value is NOT replaced by the default (a
	                 fall-through in the original keeps it).

	API
	  Validator.validateAttributes(className, instanceName, attributes, opts) -> newAttributes, issues
	  Validator.validateMission(mission, opts) -> report
	  Validator.componentKey(className, instanceName, attributes) -> key | nil
	  Validator.entry(key) -> { [attribute] = {kind, default} } | nil
	  Validator.defaultsFor(key) -> { [attribute] = default } | nil
	  Validator.kindOf(key, attribute) -> kind | nil     (also resolves global attributes)

	opts: { mode = "engine"|"exporter", includeDefaults = bool (default true), keepUnknown = bool (default by mode) }

	issue = { path, class, name, attribute, kind, message, value }
	  kind: "type" | "unknown" | "falsy-dropped" | "opt-out"
]]

local Validator = {}
Validator.VERSION = "0.1.0"

--@@ATTRMAP@@

local floor = math.floor

-------------------------------------------------------------------------------
-- Value helpers (decoded value shapes from BreachCodec)
-------------------------------------------------------------------------------
local function isVec3(v)
	return type(v) == "table" and type(v.X) == "number" and type(v.Y) == "number" and type(v.Z) == "number" and v.R == nil
end

local function isColor3(v)
	return type(v) == "table" and type(v.R) == "number" and type(v.G) == "number" and type(v.B) == "number"
end

local function valuesEqual(a, b)
	if a == b then
		return true
	end
	if type(a) == "table" and type(b) == "table" then
		if isVec3(a) and isVec3(b) then
			return a.X == b.X and a.Y == b.Y and a.Z == b.Z
		end
		if isColor3(a) and isColor3(b) then
			return a.R == b.R and a.G == b.G and a.B == b.B
		end
	end
	return false
end

local function isInt(v)
	return type(v) == "number" and v == floor(v)
end

local function toNumber(v)
	if type(v) == "number" then
		return v
	elseif type(v) == "string" then
		return tonumber(v)
	end
	return nil
end

-------------------------------------------------------------------------------
-- Kind checks. Return ok, message. (`faithful` reproduces one quirk: NETWORK_ID given as a string is
-- always rejected by the original, even when the number is valid.)
-------------------------------------------------------------------------------
local function describe(v)
	if type(v) == "table" then
		if isVec3(v) then return "Vector3" end
		if isColor3(v) then return "Color3" end
		return "table"
	end
	return type(v)
end

local CHECK = {}

CHECK.NUMBER = function(v)
	if type(v) == "number" then return true end
	return false, "must contain a number type (found " .. describe(v) .. ")"
end
CHECK.INT = function(v)
	if type(v) ~= "number" then return false, "must contain a number type (integer) (found " .. describe(v) .. ")" end
	if not isInt(v) then return false, "must be an integer (found " .. tostring(v) .. ")" end
	return true
end
CHECK.EXPRESSION = function(v)
	local t = type(v)
	if t == "boolean" or t == "string" or t == "number" then return true end
	return false, "must contain a boolean, string, or number type (found " .. describe(v) .. ")"
end
CHECK.STATE_VALUE = function(v)
	if type(v) ~= "string" then return false, "must contain a string type with no whitespace (found " .. describe(v) .. ")" end
	if string.find(v, "%s") ~= nil then return false, "must not contain whitespace (found '" .. v .. "')" end
	return true
end
CHECK.STRING = function(v)
	if type(v) == "string" then return true end
	return false, "must contain a string type (found " .. describe(v) .. ")"
end
CHECK.NETWORK_ID = function(v, faithful)
	if type(v) == "number" then
		if isInt(v) and v >= 1 and v <= 999 then return true end
		return false, "must contain a number type between 1 and 999 (found " .. tostring(v) .. ")"
	elseif type(v) == "string" then
		local n = tonumber(v)
		local valid = n ~= nil and isInt(n) and n >= 1 and n <= 999
		if valid and not faithful then return true end
		if valid then return false end -- the original rejects numeric strings here without a message
		return false, "must contain a number type between 1 and 999 (found '" .. v .. "')"
	end
	return false, "must contain a number type between 1 and 999 (found " .. describe(v) .. ")"
end
CHECK.NETWORK_ID_STRING = function(v)
	if v == "" then return true end
	local n = toNumber(v)
	if n == nil then return true end -- anything non-numeric is an expression
	if isInt(n) and n >= 1 and n <= 999 then return true end
	return false, "must be a string of a number between 1 and 999, or blank (found " .. tostring(v) .. ")"
end
CHECK.OPTIONAL_BOOL = function(v)
	if v == nil or type(v) == "boolean" then return true end
	return false, "must be a boolean or nil (found " .. describe(v) .. ")"
end
CHECK.OPTIONAL_MISSION_COLOR = function(v)
	if v == nil or isColor3(v) or type(v) == "string" then return true end
	return false, "must be nil, a Color3, or a string (found " .. describe(v) .. ")"
end
CHECK.OPTIONAL_MATERIAL = function(v)
	if v == nil or type(v) == "string" then return true end
	return false, "must be nil or a string (found " .. describe(v) .. ")"
end
CHECK.VECTOR3 = function(v)
	if isVec3(v) then return true end
	return false, "must contain a Vector3 (found " .. describe(v) .. ")"
end
CHECK.OPTIONAL_INT = function(v)
	if v == nil then return true end
	if type(v) ~= "number" then return false, "must be nil or an integer (found " .. describe(v) .. ")" end
	if not isInt(v) then return false, "must be nil or an integer (found " .. tostring(v) .. ")" end
	return true
end
CHECK.BOOL = function(v)
	if type(v) == "boolean" then return true end
	return false, "must be a boolean (found " .. describe(v) .. ")"
end

-------------------------------------------------------------------------------
-- Lookup helpers
-------------------------------------------------------------------------------
function Validator.componentKey(className, instanceName, attributes)
	if className == "BoolValue" then
		return attributes and attributes.Type or nil
	end
	return instanceName
end

function Validator.entry(key)
	return key ~= nil and ENTRIES[key] or nil
end

function Validator.defaultsFor(key)
	local e = Validator.entry(key)
	if not e then
		return nil
	end
	local d = {}
	for name, info in pairs(e) do
		if info[2] ~= nil then
			d[name] = info[2]
		end
	end
	return d
end

function Validator.kindOf(key, attribute)
	local e = Validator.entry(key)
	if e and e[attribute] then
		return e[attribute][1]
	end
	return GLOBALS[attribute]
end

-------------------------------------------------------------------------------
-- Core
-------------------------------------------------------------------------------
local function addIssue(issues, ctx, kind, attribute, message, value)
	if issues then
		issues[#issues + 1] = {
			path = ctx.path,
			class = ctx.class,
			name = ctx.name,
			attribute = attribute,
			kind = kind,
			message = message,
			value = value,
		}
	end
end

function Validator.validateAttributes(className, instanceName, attributes, opts)
	opts = opts or {}
	local exporter = opts.mode == "exporter"
	local includeDefaults = opts.includeDefaults
	if includeDefaults == nil then
		includeDefaults = true
	end
	local keepUnknown = opts.keepUnknown
	if keepUnknown == nil then
		keepUnknown = not exporter
	end
	local issues = {}
	local ctx = { path = opts.path or instanceName, class = className, name = instanceName }
	attributes = attributes or {}

	if className == "Folder" then
		return attributes, issues
	end
	if attributes.IKnowWhatImDoingDoNotValidate == true or attributes.NoValidation then
		addIssue(issues, ctx, "opt-out", nil, "intentionally opting out of attribute validation")
		return attributes, issues
	end
	if attributes.Type == "StateScript" or instanceName == "StateScriptPart" then
		return attributes, issues
	end
	local key = Validator.componentKey(className, instanceName, attributes)
	local entry = key ~= nil and ENTRIES[key] or nil
	if entry == nil then
		return attributes, issues
	end
	if attributes.AltProp or attributes.AltPropModel then
		return attributes, issues
	end

	local out = {}

	-- 1. attributes listed for this component
	for attName, info in pairs(entry) do
		local kind, default = info[1], info[2]
		local given = attributes[attName]
		local absent
		if exporter then
			absent = not given -- original: nil AND false both count as absent
			if given == false then
				addIssue(issues, ctx, "falsy-dropped", attName, "false is treated as absent by the exporter's validator", false)
			end
		else
			absent = given == nil
		end
		if absent then
			if includeDefaults and default ~= nil then
				out[attName] = default
			end
			if exporter and given == false and includeDefaults then
				-- original: the default is restored (so false becomes the default)
				out[attName] = default
			end
		else
			local ok, msg = CHECK[kind](given, exporter)
			if not ok then
				addIssue(issues, ctx, "type", attName, msg or "invalid value", given)
				if includeDefaults then
					out[attName] = default
				end
				if exporter then
					-- original falls through to the "keep" test below (see header note)
					if (valuesEqual(default, given) and includeDefaults) or not valuesEqual(default, given) then
						if includeDefaults then
							out[attName] = given
						end
					end
				end
			else
				if includeDefaults or not valuesEqual(default, given) then
					out[attName] = given
				end
			end
		end
	end

	-- 2. global attributes, and unknown ones
	for attName, value in pairs(attributes) do
		local gk = GLOBALS[attName]
		if gk then
			local ok, msg = CHECK[gk](value, exporter)
			if ok then
				out[attName] = value
			else
				addIssue(issues, ctx, "type", attName, msg or "invalid value", value)
				out[attName] = nil
			end
		elseif entry[attName] == nil then
			addIssue(issues, ctx, "unknown", attName, "unknown attribute for " .. tostring(key), value)
			if keepUnknown then
				out[attName] = value
			end
		end
	end
	return out, issues
end

-------------------------------------------------------------------------------
-- Whole-mission pass
-------------------------------------------------------------------------------
function Validator.validateMission(mission, opts)
	opts = opts or {}
	local inPlace = opts.inPlace
	if inPlace == nil then
		inPlace = true
	end
	local report = { issues = {}, nodes = 0, validated = 0, skipped = 0, changed = 0 }
	local function walk(node, path)
		report.nodes = report.nodes + 1
		local nodeOpts = {
			mode = opts.mode,
			includeDefaults = opts.includeDefaults,
			keepUnknown = opts.keepUnknown,
			path = path,
		}
		local before = node.Attrs
		local newAttrs, issues = Validator.validateAttributes(node.ClassName, node.Name, before, nodeOpts)
		if newAttrs == before then
			report.skipped = report.skipped + 1
		else
			report.validated = report.validated + 1
			-- changed?
			local same = true
			for k, v in pairs(newAttrs) do
				if not valuesEqual(before[k], v) then
					same = false
					break
				end
			end
			if same then
				for k in pairs(before) do
					if newAttrs[k] == nil then
						same = false
						break
					end
				end
			end
			if not same then
				report.changed = report.changed + 1
			end
			if inPlace then
				node.Attrs = newAttrs
			end
		end
		for _, i in ipairs(issues) do
			report.issues[#report.issues + 1] = i
		end
		for _, c in ipairs(node.Children) do
			walk(c, path .. "/" .. tostring(c.Name))
		end
	end
	walk(mission.Root, tostring(mission.Root.Name))
	return report
end

return Validator
