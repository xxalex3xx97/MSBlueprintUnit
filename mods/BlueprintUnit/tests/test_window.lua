-- test_window: bpu_window pure helpers (notes filter, build button state). Run: lua test_window.lua (exit 1 when a check fails).
local dir = (arg and arg[0] or ""):match("^(.*[/\\])") or "./"
package.path = dir .. "../Scripts/?.lua;" .. package.path
local W = require("bpu_window")

local pass, fail = 0, 0
local function check(cond, name)
    if cond then pass = pass + 1; print("PASS " .. name) else fail = fail + 1; print("FAIL " .. name) end
end

-- notes panel: block-built and ConfigHex lines are hidden (they stay in bpu_trace.log), others kept
check(W.pure.hiddenNote("skipped (block-built, no Buildable): BP_Foo") == true, "notes: block-built line hidden")
check(W.pure.hiddenNote("ConfigHex ignored for paired underground BP_Bar at (1,2)") == true, "notes: ConfigHex line hidden")
check(W.pure.hiddenNote("Contents ignored (not a container): BP_Gear@(1,2)") == false, "notes: other notes kept")
check(W.pure.hiddenNote("skipped (unknown)") == false, "notes: a different skipped line kept")

-- Build button: idle = Build, running = Abort and still enabled, Import off
local idle = W.btnState(false)
local run = W.btnState(true)
check(idle.build == "Build" and idle.build_on and idle.import_on, "button idle: Build enabled, Import enabled")
check(run.build == "Abort" and run.build_on and not run.import_on, "button running: Abort enabled, Import disabled")

-- F decision (fake io): reason string when ignored, nil = close
local function focus(desc, mine) return function() return desc, mine end end
local none = focus(nil, nil)
check(W.pure.fReason(true, true, 9, none) == "import modal open", "F: import modal open ignored")
check(W.pure.fReason(false, false, 9, none) == "window not open", "F: window closed ignored")
check((W.pure.fReason(false, true, 0.2, none)):find("age") ~= nil, "F: within 0.5s ignored")
check(W.pure.fReason(false, true, 9, focus("Edt_X class=EditableTextBox outer=WidgetTree", true)):find("typing in our box") ~= nil, "F: own box focused ignored")
check(W.pure.fReason(false, true, 9, focus("Edt_Chat class=EditableTextBox outer=Foo", false)) == nil, "F: foreign focused box does not block close")
check(W.pure.fReason(false, true, 9, none) == nil, "F: nothing focused closes")

-- Chk_Restore read: unchecked -> false (restore off), checked -> true, missing or unreadable -> nil (restore on)
check(W.pure.checkedOf({ IsChecked = function() return false end }) == false, "restore box: unchecked gives false")
check(W.pure.checkedOf({ IsChecked = function() return true end }) == true, "restore box: checked gives true")
check(W.pure.checkedOf(nil) == nil, "restore box: missing widget gives nil")
check(W.pure.checkedOf({ IsChecked = function() return "yes" end }) == nil, "restore box: non-boolean gives nil")

-- Station Build hint: shown only when ticked on an MSCore without the 0.8.0 natives
check(W.pure.stationHint(true, false) == "Station Build needs MSCore 0.8.0 or newer.", "station hint: ticked, old MSCore -> hint")
check(W.pure.stationHint(true, true) == "", "station hint: ticked, 0.8.0 -> no hint")
check(W.pure.stationHint(false, false) == "", "station hint: not ticked -> no hint")

-- probe fixtures plan through bpu_plan: P1 station block and P2 dock at (0,4), live station has BPO_Station_01 at (0,0)
local Plan = require("bpu_plan")
local FX = dofile(dir .. "fixtures/mscore_factory_snapshot.lua")
local function fixture(name)
    local f = assert(io.open(dir .. "fixtures/" .. name, "rb"))
    local s = f:read("a")
    f:close()
    return s
end
local FX_INFO = {
    BPO_Station_01 = { station = true, unlocked = true, bounds = { x0 = 0, x1 = 0, y0 = 0, y1 = 0, z0 = 0, z1 = 0 }, cost = { ITEM_A = 2 } },
    BPO_Dock_2 = { station = true, unlocked = true, bounds = { x0 = 0, x1 = 0, y0 = 0, y1 = 0, z0 = 0, z1 = 0 }, cost = { ITEM_A = 1 } },
}
local function fx_live(over)
    local l = { station = 42, blocks = { { class = "BPO_Station_01", gx = 0, gy = 0, h = 0, rot = 0 } }, existing = {},
                recipes = {}, buildables = {}, block_info = function(cls) return FX_INFO[cls] end, have = { ITEM_A = 10 } }
    for k, v in pairs(over or {}) do l[k] = v end
    return l
end
for _, name in ipairs({ "probe_p1_station01.json", "probe_p2_dock.json" }) do
    local p = Plan.plan(fixture(name), fx_live(), FX, { station_build = true })
    check(p and p.valid and p.block_count == 1 and p.blocks[1].gy == 4 and p.block_need.ITEM_A >= 1,
          name .. ": station build plans the one block at (0,4)")
    check(p and Plan.summary(p):sub(-10) == ", blocks 1", name .. ": summary ends with blocks 1")
    local off, offerr = Plan.plan(fixture(name), fx_live(), FX, {})
    check(off == nil and offerr:find("These blocks are not on the station grid", 1, true) ~= nil, name .. ": station build off -> unchanged refusal")
end

print(("RESULT %d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
