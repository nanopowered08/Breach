--!nocheck
local Codec=require("../BreachCodec") local Zstd=require("../BreachZstd") local Mission=require("../BreachMission") local V=require("../BreachValidator") local Setup=require("../BreachSetup")
local E=require("./_embedded") local P=require("./_embedded_project")
local function ser(v) if type(v)~="table" then return tostring(v) end local ks={} for k in pairs(v) do ks[#ks+1]=k end table.sort(ks,function(a,b) return tostring(a)<tostring(b) end) local o={} for _,k in ipairs(ks) do o[#o+1]=tostring(k).."="..ser(v[k]) end return "{"..table.concat(o,",").."}" end
for _,mp in ipairs({{"Dip",E,"TheDiplomat.base64"},{"Pea",E,"thepeacemaker.txt"},{"Proj",P,"theproject.txt"}}) do
  local d=Codec.decode(mp[2][mp[3]],{zstdDecompress=Zstd.decompress}) local m=Mission.build(d,{validator=V}) local t=Setup.parse(d.SetupSource)
  local fields,strings={}, {}
  local enforceKeys,allowKeys,minorKeys={}, {}, {}
  for name,c in pairs(t.Cells) do if type(c)=="table" then for k,v in pairs(c) do fields[k]=(fields[k] or 0)+1 end
      for k in pairs(c.Enforce or {}) do enforceKeys[k]=true end for k in pairs(c.EnforceMinor or {}) do enforceKeys[k]=true end for k in pairs(c.Allow or {}) do allowKeys[k]=true end for k in pairs(c.MinorTrespass or {}) do minorKeys[k]=true end
    else strings[#strings+1]=name.." = "..tostring(c) end end
  local fk={} for k,v in pairs(fields) do fk[#fk+1]=k.."x"..v end table.sort(fk)
  local function keys(t2) local o={} for k in pairs(t2) do o[#o+1]=k end table.sort(o) return table.concat(o,",") end
  print("=====",mp[1]) print("  rule fields:",table.concat(fk," ")) print("  Enforce/EnforceMinor classes:",keys(enforceKeys)) print("  Allow disguises:",keys(allowKeys)) print("  MinorTrespass disguises:",keys(minorKeys))
  for _,s in ipairs(strings) do print("  string rule:",s) end
  if t.EnforceCellLinks then print("  EnforceCellLinks:",ser(t.EnforceCellLinks):sub(1,260)) end
  -- bot classes
  local cls={} local function walk(x) if x.ClassName=="BoolValue" and x.Path:find("/Bots/",1,true) and x.Attrs and x.Attrs.Class and x.Attrs.Class~="" then cls[x.Attrs.Class]=(cls[x.Attrs.Class] or 0)+1 end for _,c in ipairs(x.Children) do walk(c) end end walk(m.Root)
  print("  bot Class values:",(function() local o={} for k,v in pairs(cls) do o[#o+1]=k.."x"..v end table.sort(o) return table.concat(o," ") end)())
  print("  CustomDisguises keys:",keys(t.CustomDisguises or {}))
end
