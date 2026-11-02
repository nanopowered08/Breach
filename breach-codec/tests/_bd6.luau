--!nocheck
local Codec=require("../BreachCodec") local Zstd=require("../BreachZstd") local Mission=require("../BreachMission") local V=require("../BreachValidator") local World=require("../BreachWorld")
local P=require("./_embedded_project")
local m=Mission.build(Codec.decode(P["theproject.txt"],{zstdDecompress=Zstd.decompress}),{validator=V}) local w=World.build(m)
local l1=w.Links[1] local ks={} for k,v in pairs(l1) do ks[#ks+1]=k.."="..(type(v)=="table" and "{..}" or tostring(v):sub(1,40)) end table.sort(ks) print("link fields:",table.concat(ks," "))
local hist={} for _,l in ipairs(w.Links) do local n=#(l.Cells or {}) hist[n]=(hist[n] or 0)+1 end for n,c in pairs(hist) do print("links touching",n,"cells:",c) end
for _,idx in ipairs({66,67,68,69,13,23}) do local c=w.Cells[idx] print(("cell #%d %s center=(%.0f,%.0f,%.0f) size=(%.0f,%.0f,%.0f) nodes=%d"):format(idx,tostring(c.Name),c.Box and c.Box.center.X or 0,c.Box and c.Box.center.Y or 0,c.Box and c.Box.center.Z or 0,c.Box and c.Box.size.X or 0,c.Box and c.Box.size.Y or 0,c.Box and c.Box.size.Z or 0,#(w._nav.byCell[idx] or {}))) end
print("-- links with fewer than 2 touching cells")
for i,l in ipairs(w.Links) do if #(l.Cells or {})<2 then
  local c=l.Center or l.Box and l.Box.center
  print(("link %d name=%s cells=%s path=%s center=(%.0f,%.0f,%.0f) size=%s"):format(i,tostring(l.Name),table.concat(l.Cells or {},","),tostring(l.Path),c and c.X or 0,c and c.Y or 0,c and c.Z or 0, l.Box and ("%.0f,%.0f,%.0f"):format(l.Box.size.X,l.Box.size.Y,l.Box.size.Z) or "?")) end end
