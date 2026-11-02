--!nocheck
local Codec=require("../BreachCodec") local Zstd=require("../BreachZstd") local Mission=require("../BreachMission") local V=require("../BreachValidator") local World=require("../BreachWorld") local Setup=require("../BreachSetup") local Logic=require("../BreachLogic") local Trespass=require("../BreachTrespass")
local E=require("./_embedded") local P=require("./_embedded_project")
for _,mp in ipairs({{"Dip",E,"TheDiplomat.base64"},{"Pea",E,"thepeacemaker.txt"},{"Proj",P,"theproject.txt"}}) do
  local d=Codec.decode(mp[2][mp[3]],{zstdDecompress=Zstd.decompress}) local m=Mission.build(d,{validator=V}) local w=World.build(m) local t=Setup.parse(d.SetupSource)
  local l=Logic.new(m,{seed=1}) local tr=Trespass.new(w,t,l)
  local unresolved,dynamic,minorOnly,total=0,0,0,0
  for _,c in ipairs(w.Cells) do total+=1 local name,rules=tr:rulesFor(c) if not rules then unresolved+=1 end if type(t.Cells[c.Node.Name])=="string" then dynamic+=1 end end
  for k,v in pairs(t.Cells) do if type(v)=="table" and v.MinorTrespass and not v.Trespass then minorOnly+=1 end end
  print(mp[1],"cells",total,"resolve to rules:",total-unresolved,"dynamic-rule cells:",dynamic,"| rule sets with MinorTrespass but no Trespass:",minorOnly,"| errors:",#tr.Errors)
  -- the server room, per disguise, before and after the keycard
  for name,v in pairs(t.Cells) do if type(v)=="string" and name:lower():find("server") then print("   dynamic rule",name,"=",v) end end
  for _,nm in ipairs({"ServerRoom","ServerRoomAwesome","ServerRoomEvil"}) do local rs=t.Cells[nm] if rs then local o={} for _,dg in ipairs({"None","Workshop","Technician","ProSecurity","Chef"}) do o[#o+1]=dg.."="..tr:status(dg,nm) end print("   ",nm,type(rs)=="table" and "table" or "dynamic",table.concat(o," ")) end end
end
