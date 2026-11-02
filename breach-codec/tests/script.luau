--!nonstrict
-- Run only the M6 tests:  luau tests/script.luau   (from breach-codec/)
local passed, failed = 0, 0
local function check(name, cond, detail)
	if cond then
		passed += 1
	else
		failed += 1
		print("FAIL: " .. name .. (detail ~= nil and (" -- " .. tostring(detail)) or ""))
	end
end
require("./script_tests")(check)
print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then error("tests failed") end
