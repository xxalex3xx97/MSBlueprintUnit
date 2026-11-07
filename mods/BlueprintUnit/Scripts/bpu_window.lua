-- bpu_window: Blueprint Unit window (WBP_BlueprintUnit). API: init(MSCore) / open(block, player, ctl) / close / isOpen /
-- fKey / impOpen / impClose (import modal) / hideCrates(block).
-- Window, grids and cost rows: MSCore.wbp (mscore_wbp.lua). Clicks: MSCore.ui. Items, plan and build: bpu_live, bpu_plan, bpu_build.
-- Every game call goes through pcall. Every log line gets the [BPUnit] tag.

local Live = require("bpu_live")
local Plan = require("bpu_plan")
local Build = require("bpu_build")

local M = {}
local MSCore, F, native   -- set by M.init

local function L(m) print("[BPUnit] " .. m .. "\n") end
local function ok(o) if o == nil or type(o) ~= "userdata" then return false end local s, v = pcall(function() return o:IsValid() end) return s and v == true end
local function nm(o) if not ok(o) then return "?" end local s, v = pcall(function() return o:GetFName():ToString() end) return s and v or "?" end
local function cn(o) if not ok(o) then return "?" end local s, v = pcall(function() return o:GetClass():GetFName():ToString() end) return s and v or "?" end
local function rd(o, p) local s, v = pcall(function() return o[p] end) if s then return v end return nil end
local function try(tag, f, ...) local s, r = pcall(f, ...) if not s then L("FAIL " .. tag .. ": " .. tostring(r)) end return s end

local WBP_CLS = "/Game/BlueprintUnitUI/WBP_BlueprintUnit.WBP_BlueprintUnit_C"
local COST_N = 40
-- widget names the WBP must provide (contract). Missing ones are logged once per open.
local CONTRACT = { "Panel", "Txt_Title", "Btn_Close", "Txt_Close", "Txt_Status", "Txt_Summary", "Txt_Notes", "Txt_Removes",
  "Btn_Import", "Txt_Import", "Btn_Build", "Txt_Build",
  "Txt_CostHdr", "Scr_Cost", "Txt_CostEmpty", "Txt_UnitInvTitle", "Scr_UnitInv", "Txt_PlayerInvTitle", "Host_PlayerInv",
  "Pnl_ImportModal", "Txt_ImportTitle", "Btn_ImportClose", "Txt_ImportClose", "Edt_ImportJson", "Txt_ImportHint",
  "Btn_ImportOk", "Txt_ImportOk", "Btn_ImportCancel", "Txt_ImportCancel" }
-- optional, never logged if missing: Btn_CostPin, Txt_CostPin, Chk_StationBuild (CheckBox), Txt_StationBuildHint.

-- S.w = WBP instance (names resolve here). S.h = MSCore.wbp handle (nil = closed). S.p = controller. S.tc = last text per name.
-- S.imp = import modal shown. S.U = unit (Live.find_unit). S.plan / S.text = last import. S.run = token of the running build.
local S = { h = nil, w = nil, p = nil, U = nil, player = nil, ctl = nil, tc = nil, imp = false,
  plan = nil, text = nil, builder = nil, io = nil, run = nil, stationBuild = false, t0 = 0 }
-- KEPT (module level, survives close/reopen): last text of the result boxes and the cost rows, re-rendered by openWindow.
-- has = an import or build ran in this session. S.plan / S.text are kept too (Build re-plans from S.text).
local KEPT = { has = false, txt = {}, rows = {} }
local KEPT_NAMES = { Txt_Status = true, Txt_Summary = true, Txt_Notes = true, Txt_Removes = true }

-- ESlateVisibility: 0 Visible, 1 Collapsed
local function setVis(o, shown) if ok(o) then try("vis", function() o:SetVisibility(shown and 0 or 1) end) end end

-- widget by name: GetWidgetFromName, then the is-variable property
local function w(name)
  if not ok(S.w) then return nil end
  local s, x = pcall(function() return S.w:GetWidgetFromName(FName(name)) end)
  if s and ok(x) then return x end
  local s2, y = pcall(function() return S.w[name] end)
  if s2 and ok(y) then return y end
  return nil
end

