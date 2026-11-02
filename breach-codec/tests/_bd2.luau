--!nocheck
local Codec=require("../BreachCodec") local Zstd=require("../BreachZstd") local Mission=require("../BreachMission") local V=require("../BreachValidator") local World=require("../BreachWorld") local Nav=require("../BreachNav") local Logic=require("../BreachLogic") local Bots=require("../BreachBots")
local E=require("./_embedded") local P=require("./_embedded_project")
for _,mp in ipairs({{"Dip",E,"TheDiplomat.base64"},{"Pea",E,"thepeacemaker.txt"},{"Proj",P,"theproject.txt"}}) do
  local m=Mission.build(Codec.decode(mp[2][mp[3]],{zstdDecompress=Zstd.decompress}),{validator=V}) local w=World.build(m)
  local l=Logic.new(m,{seed=1,builtins={Mission_Difficulty=3}}) local nav=Nav.new({pathfinder=Nav.worldAdapter(w)}) local bots=Bots.new(m,w,l,nav,{seed=1})
  local cause={sameCell=0, cellsNoLinkRoute=0, cellsLinkRouteButNavSplit=0, emptyCell=0, ok=0}
  local examples={}
  local nodeCount={} for _,c in ipairs(w.Cells) do nodeCount[c.Index]=#(w._nav.byCell[c.Index] or {}) end
  for _,b in ipairs(bots:all()) do local r=b.Route for i=1,#r do local a,c=r[i],r[i%#r+1] if a~=c then
    local res=w:findPath({X=a.X,Y=a.Y,Z=a.Z},{X=c.X,Y=c.Y,Z=c.Z})
    if res then cause.ok+=1 else
      local ca,cb=w:cellAt(a.X,a.Y,a.Z),w:cellAt(c.X,c.Y,c.Z)
      if not ca or not cb then cause.emptyCell+=1
      elseif ca==cb then cause.sameCell+=1 if #examples<2 then examples[#examples+1]=("same cell #%d (%d nodes): %s leg %d"):format(ca.Index,nodeCount[ca.Index],b.Attrs.Nodes,i) end
      elseif nodeCount[ca.Index]==0 or nodeCount[cb.Index]==0 then cause.emptyCell+=1
      else
        local rt=w:route(ca,cb,{path=true})
        if not rt then cause.cellsNoLinkRoute+=1 else cause.cellsLinkRouteButNavSplit+=1 if #examples<5 then examples[#examples+1]=("cells #%d->#%d have a %d-hop Path-link route but no nav path (%s leg %d)"):format(ca.Index,cb.Index,#rt-1,b.Attrs.Nodes,i) end end
      end end end end end
  print(mp[1],"ok",cause.ok,"| same cell (nav split inside a cell):",cause.sameCell,"| a cell has no nav nodes / no cell:",cause.emptyCell,"| cells not connected by Path links:",cause.cellsNoLinkRoute,"| connected by links but nav graph split:",cause.cellsLinkRouteButNavSplit)
  for _,e in ipairs(examples) do print("    ",e) end
  local d=w.Diagnostics print("   nav nodes",d.navNodes,"intra",d.navEdgesIntra,"inter",d.navEdgesInter,"components",d.navComponents,"suspect",d.navSuspectCells)
end
