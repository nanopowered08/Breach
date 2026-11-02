--!nocheck
local Codec=require("../BreachCodec") local Zstd=require("../BreachZstd") local Mission=require("../BreachMission") local V=require("../BreachValidator")
local E=require("./_embedded") local P=require("./_embedded_project")
local function inc(t,k) t[k]=(t[k] or 0)+1 end
for _,mp in ipairs({{"Dip",E,"TheDiplomat.base64"},{"Pea",E,"thepeacemaker.txt"},{"Proj",P,"theproject.txt"}}) do
  local D=Codec.decode(mp[2][mp[3]],{zstdDecompress=Zstd.decompress}) local m=Mission.build(D,{validator=V})
  print("=======",mp[1])
  -- node folders
  local nf=m:folder("Nodes") local attrN,nameStyle,childKinds={}, {}, {}
  local shown=0
  for _,route in ipairs(nf.Children) do
    local kids={} for _,c in ipairs(route.Children) do kids[#kids+1]=c end
    for _,c in ipairs(kids) do inc(childKinds,c.ClassName) for k,v in pairs(c.Attrs or {}) do inc(attrN,k) end end
    if shown<2 then shown+=1 local names={} for i,c in ipairs(kids) do if i<=8 then names[#names+1]=c.Name end end print("route",route.Name,"#"..#kids,"children:",table.concat(names,","), "route attrs:", (function() local t={} for k,v in pairs(route.Attrs or {}) do t[#t+1]=k.."="..tostring(v) end return table.concat(t," ") end)()) end
  end
  local ak={} for k,v in pairs(attrN) do ak[#ak+1]=k.."x"..v end table.sort(ak) print(" node attrs:",table.concat(ak," ")," | child classes:",(function() local t={} for k,v in pairs(childKinds) do t[#t+1]=k.."x"..v end return table.concat(t," ") end)())
  -- bots
  local cyc,brk,srch,inv,desp,stag,ctag,shared,outfit={}, {}, {}, {}, {}, {}, {}, {}, {}
  local cnt=0
  local function walk(x) if x.ClassName=="BoolValue" and x.Path:find("/Bots/",1,true) and x.Attrs then cnt+=1 local a=x.Attrs
      if a.PatrolCycleLength and a.PatrolCycleLength~="" and a.PatrolCycleLength~=0 then inc(cyc,tostring(a.PatrolCycleLength):sub(1,40)) end
      if a.NodesBreak and a.NodesBreak~="" then inc(brk,a.NodesBreak) end
      if a.SearchArea and a.SearchArea~="" then inc(srch,tostring(a.SearchArea):sub(1,30)) end
      if a.Inv and a.Inv~="" then inc(inv,tostring(a.Inv):sub(1,60)) end
      if a.DespawnCondition and a.DespawnCondition~="" then inc(desp,tostring(a.DespawnCondition):sub(1,70)) end
      if a.ServerTag and a.ServerTag~="" then inc(stag,a.ServerTag) end
      if a.Nodes and a.Nodes~="" then inc(shared,a.Nodes) end
    end for _,c in ipairs(x.Children) do walk(c) end end
  walk(m.Root)
  local function show(name,t,n) local ks={} for k,v in pairs(t) do ks[#ks+1]={k,v} end table.sort(ks,function(a,b) return a[2]>b[2] or (a[2]==b[2] and a[1]<b[1]) end) local o={} for i=1,math.min(#ks,n or 6) do o[#o+1]=ks[i][1].." x"..ks[i][2] end print("  "..name..": "..table.concat(o," ; "):sub(1,420)) end
  print(" bots:",cnt)
  show("PatrolCycleLength",cyc) show("NodesBreak",brk) show("SearchArea",srch) show("Inv",inv,5) show("DespawnCondition",desp,4) show("ServerTag",stag,6)
  local multi,single=0,0 for k,v in pairs(shared) do if v>1 then multi+=1 else single+=1 end end print("  routes shared by >1 bot:",multi," used by exactly 1:",single)
end
