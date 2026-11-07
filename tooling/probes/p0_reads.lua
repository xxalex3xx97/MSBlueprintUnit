-- P0 read gate probe. DEV ONLY, read-only, NEVER shipped in the release.
-- Install as a temp UE4SS mod: Mods\BlueprintUnitP0\Scripts\main.lua (+ empty enabled.txt). See tooling/probes/README.md.
-- Press F6 in game. Output: "P0 ..." lines in the UE4SS console and Scripts\P0Result.txt.
-- Only getters, FindAllOf/FindFirstOf, ForEach and IsValid are called. No writes, no commands sent.

local SRC = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
SRC = SRC:gsub("\\", "/")
local OUT = SRC .. "P0Result.txt"
local CAP = 5
local buf = {}
local S = {}

local function L(s)
  buf[#buf + 1] = "P0 " .. s
  print("P0 " .. s)
end

local function ok(o)
  if type(o) ~= "userdata" then return false end
  local s, v = pcall(function() return o:IsValid() end)
  return s and v == true
end
local function fn(o)
  local s, v = pcall(function() return o:GetFName():ToString() end)
  return s and v or "?"
end
local function cls(o)
  local s, v = pcall(function() return o:GetClass():GetFName():ToString() end)
  return s and v or "?"
end
local function objName(v)
  if ok(v) then return fn(v) end
  return "nil"
end
local function txt(v)
  if v == nil then return "nil" end
  if type(v) == "userdata" then
    local s, t = pcall(function() return v:ToString() end)
    return s and t or "<ud>"
  end
  return tostring(v)
end
local function unw(x)
  if type(x) == "userdata" then
    local s, r = pcall(function() return x:get() end)
    if s and r ~= nil then return r end
  end
  return x
end
-- property read, dot style (obj.Prop). nil on error or missing.
local function rd(o, p)
  if o == nil then return nil end
  local s, v = pcall(function() return o[p] end)
  if s then return v end
  return nil
end
-- TArray (ForEach) or Lua table -> total count + first `cap` elements (unwrapped)
local function arr(a, cap)
  local out, n = {}, 0
  if a == nil then return out, 0 end
  if type(a) == "table" then
    for _, e in ipairs(a) do
      n = n + 1
      if #out < cap then out[#out + 1] = e end
    end
    return out, n
  end
  a:ForEach(function(_, e)
    n = n + 1
    if #out < cap then out[#out + 1] = unw(e) end
  end)
  return out, n
end
-- inventory slots: GetItemSlots() getter first, else ItemSlots property
local function slotsOf(inv)
  local okG, sa = pcall(function() return inv:GetItemSlots() end)
  if okG and sa ~= nil then return sa, "GetItemSlots()" end
  return rd(inv, "ItemSlots"), "ItemSlots"
end
local function hex(list)
  local t = {}
  for i, v in ipairs(list) do t[i] = type(v) == "number" and string.format("%02X", v) or "??" end
  return table.concat(t, " ")
end
-- Transform / GridTransform / direct struct -> x, y, h, rot, source name
local function xf(e)
  local src, t = "direct", e
  if rd(e, "Transform") ~= nil then src, t = "Transform", rd(e, "Transform")
  elseif rd(e, "GridTransform") ~= nil then src, t = "GridTransform", rd(e, "GridTransform") end
  local gl = rd(t, "GridLocation")
  return txt(rd(gl, "X")), txt(rd(gl, "Y")), txt(rd(t, "Height")), txt(rd(t, "GridRotation")), src
end
local function step(tag, f)
  local t0 = os.clock()
  local s, e = pcall(f)
  local ms = (os.clock() - t0) * 1000
  if s then L(string.format("%s TIME %.2f ms", tag, ms))
  else L(string.format("%s FAIL %.2f ms: %s", tag, ms, tostring(e))) end
end

-- R1: station Blueprint (Blocks, Machines)
local function r1a()
  local all = FindAllOf("StationObject") or {}
  S.live = {}
  for _, s in ipairs(all) do
    if ok(s) and not fn(s):find("^Default__") then S.live[#S.live + 1] = s end
  end
  L("R1a expr=FindAllOf('StationObject') live=" .. #S.live)
  for i, s in ipairs(S.live) do
    if i > CAP then break end
    L(string.format("R1a station[%d] cls=%s ID=%s", i, cls(s), txt(rd(s, "ID"))))
  end
  -- pick: first station with Blueprint.Blocks, BP_StationObject_C preferred (C++ pp_scan_fn)
  S.pick = nil
  for _, s in ipairs(S.live) do
    local okB, bl = pcall(function() return s.Blueprint.Blocks end)
    local n = 0
    if okB then local _, c = arr(bl, 0); n = c end
    if n > 0 and (S.pick == nil or (cls(s) == "BP_StationObject_C" and cls(S.pick) ~= "BP_StationObject_C")) then
      S.pick = s
    end
  end
  if not S.pick then error("no station with Blueprint.Blocks") end
  L(string.format("R1a pick ID=%s cls=%s expr=stations[k] first with Blueprint.Blocks, BP_StationObject_C preferred",
    txt(rd(S.pick, "ID")), cls(S.pick)))
end
local function r1b()
  if not S.pick then error("no pick") end
  local list, n = arr(S.pick.Blueprint.Blocks, CAP)
  L(string.format("R1b OK expr=st.Blueprint.Blocks count=%d", n))
  for i, e in ipairs(list) do
    local x, y, h, rot, src = xf(e)
    L(string.format("R1b block[%d] cls=%s x=%s y=%s h=%s rot=%s via=%s", i, objName(rd(e, "Class")), x, y, h, rot, src))
  end
end
local function dumpMachines(tag, expr, marr)
  local list, n = arr(marr, CAP)
  L(string.format("%s OK expr=%s count=%d", tag, expr, n))
  for i, e in ipairs(list) do
    local x, y, h, rot, src = xf(e)
    local mid = rd(e, "MachineID")
    if mid == nil then mid = rd(e, "ID") end
    local cfg, nb = arr(rd(e, "SerializedMachineConfig"), 16)
    L(string.format("%s machine[%d] cls=%s x=%s y=%s h=%s rot=%s via=%s id=%s cfgBytes=%d hex16=%s",
      tag, i, objName(rd(e, "Class")), x, y, h, rot, src, txt(mid), nb, hex(cfg)))
  end
end
local function r1c()
  if not S.pick then error("no pick") end
  dumpMachines("R1c", "st.Blueprint.Machines", S.pick.Blueprint.Machines)
end
local function r1d()
  if not S.pick then error("no pick") end
  local bp = S.pick:GetPropertyValue("Blueprint")
  local okM, m = pcall(function() return bp:GetPropertyValue("Machines") end)
  if okM and m ~= nil then
    dumpMachines("R1d", "st:GetPropertyValue('Blueprint'):GetPropertyValue('Machines')", m)
  else
    L("R1d GetPropertyValue chain not usable: " .. tostring(m) .. " -> trying .Machines")
    dumpMachines("R1d", "st:GetPropertyValue('Blueprint').Machines", bp.Machines)
  end
end

-- R2: Buildable.ItemCost
local TARGETS = { "DAT_ConveyorBelt", "DAT_Container_2", "DAT_Assembler", "DAT_Splitter", "DAT_Refinery" }
local function r2list()
  local all = FindAllOf("Buildable") or {}
  S.bld = {}
  local names = {}
  for _, b in ipairs(all) do
    if ok(b) and not fn(b):find("^Default__") then
      S.bld[#S.bld + 1] = b
      if #names < 10 then names[#names + 1] = fn(b) end
    end
  end
  L(string.format("R2 OK expr=FindAllOf('Buildable') count=%d first10=%s", #S.bld, table.concat(names, ", ")))
end
local function r2one(t)
  if not S.bld then error("no buildable list") end
  local hit, how
  for _, b in ipairs(S.bld) do if fn(b) == t then hit, how = b, "exact" break end end
  if not hit then
    for _, b in ipairs(S.bld) do if fn(b):find(t, 1, true) then hit, how = b, "contains" break end end
  end
  if not hit then error("not found in Buildable list") end
  local list, n = arr(hit.ItemCost, CAP)
  L(string.format("R2 %s match=%s expr=buildable.ItemCost itemCount=%d", fn(hit), how, n))
  for i, e in ipairs(list) do
    L(string.format("R2 %s cost[%d] item=%s amount=%s", t, i, objName(rd(e, "Item")), txt(rd(e, "Amount"))))
  end
end

-- R3: player inventory + ContainerObject
local function r3()
  local pl = FindFirstOf("DMSPlayerObject")
  if not ok(pl) then error("no valid DMSPlayerObject") end
  local inv = rd(pl, "Inventory")
  if not ok(inv) then error("player.Inventory not valid") end
  local slots, via = slotsOf(inv)
  local list, n = arr(slots, math.huge)
  local nonEmpty = 0
  for _, s in ipairs(list) do
    local it, amt = rd(s, "Item"), rd(s, "Amount")
    if ok(it) and type(amt) == "number" and amt > 0 then
      nonEmpty = nonEmpty + 1
      if nonEmpty <= CAP then
        L(string.format("R3 slot item=%s amount=%d maxStack=%s", fn(it), amt, txt(rd(it, "MaxStackSize"))))
      end
    end
  end
  L(string.format("R3 OK player=%s playerInvID=%s inv=%s inv.ID=%s StackMultiplier=%s expr=pl.Inventory:%s slots=%d nonEmpty=%d",
    fn(pl), txt(rd(pl, "InventoryID")), fn(inv), txt(rd(inv, "ID")), txt(rd(inv, "StackMultiplier")), via, n, nonEmpty))
end
local function r3b()
  local all = FindAllOf("ContainerObject") or {}
  local valid, unit = {}, {}
  for _, c in ipairs(all) do
    if ok(c) and not fn(c):find("^Default__") then
      valid[#valid + 1] = c
      if cls(c) == "BP_BPUnitStoreObj_01_C" then unit[#unit + 1] = c end
    end
  end
  local pick = #unit > 0 and unit or valid
  L(string.format("R3b ContainerObject total=%d BP_BPUnitStoreObj_01_C=%d showing=%s",
    #valid, #unit, #unit > 0 and "unit store" or "any"))
  for i, c in ipairs(pick) do
    if i > CAP then break end
    local inv = rd(c, "Inventory")
    local _, ns = arr((slotsOf(inv)), math.huge)
    L(string.format("R3b container[%d] cls=%s ID=%s ParentID=%s inv.ID=%s slots=%d StackMultiplier=%s",
      i, cls(c), txt(rd(c, "ID")), txt(rd(c, "ParentID")), txt(rd(inv, "ID")), ns, txt(rd(inv, "StackMultiplier"))))
  end
end

-- R4: MSCore surface (no command sent)
local function r4()
  local okR, M = pcall(require, "mscore")
  local how = "require('mscore')"
  if not (okR and type(M) == "table") then
    local p = SRC .. "../../MSCore/Scripts/mscore.lua"
    local okD, M2 = pcall(dofile, p)
    if not (okD and type(M2) == "table") then
      error("require failed: " .. tostring(M) .. " | dofile failed: " .. tostring(M2))
    end
    M, how = M2, "dofile(" .. p .. ")"
  end
  L(string.format("R4 OK via %s api=%s version=%s verified_build=%s", how, txt(M.api), txt(M.version), txt(M.verified_build)))
  local nat = M.native
  L(string.format("R4 native=%s send_cmd=%s view_send=%s", type(nat),
    type(nat) == "table" and type(nat.send_cmd) or "-", type(nat) == "table" and type(nat.view_send) or "-"))
  for _, k in ipairs({ "cmd", "inv", "factory", "factory_native" }) do
    L("R4 MSCore." .. k .. "=" .. type(M[k]))
  end
  L("R4 MSCore.cmd.send=" .. type(M.cmd and M.cmd.send) .. " MSCore.cmd.send_typed=" .. type(M.cmd and M.cmd.send_typed))
end

-- R5: Recipe names
local function r5()
  local all = FindAllOf("Recipe") or {}
  local valid = {}
  for _, r in ipairs(all) do
    if ok(r) and not fn(r):find("^Default__") then valid[#valid + 1] = r end
  end
  L(string.format("R5 OK expr=FindAllOf('Recipe') count=%d", #valid))
  for i, r in ipairs(valid) do
    if i > CAP then break end
    L(string.format("R5 recipe[%d] GetFName=%s Name=%s", i, fn(r), txt(rd(r, "Name"))))
  end
end

local function save()
  local f, err = io.open(OUT, "w")
  if not f then print("P0 FILE FAIL " .. OUT .. " " .. tostring(err)); return end
  f:write(table.concat(buf, "\n"), "\n")
  f:close()
  print("P0 wrote " .. OUT)
end

local function run()
  buf, S = {}, {}
  local t0 = os.clock()
  L("=== P0 run " .. os.date("%Y-%m-%d %H:%M:%S") .. " read-only")
  step("R1a", r1a)
  step("R1b", r1b)
  step("R1c", r1c)
  step("R1d", r1d)
  step("R2 list", r2list)
  for _, t in ipairs(TARGETS) do step("R2 " .. t, function() r2one(t) end) end
  step("R3", r3)
  step("R3b", r3b)
  step("R4", r4)
  step("R5", r5)
  L(string.format("R6 TIME total %.2f ms", (os.clock() - t0) * 1000))
  save()
end

if RegisterKeyBind and Key then
  RegisterKeyBind(Key.F6, function()
    ExecuteInGameThread(function()
      local s, e = pcall(run)
      if not s then
        L("FATAL " .. tostring(e))
        save()
      end
    end)
  end)
  print("P0 probe loaded. Press F6 in game. Output: " .. OUT)
else
  print("P0 probe: RegisterKeyBind/Key missing, nothing registered")
end
