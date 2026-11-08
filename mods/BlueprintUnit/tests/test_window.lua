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

print(("RESULT %d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
