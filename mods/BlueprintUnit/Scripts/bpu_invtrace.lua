-- bpu_invtrace: DEV ONLY. Traces the game's own inventory quick-move path while the Blueprint Unit window is open.
-- uicmd = DMSPlayerController:AddInputCommand (pre-hook, any receiver). ourcmd = commands our inv_move sends (bpu_live io.send_move wraps the native call in M.sending).
-- hooks = UFunctions the game calls before a command: AddInventoryInteraction (BP caller of the quick move) and WBP_Inventory / WBP_InventorySlot click handlers.
-- Each path is registered once; a path that fails (class not loaded yet) is retried on every window open.
-- Named property reads only, no ForEach, IsValid first. Max 40 trace lines per game session (all hooks share the cap). Lines go to bpu_trace.log.
local M = { on = false, n = 0, max = 40, ours = false }

local function log(m) require("bpu_live").trace("invtrace " .. tostring(m)) end
local function ok(o) if type(o) ~= "userdata" then return false end local s, v = pcall(function() return o:IsValid() end) return s and v == true end
local function unw(x) if type(x) == "userdata" then local s, r = pcall(function() return x:get() end) if s and r ~= nil then return r end end return x end
local function rd(o, p) local s, v = pcall(function() return o[p] end) if s then return tostring(unw(v)) end return "ERR" end
local function cls(o) local s, v = pcall(function() return o:GetClass():GetFName():ToString() end) return s and v or "?" end
local function nm(o) local s, v = pcall(function() return o:GetFName():ToString() end) return s and v or "?" end
local function short(p) return p:match("[^/]+$") or p end

-- one token per UFunction param: UObject -> class/name, other -> value, struct -> opaque (no field probing here)
local function fmt(v)
    local u = unw(v)
    if ok(u) then return "obj:" .. cls(u) .. "/" .. nm(u) end
    if type(u) == "userdata" then return "struct" end
    return tostring(u)
end

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

-- generic pre-hook for the candidate UFunctions: params by label (names[i], else p<i>); named fields read from p1 (from="p1") or self
local function onFn(e)
    return function(self, ...)
        if not M.on or M.n >= M.max then return end
        local a = table.pack(...)
        local okc, err = pcall(function()
            M.n = M.n + 1
            local parts = {}
            for i = 1, a.n do parts[#parts + 1] = (e.names and e.names[i] or ("p" .. i)) .. "=" .. fmt(a[i]) end
            local src = (e.from == "p1") and unw(a[1]) or unw(self)
            for _, f in ipairs(e.fields or {}) do parts[#parts + 1] = f .. "=" .. rd(src, f) end
            log(("hook #%d %s self=%s %s"):format(M.n, short(e.path), nm(unw(self)), table.concat(parts, " ")))
        end)
        if not okc then log("hook error " .. tostring(err)) end
    end
end

local INV = "/Game/Blueprints/Widgets/Display/Inventory/"
local IX = { "PrimaryInventoryID", "SecondaryInventoryID", "SlotIndex", "Action" }
local WF = { "PrimaryInventoryID", "SecondaryInventoryID", "SlotIndex" }
-- candidate paths; each is tried on its own (a missing one logs FAILED once, then is retried on open)
local FN = {
    { path = "/Script/MainSequence.DMSPlayerController:AddInputCommand", h = onAdd },
    { path = "/Script/MainSequence.DMSPlayerController:AddInventoryInteraction", names = { "interaction" }, fields = IX, from = "p1" },
    { path = "/Game/Blueprints/Player/BP_PlayerController.BP_PlayerController_C:AddInventoryInteraction", names = { "interaction" }, fields = IX, from = "p1" },
    { path = INV .. "WBP_Inventory.WBP_Inventory_C:OnSlotPressed", names = { "event" }, fields = WF },
    { path = INV .. "WBP_Inventory.WBP_Inventory_C:OnSlotReleased", names = { "event" }, fields = WF },
    { path = INV .. "WBP_InventorySlot.WBP_InventorySlot_C:OnSlotPressed", names = { "event" }, fields = WF },
    { path = INV .. "WBP_InventorySlot.WBP_InventorySlot_C:OnSlotReleased", names = { "event" }, fields = WF },
    { path = INV .. "WBP_InventorySlot.WBP_InventorySlot_C:OnMouseButtonDown", names = { "event" }, fields = WF },
}

local done, warned = {}, {}
local function arm()
    if type(RegisterHook) ~= "function" then return end
    for _, e in ipairs(FN) do
        if not done[e.path] then
            local okr, r1, r2 = pcall(RegisterHook, e.path, e.h or onFn(e))
            if okr then
                done[e.path] = true
                log(("registered %s ids=%s,%s"):format(short(e.path), tostring(r1), tostring(r2)))
            elseif not warned[e.path] then
                warned[e.path] = true
                log("FAILED " .. e.path .. " " .. tostring(r1) .. " (retry on next open)")
            end
        end
    end
end

-- called by bpu_window when the window opens: arms any path not yet registered, then tracing is on
function M.open()
    M.on = true
    if M.n < M.max then arm() end
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
