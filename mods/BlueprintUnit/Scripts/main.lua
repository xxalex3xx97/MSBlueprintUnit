-- BlueprintUnit: Blueprint Unit window (bpu_window.lua) on MSCore. F / ESC = close (ESC closes the import modal first).
-- Needs MSCore >= 0.7.6 (Lua api 3 + native api 4). Opened by post-hooks on WidgetSubsystem:ToggleWindow, WidgetSubsystem:ShowWindow
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
require("bpu_live").mscore = MSCore  -- station blocks/machines via factory_native.read_station (0.7.2)

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
local hookPause   -- defined with the ESC pause handling below; retried on every window open until it registers

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
        if hookPause then pcall(hookPause) end   -- no-op once registered
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

-- ESC close -> the same key press reaches the game's IA_Escape and opens the pause menu.
-- Main path: poll for WBP_PauseMenu_C at 50, 150, 300 ms after our ESC close (the class may not be loaded at startup, so
-- no hook is relied on). Extra path: SetupWidget post-hook, registered at startup or on the next window open.
-- esc = { t = clock of our ESC close, done = true once the pause menu was closed }; nil = no ESC pending.
local PAUSE_CLS = "/Game/Blueprints/Widgets/Menus/WBP_PauseMenu.WBP_PauseMenu_C"
local PAUSE_POLL_MS = { 50, 150, 300 }
local pauseHooked = false
local esc = nil

local LIB = "/Script/UMG.Default__WidgetBlueprintLibrary"

