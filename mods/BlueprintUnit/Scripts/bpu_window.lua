-- bpu_window: Blueprint Unit window (WBP_BlueprintUnit). API: init(MSCore) / open(block, player, ctl) / close / isOpen /
-- fKey / impOpen / impClose (import modal) / hideCrates(block).
-- Window, grids and cost rows: MSCore.wbp (mscore_wbp.lua). Clicks: MSCore.ui. Items, plan and build: bpu_live, bpu_plan, bpu_build.
-- Every game call goes through pcall. Every log line gets the [BPUnit] tag.

local Live = require("bpu_live")
local Plan = require("bpu_plan")
local Build = require("bpu_build")
local Invtrace = require("bpu_invtrace")   -- DEV: uicmd/ourcmd InventoryInput trace

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
-- optional, never logged if missing: Btn_CostPin, Txt_CostPin, Chk_StationBuild (CheckBox), Txt_StationBuildHint, Chk_Restore (CheckBox:
-- unchecked = restore off; missing or checked = restore on, read on every Build press). Txt_Restore, Txt_RestoreHint: label + hint.

-- S.w = WBP instance (names resolve here). S.h = MSCore.wbp handle (nil = closed). S.p = controller. S.tc = last text per name.
-- S.imp = import modal shown. S.U = unit (Live.find_unit). S.plan / S.text = last import. S.run = token of the running build.
local S = { h = nil, w = nil, p = nil, U = nil, player = nil, ctl = nil, tc = nil, imp = false,
  plan = nil, text = nil, builder = nil, io = nil, run = nil, stationBuild = false, t0 = 0 }
-- KEPT (module level, survives close/reopen): the cost rows, and NOTE = the text of the Notes panel (re-rendered by openWindow).
-- has = an import or build ran in this session. S.plan / S.text are kept too (Build re-plans from S.text).
-- Notes panel (Txt_Notes) = status line, plan summary, removes line, folded notes. Txt_Status, Txt_Summary and Txt_Removes
-- are collapsed (empty): no text above the buttons.
local KEPT = { has = false, rows = {}, pinned = false }
local NOTE = { status = "", summary = "", removes = "", list = "" }

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
  S.tc = S.tc or {}
  if S.tc[name] == s then return end
  local tb = w(name); if not ok(tb) then return end
  if try("SetText " .. name, function() tb:SetText(FText(s)) end) then S.tc[name] = s end
end

-- text block + its visibility (hidden when empty)
local function showText(name, s) txt(name, s); setVis(w(name), s ~= "") end

