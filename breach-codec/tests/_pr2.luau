--!nocheck
local Codec=require("../BreachCodec") local Zstd=require("../BreachZstd") local Mission=require("../BreachMission") local V=require("../BreachValidator")
local E=require("./_embedded") local P=require("./_embedded_project")
local maps={{E,"TheDiplomat.base64"},{E,"thepeacemaker.txt"},{P,"theproject.txt"}}
local want={TriggerZone=1,TriggerRoom=1,FreeTrigger=1,ItemSpawn=1,MissionEndZone=1,ItemDeposit=1,DoorMetal=1,DoorWood=1,CardReader=1,KeypadDoor=1}
local stat={}
for _,mp in ipairs(maps) do
  local D=Codec.decode(mp[1][mp[2]],{zstdDecompress=Zstd.decompress}) local m=Mission.build(D,{validator=V})
  local function walk(n)
    if want[n.Name] and n.ClassName=="Part" then
      local s=stat[n.Name] or {n=0,attrs={}} stat[n.Name]=s s.n+=1
      local defaults=V.defaultsFor(n.Name) or {}
      for k,v in pairs(n.Attrs) do
        local d=defaults[k]
        if v~="" and v~=false and v~=d then local a=s.attrs[k] or {c=0,ex={}} s.attrs[k]=a a.c+=1 local sv=tostring(v):sub(1,48) if #a.ex<2 and not a.seen then end a.ex[sv]=(a.ex[sv] or 0)+1 end
      end
    end
    for _,c in ipairs(n.Children) do walk(c) end end
  walk(m.Root)
end
for name,s in pairs(stat) do
  local keys={} for k in pairs(s.attrs) do keys[#keys+1]=k end table.sort(keys,function(a,b) return s.attrs[a].c>s.attrs[b].c end)
  print(("== %s  (%d placed)"):format(name,s.n))
  for i=1,math.min(#keys,12) do local k=keys[i] local a=s.attrs[k] local ex={} for sv in pairs(a.ex) do ex[#ex+1]=sv end table.sort(ex) print(("   %-26s x%-4d %s"):format(k,a.c,table.concat(ex," ; "):sub(1,110))) end
end
