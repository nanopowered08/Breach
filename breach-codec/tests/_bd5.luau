--!nocheck
local Codec=require("../BreachCodec") local Zstd=require("../BreachZstd") local Mission=require("../BreachMission") local V=require("../BreachValidator") local World=require("../BreachWorld")
local P=require("./_embedded")
local m=Mission.build(Codec.decode(P["thepeacemaker.txt"],{zstdDecompress=Zstd.decompress}),{validator=V}) local w=World.build(m)
local nodeCount={} for _,c in ipairs(w.Cells) do nodeCount[c.Index]=#(w._nav.byCell[c.Index] or {}) end
local byPair={} local total=0
local function find(n,name) for _,c in ipairs(n.Children) do if c.Name:lower()==name:lower() then return c end local r=find(c,name) if r then return r end end end
local nf=m:folder("Nodes")
local function walk(x) if x.ClassName=="BoolValue" and x.Path:find("/Bots/",1,true) and x.Attrs.Nodes then
  for name in tostring(x.Attrs.Nodes):gmatch("%S+") do local f=find(nf,name) if f then local pts={} local function col(n) for _,c in ipairs(n.Children) do if c.ClassName=="Part" and c.Props and c.Props.CFrame then pts[#pts+1]=c.Props.CFrame.Position elseif c.ClassName=="Folder" then col(c) end end end col(f)
    for i=1,#pts do local a,b=pts[i],pts[i%#pts+1] if a~=b and not w:findPath(a,b) then
      local ca,cb=w:cellAt(a.X,a.Y,a.Z),w:cellAt(b.X,b.Y,b.Z)
      local key=(ca and ca.Index or "?")..">"..(cb and cb.Index or "?")
      local any=ca and cb and w:route(ca,cb) ~= nil
      byPair[key]=byPair[key] or {n=0,anyLinkRoute=any,dy=math.abs(a.Y-b.Y),nodesA=ca and nodeCount[ca.Index],nodesB=cb and nodeCount[cb.Index],route=name}
      byPair[key].n+=1 total+=1 end end end end end
  for _,c in ipairs(x.Children) do walk(c) end end walk(m.Root)
local arr={} for k,v in pairs(byPair) do arr[#arr+1]={k,v} end table.sort(arr,function(a,b) return a[2].n>b[2].n end)
print("unpathable legs:",total,"distinct cell pairs:",#arr)
for i=1,math.min(#arr,10) do local k,v=arr[i][1],arr[i][2] print(("  cells %-8s legs=%-3d any-link-route=%-5s |dy|=%5.1f nodes(a,b)=%s,%s route=%s"):format(k,v.n,tostring(v.anyLinkRoute),v.dy,tostring(v.nodesA),tostring(v.nodesB),v.route)) end
local nolink=0 for _,v in ipairs(arr) do if not v[2].anyLinkRoute then nolink+=v[2].n end end print("legs whose cells are not connected even by ANY link:",nolink)
-- link stats
local pathLinks,anyLinks=0,0 for _,l in ipairs(w.Links) do anyLinks+=1 if l.Path==true then pathLinks+=1 end end print("links:",anyLinks,"with Path attr:",pathLinks)
