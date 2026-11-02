--!nocheck
local Codec=require("../BreachCodec") local Zstd=require("../BreachZstd") local Mission=require("../BreachMission") local V=require("../BreachValidator") local World=require("../BreachWorld") local Setup=require("../BreachSetup")
local E=require("./_embedded") local P=require("./_embedded_project")
for _,mp in ipairs({{"Dip",E,"TheDiplomat.base64"},{"Pea",E,"thepeacemaker.txt"},{"Proj",P,"theproject.txt"}}) do
  local d=Codec.decode(mp[2][mp[3]],{zstdDecompress=Zstd.decompress}) local m=Mission.build(d,{validator=V}) local w=World.build(m) local t=Setup.parse(d.SetupSource)
  local keys={} for k in pairs(t.Cells) do keys[k:lower()]=k end
  local nameHit,attrHit,total=0,{}, 0
  local attrKeys={}
  local samples={}
  for _,c in ipairs(w.Cells) do total+=1 local n=c.Node
    if keys[n.Name:lower()] then nameHit+=1 end
    for k,v in pairs(n.Attrs or {}) do attrKeys[k]=(attrKeys[k] or 0)+1 if type(v)=="string" then for tok in v:gmatch("[%w_%.]+") do if keys[tok:lower()] then attrHit[k]=(attrHit[k] or 0)+1 end end end end
    if #samples<4 then local ps={} for k,v in pairs(n.Attrs or {}) do ps[#ps+1]=k.."="..tostring(v):sub(1,26) end table.sort(ps) samples[#samples+1]=n.Name.." :: "..table.concat(ps," ") end end
  local ak={} for k,v in pairs(attrKeys) do ak[#ak+1]=k.."x"..v end table.sort(ak)
  local hk={} for k,v in pairs(attrHit) do hk[#hk+1]=k.."x"..v end table.sort(hk)
  print(("%s: cells %d | node Name matches a Cells key: %d | cell attrs seen: %s | attrs whose value contains a Cells key: %s"):format(mp[1],total,nameHit,table.concat(ak," "),table.concat(hk," ")))
  for _,x in ipairs(samples) do print("    ",x) end
end
