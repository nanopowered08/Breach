--!nonstrict
--[[
	BreachCFrame — just enough CFrame math for StateScript (BreachEngine M6). Pure Luau, no Roblox APIs, so scripts
	run the same headless and in-game. A host that has real CFrames converts at the edge (see BreachScript's `host`).

	A CFrame is an array of 12 numbers in Roblox's component order: x, y, z, R00 R01 R02, R10 R11 R12, R20 R21 R22
	(row-major rotation). Euler angles follow Roblox's CFrame.Angles: R = Rx · Ry · Rz (main doc §6.5).

	    CF.new(x, y, z)   CF.identity()   CF.angles(rx, ry, rz)   CF.fromQuat(x, y, z, w)   CF.fromString("1, 2, 3")
	    CF.mul(a, b)      CF.inverse(a)   CF.lerp(a, b, t)         CF.position(a)   CF.toQuat(a)   CF.equals(a, b)
	    CF.isCF(v)        CF.arith(op, a, b)   -- the hook BreachExpr uses for `[#Pos * #Rot]`
]]

local CF = {}
local MT = {}
MT.__index = MT

local function make(t)
	return setmetatable(t, MT)
end

-- Structural, not identity: every build of this module (standalone, or the copy embedded in BreachScript/BreachLogic)
-- has its own metatable, and a CFrame made by one must be recognised by another.
MT.__breachCFrame = true
function CF.isCF(v)
	if type(v) ~= "table" then
		return false
	end
	local mt = getmetatable(v)
	return mt ~= nil and mt.__breachCFrame == true and #v == 12
end

function CF.new(x, y, z)
	return make({ x or 0, y or 0, z or 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 })
end

function CF.identity()
	return CF.new(0, 0, 0)
end

function CF.position(c: any)
	return c[1], c[2], c[3]
end

-- 12 numbers in Roblox order.
function CF.fromComponents(list)
	if #list ~= 12 then
		return nil, "a CFrame needs 12 components, got " .. #list
	end
	local t = {}
	for i = 1, 12 do
		t[i] = list[i]
	end
	return make(t)
end

function CF.fromQuat(x, y, z, w, px, py, pz)
	local n = math.sqrt(x * x + y * y + z * z + w * w)
	if n == 0 then
		return CF.new(px, py, pz)
	end
	x, y, z, w = x / n, y / n, z / n, w / n
	return make({
		px or 0, py or 0, pz or 0,
		1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w),
		2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w),
		2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y),
	})
end

function CF.toQuat(c: any)
	local m00, m01, m02, m10, m11, m12, m20, m21, m22 = c[4], c[5], c[6], c[7], c[8], c[9], c[10], c[11], c[12]
	local tr = m00 + m11 + m22
	local x, y, z, w
	if tr > 0 then
		local s = math.sqrt(tr + 1) * 2
		w, x, y, z = 0.25 * s, (m21 - m12) / s, (m02 - m20) / s, (m10 - m01) / s
	elseif m00 > m11 and m00 > m22 then
		local s = math.sqrt(1 + m00 - m11 - m22) * 2
		w, x, y, z = (m21 - m12) / s, 0.25 * s, (m01 + m10) / s, (m02 + m20) / s
	elseif m11 > m22 then
		local s = math.sqrt(1 + m11 - m00 - m22) * 2
		w, x, y, z = (m02 - m20) / s, (m01 + m10) / s, 0.25 * s, (m12 + m21) / s
	else
		local s = math.sqrt(1 + m22 - m00 - m11) * 2
		w, x, y, z = (m10 - m01) / s, (m02 + m20) / s, (m12 + m21) / s, 0.25 * s
	end
	return x, y, z, w
end

-- Roblox CFrame.Angles: R = Rx * Ry * Rz (radians).
function CF.angles(rx, ry, rz)
	local cx, sx, cy, sy, cz, sz = math.cos(rx), math.sin(rx), math.cos(ry), math.sin(ry), math.cos(rz), math.sin(rz)
	return make({
		0, 0, 0,
		cy * cz, -cy * sz, sy,
		cx * sz + sx * sy * cz, cx * cz - sx * sy * sz, -sx * cy,
		sx * sz - cx * sy * cz, sx * cz + cx * sy * sz, cx * cy,
	})
end