-- explicit input restore (as MSCore.wbp.close teardown). Skipped while a pause menu is still on screen.
local function restoreInput(label)
  local pm = FindFirstOf("WBP_PauseMenu_C")
  if ok(pm) then
    local s, inV = pcall(function() return pm:IsInViewport() end)
    if not s or inV == true then print(TAG .. "input restore skipped (" .. label .. "): pause menu still open\n") return end
  end
  local pc = FindFirstOf("DMSPlayerController")
  if not ok(pc) then print(TAG .. "input restore skipped (" .. label .. "): controller invalid\n") return end
  local r = {}
  local function step(name, f)
    local s, e = pcall(f)
    r[#r + 1] = name .. "=" .. (s and "ok" or ("err " .. tostring(e)))
  end
  step("look", function() pc:SetIgnoreLookInput(false) end)
  step("move", function() pc:SetIgnoreMoveInput(false) end)
  step("mouse", function() pc.bShowMouseCursor = false end)
  step("gameOnly", function() StaticFindObject(LIB):SetInputMode_GameOnly(pc, false) end)
  -- movement gate: only when readable and currently false
  local okR, cie = pcall(function() return pc.CharacterInputEnabled end)
  if okR and cie == false then
    step("charInput", function() pc.CharacterInputEnabled = true end)
  else
    r[#r + 1] = "charInput=" .. (okR and tostring(cie) or "unreadable")
  end
  local okP, paused = pcall(function() return pc:IsPaused() end)
  print(TAG .. "input restore (" .. label .. "): " .. table.concat(r, " ") .. " paused=" .. tostring(okP and paused or "n/a") .. "\n")
end

-- game's own close first (CloseWidgetOrPause = second ESC press: closes the tracked window or pause menu, restores input).
-- Fallback only when that call is missing/errors: pause widget CloseSelf, then HideWidget. Input restore 150 ms later.
local function closePause(w, label)
  local pc = FindFirstOf("DMSPlayerController")
  local how, why = nil, nil
  if ok(pc) then
    local s, e = pcall(function() pc:CloseWidgetOrPause() end)
    if s then how = "CloseWidgetOrPause" else why = "CloseWidgetOrPause err=" .. tostring(e) end
  else
    why = "controller invalid"
  end
  if not how then
    if not ok(w) then print(TAG .. "pause menu close: widget invalid (" .. label .. ") " .. tostring(why) .. "\n") return false end
    local s, e = pcall(function() w:CloseSelf() end)
    if s then
      how = "CloseSelf"
    else
      why = tostring(why) .. " CloseSelf err=" .. tostring(e)
      if ok(pc) then
        local s2, e2 = pcall(function() pc:HideWidget(w, false) end)
        if s2 then how = "HideWidget" else why = why .. " HideWidget err=" .. tostring(e2) end
      end
    end
  end
  print(TAG .. "pause menu closed (" .. label .. ") via " .. tostring(how or "FAILED") .. (how and "" or (" " .. tostring(why))) .. "\n")
  if not how then return false end
  ExecuteWithDelay(150, function() ExecuteInGameThread(function() pcall(restoreInput, label) end) end)
  return true
end

-- game thread. Closes the pause menu when it is found on screen. true = handled.
local function pausePoll(label)
  local w = FindFirstOf("WBP_PauseMenu_C")
  if not ok(w) then return false end
  local okV, inV = pcall(function() return w:IsInViewport() end)
  if okV and inV ~= true then return false end   -- object exists but is not on screen
  if not okV then print(TAG .. "pause poll: IsInViewport unavailable, closing anyway\n") end
  return closePause(w, label)
end

local function escPending(e) return esc == e and not e.done end

local function schedulePausePoll()
  local e = { t = os.clock(), done = false }
  esc = e
  for _, ms in ipairs(PAUSE_POLL_MS) do
    ExecuteWithDelay(ms, function()
      ExecuteInGameThread(function()
        pcall(function()
          if not escPending(e) then return end
          if pausePoll("poll " .. ms .. " ms") then e.done = true end
          if ms == PAUSE_POLL_MS[#PAUSE_POLL_MS] and not e.done then print(TAG .. "pause menu: not on screen within 300 ms of ESC\n") end
        end)
      end)
    end)
  end
  return e
end

local function onPause(self)
  if not esc or esc.done or os.clock() - esc.t >= 0.3 then return end
  esc.done = true
  local w = unw(self)
  ExecuteInGameThread(function() pcall(closePause, w, "hook") end)
end

function hookPause()
  if pauseHooked then return true end
  local s, pre, post = pcall(RegisterHook, PAUSE_CLS .. ":SetupWidget", function() end, function(self) pcall(onPause, self) end)
  if s then pauseHooked = true end
  print(TAG .. "hook pause menu " .. (s and ("registered ids=" .. tostring(pre) .. "," .. tostring(post)) or "FAILED") .. " path=" .. PAUSE_CLS .. "\n")
  return s
end
if not hookPause() then
  -- class not loaded yet: retry when a pause menu object is created (full path, then short name)
  for _, n in ipairs({ PAUSE_CLS, "WBP_PauseMenu_C" }) do
    local sN = pcall(NotifyOnNewObject, n, function() pcall(ExecuteInGameThread, hookPause) end)
    print(TAG .. "pause menu NotifyOnNewObject " .. n .. (sN and " armed" or " FAILED") .. "\n")
  end
end

-- keys: all do nothing while our window is closed
pcall(function()
  RegisterKeyBind(Key.ESCAPE, function()
    pcall(function()
      if BPU.impOpen() or BPU.isOpen() then require("bpu_live").trace("ESC: " .. (BPU.impOpen() and "import modal" or "window")) end
      if BPU.impOpen() then schedulePausePoll(); pcall(ExecuteInGameThread, BPU.impClose)
      elseif BPU.isOpen() then schedulePausePoll(); pcall(ExecuteInGameThread, BPU.close) end
    end)
  end)
end)
pcall(function()
  RegisterKeyBind(Key.F, function()
    pcall(function()
      if BPU.isOpen() then pcall(ExecuteInGameThread, BPU.fKey) end
    end)
  end)
end)
-- crate hide, world scan: every 3 s, on the game thread (BPU.loopGT). Only crate sims (BP_BPUnitStoreObj_01_C) cost anything; done ones are cached.
pcall(BPU.loopGT, 3000, function() pcall(BPU.hideCrates, nil); return false end)
