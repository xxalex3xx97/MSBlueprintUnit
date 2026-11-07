-- BlueprintUnit: Blueprint Unit window (bpu_window.lua) on MSCore. F / ESC = close (ESC closes the import modal first).
-- Needs MSCore >= 0.7.1 (Lua api 3 + native api 4). Opened by post-hooks on WidgetSubsystem:ToggleWindow, WidgetSubsystem:ShowWindow
-- and DMSPlayerController:ToggleWidget (ONLY when an arg is the block, class BPO_BlueprintUnit_C). Blocks and research come from pak100.

local TAG = "[BPUnit] "
local SRC = ((debug.getinfo(1, "S").source or ""):match("^@(.*[/\\])") or ""):gsub("\\", "/")  -- this script's dir
package.path = SRC .. "?.lua;" .. SRC .. "../../MSCore/Scripts/?.lua;" .. package.path

local V = require("bpu_version")
local okM, MSCore = pcall(require, "mscore")

local function ver(s) local t = {} for n in tostring(s):gmatch("%d+") do t[#t + 1] = tonumber(n) end return t end
local function ver_ok(have, need)
  local a, b = ver(have), ver(need)
  for i = 1, math.max(#a, #b) do
    local x, y = a[i] or 0, b[i] or 0
    if x ~= y then return x > y end
  end
  return true
end

-- nil = all good, else the reason
local function why_not()
  if not okM then return "mscore not found: " .. tostring(MSCore) end
  local okA, errA = pcall(MSCore.require, V.min_lua_api)
  if not okA then return tostring(errA) end
  if not (MSCore.native and MSCore.factory and MSCore.factory_native) then return "MSCore native part or factory module missing" end
  if not ver_ok(MSCore.version, V.min_mscore) then return "installed MSCore is " .. tostring(MSCore.version) end
  return nil
end

local reason = why_not()
if reason then
  print("[BPUnit] needs MSCore >= " .. V.min_mscore .. " (Lua api " .. V.min_lua_api .. " + native api 4): " .. reason .. "\n")
  return
end
print(TAG .. "loaded " .. V.version .. " on MSCore " .. tostring(MSCore.version) .. "\n")

local BPU = require("bpu_window")
BPU.init(MSCore)

local function ok(o) if o == nil or type(o) ~= "userdata" then return false end local s, v = pcall(function() return o:IsValid() end) return s and v == true end
local function nm(o) if not ok(o) then return "?" end local s, v = pcall(function() return o:GetFName():ToString() end) return s and v or "?" end
local function cn(o) if not ok(o) then return "?" end local s, v = pcall(function() return o:GetClass():GetFName():ToString() end) return s and v or "?" end
local function unw(x) if type(x) == "userdata" then local s, r = pcall(function() return x:get() end) if s and r ~= nil then return r end end return x end

-- opener filter: ONLY a call with a BPO_BlueprintUnit_C arg (our block) is handled. Every other opener (Command Module,
-- scanners, containers BP_BPUnitStoreObj_01_C, docks...) returns right after the class check: no hide, no close, no state, no log (unless LOG_OPENERS).
-- The container is never ours: F on the crate opens the native WBP_Container untouched. Arg a1 may be nil/invalid: never the filter.
-- true: print the arg classes of each opener once per signature (debug). Default off: other openers log nothing from us.
local LOG_OPENERS = false
local seen = {}
local function onOpen(src, self, a1, a2, a3, a4, a5)
  pcall(function()
    local args = { unw(a1), unw(a2), unw(a3), unw(a4), unw(a5) }
    local block, sig = nil, {}
    for i = 1, 5 do
      local x = args[i]
      if ok(x) then
        local c = cn(x)
        if LOG_OPENERS then sig[#sig + 1] = c end
        if not block and c == "BPO_BlueprintUnit_C" then block = x end
      end
    end
    if LOG_OPENERS then
      local key = src .. " (" .. table.concat(sig, ", ") .. ")"
      if not seen[key] then seen[key] = true; print(TAG .. "opener " .. key .. "\n") end
    end
    if not ok(block) then return end
    local player, widget
    for i = 1, 5 do
      local x = args[i]
      if ok(x) then
        local c = cn(x)
        if not player and c == "DMSPlayerObject" then player = x end
        if not widget and c:sub(-2) == "_C" and c ~= "WidgetBlueprintGeneratedClass" and nm(x):find("^WBP_") then widget = x end
      end
    end
    local ctl = (src == "DMSPlayerController:ToggleWidget") and unw(self) or nil
    print(TAG .. "open request via " .. src .. " block=" .. cn(block) .. "\n")
    ExecuteInGameThread(function()
      pcall(function()
        -- game's own widget for the block (ToggleWidget only): hide it, as the Mining Unit does
        if ok(widget) and ok(ctl) then ctl:HideWidget(widget, false) end
        BPU.open(block, ok(player) and player or nil, ctl)
      end)
    end)
  end)
end

local function hookOne(path, src)
  local s, pre, post = pcall(RegisterHook, path, function() end, function(self, a1, a2, a3, a4, a5) pcall(onOpen, src, self, a1, a2, a3, a4, a5) end)
  print(TAG .. "hook " .. src .. " " .. (s and ("registered ids=" .. tostring(pre) .. "," .. tostring(post)) or "FAILED") .. "\n")
end
hookOne("/Script/MainSequence.WidgetSubsystem:ToggleWindow", "WidgetSubsystem:ToggleWindow")
hookOne("/Script/MainSequence.WidgetSubsystem:ShowWindow", "WidgetSubsystem:ShowWindow")
hookOne("/Script/MainSequence.DMSPlayerController:ToggleWidget", "DMSPlayerController:ToggleWidget")

-- keys: all do nothing while our window is closed
pcall(function()
  RegisterKeyBind(Key.ESCAPE, function()
    pcall(function()
      if BPU.impOpen() then pcall(ExecuteInGameThread, BPU.impClose)
      elseif BPU.isOpen() then pcall(ExecuteInGameThread, BPU.close) end
    end)
  end)
end)
pcall(function()
  RegisterKeyBind(Key.F, function()
    pcall(function() if BPU.isOpen() then pcall(ExecuteInGameThread, BPU.fKey) end end)
  end)
end)
-- crate hide, world scan: every 3 s. Only crate sims (BP_BPUnitStoreObj_01_C) cost anything; done ones are cached.
pcall(LoopAsync, 3000, function()
  pcall(ExecuteInGameThread, function() pcall(BPU.hideCrates, nil) end)
  return false
end)
