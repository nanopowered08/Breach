--!nocheck
local Codec=require("../BreachCodec") local Zstd=require("../BreachZstd") local Mission=require("../BreachMission") local V=require("../BreachValidator") local World=require("../BreachWorld")
local P=require("./_embedded_project")
local m=Mission.build(Codec.decode(P["theproject.txt"],{zstdDecompress=Zstd.decompress}),{validator=V}) local w=World.build(m)
for i,l in ipairs(w.Links) do if #(l.Cells or {})<2 and l.Path==true then
  local hits={} for cell,h in pairs(l.Hits or {}) do hits[#hits+1]=("cell%s:%s"):format(tostring(cell),type(h)=="number" and ("%.2f"):format(h) or tostring(h)) end
  print(("link %d path cells=%s hits=%s"):format(i,table.concat(l.Cells or {},","),table.concat(hits," "))) end end
