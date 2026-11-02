--!nocheck
local Codec=require("../BreachCodec") local Zstd=require("../BreachZstd") local Mission=require("../BreachMission") local V=require("../BreachValidator") local World=require("../BreachWorld")
local E=require("./_embedded") local P=require("./_embedded_project")
local function legs(m,w,diff)
  local ok,tot=0,0
  local function walk(x) if x.ClassName=="BoolValue" and x.Path:find("/Bots/",1,true) and x.Attrs.Nodes then
      local nf=m:folder("Nodes") local function find(n,name) for _,c in ipairs(n.Children) do if c.Name:lower()==name:lower() then return c end local r=find(c,name) if r then return r end end end
      for name in tostring(x.Attrs.Nodes):gmatch("%S+") do local f=find(nf,name) if f then local pts={} local function col(n) for _,c in ipairs(n.Children) do if c.ClassName=="Part" and c.Props and c.Props.CFrame then pts[#pts+1]=c.Props.CFrame.Position elseif c.ClassName=="Folder" then col(c) end end end col(f)
        for i=1,#pts do local a,b=pts[i],pts[i%#pts+1] if a~=b then tot+=1 if w:findPath(a,b) then ok+=1 end end end end end end
    for _,c in ipairs(x.Children) do walk(c) end end
  walk(m.Root) return ok,tot end
for _,mp in ipairs({{"Dip",E,"TheDiplomat.base64"},{"Pea",E,"thepeacemaker.txt"},{"Proj",P,"theproject.txt"}}) do
  local m=Mission.build(Codec.decode(mp[2][mp[3]],{zstdDecompress=Zstd.decompress}),{validator=V})
  for _,frac in ipairs({0.5,0.3,0.15,0.05,0.001}) do
    local w=World.build(m,{minHitFraction=frac}) local ok,tot=legs(m,w) local d=w.Diagnostics
    local two=0 local one=0 for _,l in ipairs(w.Links) do if #(l.Cells or {})>=2 then two+=1 elseif #(l.Cells or {})==1 then one+=1 end end
    print(("%-5s minHit=%-5s pathable %d/%d (%.0f%%)  links touching 2+ cells: %d  nav comps %d"):format(mp[1],frac,ok,tot,100*ok/tot,two,d.navComponents))
  end
end
