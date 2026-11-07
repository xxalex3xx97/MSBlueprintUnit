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

print(("RESULT %d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
