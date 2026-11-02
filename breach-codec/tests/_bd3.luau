--!nocheck
local Codec=require("../BreachCodec") local Zstd=require("../BreachZstd") local Mission=require("../BreachMission") local V=require("../BreachValidator") local World=require("../BreachWorld") local CF=require("../BreachCFrame")
local E=require("./_embedded") local P=require("./_embedded_project")
local function frame(node) local p=node.Props.CFrame local pos,e=p.Position,p.EulerXYZ local f=CF.angles(e.X,e.Y,e.Z) f[1],f[2],f[3]=pos.X,pos.Y,pos.Z return f end
local function apply(f,x,y,z) return f[1]+f[4]*x+f[5]*y+f[6]*z, f[2]+f[7]*x+f[8]*y+f[9]*z, f[3]+f[10]*x+f[11]*y+f[12]*z end
for _,mp in ipairs({{"Dip",E,"TheDiplomat.base64"},{"Pea",E,"thepeacemaker.txt"},{"Proj",P,"theproject.txt"}}) do
  local m=Mission.build(Codec.decode(mp[2][mp[3]],{zstdDecompress=Zstd.decompress}),{validator=V}) local w=World.build(m)
  local nodes=w._nav.nodes
  local function nearest(x,y,z) local best,bi=1e9,nil for i,n in ipairs(nodes) do local d=math.sqrt((n.X-x)^2+(n.Y-y)^2+(n.Z-z)^2) if d<best then best,bi=d,i end end return best,bi end
  local props=m:folder("Props")
  local directDoors,nestedDoors={}, {}
  local function isDoor(n) return n.Name:match("^Door%u") or n.Name=="Door" or n.Name:match("%uDoor$") or n.Name=="GarageDoor" end
  for _,ch in ipairs(props.Children) do if ch.ClassName=="Part" and isDoor(ch) and ch.Props and ch.Props.CFrame then directDoors[#directDoors+1]=ch end end
  local function walk(x,depth) for _,ch in ipairs(x.Children) do if ch.ClassName=="Part" and isDoor(ch) and depth>0 and ch.Props and ch.Props.CFrame then nestedDoors[#nestedDoors+1]=ch end walk(ch,depth+1) end end walk(props,0)
  local function test(list,label)
    local hit01,hit05,hit2,n=0,0,0,0 local crossCell,crossNeeds=0,0
    for _,d in ipairs(list) do local f=frame(d)
      local ax,ay,az=apply(f,0,-3,4.5) local bx,by,bz=apply(f,0,-3,-4.5)
      local da,ia=nearest(ax,ay,az) local db,ib=nearest(bx,by,bz) n+=2
      for _,dd in ipairs({da,db}) do if dd<=0.1 then hit01+=1 end if dd<=0.5 then hit05+=1 end if dd<=2 then hit2+=1 end end
      if da<=0.5 and db<=0.5 and nodes[ia].cell~=nodes[ib].cell then crossCell+=1 end
    end
    print(("  %-14s doors=%d  expected-node hits: <=0.1: %d/%d  <=0.5: %d/%d  <=2: %d/%d | door pairs whose two nodes are in DIFFERENT cells: %d"):format(label,#list,hit01,n,hit05,n,hit2,n,crossCell))
  end
  print("=====",mp[1],"nav nodes",#nodes)
  test(directDoors,"direct Props") test(nestedDoors,"nested Props")
end
