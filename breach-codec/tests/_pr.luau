--!nocheck
local Codec=require("../BreachCodec") local Zstd=require("../BreachZstd") local Mission=require("../BreachMission") local V=require("../BreachValidator")
local E=require("./_embedded") local P=require("./_embedded_project")
local maps={{"Dip",E,"TheDiplomat.base64"},{"Pea",E,"thepeacemaker.txt"},{"Proj",P,"theproject.txt"}}
local census={}
local sample
for _,mp in ipairs(maps) do
  local D=Codec.decode(mp[2][mp[3]],{zstdDecompress=Zstd.decompress}) local m=Mission.build(D,{validator=V})
  local props=m:folder("Props")
  local function walk(n,depth)
    if n.ClassName~="Folder" and n.ClassName~="Configuration" then
      census[n.Name]=census[n.Name] or {Dip=0,Pea=0,Proj=0,class=n.ClassName}
      census[n.Name][mp[1]]+=1
      if n.Name=="TriggerZone" and not sample then sample=n end
    end
    for _,c in ipairs(n.Children) do walk(c,depth+1) end end
  if props then walk(props,0) end
end
local arr={} for k,v in pairs(census) do arr[#arr+1]={k,v.Dip+v.Pea+v.Proj,v} end table.sort(arr,function(a,b) return a[2]>b[2] end)
print("distinct prop names:",#arr)
for i=1,45 do local a=arr[i] if a then print(("%-34s %5d   dip %-4d pea %-4d proj %-4d [%s]"):format(a[1],a[2],a[3].Dip,a[3].Pea,a[3].Proj,a[3].class)) end end
print("---- one TriggerZone node: all fields")
for k,v in pairs(sample) do if k~="Children" and k~="Parent" then print("  ",k,type(v)=="table" and "{table}" or tostring(v)) end end
for k,v in pairs(sample.Props or sample.Properties or {}) do print("   prop",k,tostring(v):sub(1,80)) end
local ps={} for k,v in pairs(sample.Attrs) do ps[#ps+1]=k.."="..tostring(v):sub(1,50) end table.sort(ps) print("   attrs:",table.concat(ps," | "))
