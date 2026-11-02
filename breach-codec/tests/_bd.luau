--!nocheck
local Codec=require("../BreachCodec") local Zstd=require("../BreachZstd") local Mission=require("../BreachMission") local V=require("../BreachValidator") local World=require("../BreachWorld") local Nav=require("../BreachNav") local Logic=require("../BreachLogic") local Bots=require("../BreachBots")
local E=require("./_embedded") local P=require("./_embedded_project")
for _,mp in ipairs({{"Dip",E,"TheDiplomat.base64"},{"Pea",E,"thepeacemaker.txt"},{"Proj",P,"theproject.txt"}}) do
  local m=Mission.build(Codec.decode(mp[2][mp[3]],{zstdDecompress=Zstd.decompress}),{validator=V}) local w=World.build(m)
  print("=======",mp[1])
  -- 1. which BoolValues under Bots/ are not instantiated
  local l=Logic.new(m,{seed=1}) local nav=Nav.new({pathfinder=Nav.worldAdapter(w)}) local bots=Bots.new(m,w,l,nav,{seed=1})
  local made={} for _,b in ipairs(bots:all()) do made[b.Id]=true end
  local ex={}
  local function walk(x,chain) local c2=chain
    if x.ClassName=="Folder" then c2=chain.."/"..x.Name..(x.Attrs and x.Attrs.Condition and x.Attrs.Condition~="" and "[cond:"..tostring(x.Attrs.Condition):sub(1,30).."]" or "") end
    if x.ClassName=="BoolValue" and x.Path:find("/Bots/",1,true) and not made[x.Id] then ex[#ex+1]=c2.." :: "..x.Name.." behavior="..tostring(x.Attrs.Behavior).." nodes="..tostring(x.Attrs.Nodes) end
    for _,ch in ipairs(x.Children) do walk(ch,c2) end end
  walk(m.Root,"")
  for i=1,math.min(#ex,5) do print("  not made:",ex[i]) end print("  total not made:",#ex,"skipped:",#bots.Skipped)
  for i=1,math.min(#bots.Skipped,2) do print("  skip:",bots.Skipped[i].Reason) end
  -- 3. path failures on real consecutive route nodes
  local ok,fail,nearFar,total=0,0,0,0
  local reasons={}
  for _,b in ipairs(bots:all()) do local r=b.Route for i=1,#r do local a,c=r[i],r[i%#r+1]
      if a~=c then total+=1
        local res,why=w:findPath({X=a.X,Y=a.Y,Z=a.Z},{X=c.X,Y=c.Y,Z=c.Z})
        if res then ok+=1 else fail+=1 reasons[tostring(why)]=(reasons[tostring(why)] or 0)+1 end end end end
  print("  consecutive route legs:",total,"pathable:",ok,"not:",fail)
  for k,v in pairs(reasons) do print("    reason:",k,v) end
  -- distance from route nodes to nearest nav node, and whether inside a cell
  local nodes=w._nav.nodes local far,incell,nn=0,0,0
  for _,b in ipairs(bots:all()) do for _,n in ipairs(b.Route) do nn+=1 local best=1e9 for _,q in ipairs(nodes) do local d=math.sqrt((q.X-n.X)^2+(q.Y-n.Y)^2+(q.Z-n.Z)^2) if d<best then best=d end end if best>12 then far+=1 end if w:cellAt(n.X,n.Y,n.Z) then incell+=1 end end end
  print("  route nodes:",nn,"farther than 12 studs from any nav node:",far,"inside some cell:",incell)
end
