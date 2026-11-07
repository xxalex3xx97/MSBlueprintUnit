-- bpu_invtrace: DEV ONLY. Traces InventoryInput commands (quick move) while the Blueprint Unit window is open.
-- uicmd = the game's own command (pre-hook on DMSPlayerController:AddInputCommand, any receiver).
-- ourcmd = commands our inv_move sends (bpu_live io.send_move wraps the native call in M.sending).
-- Named property reads only, no ForEach, IsValid first. Max 40 matching commands per game session. Lines go to bpu_trace.log.
local M = { on = false, n = 0, max = 40, ours = false, hooked = false }

local function log(m) require("bpu_live").trace("invtrace " .. tostring(m)) end
local function ok(o) if type(o) ~= "userdata" then return false end local s, v = pcall(function() return o:IsValid() end) return s and v == true end
local function unw(x) if type(x) == "userdata" then local s, r = pcall(function() return x:get() end) if s and r ~= nil then return r end end return x end
local function rd(o, p) local s, v = pcall(function() return o[p] end) if s then return tostring(v) end return "ERR" end
local function cls(o) local s, v = pcall(function() return o:GetClass():GetFName():ToString() end) return s and v or "?" end

-- pre-hook: args (self, InReceiverID, InCommand). Only reads; never calls game functions.
local function onAdd(_, a1, a2)
    if not M.on or M.n >= M.max then return end
    local okc, err = pcall(function()
        local cmd = unw(a2)
        if not ok(cmd) then return end
        local c = cls(cmd)
        if not c:find("InventoryInput", 1, true) then return end
        M.n = M.n + 1
        log(("%s #%d recv=%s class=%s Primary=%s Secondary=%s SlotIndex=%s Action=%s"):format(
            M.ours and "ourcmd" or "uicmd", M.n, tostring(unw(a1)), c,
            rd(cmd, "PrimaryInventoryID"), rd(cmd, "SecondaryInventoryID"), rd(cmd, "SlotIndex"), rd(cmd, "Action")))
    end)
    if not okc then log("hook error " .. tostring(err)) end
end

-- called by bpu_window when the window opens: arms the hook once, then tracing is on
function M.open()
    M.on = true
    if M.hooked or M.n >= M.max or type(RegisterHook) ~= "function" then return end
    local okr, e = pcall(RegisterHook, "/Script/MainSequence.DMSPlayerController:AddInputCommand", onAdd)
    if okr then M.hooked = true; log("hook armed on AddInputCommand") else log("RegisterHook FAIL " .. tostring(e)) end
end

function M.close() M.on = false end

-- wraps our native inv_move call: commands created inside are tagged ourcmd
function M.sending(fn, ...)
    M.ours = true
    local s, a, b = pcall(fn, ...)
    M.ours = false
    if not s then error(a, 0) end
    return a, b
end

return M
