--!nocheck
local Codec=require("../BreachCodec") local Zstd=require("../BreachZstd") local Setup=require("../BreachSetup")
local E=require("./_embedded") local P=require("./_embedded_project")
local function ser(v,ind) if type(v)~="table" then return tostring(v) end local ks={} for k in pairs(v) do ks[#ks+1]=k end table.sort(ks,function(a,b) return tostring(a)<tostring(b) end) local o={} for _,k in ipairs(ks) do o[#o+1]=tostring(k).."="..ser(v[k]) end return "{"..table.concat(o,", ").."}" end
for _,pair in ipairs({{"Dip",E,"TheDiplomat.base64"},{"Proj",P,"theproject.txt"}}) do
  local d=Codec.decode(pair[2][pair[3]],{zstdDecompress=Zstd.decompress}) local t=Setup.parse(d.SetupSource)
  print("=====",pair[1]) 
  local ks={} for k in pairs(t.EnforceClass) do ks[#ks+1]=k end table.sort(ks)
  for _,k in ipairs(ks) do print("  EnforceClass."..k,ser(t.EnforceClass[k])) end
  local n=0 for name,c in pairs(t.Cells) do n+=1 if n<=6 then print("  Cells."..name,ser(c):sub(1,230)) end end
  print("  CustomDisguises:",ser(t.CustomDisguises):sub(1,300))
end