function CF.mul(a: any, b: any)
	local ax, ay, az = a[1], a[2], a[3]
	local a00, a01, a02, a10, a11, a12, a20, a21, a22 = a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11], a[12]
	local bx, by, bz = b[1], b[2], b[3]
	local b00, b01, b02, b10, b11, b12, b20, b21, b22 = b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12]
	return make({
		ax + a00 * bx + a01 * by + a02 * bz,
		ay + a10 * bx + a11 * by + a12 * bz,
		az + a20 * bx + a21 * by + a22 * bz,
		a00 * b00 + a01 * b10 + a02 * b20, a00 * b01 + a01 * b11 + a02 * b21, a00 * b02 + a01 * b12 + a02 * b22,
		a10 * b00 + a11 * b10 + a12 * b20, a10 * b01 + a11 * b11 + a12 * b21, a10 * b02 + a11 * b12 + a12 * b22,
		a20 * b00 + a21 * b10 + a22 * b20, a20 * b01 + a21 * b11 + a22 * b21, a20 * b02 + a21 * b12 + a22 * b22,
	})
end

function CF.inverse(c: any)
	local x, y, z = c[1], c[2], c[3]
	local r00, r01, r02, r10, r11, r12, r20, r21, r22 = c[4], c[5], c[6], c[7], c[8], c[9], c[10], c[11], c[12]
	return make({
		-(r00 * x + r10 * y + r20 * z), -(r01 * x + r11 * y + r21 * z), -(r02 * x + r12 * y + r22 * z),
		r00, r10, r20,
		r01, r11, r21,
		r02, r12, r22,
	})
end

-- Position lerps linearly; rotation slerps (nlerp when nearly parallel).
function CF.lerp(a: any, b: any, t: number)
	local x, y, z = a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t
	local ax, ay, az, aw = CF.toQuat(a)
	local bx, by, bz, bw = CF.toQuat(b)
	local dot = ax * bx + ay * by + az * bz + aw * bw
	if dot < 0 then
		bx, by, bz, bw, dot = -bx, -by, -bz, -bw, -dot
	end
	local ka, kb
	if dot > 0.9995 then
		ka, kb = 1 - t, t
	else
		local theta = math.acos(dot)
		local s = math.sin(theta)
		ka, kb = math.sin((1 - t) * theta) / s, math.sin(t * theta) / s
	end
	return CF.fromQuat(ka * ax + kb * bx, ka * ay + kb * by, ka * az + kb * bz, ka * aw + kb * bw, x, y, z)
end

function CF.equals(a: any, b: any, tol: number)
	tol = tol or 1e-9
	for i = 1, 12 do
		if math.abs(a[i] - b[i]) > tol then
			return false
		end
	end
	return true
end

-- "x, y, z" (position) | 7 numbers (position + quaternion x y z w) | 12 numbers (Roblox order).
function CF.fromString(s)
	local nums = {}
	for tok in string.gmatch((s:gsub(",", " ")), "%S+") do
		local n = tonumber(tok)
		if n == nil then
			return nil, "not a number: '" .. tok .. "'"
		end
		nums[#nums + 1] = n
	end
	if #nums == 3 then
		return CF.new(nums[1], nums[2], nums[3])
	elseif #nums == 7 then
		return CF.fromQuat(nums[4], nums[5], nums[6], nums[7], nums[1], nums[2], nums[3])
	elseif #nums == 12 then
		return CF.fromComponents(nums)
	end
	return nil, "expected 3, 7 or 12 numbers, got " .. #nums
end

-- The expression-language hook: arithmetic and equality when an operand is a CFrame. Returns value, or nil + reason.
function CF.arith(op: string, a: any, b: any)
	if CF.isCF(a) and CF.isCF(b) then
		if op == "*" then
			return CF.mul(a, b)
		elseif op == "==" then
			return CF.equals(a, b) and 1 or 0
		elseif op == "~=" or op == "!=" then
			return CF.equals(a, b) and 0 or 1
		end
		return nil, "'" .. op .. "' is not defined for two CFrames"
	end
	if op == "==" then
		return 0
	elseif op == "~=" or op == "!=" then
		return 1
	end
	return nil, "'" .. op .. "' mixes a CFrame with a non-CFrame"
end

function MT.__tostring(c)
	local rotated = not (c[4] == 1 and c[5] == 0 and c[6] == 0 and c[7] == 0 and c[8] == 1 and c[9] == 0 and c[10] == 0 and c[11] == 0 and c[12] == 1)
	return ("CFrame(%g, %g, %g%s)"):format(c[1], c[2], c[3], rotated and ", rotated" or "")
end

return CF
