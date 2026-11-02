--!nocheck
local Codec=require("../BreachCodec") local Zstd=require("../BreachZstd") local Mission=require("../BreachMission") local V=require("../BreachValidator")
local D=Codec.decode(require("./_embedded_project")["theproject.txt"],{zstdDecompress=Zstd.decompress}) local m=Mission.build(D,{validator=V})
local function dump(t,ind) ind=ind or "" for k,v in pairs(t) do if type(v)=="table" then local n=0 for _ in pairs(v) do n+=1 end print(ind..tostring(k).." {table, "..n.." entries}") if n<=12 then dump(v,ind.."   ") end else print(ind..tostring(k).."="..tostring(v)) end end end
local found
local function walk(n) if not found and n.Name=="TriggerZone" and n.Attrs.Tag=="StealthExit" then found=n end for _,c in ipairs(n.Children) do walk(c) end end walk(m.Root)
if found then print(found.Path) local ps={} for k,v in pairs(found.Attrs) do ps[#ps+1]=k.."="..tostring(v):sub(1,60) end table.sort(ps) print(table.concat(ps," | ")) print("CFrame:") dump(found.Props.CFrame,"  ") print("Size:") dump(found.Props.Size,"  ") end
