--!nocheck
local Codec=require("../BreachCodec") local Zstd=require("../BreachZstd") local Mission=require("../BreachMission") local V=require("../BreachValidator") local Setup=require("../BreachSetup")
local E=require("./_embedded") local P=require("./_embedded_project")
for _,mp in ipairs({{"Dip",E,"TheDiplomat.base64"},{"Pea",E,"thepeacemaker.txt"},{"Proj",P,"theproject.txt"}}) do
  local D=Codec.decode(mp[2][mp[3]],{zstdDecompress=Zstd.decompress}) local m=Mission.build(D,{validator=V})
  print("=====",mp[1])
  for _,n in ipairs(m:byComponent("AlertRaiseCondition") or {}) do local a=n.Attrs
    print(("  ARC %-22s Amount=%s Min=%s Max=%s Reason=%s | Cond: %s"):format(n.Name:sub(1,22),tostring(a.Amount),tostring(a.MinValue),tostring(a.MaxValue),tostring(a.Reason),tostring(a.Condition):sub(1,90))) end
  -- Mission_AlertLevel / AlarmRaised usage in expressions
  local uses={}
  local function scan(src,where) if type(src)~="string" then return end for pat in src:gmatch("Mission_AlertLevel[%s]*([<>=~!]+[%s]*%d)") do uses["AlertLevel "..pat]=(uses["AlertLevel "..pat] or 0)+1 end if src:find("Mission_AlertLevel") and not src:find("Mission_AlertLevel%s*[<>=~!]") then uses["AlertLevel (bare)"]=(uses["AlertLevel (bare)"] or 0)+1 end end
  for _,st in ipairs({"Globals","Internals","ClientState"}) do for k,v in pairs(D.Setup[st]) do scan(v) end end
  local function walk(n) local key=Mission.componentKey(n) for a,v in pairs(n.Attrs or {}) do if V.kindOf(key,a)=="EXPRESSION" or a=="ScriptSource" then scan(v) end end for _,c in ipairs(n.Children) do walk(c) end end walk(m.Root)
  local o={} for k,v in pairs(uses) do o[#o+1]=k.." x"..v end table.sort(o) print("  Mission_AlertLevel uses:",table.concat(o,"; "))
  local prof={} local function w2(x) if x.ClassName=="BoolValue" and x.Path:find("/Bots/",1,true) and x.Attrs and x.Attrs.Profile and x.Attrs.Profile~="" then prof[x.Attrs.Profile]=(prof[x.Attrs.Profile] or 0)+1 end for _,c in ipairs(x.Children) do w2(c) end end w2(m.Root)
  local pp={} for k,v in pairs(prof) do pp[#pp+1]=k.."x"..v end table.sort(pp) print("  bot Profiles:",table.concat(pp," "))
end