-- Notes panel text from NOTE (empty parts skipped)
local function renderNotes()
  local parts = {}
  for _, p in ipairs({ NOTE.status, NOTE.summary, NOTE.removes, NOTE.list }) do
    if p ~= "" then parts[#parts + 1] = p end
  end
  showText("Txt_Notes", table.concat(parts, "\n"))
end
-- the status line (import result, build progress, error): first line of the Notes panel
local function setStatus(s)
  NOTE.status = s or ""
  renderNotes()
end

local function setEnabled(name, b) local o = w(name); if ok(o) then pcall(function() o:SetIsEnabled(b) end) end end
-- button state: idle -> Build + Import; running -> the Build button reads Abort and stays enabled (cancels), Import off
local function setBuildBtns(idle)
  local st = M.btnState(not idle)
  setEnabled("Btn_Build", st.build_on)
  setEnabled("Btn_Import", st.import_on)
  txt("Txt_Build", st.build)
end

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

-- outer chain of a widget reaches our window (UserWidget): WidgetTree -> UserWidget
local function owned(e)
  local s0, want = pcall(function() return S.w:GetFullName() end)
  if not s0 then return false end
  local o = e
  for _ = 1, 12 do
    local s1, nxt = pcall(function() return o:GetOuter() end)
    if not s1 or not ok(nxt) then return false end
    local s2, fn = pcall(function() return nxt:GetFullName() end)
    if s2 and fn == want then return true end
    o = nxt
  end
  return false
end

-- first focused EditableTextBox in the game: desc (name, class, outer class), ours (owned by S.w). nil when none
local function focusedBox()
  for _, e in ipairs(FindAllOf("EditableTextBox") or {}) do
    if ok(e) then
      local s, v = pcall(function() return e:HasKeyboardFocus() end)
      if s and v then
        local s3, outer = pcall(function() return e:GetOuter() end)
        local oc = (s3 and ok(outer)) and cn(outer) or "?"
        return nm(e) .. " class=" .. cn(e) .. " outer=" .. oc, owned(e)
      end
    end
  end
  return nil
end

-- F decision (pure): nil = close, else the reason it is ignored. box() -> desc, ours (only our own focused box blocks F)
local function fReason(imp, open, age, box)
  if imp then return "import modal open" end
  if not open then return "window not open" end
  if age <= 0.5 then return ("age %.2fs <= 0.5s"):format(age) end
  local desc, mine = box()
  if desc and mine then return "typing in our box " .. desc end
  return nil, desc and ("foreign focus ignored: " .. desc) or nil
end

function M.isOpen() return S.h ~= nil and ok(S.w) end

-- import modal state (Lua flag + window valid)
function M.impOpen() return S.imp == true and ok(S.w) end

-- results area: notes, cost rows back to empty
local function resetResults()
  NOTE.status, NOTE.summary, NOTE.removes, NOTE.list = "", "", "", ""
  renderNotes()
  fillCost({})
end

-- Notes panel: diagnostics only (they stay in bpu_trace.log)
local HIDDEN_NOTES = { "skipped (block-built", "ConfigHex ignored for paired underground" }
local function hiddenNote(n)
  for _, p in ipairs(HIDDEN_NOTES) do if n:sub(1, #p) == p then return true end end
  return false
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
  if not ok(box) or not sr or type(text) ~= "string" then setStatus("error: could not read text"); return end
  if text == "" then setStatus("paste the blueprint JSON first"); return end
  -- GC off while the station structs are read: UE4SS crashes in luaL_traceback (dead table keys) when a collection runs mid-read
  collectgarbage("stop")
  S.lastText = text
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
    if not plan then setStatus("error: " .. tostring(perr)); return end
    S.plan, S.text = plan, text
    KEPT.has = true
    NOTE.summary = Plan.summary(plan)
    NOTE.removes = Plan.removes_text(plan)
    -- notes (scrollable): same text folded into "xN", no cap
    local order, count = {}, {}
    for _, n in ipairs(plan.notes or {}) do
      if hiddenNote(n) then
        Live.trace("note kept out of the panel: " .. n)
      else
        if not count[n] then count[n] = 0; order[#order + 1] = n end
        count[n] = count[n] + 1
      end
    end
    local lines = {}
    for _, n in ipairs(order) do
      lines[#lines + 1] = count[n] > 1 and (n .. " x" .. count[n]) or n
    end
    NOTE.list = table.concat(lines, "\n")
    setStatus("Blueprint: " .. (plan.name or "Ready"))
    t0 = os.clock()
    local rows = Plan.cost_rows(plan)
    fillCost(rows)
    Live.trace(("impOk fillCost %.1f ms rows=%d"):format((os.clock() - t0) * 1000, #rows))
    M.impClose()
    Live.trace("impOk done")
  end, function(e) pcall(function() local f = io.open("Mods/BlueprintUnit/bpu_last_import.json", "wb"); if f then f:write(S.lastText or ""); f:close() end end); Live.trace("impOk ERROR " .. tostring(e) .. " | " .. (tostring(debug.traceback("", 2)):gsub("\n", " ; "))); return e end)
  collectgarbage("restart")
  if not okRun then L("import failed: " .. tostring(err)); setStatus("error: import failed: " .. tostring(err)) end
end

-- end of a build run: buttons back, result line, cost list re-planned from the saved text (what is still missing)
local function finishBuild(run)
  if S.run ~= run then return end
  S.run = nil
  setBuildBtns(true)
  KEPT.has = true   -- the result line is the Notes status line (buildLoop); the plan summary stays
  local okR, err = pcall(function()
    local plan, perr = Plan.plan(S.text, Live.snapshot(S.U, F), F)
    if not plan then
      Live.trace("finishBuild replan failed: " .. tostring(perr))
      setStatus("error: " .. tostring(perr) .. " (import again if this stays)")
      return
    end
    S.plan = plan
    fillCost(Plan.cost_rows(plan))
  end)
  if not okR then L("refresh after build failed: " .. tostring(err)) end
end

-- polls the builder every 300 ms on the game thread. Stops (returns true) when the run was replaced or closed.
-- A Lua error in a tick ends the run (finishBuild sets S.run = nil, the next poll returns true); S.plan / S.text stay.
local function buildLoop(run)
  return function()
    if S.run ~= run then return true end
    pcall(ExecuteInGameThread, function()
      local okT, errT = xpcall(function()
        if S.run ~= run then return end
        S.builder:tick(S.io.now())
        local st = S.builder:status()
        setStatus(st.text)
        if st.state == "done" or st.state == "error" then finishBuild(run) end
      end, function(e)
        -- full traceback to bpu_trace.log; the short error (returned) still goes to the Notes panel
        Live.trace("build tick traceback: " .. (debug.traceback(tostring(e), 2):gsub("\n", " ; ")))
        return tostring(e)
      end)
      if not okT then
        Live.trace("build tick ERROR " .. tostring(errT))
        NOTE.status = "error: " .. tostring(errT)
        renderNotes()
        finishBuild(run)
      end
    end)
    return false
  end
end

-- IsChecked of a CheckBox-like object: true / false, nil when missing or unreadable
local function checkedOf(c)
  if c == nil then return nil end
  local s, v = pcall(function() return c:IsChecked() end)
  if s and type(v) == "boolean" then return v end
  return nil
end

-- Chk_Restore (optional CheckBox, read on every Build press): true / false, nil when the widget is missing (restore on)
local function readRestoreBox()
  local c = w("Chk_Restore")
  if not ok(c) then return nil end
  return checkedOf(c)
end

-- Btn_Build: re-plan from the saved text (station may have changed), start the builder, poll it.
local function buildClick()
  if S.run then return end
  if not S.plan and not S.text then setStatus("import first"); return end
  readStationBuild()
  local ui = readRestoreBox()
  local okRun, err = pcall(function()
    local live = Live.snapshot(S.U, F)
    local plan, perr = Plan.plan(S.text, live, F)
    if not plan then
      Live.trace("buildClick replan failed: " .. tostring(perr))
      setStatus("error: " .. tostring(perr) .. " (import again if this stays)")
      return
    end
    S.plan = plan
    if not S.builder then   -- one builder per window open
      S.io = Live.make_io({ unit = S.U, player = S.player, ctl = S.ctl, F = F, native = native, plan_mod = Plan, buildables = live.buildables })
      S.builder = Build.new(S.io)
    end
    local started, msg = S.builder:start(plan, { restore = ui })
    if not started then setStatus(msg); return end
    local run = {}
    S.run = run
    setBuildBtns(false)
    setStatus(S.builder:status().text)
    LoopAsync(300, buildLoop(run))
  end)
  if not okRun then
    L("build failed: " .. tostring(err))
    S.run = nil
    setBuildBtns(true)
    setStatus("error: build failed: " .. tostring(err))
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
    NOTE.status = S.builder:status().text   -- the line shown on reopen: the cancelled result
  end
  S.h, S.w, S.p, S.U, S.player, S.ctl = nil, nil, nil, nil, nil, nil
  S.builder, S.io, S.run, S.tc, S.imp = nil, nil, nil, nil, false   -- S.plan / S.text stay (Build re-plans from S.text)
  MSCore.wbp.close(h)
  Invtrace.close()
  pcall(ExecuteWithDelay, 100, function() pcall(ExecuteInGameThread, MSCore.ui.clearClicks) end)
end

-- F: closes the window, except while the import modal is open or our own edit box has focus. Traces every press.
function M.fKey()
  local why, note = fReason(M.impOpen(), M.isOpen(), os.clock() - S.t0, focusedBox)
  if why then Live.trace("F ignored: " .. why); return end
  Live.trace("F closes window" .. (note and (" (" .. note .. ")") or ""))
  M.close()
end

-- Pin (Btn_CostPin): sends the game's SetPinnedCostInput with the net-need stacks (net > 0, amount = net). Pressed again = empty array = unpin.
-- The game HUD shows the list (amounts only, no live refresh). The label follows our last click only.
local function pinClick()
  local stacks = {}
  if not KEPT.pinned then
    for _, r in ipairs(KEPT.rows) do if r.net > 0 then stacks[#stacks + 1] = { name = r.name, n = r.net } end end
    if #stacks == 0 then setStatus("nothing to pin"); return end
  end
  local okp, r = Live.send_pin(S.ctl, S.player, stacks)
  L(("pin %s n=%d -> ok=%s ret=%s"):format(KEPT.pinned and "clear" or "set", #stacks, tostring(okp), tostring(r)))
  if okp then
    KEPT.pinned = not KEPT.pinned
    txt("Txt_CostPin", KEPT.pinned and "Unpin" or "Pin")
  else
    setStatus("pin failed (see log)")
  end
end

-- Btn_Build while a run is going: Abort. Cancels the builder (items already moved stay where they are, as on close).
local function abortClick()
  local run = S.run
  if not run or not S.builder then return end
  local okc, msg = pcall(function() return S.builder:cancel() end)
  L("abort: " .. tostring(okc) .. " " .. tostring(msg))
  setStatus(S.builder:status().text)
  finishBuild(run)
end
local function buildOrAbort()
  if S.run then abortClick() else buildClick() end
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
  bind("Btn_Build", buildOrAbort)
  bind("Btn_ImportClose", M.impClose)
  bind("Btn_ImportCancel", impCancel)
  bind("Btn_ImportOk", impOk)
  bind("Btn_CostPin", pinClick)

  setVis(w("Pnl_ImportModal"), false)
  showText("Txt_Status", "")    -- collapsed: the text lives in the Notes panel
  showText("Txt_Summary", "")
  showText("Txt_Removes", "")
  if KEPT.has then   -- reopen in the same session: the last results again (Notes from NOTE)
    renderNotes()
    fillCost(KEPT.rows)
  else
    resetResults()
  end
  readStationBuild()
  setBuildBtns(true)
  txt("Txt_CostPin", KEPT.pinned and "Unpin" or "Pin")
  L("open unit=".. tostring(rd(U.unit_inv, "ID")) .. " player=" .. tostring(rd(pinv, "ID")))
  Invtrace.open()
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

-- pure helpers for the tests (no game objects)
M.pure = { hiddenNote = hiddenNote, fReason = fReason, checkedOf = checkedOf }
-- label and enabled state of the build buttons while a run goes (running = true)
function M.btnState(running)
  if running then return { build = "Abort", build_on = true, import_on = false } end
  return { build = "Build", build_on = true, import_on = true }
end

function M.init(mscore)
  MSCore = mscore
  F = mscore.factory
  native = mscore.factory_native
  return M
end

return M