-- SetText(FText) on the TextBlock; unchanged writes skipped (S.tc). Never read an edit box right after this.
local function txt(name, s)
  if KEPT_NAMES[name] then KEPT.txt[name] = s end
  S.tc = S.tc or {}
  if S.tc[name] == s then return end
  local tb = w(name); if not ok(tb) then return end
  if try("SetText " .. name, function() tb:SetText(FText(s)) end) then S.tc[name] = s end
end

-- text block + its visibility (hidden when empty)
local function showText(name, s) txt(name, s); setVis(w(name), s ~= "") end

local function setEnabled(name, b) local o = w(name); if ok(o) then pcall(function() o:SetIsEnabled(b) end) end end
local function setBuildBtns(on) setEnabled("Btn_Build", on); setEnabled("Btn_Import", on) end

-- read-only count: unit + player inventory. A GetItemAmount error counts as 0.
local function haveOf(item)
  local n = 0
  local function add(inv)
    local s, v = pcall(function() return inv:GetItemAmount(item) end)
    if s and type(v) == "number" then n = n + v end
  end
  if S.U then add(S.U.unit_inv) end
  add(rd(S.player, "Inventory"))
  return n
end

-- cost list (Scr_Cost): need rows first, then refund rows, max COST_N. rows = P.cost_rows(plan).
local missLogged = {}
local function fillCost(rows)
  KEPT.rows = rows or {}
  local host = w("Scr_Cost")
  if not ok(host) then return end
  pcall(function() host:ClearChildren() end)
  local list = {}
  for _, r in ipairs(rows or {}) do if r.net > 0 then list[#list + 1] = r end end
  for _, r in ipairs(rows or {}) do if r.net < 0 then list[#list + 1] = r end end
  local shown = 0
  for _, r in ipairs(list) do
    if shown >= COST_N then break end
    local item = Live.item_by_name(r.name)
    if not item then
      if not missLogged[r.name] then missLogged[r.name] = true; L("cost item not found: " .. r.name) end
    else
      local row
      if r.net > 0 then
        row = MSCore.wbp.cost_row(host, item, r.net, haveOf(item), { pc = S.p })
      else
        row = MSCore.wbp.cost_row(host, item, -r.net, 0, { refund = true, pc = S.p })
      end
      if row then shown = shown + 1 end
    end
  end
  setVis(w("Txt_CostEmpty"), shown == 0)
end

-- Station Build placeholder: optional Chk_StationBuild (designer CheckBox). Only the hint text changes; nothing is sent.
local function readStationBuild()
  local c = w("Chk_StationBuild")
  if ok(c) then
    local s, v = pcall(function() return c:IsChecked() end)
    if not s or type(v) ~= "boolean" then s, v = pcall(function() return c:GetCheckedState() == 1 end) end
    if s and type(v) == "boolean" then S.stationBuild = v end
  end
  local h = w("Txt_StationBuildHint")
  if ok(h) then txt("Txt_StationBuildHint", S.stationBuild and "station blocks: not implemented yet" or "") end
end

-- typing in an edit box: F does not close the window then
local function typing()
  for _, e in ipairs(FindAllOf("EditableTextBox") or {}) do
    if ok(e) then local s, v = pcall(function() return e:HasKeyboardFocus() end); if s and v then return true end end
  end
  return false
end

function M.isOpen() return S.h ~= nil and ok(S.w) end

-- import modal state (Lua flag + window valid)
function M.impOpen() return S.imp == true and ok(S.w) end

-- results area: summary, removes, cost rows back to empty
local function resetResults()
  showText("Txt_Summary", "")
  showText("Txt_Notes", "")
  showText("Txt_Removes", "")
  fillCost({})
end

-- Btn_Import: open the modal, focus the box (text from the last open is kept)
local function impOpenModal()
  if not ok(S.w) or S.run then return end   -- no import while a build runs
  S.imp = true
  setVis(w("Pnl_ImportModal"), true)
  local box = w("Edt_ImportJson")
  if ok(box) then try("import focus", function() box:SetKeyboardFocus() end) end
end

-- X and ESC: close the modal, keep the text
function M.impClose()
  S.imp = false
  setVis(w("Pnl_ImportModal"), false)
end

-- Cancel: clear the box, close the modal
local function impCancel()
  if not M.impOpen() then return end
  local box = w("Edt_ImportJson")
  if ok(box) then try("import clear", function() box:SetText(FText("")) end) end
  M.impClose()
end

-- Btn_ImportOk: plan the pasted JSON against the live station. Error -> status, modal stays open.
local function impOk()
  if not M.impOpen() then return end
  local box = w("Edt_ImportJson")
  local sr, text = pcall(function() return box:GetText():ToString() end)
  if not ok(box) or not sr or type(text) ~= "string" then txt("Txt_Status", "error: could not read text"); return end
  if text == "" then txt("Txt_Status", "paste the blueprint JSON first"); return end
  -- GC off while the station structs are read: UE4SS crashes in luaL_traceback (dead table keys) when a collection runs mid-read
  collectgarbage("stop")
  local okRun, err = xpcall(function()
    Live.trace("impOk start")
    Live.trace("impOk text bytes=" .. #text)
    Live.trace("impOk before readStationBuild")
    readStationBuild()
    Live.trace("impOk after readStationBuild")
    local t0 = os.clock()
    local live = Live.snapshot(S.U, F)
    Live.trace(("impOk snapshot %.1f ms blocks=%d machines=%d"):format((os.clock() - t0) * 1000, #live.blocks, #live.existing))
    t0 = os.clock()
    local plan, perr = Plan.plan(text, live, F, { trace = Live.trace })
    Live.trace(("impOk plan %.1f ms ok=%s"):format((os.clock() - t0) * 1000, tostring(plan ~= nil)))
    if not plan then txt("Txt_Status", "error: " .. tostring(perr)); return end
    S.plan, S.text = plan, text
    KEPT.has = true
    txt("Txt_Status", "Blueprint: " .. (plan.name or "Ready"))
    showText("Txt_Summary", Plan.summary(plan))
    -- notes panel (right, scrollable): same text folded into "xN", no cap
    local order, count = {}, {}
    for _, n in ipairs(plan.notes or {}) do
      if not count[n] then count[n] = 0; order[#order + 1] = n end
      count[n] = count[n] + 1
    end
    local lines = {}
    for _, n in ipairs(order) do
      lines[#lines + 1] = count[n] > 1 and (n .. " x" .. count[n]) or n
    end
    showText("Txt_Notes", table.concat(lines, "\n"))
    showText("Txt_Removes", Plan.removes_text(plan))
    t0 = os.clock()
    local rows = Plan.cost_rows(plan)
    fillCost(rows)
    Live.trace(("impOk fillCost %.1f ms rows=%d"):format((os.clock() - t0) * 1000, #rows))
    M.impClose()
    Live.trace("impOk done")
  end, function(e) Live.trace("impOk ERROR " .. tostring(e) .. " | " .. (tostring(debug.traceback("", 2)):gsub("\n", " ; "))); return e end)
  collectgarbage("restart")
  if not okRun then L("import failed: " .. tostring(err)); txt("Txt_Status", "error: import failed: " .. tostring(err)) end
end

-- end of a build run: buttons back, result line, cost list re-planned from the saved text (what is still missing)
local function finishBuild(run)
  if S.run ~= run then return end
  S.run = nil
  setBuildBtns(true)
  showText("Txt_Summary", S.builder:status().text)
  KEPT.has = true
  local okR, err = pcall(function()
    local plan, perr = Plan.plan(S.text, Live.snapshot(S.U, F), F)
    if not plan then txt("Txt_Status", "error: " .. tostring(perr)); return end
    S.plan = plan
    fillCost(Plan.cost_rows(plan))
  end)
  if not okR then L("refresh after build failed: " .. tostring(err)) end
end

-- polls the builder every 300 ms on the game thread. Stops (returns true) when the run was replaced or closed.
local function buildLoop(run)
  return function()
    if S.run ~= run then return true end
    pcall(ExecuteInGameThread, function()
      pcall(function()
        if S.run ~= run then return end
        S.builder:tick(S.io.now())
        local st = S.builder:status()
        txt("Txt_Status", st.text)
        if st.state == "done" or st.state == "error" then finishBuild(run) end
      end)
    end)
    return false
  end
end

-- Btn_Build: re-plan from the saved text (station may have changed), start the builder, poll it.
local function buildClick()
  if S.run then return end
  if not S.plan then txt("Txt_Status", "import first"); return end
  readStationBuild()
  local okRun, err = pcall(function()
    local live = Live.snapshot(S.U, F)
    local plan, perr = Plan.plan(S.text, live, F)
    if not plan then txt("Txt_Status", "error: " .. tostring(perr)); return end
    S.plan = plan
    if not S.builder then   -- one builder per window open
      S.io = Live.make_io({ unit = S.U, player = S.player, ctl = S.ctl, F = F, native = native, plan_mod = Plan, buildables = live.buildables })
      S.builder = Build.new(S.io)
    end
    local started, msg = S.builder:start(plan)
    if not started then txt("Txt_Status", msg); return end
    local run = {}
    S.run = run
    setBuildBtns(false)
    txt("Txt_Status", S.builder:status().text)
    LoopAsync(300, buildLoop(run))
  end)
  if not okRun then
    L("build failed: " .. tostring(err))
    S.run = nil
    setBuildBtns(true)
    txt("Txt_Status", "error: build failed: " .. tostring(err))
  end
end

-- ---------------------------------------------------------------------------------------------
-- Crate hide. Our container = sim BP_BPUnitStoreObj_01_C, ParentID = unit block ID or frame ID.
-- Its actor = BP_Container_2_C with BPC_MachineInteraction.MachineObject == that sim (match by ID, class checked).
-- Exactly one link -> hide actor + its interaction (no collision, hidden). Anything else: log once, hide nothing.
-- ---------------------------------------------------------------------------------------------
local CRATE_SIM, CRATE_ACT = "BP_BPUnitStoreObj_01_C", "BP_Container_2_C"
local crateDone, crateLogged = {}, {}   -- crateDone[simID|actor name] = true once hidden
-- sim IDs of unit blocks and their frames (block arg optional; every BPO_BlueprintUnit_C in the world is added)
local function unitIds(block)
  local set = {}
  local function add(b)
    if not ok(b) then return end
    local id = rd(b, "ID"); if id ~= nil then set[id] = true end
    local s, fr = pcall(function() return b:GetFrame() end)
    if s and ok(fr) and rd(fr, "ID") ~= nil then set[rd(fr, "ID")] = true end
  end
  add(block)
  local s, list = pcall(FindAllOf, "BPO_BlueprintUnit_C")
  if s and type(list) == "table" then for _, b in ipairs(list) do add(b) end end
  return set
end
-- BP_Container_2_C actors whose MachineObject is this sim (ID equal, class BP_BPUnitStoreObj_01_C)
local function linkedActors(sid)
  local hits = {}
  local s, list = pcall(FindAllOf, CRATE_ACT)
  for _, a in ipairs((s and type(list) == "table") and list or {}) do
    if ok(a) then
      local comp = rd(a, "BPC_MachineInteraction")
      local mo = ok(comp) and rd(comp, "MachineObject") or nil
      if ok(mo) and rd(mo, "ID") == sid and cn(mo) == CRATE_SIM then hits[#hits + 1] = a end
    end
  end
  return hits
end
local function hideCrate(a, sid)
  try("crate hide", function() a:SetActorHiddenInGame(true) end)
  try("crate no collision", function() a:SetActorEnableCollision(false) end)
  local comp = rd(a, "BPC_MachineInteraction")   -- the interaction component: 'Press F to Access Container' prompt
  if ok(comp) then
    try("crate interact off", function() comp:SetCollisionEnabled(0) end)   -- ECollisionEnabled::NoCollision
    try("crate interact hidden", function() comp:SetVisibility(false, true) end)
  end
  L("crate hidden ID=" .. tostring(sid) .. " actor=" .. nm(a))
end
-- block may be nil (world scan). Cheap when no crate sim exists.
function M.hideCrates(block)
  local s, sims = pcall(FindAllOf, CRATE_SIM)
  if not s or type(sims) ~= "table" or #sims == 0 then return end
  local ids = unitIds(block)
  for _, sim in ipairs(sims) do
    if ok(sim) then
      local sid, pid = rd(sim, "ID"), rd(sim, "ParentID")
      if sid ~= nil and pid ~= nil and ids[pid] then
        local hits = linkedActors(sid)
        if #hits == 1 then
          local key = tostring(sid) .. "|" .. nm(hits[1])
          if not crateDone[key] then crateDone[key] = true; hideCrate(hits[1], sid) end
        elseif not crateLogged[sid] then
          crateLogged[sid] = true
          L("crate link unknown ID=" .. tostring(sid) .. " parent=" .. tostring(pid) .. " actors=" .. #hits .. " (nothing hidden)")
        end
      end
    end
  end
end

function M.close()
  local h = S.h
  if not h then return end
  if S.run and S.builder then
    pcall(function() S.builder:cancel() end)
    KEPT.txt.Txt_Status = S.builder:status().text   -- the line shown on reopen: the cancelled result
  end
  S.h, S.w, S.p, S.U, S.player, S.ctl = nil, nil, nil, nil, nil, nil
  S.builder, S.io, S.run, S.tc, S.imp = nil, nil, nil, nil, false   -- S.plan / S.text stay (Build re-plans from S.text)
  MSCore.wbp.close(h)
  pcall(ExecuteWithDelay, 100, function() pcall(ExecuteInGameThread, MSCore.ui.clearClicks) end)
end

-- F: closes the window, except while the import modal is open (typing) or an edit box has focus
function M.fKey()
  if M.impOpen() then return end
  if M.isOpen() and os.clock() - S.t0 > 0.5 and not typing() then M.close() end
end

local function openWindow(block, player, ctl)
  local U, err = Live.find_unit(block)
  if not U then L("open: " .. tostring(err)); return end
  if not ok(player) then player = FindFirstOf("DMSPlayerObject"); L("open: player arg missing, FindFirstOf fallback") end
  Live.reset()
  local h = MSCore.wbp.open(WBP_CLS, ctl)
  if not h then L("open: window failed"); return end
  S.h, S.w, S.p = h, h.wbp, h.pc
  S.U, S.player, S.ctl = U, player, ctl
  S.t0, S.tc, S.imp = os.clock(), {}, false
  S.builder, S.io, S.run = nil, nil, nil

  local miss = {}
  for _, n in ipairs(CONTRACT) do if not ok(w(n)) then miss[#miss + 1] = n end end
  if #miss > 0 then L("missing widgets: " .. table.concat(miss, " ")) end

  local pinv = rd(player, "Inventory")
  MSCore.wbp.inventory_grid(h, "Scr_UnitInv", U.unit_inv, pinv, 8)
  MSCore.wbp.inventory_grid(h, "Host_PlayerInv", pinv, U.unit_inv, 8)

  local function bind(n, fn)
    local b = w(n)
    if ok(b) then try("bind " .. n, function() MSCore.ui.onClick(b, fn) end) end
  end
  bind("Btn_Close", M.close)
  bind("Btn_Import", impOpenModal)
  bind("Btn_Build", buildClick)
  bind("Btn_ImportClose", M.impClose)
  bind("Btn_ImportCancel", impCancel)
  bind("Btn_ImportOk", impOk)

  setVis(w("Pnl_ImportModal"), false)
  if KEPT.has then   -- reopen in the same session: the last results again
    for _, n in ipairs({ "Txt_Status", "Txt_Summary", "Txt_Notes", "Txt_Removes" }) do showText(n, KEPT.txt[n] or "") end
    fillCost(KEPT.rows)
  else
    resetResults()
  end
  readStationBuild()
  L("open unit=" .. tostring(rd(U.unit_inv, "ID")) .. " player=" .. tostring(rd(pinv, "ID")))
end

-- block = BPO_BlueprintUnit_C only (main.lua opener filter). player = DMSPlayerObject. ctl = controller or nil. Game thread.
function M.open(block, player, ctl)
  if S.h then return end   -- already open
  local okO, err = pcall(function()
    M.hideCrates(block)
    openWindow(block, player, ctl)
  end)
  if not okO then L("open failed: " .. tostring(err)) end
end

function M.init(mscore)
  MSCore = mscore
  F = mscore.factory
  native = mscore.factory_native
  return M
end

return M
