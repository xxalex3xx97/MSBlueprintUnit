-- test_build: plain asserts for Scripts/bpu_build.lua (pure helpers + build flows on a fake io).
-- Run: lua test_build.lua   (exit 0 = all pass, 1 = failures)
local dir = (arg and arg[0] or ""):match("^(.*)[/\\]") or "."
package.path = dir .. "/../Scripts/?.lua;" .. package.path   -- bpu_build requires bpu_blocks (Station Build)
local B = dofile(dir .. "/../Scripts/bpu_build.lua")
local P = B.pure

local pass, failn = 0, 0
local function check(cond, name)
    if cond then
        pass = pass + 1
        print("PASS " .. name)
    else
        failn = failn + 1
        print("FAIL " .. name)
    end
end

local function same(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return a == b end
    for k, v in pairs(a) do if not same(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

local function E() return { item = "", amount = 0, max = 1 } end
local function S(item, amount, max) return { item = item, amount = amount, max = max or 50 } end
local function inv(items, total)
    local t = {}
    for i, s in ipairs(items) do t[i] = s end
    for i = #t + 1, total or #t do t[i] = E() end
    return t
end
local function M(bcls, x, y, cost) return { bcls = bcls, x = x, y = y, cost = cost } end

-- fake game: inventories, station, quick moves with partial fills, removals refund to the player
local function fake(spec)
    local f = {
        calls = { rm = 0, mv = 0, pl = 0, ch = 0 }, moves = {}, clock = 1000,
        no_charge = spec.no_charge,
        station = spec.station or {}, next_id = 100, creative = spec.creative or false,
        max = spec.max or {}, refund_of = spec.refund_of or {}, max_per_move = spec.max_per_move,
        noop_moves = spec.noop_moves, shift_x = spec.shift_x or 0, drop_place = spec.drop_place,
        inv = { player = { id = 101, slots = spec.player }, unit = { id = 202, slots = spec.unit } },
        live_bcls = spec.live_bcls, vanish_after = spec.vanish_after,
        mult = spec.mult or {},   -- StackMultiplier per inventory ("player" / "unit")
    }
    local function mx(item) return f.max[item] or 50 end
    local function inv_by_id(id)
        for _, v in pairs(f.inv) do if v.id == id then return v end end
    end
    -- puts n of item into slots (partial stacks first, then empty slots). Returns what did not fit.
    local function put(slots, item, n, m)
        for _, s in ipairs(slots) do
            if n <= 0 then break end
            if s.item == item and s.amount > 0 and s.amount < m then
                local add = math.min(m - s.amount, n)
                s.amount = s.amount + add
                n = n - add
            end
        end
        for _, s in ipairs(slots) do
            if n <= 0 then break end
            if s.amount <= 0 then
                local add = math.min(m, n)
                s.item, s.amount, s.max = item, add, m
                n = n - add
            end
        end
        return n
    end
    local function have(slots, item)
        local n = 0
        for _, s in ipairs(slots) do if s.item == item and s.amount > 0 then n = n + s.amount end end
        return n
    end
    local function take(slots, item, n)
        for _, s in ipairs(slots) do
            if n <= 0 then break end
            if s.item == item and s.amount > 0 then
                local t = math.min(s.amount, n)
                s.amount = s.amount - t
                n = n - t
                if s.amount == 0 then s.item = "" end
            end
        end
    end

    -- the fake game applies inventory commands (see io.send_inv). Violations: game-rule breaks the restore must never make.
    -- action 4 DROP_CURSOR (cursor -> player), 0 TAKE (empty cursor: min(slot, max); holding: whole cursor into the slot),
    -- 1 PLACE_SINGLE (holding: one item into the slot). Only the press is modelled.
    -- registered inventory id -> slots. A machine id or an unknown id is a violation (the game derefs null on PLACE_SINGLE and
    -- TRANSFER: crash 2026-11-07 23:05). Container INVENTORY id = machine id + 5000.
    local function inv_slots(id, action)
        if id == 101 then return f.inv.player.slots end
        if id == 202 then return f.inv.unit.slots end
        if id > 5000 and f.containers[id - 5000] then return f.containers[id - 5000].slots end
        f.violations[#f.violations + 1] = ("action %s on id %s, not a registered inventory id"):format(tostring(action), tostring(id))
        return nil
    end
    local function apply_inv(prim, sec, slot0, action)
        if action == 3 or action == 4 then f.violations[#f.violations + 1] = ("action %d sent"):format(action) end
        if action == 4 then
            if f.cursor.amount > 0 then put(f.inv.player.slots, f.cursor.item, f.cursor.amount, mx(f.cursor.item)) end
            f.cursor = { item = "", amount = 0 }
            return
        end
        if action == 2 then
            -- TRANSFER: whole source slot into the secondary inventory (same-item stacks, then empty slots); the rest stays
            local src, dst = inv_slots(prim, action), inv_slots(sec, action)
            if not src or not dst then return end
            local s = src[slot0 + 1]
            if not s or s.amount <= 0 then return end
            s.amount = put(dst, s.item, s.amount, mx(s.item))
            if s.amount <= 0 then s.item, s.amount = "", 0 end
            return
        end
        local slots = inv_slots(prim, action)
        if not slots then return end
        local s = slots[slot0 + 1]
        if not s then return end
        if action == 0 then
            if f.cursor.amount > 0 and s.amount > 0 and s.item ~= f.cursor.item then
                f.violations[#f.violations + 1] = ("take onto %s while holding %s"):format(s.item, f.cursor.item)
            end
            if f.cursor.amount == 0 then
                if s.amount > 0 then
                    local c = math.min(s.amount, mx(s.item))
                    f.cursor = { item = s.item, amount = c }
                    s.amount = s.amount - c
                    if s.amount == 0 then s.item = "" end
                end
            elseif s.amount <= 0 then
                s.item, s.amount = f.cursor.item, f.cursor.amount
                f.cursor = { item = "", amount = 0 }
            elseif s.item == f.cursor.item and s.amount + f.cursor.amount <= mx(s.item) then
                s.amount = s.amount + f.cursor.amount
                f.cursor = { item = "", amount = 0 }
            end
        elseif action == 1 then
            if f.cursor.amount == 0 then f.violations[#f.violations + 1] = "place single with empty cursor"; return end
            if s.amount <= 0 then
                s.item, s.amount = f.cursor.item, 1
            elseif s.item == f.cursor.item and s.amount < mx(s.item) then
                s.amount = s.amount + 1
            else
                return
            end
            f.cursor.amount = f.cursor.amount - 1
            if f.cursor.amount == 0 then f.cursor.item = "" end
        end
    end
    -- delayed commands whose time has come, in send order (called by every read and send)
    local function flush()
        while #f.pending > 0 and f.pending[1].at <= f.clock do table.remove(f.pending, 1).run() end
    end

    local io = {}
    local redirect = type(spec.redirect) == "string" and spec.redirect:sub(1, 2) == "on"
    f.rd_log = {}   -- redirect switch calls in order: "enable:true", "status", "enable:false"
    -- the switch has a state: it starts as spec.rd_initial (default off; without redirect_enable it is simply spec.redirect), enable(true) turns it
    -- into spec.redirect, enable(false) into off. redirect_status reads the state.
    f.rd_state = spec.no_enable and spec.redirect or spec.rd_initial or "off"
    if spec.redirect ~= nil then io.redirect_status = function() f.rd_log[#f.rd_log + 1] = "status"; return f.rd_state end end
    if not spec.no_enable then
        io.redirect_enable = function(on)
            f.rd_log[#f.rd_log + 1] = "enable:" .. tostring(on)
            if spec.enable_error then error("enable boom") end
            f.rd_state = on and (spec.redirect or "off") or "off"
            return f.rd_state
        end
    end
    f.order = {}   -- sent commands in order: "rm:<id>" / "pl:<x>"
    -- containers (restore): id -> { slots }. A placed container gets id next_id + 500 (never a player/unit id)
    f.containers = spec.containers or {}
    f.cont_slots = spec.cont_slots or 4
    f.cont_mult = spec.cont_mult or 1   -- container StackMultiplier (read_machine_inv)
    f.noop_inv = spec.noop_inv
    f.cursor = { item = "", amount = 0 }   -- one player cursor (AddInventoryInteraction model)
    f.cmd_log = {}                         -- inventory commands {primary, secondary, slot0, action, clock}
    f.violations = {}                      -- game-rule breaks (apply_inv): TAKE onto another item, PLACE_SINGLE empty, action 3/4
    f.pending = {}                         -- delayed inventory commands (f.delay): {sent=, at=, run=}
    f.inflight = 0                         -- sends while an earlier delayed batch was still pending
    f.unready, f.stall_after, f.delay, f.mode = spec.unready, spec.stall_after, spec.delay, spec.mode
    f.remembered = {}
    function io.now() return f.clock end
    function io.creative() return f.creative end
    function io.scan(station)
        if f.scan_err then return nil, f.scan_err end
        if f.vanish_after and f.placed_at and not f.vanished and f.clock >= f.placed_at + f.vanish_after then
            f.vanished = true
            for i, m in ipairs(f.station) do if m.id > 100 then table.remove(f.station, i) break end end
        end
        local out = {}
        for i, m in ipairs(f.station) do out[i] = m end
        return out
    end
    function io.scan_raw(station)   -- raw view: no overlay in the fake, same list as scan
        local out = {}
        for i, m in ipairs(f.station) do out[i] = m end
        return out
    end
    function io.fingerprint(ex)
        local parts = {}
        for _, m in ipairs(ex) do parts[#parts + 1] = table.concat({ m.id, m.bcls, m.x, m.y }, ":") end
        return table.concat(parts, "|")
    end
    function io.read_inv(which)
        flush()
        local v = f.inv[which]
        local slots = {}
        for i, s in ipairs(v.slots) do slots[i] = { item = s.item, amount = s.amount, max = s.max } end
        return { slots = slots, id = v.id, ok = true, mult = f.mult[which] }
    end
    -- raw MaxStackSize (live: Item UObject); 50 = the fake's stack size for items not listed in spec.raw
    io.item_max = function(k) local r = spec.raw; return r and r[k] or 50 end
    function io.unit_ids() return { unit_id = 202, player_id = 101 } end
    function io.costs(place)
        local out = {}
        for k, m in ipairs(place) do out[k] = m.cost or {} end
        return out
    end
    function io.send_remove(id)
        f.calls.rm = f.calls.rm + 1
        for i, m in ipairs(f.station) do
            if m.id == id then
                table.remove(f.station, i)
                f.order[#f.order + 1] = "rm:" .. id
                f.last_rm_at = f.clock
                for item, n in pairs(f.refund_of[id] or {}) do
                    if redirect then
                        local left = put(f.inv.unit.slots, item, n, mx(item))
                        if left > 0 then put(f.inv.player.slots, item, left, mx(item)) end
                    else
                        put(f.inv.player.slots, item, n, mx(item))
                    end
                end
                return true
            end
        end
        return false
    end
    -- like bpu_live io.send_move: press (action 2, to sec) then release (action 3, sec 0). Both recorded; only the press moves.
    function io.send_move(prim, sec, slot)
        f.calls.mv = f.calls.mv + 2
        f.moves[#f.moves + 1] = { prim, sec, slot, 2 }
        f.moves[#f.moves + 1] = { prim, 0, slot, 3 }
        local src, dst = inv_by_id(prim), inv_by_id(sec)
        if not src or not dst then return false end
        local s = src.slots[slot + 1]
        if not s or s.amount <= 0 then return true end
        if f.noop_moves then return true end
        local n = s.amount
        if f.max_per_move then n = math.min(n, f.max_per_move) end
        local left = put(dst.slots, s.item, n, mx(s.item))
        s.amount = s.amount - (n - left)
        if s.amount <= 0 then s.item, s.amount = "", 0 end
        return true
    end
    function io.send_place(m)
        f.calls.pl = f.calls.pl + 1
        local cost = m.cost or {}
        f.order[#f.order + 1] = "pl:" .. m.x
        f.place_gap = f.place_gap or (f.last_rm_at and f.clock - f.last_rm_at)
        if redirect and not f.creative then   -- charge: unit first, player second
            for item, n in pairs(cost) do
                local t = math.min(have(f.inv.unit.slots, item), n)
                take(f.inv.unit.slots, item, t)
                take(f.inv.player.slots, item, n - t)
            end
        elseif not f.creative then
            for item, n in pairs(cost) do if have(f.inv.player.slots, item) < n then return false end end
            if not f.no_charge then for item, n in pairs(cost) do take(f.inv.player.slots, item, n) end end
        end
        if f.drop_place then return true end   -- accepted, never shows up on the station
        f.next_id = f.next_id + 1
        f.placed_at = f.placed_at or f.clock
        local bcls = f.live_bcls or m.bcls
        f.station[#f.station + 1] = { id = f.next_id, bcls = bcls, x = m.x + f.shift_x, y = m.y, h = 0, rot = 0,
                                      cfg = spec.game_cfg and spec.game_cfg(m.cfg) or m.cfg }   -- game_cfg: what the game keeps
        if bcls:find("Container", 1, true) then
            local slots = {}
            for i = 1, f.cont_slots do slots[i] = { item = "", amount = 0, max = 50 } end
            f.containers[f.next_id + 500] = { slots = slots }
        end
        return true
    end
    function io.send_changes(chg)
        f.calls.ch = f.calls.ch + 1
        return true
    end
    -- containers: default read (nil = not a container), ids, memory, and the exact-N cursor model of AddInventoryInteraction
    function io.read_machine_inv(id)
        flush()
        local c = f.containers[id]
        if not c then return nil end
        if id > 500 and (f.unready or 0) > 0 then   -- f.unready = n: the next n container reads are not ready (ok = false)
            f.unready = f.unready - 1
            return { ok = false, id = id, slots = {}, mult = 1 }
        end
        local slots = {}
        for i, s in ipairs(c.slots) do slots[i] = { item = s.item, amount = s.amount, max = s.max } end
        return { ok = true, id = id + 5000, slots = slots, mult = f.cont_mult }
    end
    function io.container_ids()
        local out = {}
        for id in pairs(f.containers) do out[#out + 1] = id end
        table.sort(out)
        return out
    end
    function io.restore_mode() return f.mode end   -- nil (default) = "on" in bpu_build
    function io.remember(key, list)
        f.remembered[key] = list
        f.remember_at = f.calls.rm + f.calls.pl + f.calls.mv
    end
    -- io.send_inv: one raw InventoryInteraction. f.cmd_log records every send. f.stall_after = n: sends after the n-th return
    -- true and apply nothing. f.delay = ms: applied when the clock reaches send time + delay. A send while an earlier delayed
    -- batch is still pending counts in f.inflight.
    -- f.refuse_after = n: send n+1 returns false (not recorded as applied). f.stall_after: as above.
    function io.send_inv(prim, sec, slot0, action)
        f.attempts = (f.attempts or 0) + 1
        if action == 5 then   -- SORT (split route): the unit inventory, sec 0, slot 0. Logged, refused on request, applied unless noop_sort.
            f.sorts = (f.sorts or 0) + 1
            if prim ~= 202 or sec ~= 0 or slot0 ~= 0 then f.violations[#f.violations + 1] = "sort sent with wrong args" end
            f.cmd_log[#f.cmd_log + 1] = { prim, sec, slot0, action, f.clock }
            f.sort_at = f.sort_at or f.clock
            if f.refuse_sort then return false, "refused" end
            if not f.noop_sort then f.sort_apply() end
            return true
        end
        if action ~= 2 then f.violations[#f.violations + 1] = ("action %s sent: restore is TRANSFER (2) only"):format(tostring(action)) end
        if (f.fail_next or 0) > 0 then f.fail_next = f.fail_next - 1; return false, "UFunction expected 1 parameters, received 2" end
        f.cmd_log[#f.cmd_log + 1] = { prim, sec, slot0, action, f.clock }
        if #f.cmd_log == 1 then f.first_unready = f.unready end
        if f.refuse_after and #f.cmd_log > f.refuse_after then return false end
        if f.noop_inv then return true end
        if f.stall_after and #f.cmd_log > f.stall_after then return true end
        flush()
        if f.delay then
            if #f.pending > 0 and f.pending[1].sent < f.clock then f.inflight = f.inflight + 1 end
            f.pending[#f.pending + 1] = { sent = f.clock, at = f.clock + f.delay, run = function() apply_inv(prim, sec, slot0, action) end }
        else
            apply_inv(prim, sec, slot0, action)
        end
        return true
    end
    -- SORT model: non-empty slots to the front, stable by item name, the rest empty
    function f.sort_apply()
        local items = {}
        for i, s in ipairs(f.inv.unit.slots) do if s.item ~= "" and s.amount > 0 then items[#items + 1] = { s = s, i = i } end end
        table.sort(items, function(a, b) if a.s.item ~= b.s.item then return a.s.item < b.s.item end return a.i < b.i end)
        local copy = {}
        for k, e in ipairs(items) do copy[k] = { item = e.s.item, amount = e.s.amount, max = e.s.max } end
        for i, s in ipairs(f.inv.unit.slots) do
            if copy[i] then s.item, s.amount, s.max = copy[i].item, copy[i].amount, copy[i].max else s.item, s.amount = "", 0 end
        end
    end
    -- io.split (MSCore 0.7.6 native, split route only): exact split inside the unit inventory, applied at once.
    -- f.split_fail_n = n: the next n calls are refused (nothing applied). f.split_noop: returns true, applies nothing.
    -- Violations: non-unit inventory, slot out of range, dst not empty, amount more than the source holds.
    if spec.split then
        f.splits = {}
        function io.split(inv, src0, amount, dst0)
            f.splits[#f.splits + 1] = { inv, src0, amount, dst0 }
            local slots = (inv == 202 and f.inv.unit.slots) or (inv == 101 and f.inv.player.slots)
            if not slots then f.violations[#f.violations + 1] = "split on an unregistered inventory"; return false, "inv" end
            local src, dst = slots[src0 + 1], slots[dst0 + 1]
            if not src or not dst then f.violations[#f.violations + 1] = "split slot out of range"; return false, "range" end
            if (f.split_fail_n or 0) > 0 then f.split_fail_n = f.split_fail_n - 1; return false, "split refused" end
            if f.split_noop then return true end
            if dst.amount > 0 then f.violations[#f.violations + 1] = "split into a non-empty slot" end
            if src.amount < amount then f.violations[#f.violations + 1] = "split more than the slot holds" end
            dst.item, dst.amount, dst.max = src.item, amount, src.max
            src.amount = src.amount - amount
            if src.amount <= 0 then src.item, src.amount = "", 0 end
            return true
        end
    end
    if spec.give then
        f.gives = {}
        function io.give_creative(item, n)
            f.gives[#f.gives + 1] = { item, n }
            if f.give_fail then return false, "give refused" end
            if not f.give_noop then put(f.inv.player.slots, item, n, mx(item)) end
            return true
        end
    end
    f.io = io
    return f
end

local function plan_for(f, o)
    local removed = {}
    for i, m in ipairs(o.removed or {}) do   -- per-machine refund (plan.removed entries); a single removal gets the plan refund
        local c = {}
        for k, v in pairs(m) do c[k] = v end
        c.refund = m.refund or o.refund or {}
        removed[i] = c
    end
    return {
        valid = true, station = 1, fp = f.io.fingerprint(f.station), name = "T",
        place = o.place or {}, kept = {}, chg = {}, removed = removed,
        need = o.need or {}, refund = o.refund or {}, refund_cost = o.refund_cost, recChanged = 0,
    }
end

-- steps the builder every 250 ms until it leaves 'working'
local function run(b, f, limit)
    local n = 0
    while b:status().state == "working" and n < (limit or 800) do
        f.clock = f.clock + 250
        b:tick(f.clock)
        n = n + 1
    end
    return b:status()
end

local function starts_with(s, p) return type(s) == "string" and s:sub(1, #p) == p end
local DONE2 = "sent: placed 2, removed 0 (the game updates its blueprint view in about 30 s)"

-- ===== pure helpers =====
do
    local need = { ITEM_X = 10 }
    check(P.total_check(need, { ITEM_X = 3 }, { ITEM_X = 3 }, { ITEM_X = 4 }) == "", "totals: need 10 = player 3 + unit 4 + refund 3 ok")
    check(P.total_check(need, { ITEM_X = 2 }, { ITEM_X = 3 }, { ITEM_X = 4 }) == "not enough items: X x1", "totals: refund 2 -> X x1 short")
    check(P.total_check({ ITEM_A = 5, ITEM_B = 5 }, {}, {}, {}) == "not enough items: A x5, B x5", "totals: two short items listed")
    check(P.total_check({}, {}, {}, {}) == "", "totals: empty need ok")

    check(same(P.stage_moves({ S("ITEM_A", 5) }, { ITEM_A = 3 }), { 1 }), "stage: stack 5, shortfall 3 -> one move")
    local u3 = { S("ITEM_A", 5), S("ITEM_A", 5), S("ITEM_A", 5) }
    check(same(P.stage_moves(u3, { ITEM_A = 8 }), { 1, 2 }), "stage: shortfall 8 over 5,5,5 -> slots 1,2 in order")
    check(same(P.stage_moves({ E(), S("ITEM_A", 5) }, { ITEM_A = 3 }), { 2 }), "stage: empty slot skipped")
    check(#P.stage_moves(u3, {}) == 0 and #P.stage_moves(u3, { ITEM_A = 0 }) == 0, "stage: shortfall 0 -> no moves")
    local u10 = {}
    for i = 1, 10 do u10[i] = S("ITEM_A", 5) end
    check(#P.stage_moves(u10, { ITEM_A = 1000 }, 3) == 3, "stage: maxMoves cap")

    local maxA = { ITEM_A = 100 }
    check(P.chunk_len({ { ITEM_A = 150 } }, 1, { E() }, maxA) == 0, "chunk: 1 free slot, A 150 max 100 -> 0")
    local c60 = { { ITEM_A = 60 }, { ITEM_A = 60 } }
    check(P.chunk_len(c60, 1, { E(), E() }, { ITEM_A = 50 }) == 1, "chunk: 2 free slots, A 60 max 50 -> 1 per chunk")
    check(P.chunk_len(c60, 1, { S("ITEM_A", 50), S("ITEM_A", 50), S("ITEM_A", 20) }, { ITEM_A = 50 }) == 2, "chunk: 120 A already held -> 2")
    local c100 = { { ITEM_A = 100 }, { ITEM_A = 100 }, { ITEM_A = 100 }, { ITEM_A = 100 } }
    check(P.chunk_len(c100, 1, { S("ITEM_A", 100, 100), S("ITEM_A", 100, 100), S("ITEM_A", 100, 100), S("ITEM_A", 100, 100) }, maxA) == 4, "chunk: player holds all -> full length")
    local c5 = { { ITEM_A = 5 }, { ITEM_A = 5 }, { ITEM_A = 5 } }
    check(P.chunk_len(c5, 1, inv({}, 10), { ITEM_A = 50 }) == 3, "chunk: ample slots -> all")

    check(P.overlaps({ { x = 1, y = 1 } }, { { x = 1, y = 1 } }) and not P.overlaps({ { x = 1, y = 1 } }, { { x = 2, y = 1 } }),
          "overlaps: placement on a removed cell only")
end

-- ===== flows =====
-- plain build, staging from the unit
do
    local f = fake({ player = inv({ S("ITEM_Plate", 1) }, 10), unit = inv({ S("ITEM_Plate", 4) }, 2) })
    local b = B.new(f.io)
    local plan = plan_for(f, { place = { M("BP_A", 0, 0, { ITEM_Plate = 3 }), M("BP_B", 5, 0, { ITEM_Plate = 2 }) }, need = { ITEM_Plate = 5 } })
    local ok, msg = b:start(plan, {})
    check(ok and msg == "ok build started", "plain: start ok")
    local st = run(b, f)
    check(st.state == "done" and st.placed == 2 and st.moved_in == 1 and st.chunk == "1/1" and st.text == DONE2, "plain: staged from unit, placed 2, final text")
    check(f.calls.rm == 0 and f.calls.pl == 2 and same(f.moves[1], { 202, 101, 0, 2 }) and same(f.moves[2], { 202, 0, 0, 3 }),
          "plain: no removals, unit->player pair (press 2 then release 3) on slot 0")
end

-- removal, refund arrives in the player inventory -> whole refund stack moved to the unit (press+release, no result poll), text 'refund moved'
do
    local f = fake({ player = inv({ S("ITEM_Plate", 1) }, 3), unit = inv({}, 3),
                     station = { { id = 7, bcls = "BP_OLD", x = 0, y = 0 } }, refund_of = { [7] = { ITEM_Gear = 2 } } })
    local b = B.new(f.io)
    local plan = plan_for(f, { place = { M("BP_NEW", 5, 0, { ITEM_Plate = 1 }) }, need = { ITEM_Plate = 1 },
                               refund = { ITEM_Gear = 2 }, removed = { { id = 7, bcls = "BP_OLD", x = 0, y = 0 } } })
    local t0 = f.clock
    local ok = b:start(plan, {})
    local st = run(b, f)
    check(ok and st.state == "done" and st.removed == 1 and st.placed == 1 and f.calls.mv == 2
          and same(f.moves[1], { 101, 202, 1, 2 }) and same(f.moves[2], { 101, 0, 1, 3 }),
          "moveout: refund stack (player slot 2) sent as press+release to the unit (" .. st.text .. ")")
    check(st.text == "sent: placed 1, removed 1, refund moved to the unit (the game updates its blueprint view in about 30 s)",
          "moveout: final text names the refund move")
    check(f.inv.unit.slots[1].item == "ITEM_Gear" and f.inv.unit.slots[1].amount == 2 and f.inv.player.slots[2].item == "",
          "moveout: refund now in the unit, player slot empty")
    check(f.clock - t0 <= 2000, "moveout: success path within 2 s fake time (" .. (f.clock - t0) .. " ms)")
end

-- refund does not fit the player inventory -> refused at start, nothing removed, no move sent
do
    local f = fake({ player = inv({ S("ITEM_Gear", 50, 50), S("ITEM_Junk", 50, 50) }, 2),
                     unit = inv({ E(), S("ITEM_Plate", 1), E() }, 3),
                     station = { { id = 7, bcls = "BP_OLD", x = 0, y = 0 } }, refund_of = { [7] = { ITEM_Gear = 2 } } })
    local b = B.new(f.io)
    local plan = plan_for(f, { place = { M("BP_NEW", 0, 0, { ITEM_Plate = 1 }) }, need = { ITEM_Plate = 1 },
                               refund = { ITEM_Gear = 2 }, removed = { { id = 7, bcls = "BP_OLD", x = 0, y = 0 } } })
    local ok, msg = b:start(plan, {})
    local st = b:status()
    check(not ok and st.state == "error" and st.text:find("does not fit the player inventory", 1, true)
          and f.calls.rm == 0 and f.calls.mv == 0 and f.calls.pl == 0, "refund room: single refund does not fit -> stall at start, nothing sent (" .. msg .. ")")
end

-- full player inventory, nothing to chunk
do
    local f = fake({ player = inv({ S("ITEM_Junk", 50, 50) }, 1), unit = inv({ S("ITEM_Plate", 1) }, 1) })
    local b = B.new(f.io)
    b:start(plan_for(f, { place = { M("BP_A", 0, 0, { ITEM_Plate = 1 }) }, need = { ITEM_Plate = 1 } }), {})
    local st = run(b, f)
    check(st.state == "error" and starts_with(st.text, "player inventory full") and st.text:find("(0 of 1 placed)", 1, true) and f.calls.pl == 0,
          "full inventory: error with counts, nothing placed")
end

-- full player inventory -> chunks of one machine, refilled from the unit
do
    local f = fake({ player = inv({}, 1), unit = inv({ S("ITEM_Plate", 30, 50), S("ITEM_Plate", 30, 50) }, 2), max = { ITEM_Plate = 50 } })
    local b = B.new(f.io)
    local plan = plan_for(f, { place = { M("BP_A", 0, 0, { ITEM_Plate = 30 }), M("BP_B", 2, 0, { ITEM_Plate = 30 }) }, need = { ITEM_Plate = 60 } })
    b:start(plan, {})
    local st = run(b, f)
    check(st.state == "done" and st.chunk == "2/2" and st.placed == 2 and st.moved_in == 2, "chunking: 2 chunks of 1, placed 2")
end

-- missing items -> refused before any change
do
    local f = fake({ player = inv({}, 1), unit = inv({ S("ITEM_Plate", 3) }, 1) })
    local b = B.new(f.io)
    local ok, msg = b:start(plan_for(f, { place = { M("BP_A", 0, 0, { ITEM_Plate = 10 }) }, need = { ITEM_Plate = 10 } }), {})
    local st = b:status()
    check(not ok and msg == "error: not enough items: Plate x7" and st.state == "error" and
          st.text == "not enough items: Plate x7 (placed 0, removed 0, moved_in 0)", "missing: refused with 'not enough items: Plate x7'")
    check(f.calls.rm == 0 and f.calls.mv == 0 and f.calls.pl == 0 and f.calls.ch == 0, "missing: no removal, move or place call")
end

-- station changed since import -> refused before any change
do
    local f = fake({ player = inv({}, 2), unit = inv({ S("ITEM_Plate", 5) }, 1), station = { { id = 3, bcls = "BP_X", x = 0, y = 0 } } })
    local b = B.new(f.io)
    local plan = plan_for(f, { place = { M("BP_A", 0, 0, { ITEM_Plate = 1 }) }, need = { ITEM_Plate = 1 } })
    table.insert(f.station, { id = 4, bcls = "BP_Y", x = 2, y = 0 })
    local ok = b:start(plan, {})
    check(not ok and b:status().text == "station changed since import, import again (placed 0, removed 0, moved_in 0)", "station changed: refused")
    check(f.calls.rm == 0 and f.calls.mv == 0 and f.calls.pl == 0, "station changed: no call")
end

-- import first / idle / nothing to build
do
    local f = fake({ player = inv({}, 1), unit = inv({}, 1) })
    local b = B.new(f.io)
    check(b:status().state == "idle", "idle: status before start")
    local ok, msg = b:start(nil, {})
    check(not ok and msg == "error: import first", "no plan: 'import first'")
    local ok2, msg2 = b:start({ valid = true, station = 1, fp = f.io.fingerprint(f.station), place = {}, removed = {}, chg = {} }, {})
    check(ok2 and msg2 == "ok nothing to build" and b:status().state == "done", "empty plan: nothing to build")
end

-- creative: no moves, no cost check
do
    local f = fake({ player = inv({}, 2), unit = inv({}, 2), creative = true })
    local b = B.new(f.io)
    local plan = plan_for(f, { place = { M("BP_A", 0, 0, { ITEM_Plate = 5 }), M("BP_B", 2, 0, { ITEM_Plate = 5 }) }, need = { ITEM_Plate = 10 } })
    local ok = b:start(plan, {})
    local st = run(b, f)
    check(ok and st.state == "done" and st.placed == 2 and st.moved_in == 0 and f.calls.mv == 0, "creative: placed without moves or cost check")
end

-- cancel and busy
do
    local f = fake({ player = inv({ S("ITEM_Plate", 1) }, 10), unit = inv({ S("ITEM_Plate", 4) }, 2), noop_moves = true })
    local b = B.new(f.io)
    b:start(plan_for(f, { place = { M("BP_A", 0, 0, { ITEM_Plate = 3 }), M("BP_B", 5, 0, { ITEM_Plate = 2 }) }, need = { ITEM_Plate = 5 } }), {})
    b:tick(1250)
    local okb, msgb = b:start(plan_for(f, {}), {})
    check(not okb and msgb == "error: busy: another build is running", "busy: second start refused while running")
    local okc, msgc = b:cancel()
    local st = b:status()
    check(okc and msgc == "ok bp_build cancelled" and st.state == "error" and starts_with(st.text, "cancelled") and st.moved_in == 1, "cancel: error|cancelled with counts")
    b:tick(9000)
    check(b:status().state == "error" and not select(1, b:cancel()), "cancel: nothing runs after cancel")
end

-- whole-run timeout
do
    local f = fake({ player = inv({ S("ITEM_Plate", 1) }, 10), unit = inv({ S("ITEM_Plate", 4) }, 2), noop_moves = true })
    local b = B.new(f.io)
    b:start(plan_for(f, { place = { M("BP_A", 0, 0, { ITEM_Plate = 3 }), M("BP_B", 5, 0, { ITEM_Plate = 2 }) }, need = { ITEM_Plate = 5 } }), {})
    b:tick(1250)
    b:tick(1000 + 31000)
    check(b:status().state == "error" and starts_with(b:status().text, "staging stalled"), "timeout: staging stall (30 s) fires before the 300 s no-progress cap")
end

-- staging never moves anything -> stalled after 30 s
do
    local f = fake({ player = inv({ S("ITEM_Plate", 1) }, 10), unit = inv({ S("ITEM_Plate", 4) }, 2), noop_moves = true })
    local b = B.new(f.io)
    b:start(plan_for(f, { place = { M("BP_A", 0, 0, { ITEM_Plate = 3 }), M("BP_B", 5, 0, { ITEM_Plate = 2 }) }, need = { ITEM_Plate = 5 } }), {})
    local st = run(b, f)
    check(st.state == "error" and starts_with(st.text, "staging stalled: Plate x4"), "staging: no progress -> stalled")
end

-- partial quick moves: unit slot gives 20 per move (fake limit), the build re-issues until covered
do
    local f = fake({ player = inv({}, 1), unit = inv({ S("ITEM_Plate", 50, 50) }, 1), max_per_move = 20 })
    local b = B.new(f.io)
    b:start(plan_for(f, { place = { M("BP_A", 0, 0, { ITEM_Plate = 30 }) }, need = { ITEM_Plate = 30 } }), {})
    local st = run(b, f)
    check(st.state == "done" and st.moved_in == 2 and st.placed == 1 and f.inv.unit.slots[1].amount == 10,
          "partial moves: 2 rounds of 20, unit keeps 10, placed 1")
end

-- placed machine one cell off the plan: done at once after the last send, the station view is not read
do
    local f = fake({ player = inv({}, 2), unit = inv({ S("ITEM_Plate", 10) }, 2), shift_x = 1 })
    local b = B.new(f.io)
    local t0 = f.clock
    b:start(plan_for(f, { place = { M("BP_A", 0, 0, { ITEM_Plate = 3 }) }, need = { ITEM_Plate = 3 } }), {})
    local st = run(b, f)
    check(st.state == "done" and st.text == "sent: placed 1, removed 0 (the game updates its blueprint view in about 30 s)"
          and f.clock - t0 < 2000, "count met, position shifted: done, no view check")
end

-- unit has no items to stage: a machine not charged is not seen (last command sent = done, no charge poll)
do
    local f = fake({ player = inv({ S("ITEM_Plate", 3) }, 2), unit = inv({}, 2), no_charge = true })
    local b = B.new(f.io)
    local t0 = f.clock
    b:start(plan_for(f, { place = { M("BP_A", 0, 0, { ITEM_Plate = 3 }) }, need = { ITEM_Plate = 3 } }), {})
    check(b:status().state == "done" and f.clock == t0 and f.calls.pl == 1, "last chunk: done at once, no charge poll")
end

-- intermediate chunk not charged: the next chunk cannot be staged, error after CHARGE_MS
do
    local f = fake({ player = inv({}, 1), unit = inv({ S("ITEM_Plate", 30, 50), S("ITEM_Plate", 30, 50) }, 2), max = { ITEM_Plate = 50 }, no_charge = true })
    local b = B.new(f.io)
    local t0 = f.clock
    b:start(plan_for(f, { place = { M("BP_A", 0, 0, { ITEM_Plate = 30 }), M("BP_B", 2, 0, { ITEM_Plate = 30 }) }, need = { ITEM_Plate = 60 } }), {})
    local st = run(b, f)
    check(st.state == "error" and st.text:find("chunk 1: items were not charged (sim did not accept the build)", 1, true)
          and f.clock - t0 <= 31000, "chunk 1 not charged: error 'items were not charged' within 30 s (" .. st.text .. " at " .. (f.clock - t0) .. ")")
end

-- charge appears: the station view is not needed, and a single chunk is done at once (drop_place: never on the station)
do
    local f = fake({ player = inv({}, 2), unit = inv({ S("ITEM_Plate", 10) }, 2), drop_place = true })
    local b = B.new(f.io)
    local t0 = f.clock
    b:start(plan_for(f, { place = { M("BP_A", 0, 0, { ITEM_Plate = 3 }) }, need = { ITEM_Plate = 3 } }), {})
    local st = run(b, f)
    check(st.state == "done" and st.placed == 1 and f.clock - t0 < 2000 and f.calls.pl == 1,
          "station view not needed: done, machine sent")
end

-- live class name differs from the plan (BP_A -> BP_A_Live): total met -> done quickly, new machines traced
do
    local f = fake({ player = inv({}, 2), unit = inv({ S("ITEM_Plate", 10) }, 2), live_bcls = "BP_A_Live",
                     station = { { id = 3, bcls = "BP_Old", x = 9, y = 9, h = 0, rot = 0 } } })
    local traces = {}
    f.io.trace = function(t) traces[#traces + 1] = t end
    local b = B.new(f.io)
    local t0 = f.clock
    b:start(plan_for(f, { place = { M("BP_A", 0, 0, { ITEM_Plate = 3 }), M("BP_A", 2, 0, { ITEM_Plate = 3 }) }, need = { ITEM_Plate = 6 } }), {})
    local st = run(b, f)
    check(st.state == "done" and st.placed == 2 and f.clock - t0 < 20000,
          "class differs: done, placed 2")
end

-- machine missing from the station view after the charge: still done (the view is not the acceptance rule)
do
    local f = fake({ player = inv({}, 2), unit = inv({ S("ITEM_Plate", 10) }, 2), vanish_after = 1000 })
    local b = B.new(f.io)
    b:start(plan_for(f, { place = { M("BP_A", 0, 0, { ITEM_Plate = 3 }), M("BP_A", 2, 0, { ITEM_Plate = 3 }) }, need = { ITEM_Plate = 6 } }), {})
    local st = run(b, f)
    check(st.state == "done" and st.placed == 2 and st.text == DONE2, "view lag: machine missing from the view does not fail the build")
end

-- removal before a placement on the same cell (overlap): refund shows -> placing at the first poll; no refund -> 500 ms settle
do
    local function rm_gap(refund_of)
        local f = fake({ player = inv({ S("ITEM_Plate", 1) }, 3), unit = inv({}, 3),
                         station = { { id = 7, bcls = "BP_OLD", x = 0, y = 0 } }, refund_of = refund_of })
        local b = B.new(f.io)
        b:start(plan_for(f, { place = { M("BP_NEW", 0, 0, { ITEM_Plate = 1 }) }, need = { ITEM_Plate = 1 },
                              refund = { ITEM_Gear = 2 }, removed = { { id = 7, bcls = "BP_OLD", x = 0, y = 0 } } }), {})
        local rm_at = f.calls.rm == 1 and f.clock   -- removals are sent inside start
        local pl_at
        while b:status().state == "working" do
            f.clock = f.clock + 250
            b:tick(f.clock)
            if not pl_at and f.calls.pl == 1 then pl_at = f.clock end
        end
        return b:status(), pl_at and rm_at and pl_at - rm_at
    end
    local st1, gap1 = rm_gap({ [7] = { ITEM_Gear = 2 } })
    local st2, gap2 = rm_gap({})   -- the refund never shows up in the fake: the cap (1.5 s) decides, no move
    check(st1.state == "done" and gap1 == 250 and st1.text:find("refund moved to the unit", 1, true), "removal: refund arrived, moved and placed at the first poll (" .. tostring(gap1) .. " ms)")
    check(st2.state == "error" and gap2 == nil and st2.text:find("stopped after 1 removals: the refund did not show", 1, true),
          "removal: refund not seen in 2 s -> stall, placement not sent (" .. st2.text .. ")")
end

-- no overlap, refund items: the removal is polled for the refund (250 ms), then the move and the placement; nothing sent in start
do
    local f = fake({ player = inv({ S("ITEM_Plate", 1) }, 3), unit = inv({}, 3),
                     station = { { id = 7, bcls = "BP_OLD", x = 0, y = 0 } }, refund_of = { [7] = { ITEM_Gear = 2 } } })
    local b = B.new(f.io)
    local ok = b:start(plan_for(f, { place = { M("BP_NEW", 5, 0, { ITEM_Plate = 1 }) }, need = { ITEM_Plate = 1 },
                          refund = { ITEM_Gear = 2 }, removed = { { id = 7, bcls = "BP_OLD", x = 0, y = 0 } } }), {})
    check(ok and b:status().state == "working" and f.calls.rm == 1 and f.calls.pl == 0 and f.calls.mv == 0, "no overlap: removal sent in start, refund polled first")
    local st = run(b, f)
    check(st.state == "done" and f.calls.pl == 1 and f.calls.mv == 2, "no overlap: refund move and placement sent, done")
end

-- no overlap, no refund items: removal and placement go back to back inside start (no wait)
do
    local f = fake({ player = inv({ S("ITEM_Plate", 1) }, 3), unit = inv({}, 3), station = { { id = 7, bcls = "BP_OLD", x = 0, y = 0 } } })
    local b = B.new(f.io)
    local ok = b:start(plan_for(f, { place = { M("BP_NEW", 5, 0, { ITEM_Plate = 1 }) }, need = { ITEM_Plate = 1 },
                          removed = { { id = 7, bcls = "BP_OLD", x = 0, y = 0 } } }), {})
    check(ok and b:status().state == "done" and f.calls.rm == 1 and f.calls.pl == 1 and f.calls.mv == 0, "no refund, no overlap: removal and placement sent in start, done")
end

-- fingerprint call fails: traced, the build goes on. A real mismatch still refuses.
do
    local traces = {}
    local f = fake({ player = inv({ S("ITEM_Plate", 1) }, 3), unit = inv({}, 3) })
    f.io.trace = function(t) traces[#traces + 1] = t end
    local plan = plan_for(f, { place = { M("BP_A", 0, 0, { ITEM_Plate = 1 }) }, need = { ITEM_Plate = 1 } })
    f.io.fingerprint = function() error("attempt to perform bitwise operation on a string value") end
    local b = B.new(f.io)
    local ok = b:start(plan, {})
    local traced = false
    for _, t in ipairs(traces) do if t:find("fingerprint failed, staleness check skipped", 1, true) then traced = true end end
    check(ok and b:status().state == "done" and traced, "fingerprint error: traced, build goes on, done")

    local f2 = fake({ player = inv({ S("ITEM_Plate", 1) }, 3), unit = inv({}, 3) })
    local plan2 = plan_for(f2, { place = { M("BP_A", 0, 0, { ITEM_Plate = 1 }) }, need = { ITEM_Plate = 1 } })
    plan2.fp = "stale"
    local ok2, msg2 = B.new(f2.io):start(plan2, {})
    check(not ok2 and msg2 == "error: station changed since import, import again", "fingerprint mismatch: still refused")
end

-- no settle refusal: a second build starts at once after a build that placed machines
do
    local f = fake({ player = inv({}, 2), unit = inv({ S("ITEM_Plate", 10) }, 2) })
    local b = B.new(f.io)
    b:start(plan_for(f, { place = { M("BP_A", 0, 0, { ITEM_Plate = 3 }) }, need = { ITEM_Plate = 3 } }), {})
    run(b, f)
    local b2 = B.new(f.io)
    local ok2, msg2 = b2:start(plan_for(f, {}), {})
    check(ok2 and msg2 == "ok nothing to build", "no refusal: second build starts right after a build")
end

-- live overlay hook (io.note_build): a run that placed or removed machines reports them; a refused run reports nothing
do
    local f = fake({ player = inv({}, 2), unit = inv({ S("ITEM_Plate", 10) }, 2) })
    local noted
    f.io.note_build = function(p, r) noted = { p = p, r = r } end
    local b = B.new(f.io)
    b:start(plan_for(f, { place = { M("BP_A", 0, 0, { ITEM_Plate = 3 }) }, need = { ITEM_Plate = 3 } }), {})
    run(b, f)
    check(noted and #noted.p == 1 and noted.p[1].bcls == "BP_A" and #noted.r == 0, "note_build: placed machine reported after the run")

    local f2 = fake({ station = { { id = 7, bcls = "BP_OLD", x = 0, y = 0 } }, player = inv({ S("ITEM_Plate", 1) }, 3), unit = inv({}, 3),
                      refund_of = { [7] = { ITEM_Gear = 2 } } })
    local noted2
    f2.io.note_build = function(p, r) noted2 = { p = p, r = r } end
    local b2 = B.new(f2.io)
    b2:start(plan_for(f2, { place = { M("BP_NEW", 0, 0, { ITEM_Plate = 1 }) }, need = { ITEM_Plate = 1 },
                            refund = { ITEM_Gear = 2 }, removed = { { id = 7, bcls = "BP_OLD" } } }), {})
    run(b2, f2)
    check(noted2 and #noted2.p == 1 and #noted2.r == 1 and noted2.r[1] == 7, "note_build: removed id reported")

    local f3 = fake({ player = inv({ S("ITEM_Plate", 1) }, 1), unit = inv({ S("ITEM_Plate", 4) }, 1) })
    local noted3
    f3.io.note_build = function() noted3 = true end
    local b3 = B.new(f3.io)
    b3:start(plan_for(f3, { place = { M("BP_A", 0, 0, { ITEM_Plate = 9 }) }, need = { ITEM_Plate = 9 } }), {})
    check(b3:status().state == "error" and noted3 == nil, "note_build: refused build (nothing placed) reports nothing")
end

-- ===== effective stack size: native max 1 is wrong, raw MaxStackSize 200 * StackMultiplier 8 = 1600 per slot =====
local EFF = { raw = { ITEM_Frame = 200, ITEM_Coil = 10 }, max = { ITEM_Frame = 1600, ITEM_Coil = 80 }, mult = { player = 8, unit = 202 } }
-- refund 2 frames (merge room in the 190 stack) + 2 coils (1 new slot): fits with 1 free slot. Old max 1 -> refused.
do
    local f = fake(setmetatable({ player = { E(), E(), S("ITEM_Frame", 190, 1) }, unit = inv({}, 3),
                     station = { { id = 7, bcls = "BP_OLD", x = 0, y = 0 } }, refund_of = { [7] = { ITEM_Frame = 2, ITEM_Coil = 2 } } }, { __index = EFF }))
    local b = B.new(f.io)
    b:start(plan_for(f, { removed = { { id = 7, bcls = "BP_OLD" } }, refund = { ITEM_Frame = 2, ITEM_Coil = 2 } }), {})
    local st = run(b, f)
    check(st.state == "done" and st.removed == 1 and not starts_with(st.text, "stopped"),
          "refund eff max: 2 frames (merge) + 2 coils (1 slot) with 2 free slots (1 kept back) -> done (" .. st.text .. ")")
end

-- refund does not fit, unit has room: stall at start (the room is the player's, the unit does not take it)
do
    local f = fake(setmetatable({ player = { S("ITEM_Junk", 50, 50), S("ITEM_Other", 50, 50) }, unit = inv({}, 6),
                     station = { { id = 7, bcls = "BP_OLD", x = 0, y = 0 } }, refund_of = { [7] = { ITEM_Frame = 5, ITEM_Coil = 10 } } }, { __index = EFF }))
    local b = B.new(f.io)
    b:start(plan_for(f, { removed = { { id = 7, bcls = "BP_OLD" } }, refund = { ITEM_Frame = 5, ITEM_Coil = 10 } }), {})
    local st = run(b, f)
    check(st.state == "error" and st.text:find("does not fit the player inventory", 1, true) and f.calls.rm == 0 and f.calls.mv == 0,
          "refund room: player full, nothing removed, no moves (" .. st.text .. ")")
end

-- refund does not fit at all: stall at start, nothing removed
do
    local f = fake(setmetatable({ player = { S("ITEM_Junk", 50, 50), S("ITEM_Other", 50, 50) }, unit = inv({ S("ITEM_Plate", 50, 50) }, 1),
                     station = { { id = 7, bcls = "BP_OLD", x = 0, y = 0 } }, refund_of = { [7] = { ITEM_Frame = 5, ITEM_Coil = 10 } } }, { __index = EFF }))
    local b = B.new(f.io)
    b:start(plan_for(f, { removed = { { id = 7, bcls = "BP_OLD" } }, refund = { ITEM_Frame = 5, ITEM_Coil = 10 } }), {})
    local st = run(b, f)
    check(st.state == "error" and st.text:find("does not fit the player inventory", 1, true) and f.calls.rm == 0,
          "refund room: unit full too -> error, nothing removed (" .. st.text .. ")")
end

-- overlap + refund never shows up in the view: the arrival cap (2 s) stalls the run, the placement is not sent, no moveout
do
    local f = fake({ player = inv({ S("ITEM_Plate", 1) }, 3), unit = inv({}, 3),
                     station = { { id = 7, bcls = "BP_OLD", x = 0, y = 0 } } })   -- no refund_of: the refund never shows
    local b = B.new(f.io)
    local t0 = f.clock
    b:start(plan_for(f, { place = { M("BP_NEW", 0, 0, { ITEM_Plate = 1 }) }, need = { ITEM_Plate = 1 },
                          refund = { ITEM_Gear = 2 }, removed = { { id = 7, bcls = "BP_OLD", x = 0, y = 0 } } }), {})
    local st = run(b, f)
    check(st.state == "error" and st.removed == 1 and st.placed == 0 and f.calls.mv == 0 and f.calls.pl == 0 and f.clock - t0 == 2000
          and st.text == "stopped after 1 removals: the refund did not show in the player inventory within 2 s, check the game, then Build again",
          "refund never shown: stall at 2 s, nothing placed, no moveout (" .. st.text .. ")")
end

-- ===== batched removal: n removals, each refunds `each` Gear; player free slots decide the batch =====
-- Gear max 50 per slot (raw 50, mult 1). Player 4 empty slots, 1 kept back -> 3 slots = 150 Gear = 15 machines per batch.
local function many(n, each)
    local st, ref, rem, tot = {}, {}, {}, {}
    for i = 1, n do
        st[i] = { id = i, bcls = "BP_OLD", x = i, y = 0 }
        ref[i] = each > 0 and { ITEM_Gear = each } or {}
        rem[i] = { id = i, bcls = "BP_OLD", x = i, y = 0, refund = ref[i] }
        if each > 0 then tot.ITEM_Gear = (tot.ITEM_Gear or 0) + each end
    end
    local refund_of = {}
    for i = 1, n do refund_of[i] = ref[i] end
    return { station = st, refund_of = refund_of, removed = rem, total = tot }
end
local function gear_in(slots)
    local n = 0
    for _, s in ipairs(slots) do if s.item == "ITEM_Gear" then n = n + s.amount end end
    return n
end
local function presses(f)
    local n = 0
    for _, mv in ipairs(f.moves) do if mv[4] == 2 then n = n + 1 end end
    return n
end
do
    local m = many(40, 10)
    local f = fake({ player = inv({}, 4), unit = inv({}, 10), raw = { ITEM_Gear = 50 }, station = m.station, refund_of = m.refund_of })
    local noted
    f.io.note_build = function(p, r) noted = { p = p, r = r } end
    local b = B.new(f.io)
    local ok = b:start(plan_for(f, { removed = m.removed, refund = m.total }), {})
    local st = run(b, f, 4000)
    check(ok and st.state == "done" and st.removed == 40 and f.calls.rm == 40, "batches: 40 removals in batches, all sent (" .. st.text .. ")")
    check(gear_in(f.inv.unit.slots) == 400 and gear_in(f.inv.player.slots) == 0, "batches: all 400 Gear moved to the unit, none lost")
    check(presses(f) == 8, "batches: 15+15+10 removals, stacks moved 3+3+2 (presses " .. presses(f) .. ")")
    check(noted and #noted.r == 40, "batches: note_build reports the 40 removed ids")
end

-- moves never drain: the first batch is removed, the moved refund stays in the player -> STALL after 3 s, no further removal
do
    local m = many(40, 10)
    local f = fake({ player = inv({}, 4), unit = inv({}, 10), raw = { ITEM_Gear = 50 }, station = m.station, refund_of = m.refund_of, noop_moves = true })
    local noted
    f.io.note_build = function(p, r) noted = { p = p, r = r } end
    local b = B.new(f.io)
    b:start(plan_for(f, { removed = m.removed, refund = m.total }), {})
    local st = run(b, f, 4000)
    check(st.state == "error" and st.removed == 15 and f.calls.rm == 15 and st.text ==
          "stopped after 15 removals: the game did not apply the move (see bpu_trace.log)",
          "stall: moves never drain -> stop after the first batch, no more removals (" .. st.text .. ")")
    check(noted and #noted.r == 15, "stall: note_build reports only the 15 sent removals")
end

-- unit inventory full: the refund cannot be moved out -> STALL before the moves, after the first batch
do
    local m = many(40, 10)
    local f = fake({ player = inv({}, 4), unit = inv({ S("ITEM_Plate", 50, 50) }, 1), raw = { ITEM_Gear = 50 }, station = m.station, refund_of = m.refund_of })
    local b = B.new(f.io)
    b:start(plan_for(f, { removed = m.removed, refund = m.total }), {})
    local st = run(b, f, 4000)
    check(st.state == "error" and st.removed == 15 and f.calls.rm == 15 and f.calls.mv == 0 and st.text ==
          "stopped after 15 removals: the unit inventory is full, empty it and Build again",
          "stall: unit full -> stop after the first batch, no move sent (" .. st.text .. ")")
end

-- a single machine whose refund does not fit the player (200 Gear = 4 slots, 3 usable): stall at start, nothing sent
do
    local m = many(1, 200)
    local f = fake({ player = inv({}, 4), unit = inv({}, 10), raw = { ITEM_Gear = 50 }, station = m.station, refund_of = m.refund_of })
    local b = B.new(f.io)
    local ok, msg = b:start(plan_for(f, { removed = m.removed, refund = m.total }), {})
    local st = b:status()
    check(not ok and st.state == "error" and st.text:find("does not fit the player inventory", 1, true) and f.calls.rm == 0 and f.calls.mv == 0,
          "single refund too big: stall at start, nothing removed (" .. msg .. ")")
end

-- no refund items: all removals go in one batch inside start, done at once
do
    local m = many(40, 0)
    local f = fake({ player = inv({}, 4), unit = inv({}, 4), station = m.station })
    local b = B.new(f.io)
    local ok = b:start(plan_for(f, { removed = m.removed }), {})
    check(ok and b:status().state == "done" and f.calls.rm == 40 and f.calls.mv == 0, "no refund: 40 removals in one batch, done inside start")
end

-- per-machine refund missing from the plan: refused before any command
do
    local f = fake({ player = inv({}, 4), unit = inv({}, 4), station = { { id = 7, bcls = "BP_OLD", x = 0, y = 0 } } })
    local plan = plan_for(f, {})
    plan.removed = { { id = 7, bcls = "BP_OLD", x = 0, y = 0 } }
    local ok, msg = B.new(f.io):start(plan, {})
    check(not ok and msg:find("refund unknown", 1, true) and f.calls.rm == 0, "refund per machine missing: refused before any command")
end

-- ===== success path duration (fake clock, 250 ms steps; the window ticks every 300 ms) =====
do
    local function timed(label, f, plan)
        local b = B.new(f.io)
        local t0 = f.clock
        local ok = b:start(plan, {})
        local st = run(b, f)
        local ms = f.clock - t0
        print(("timing %-44s ok=%s state=%s %d ms"):format(label, tostring(ok), st.state, ms))
        return st, ms
    end
    -- small change, no removal, items already in the player: sent in start, done at once
    local f1 = fake({ player = inv({ S("ITEM_Plate", 5) }, 3), unit = inv({}, 3) })
    local st1b, ms1b = timed("small: items held, no removal", f1,
        plan_for(f1, { place = { M("BP_A", 0, 0, { ITEM_Plate = 3 }) }, need = { ITEM_Plate = 3 } }))
    check(st1b.state == "done" and ms1b == 0, "timing: small change, items held -> done at once (" .. ms1b .. " ms)")
    -- small change, one staging move from the unit: staging poll 250 ms, then sent
    local f2 = fake({ player = inv({ S("ITEM_Plate", 1) }, 3), unit = inv({ S("ITEM_Plate", 10) }, 2) })
    local st2, ms2 = timed("small: one staged stack from the unit", f2,
        plan_for(f2, { place = { M("BP_A", 0, 0, { ITEM_Plate = 3 }) }, need = { ITEM_Plate = 3 } }))
    check(st2.state == "done" and ms2 <= 500, "timing: small change, staging -> done in <= 500 ms (" .. ms2 .. " ms)")
    -- removal, refund arrives, no overlap: first poll sees the refund, move + placement sent
    local f3 = fake({ player = inv({ S("ITEM_Plate", 1) }, 3), unit = inv({}, 3),
                      station = { { id = 7, bcls = "BP_OLD", x = 0, y = 0 } }, refund_of = { [7] = { ITEM_Gear = 2 } } })
    local st3, ms3 = timed("removal, no overlap", f3, plan_for(f3, { place = { M("BP_NEW", 5, 0, { ITEM_Plate = 1 }) }, need = { ITEM_Plate = 1 },
        refund = { ITEM_Gear = 2 }, removed = { { id = 7, bcls = "BP_OLD", x = 0, y = 0 } } }))
    check(st3.state == "done" and ms3 == 250 and st3.text:find("refund moved to the unit", 1, true), "timing: removal + refund move -> done at the first poll (" .. ms3 .. " ms)")
    -- removal on the placement cell, no refund items: 500 ms settle
    local f4 = fake({ player = inv({ S("ITEM_Plate", 1) }, 3), unit = inv({}, 3),
                      station = { { id = 7, bcls = "BP_OLD", x = 0, y = 0 } } })
    local st4, ms4 = timed("removal on the cell, no refund items", f4, plan_for(f4, { place = { M("BP_NEW", 0, 0, { ITEM_Plate = 1 }) }, need = { ITEM_Plate = 1 },
        removed = { { id = 7, bcls = "BP_OLD", x = 0, y = 0 } } }))
    check(st4.state == "done" and ms4 == 500, "timing: removal on the cell, no refund -> 500 ms settle (" .. ms4 .. " ms)")
end

-- ===== containers: io.read_machine_inv fake (nil = not a container). Contents end a batch; a head container is emptied first =====
local function with_containers(f, conts)
    for mid, c in pairs(conts) do f.inv["cont" .. mid] = { id = c.id, slots = c.slots } end
    f.io.read_machine_inv = function(mid)
        local c = conts[mid]
        if not c then return nil end
        if c.bad then return { ok = false, id = c.id, slots = {} } end
        local slots = {}
        for i, s in ipairs(f.inv["cont" .. mid].slots) do slots[i] = { item = s.item, amount = s.amount, max = s.max } end
        return { ok = true, id = c.id, slots = slots, mult = 1 }
    end
end
local function cont_station()
    return { { id = 7, bcls = "BP_OLD", x = 0, y = 0 }, { id = 8, bcls = "BP_BOX", x = 1, y = 0 }, { id = 9, bcls = "BP_OLD", x = 2, y = 0 } }
end
local function cont_removed()
    return { { id = 7, bcls = "BP_OLD", x = 0, y = 0, refund = { ITEM_Gear = 2 } },
             { id = 8, bcls = "BP_BOX", x = 1, y = 0, refund = { ITEM_Gear = 1 } },
             { id = 9, bcls = "BP_OLD", x = 2, y = 0, refund = { ITEM_Gear = 2 } } }
end
local function box_slots() return { S("ITEM_Plate", 5), S("ITEM_Plate", 3), E() } end
local function first_pick(traces)
    for _, t in ipairs(traces) do if t:find("^pick:") then return t end end
end

-- container 8 (middle) holds 8 Plate in 2 slots: batch = belt 7 only, then the container is emptied, then 8 and 9
do
    local traces = {}
    local f = fake({ player = inv({}, 3), unit = inv({}, 10), station = cont_station(),
        refund_of = { [7] = { ITEM_Gear = 2 }, [8] = { ITEM_Gear = 1 }, [9] = { ITEM_Gear = 2 } } })
    f.io.trace = function(m) traces[#traces + 1] = m end
    with_containers(f, { [8] = { id = 303, slots = box_slots() } })
    local b = B.new(f.io)
    b:start(plan_for(f, { removed = cont_removed() }), {})
    local st = run(b, f, 4000)
    local emptied = true
    for _, s in ipairs(f.inv.cont8.slots) do if s.item ~= "" or s.amount ~= 0 then emptied = false end end
    local presses, plate = 0, 0
    for _, mv in ipairs(f.moves) do if mv[1] == 303 and mv[4] == 2 then presses = presses + 1 end end
    for _, s in ipairs(f.inv.unit.slots) do if s.item == "ITEM_Plate" then plate = plate + s.amount end end
    local extra = false
    for _, t in ipairs(traces) do if t:find("batch extra:", 1, true) then extra = true end end
    check(st.state == "done" and f.calls.rm == 3, "container: 3 removals done (" .. st.text .. ")")
    check(presses == 2 and emptied and plate == 8, "container: emptied into the unit, one move per filled slot")
    check(extra, "container: batch extra traced")
end

-- unreadable container (not the head): the batch stops before it; at the head it stalls
do
    local f = fake({ player = inv({}, 3), unit = inv({}, 10), station = cont_station(),
        refund_of = { [7] = { ITEM_Gear = 2 }, [8] = { ITEM_Gear = 1 }, [9] = { ITEM_Gear = 2 } } })
    with_containers(f, { [8] = { id = 303, slots = box_slots(), bad = true } })
    local b = B.new(f.io)
    b:start(plan_for(f, { removed = cont_removed() }), {})
    local st = run(b, f, 4000)
    check(st.state == "error" and st.removed == 1 and f.calls.rm == 1 and st.text ==
          "stopped after 1 removals: container id 8 cannot be read, Build again", "container: unreadable at the head -> stall (" .. st.text .. ")")
end

-- carriers add a reserve slot each (RESERVE 1 + carriers): 4 empty slots, Gear 50 per belt
local function carrier_traces(bcls)
    local traces, stn, removed = {}, {}, {}
    for i = 1, 4 do
        stn[i] = { id = i, bcls = bcls, x = i - 1, y = 0 }
        removed[i] = { id = i, bcls = bcls, x = i - 1, y = 0, refund = { ITEM_Gear = 50 } }
    end
    local f = fake({ player = inv({}, 4), unit = inv({}, 10), station = stn,
        refund_of = { [1] = { ITEM_Gear = 50 }, [2] = { ITEM_Gear = 50 }, [3] = { ITEM_Gear = 50 }, [4] = { ITEM_Gear = 50 } } })
    f.io.trace = function(m) traces[#traces + 1] = m end
    B.new(f.io):start(plan_for(f, { removed = removed }), {})
    return traces
end
check(first_pick(carrier_traces("BP_ConveyorBeltObject")) == "pick: n=1 carriers=1 reserve=2", "reserve: 1 carrier -> reserve 2, batch 1")
check(first_pick(carrier_traces("BP_Plain")) == "pick: n=3 carriers=0 reserve=1", "reserve: no carrier -> reserve 1, batch 3")

-- moves never empty the container: stall after DRAIN_MS, nothing removed
do
    local f = fake({ player = inv({}, 3), unit = inv({}, 10), station = cont_station(), noop_moves = true,
        refund_of = { [8] = { ITEM_Gear = 1 } } })
    with_containers(f, { [8] = { id = 303, slots = box_slots() } })
    local b = B.new(f.io)
    b:start(plan_for(f, { removed = { { id = 8, bcls = "BP_BOX", x = 1, y = 0, refund = { ITEM_Gear = 1 } } } }), {})
    local st = run(b, f, 4000)
    check(st.state == "error" and f.calls.rm == 0 and st.text ==
          "the game did not move the container items (see bpu_trace.log)",
          "container: moves never empty it -> stall, nothing removed (" .. st.text .. ")")
end

-- unit full: the container contents do not fit the unit -> stall before any move, nothing removed
do
    local f = fake({ player = inv({}, 3), unit = inv({ S("ITEM_Gear", 50), S("ITEM_Gear", 50) }, 2),
        station = cont_station(), refund_of = { [8] = { ITEM_Gear = 1 } } })
    with_containers(f, { [8] = { id = 303, slots = box_slots() } })
    local b = B.new(f.io)
    b:start(plan_for(f, { removed = { { id = 8, bcls = "BP_BOX", x = 1, y = 0, refund = { ITEM_Gear = 1 } } } }), {})
    local st = run(b, f, 4000)
    check(st.state == "error" and f.calls.rm == 0 and #f.moves == 0 and st.text ==
          "the unit inventory is full, empty it and Build again (container id 8 holds items)", "container: unit full -> stall before moves (" .. st.text .. ")")
end

-- ===== redirect flow (io.redirect_status 'on...'): everything sent, FIFO, capped per tick, no waits =====
do
    local on = "on: redirect=on probe_log=off groups=yes"
    local function ids_station(n)
        local st = {}
        for i = 1, n do st[i] = { id = i, bcls = "BP_OLD", x = 100 + i, y = 0 } end
        return st
    end
    local function removed_of(n, refund)
        local r = {}
        for i = 1, n do r[i] = { id = i, bcls = "BP_OLD", x = 100 + i, y = 0, refund = refund } end
        return r
    end
    local function places(n)
        local p = {}
        for i = 1, n do p[i] = M("BP_NEW", 1000 + i, 0, { ITEM_Plate = 1 }) end
        return p
    end

    -- 400 removals + 300 placements: 150 per tick, FIFO (all removals first), no wait, done after the last send
    local f = fake({ redirect = on, player = inv({}, 4), unit = inv({ S("ITEM_Plate", 50), S("ITEM_Plate", 50), S("ITEM_Plate", 50),
                       S("ITEM_Plate", 50), S("ITEM_Plate", 50), S("ITEM_Plate", 50) }, 120), station = ids_station(400) })
    local b = B.new(f.io)
    local ok = b:start(plan_for(f, { place = places(300), need = { ITEM_Plate = 300 }, removed = removed_of(400, {}) }), {})
    check(ok and #f.order == 150 and b:status().state == "working", "redirect: start sends exactly 150 commands (cap), still working (" .. #f.order .. ")")
    local ticks = 0
    while b:status().state == "working" and ticks < 50 do
        f.clock = f.clock + 1
        b:tick(f.clock)
        ticks = ticks + 1
    end
    local st = b:status()
    local fifo = true
    for i, c in ipairs(f.order) do
        local want = i <= 400 and ("rm:" .. i) or ("pl:" .. (1000 + i - 400))
        if c ~= want then fifo = false end
    end
    check(st.state == "done" and #f.order == 700 and fifo, "redirect: 700 commands in FIFO order, removals first")
    check(ticks == 4, "redirect: 700 commands = start + 4 ticks, 1 ms apart (no waits) (" .. ticks .. ")")
    check(st.text == "sent: placed 300, removed 400 (refund goes into the unit; the game updates its blueprint view in about 30 s)",
          "redirect: done text (" .. st.text .. ")")
    check(f.calls.mv == 0 and f.calls.ch == 1, "redirect: no inventory moves, changes sent once")
end

-- removal refund goes to the unit, charge from the unit: no staging, no moveout, no waits
do
    local f = fake({ redirect = "on: redirect=on probe_log=off groups=yes", player = inv({}, 3), unit = inv({ S("ITEM_Plate", 5) }, 3),
                     station = { { id = 7, bcls = "BP_OLD", x = 9, y = 0 } }, refund_of = { [7] = { ITEM_Gear = 2 } } })
    local b = B.new(f.io)
    local ok = b:start(plan_for(f, { place = { M("BP_NEW", 5, 0, { ITEM_Plate = 1 }) }, need = { ITEM_Plate = 1 },
                                     refund = { ITEM_Gear = 2 }, removed = { { id = 7, bcls = "BP_OLD", x = 9, y = 0, refund = { ITEM_Gear = 2 } } } }), {})
    local st = b:status()
    check(ok and st.state == "done" and f.calls.rm == 1 and f.calls.pl == 1 and f.calls.mv == 0,
          "redirect: removal+placement both sent inside start, done at once, no moves (" .. st.text .. ")")
    check(f.inv.unit.slots[2].item == "ITEM_Gear" and f.inv.unit.slots[1].amount == 4 and f.inv.player.slots[1].item == "",
          "redirect: refund in the unit, charge taken from the unit")
    check(st.text == "sent: placed 1, removed 1 (refund goes into the unit; the game updates its blueprint view in about 30 s)", "redirect: done text, single")
end

-- overlap: the placement waits SETTLE_MS (500) from the last removal, once
do
    local f = fake({ redirect = "on", player = inv({}, 3), unit = inv({ S("ITEM_Plate", 5) }, 3),
                     station = { { id = 7, bcls = "BP_OLD", x = 1, y = 0 } } })
    local b = B.new(f.io)
    b:start(plan_for(f, { place = { M("BP_NEW", 1, 0, { ITEM_Plate = 1 }), M("BP_NEW", 2, 0, { ITEM_Plate = 1 }) }, need = { ITEM_Plate = 2 },
                          removed = { { id = 7, bcls = "BP_OLD", x = 1, y = 0, refund = {} } } }), {})
    check(f.calls.rm == 1 and f.calls.pl == 0 and b:status().state == "working", "redirect overlap: removal sent, placement held back")
    local n = 0
    while b:status().state == "working" and n < 40 do f.clock = f.clock + 100; b:tick(f.clock); n = n + 1 end
    check(b:status().state == "done" and f.calls.pl == 2 and f.place_gap >= 500 and f.place_gap < 700,
          "redirect overlap: placements after ~500 ms settle (" .. tostring(f.place_gap) .. " ms)")
end

-- total check still refuses before any command; unit-full pre-check
do
    local f = fake({ redirect = "on", player = inv({}, 3), unit = inv({}, 3), station = { { id = 1, bcls = "BP_OLD", x = 101, y = 0 } } })
    local b = B.new(f.io)
    local ok, msg = b:start(plan_for(f, { place = { M("BP_NEW", 1, 0, { ITEM_Plate = 1 }) }, need = { ITEM_Plate = 1 },
                                          removed = { { id = 1, bcls = "BP_OLD", x = 101, y = 0, refund = {} } } }), {})
    check(not ok and msg:find("not enough items: Plate x1", 1, true) and f.calls.rm == 0, "redirect: total check refuses, nothing sent")

    local function unit_case(unit, raw, item_max_nil, amount)
        local g = fake({ redirect = "on", player = inv({}, 2), unit = unit, raw = raw,
                         station = { { id = 1, bcls = "BP_OLD", x = 101, y = 0 } }, refund_of = { [1] = { ITEM_Gear = amount } } })
        if item_max_nil then g.io.item_max = function() return nil end end
        local okk, m = B.new(g.io):start(plan_for(g, { refund = { ITEM_Gear = amount },
            removed = { { id = 1, bcls = "BP_OLD", x = 101, y = 0, refund = { ITEM_Gear = amount } } } }), {})
        return okk, m, g
    end
    local ok2, msg2, g2 = unit_case(inv({ S("ITEM_Gear", 50), S("ITEM_Gear", 50) }, 2), { ITEM_Gear = 50 }, false, 10)
    check(not ok2 and msg2 == "error: the unit inventory is full, empty it and Build again" and g2.calls.rm == 0,
          "redirect: unit cannot hold the refund -> unit full, nothing sent (" .. tostring(msg2) .. ")")
    local ok3, _, g3 = unit_case(inv({ S("ITEM_Gear", 50) }, 2), { ITEM_Gear = 50 }, false, 10)
    check(ok3 and g3.calls.rm == 1, "redirect: unit has room -> sent")
    local ok4 = unit_case(inv({ S("ITEM_Gear", 50) }, 2), nil, true, 10000)
    check(ok4, "redirect: unknown item max is optimistic")
end

-- refused removal ends the run with an error, no placement sent
do
    local f = fake({ redirect = "on", player = inv({}, 3), unit = inv({ S("ITEM_Plate", 5) }, 3), station = {} })
    local b = B.new(f.io)
    local ok, msg = b:start(plan_for(f, { place = { M("BP_NEW", 1, 0, { ITEM_Plate = 1 }) }, need = { ITEM_Plate = 1 },
                                          removed = { { id = 9, bcls = "BP_OLD", x = 3, y = 0, refund = {} } } }), {})
    check(not ok and msg:find("removal refused", 1, true) and f.calls.pl == 0, "redirect: refused removal -> error, nothing placed (" .. tostring(msg) .. ")")
end

-- detection: only a status starting with 'on' selects the redirect flow
do
    local function flow(status)
        local traces = {}
        local f = fake({ redirect = status, player = inv({ S("ITEM_Plate", 5) }, 3), unit = inv({}, 3) })
        if status == nil then f.io.redirect_status = nil end
        f.io.trace = function(t) traces[#traces + 1] = t end
        local b = B.new(f.io)
        b:start(plan_for(f, { place = { M("BP_A", 0, 0, { ITEM_Plate = 1 }) }, need = { ITEM_Plate = 1 } }), {})
        run(b, f)
        for _, t in ipairs(traces) do
            local fl = t:match("^build flow: (%a+)")
            if fl then return fl, b:status() end
        end
    end
    check(flow("on: redirect=on probe_log=off groups=yes") == "redirect", "detect: 'on: ...' = redirect")
    check(flow("off") == "legacy", "detect: 'off' = legacy")
    check(flow("COMPAT refund failed: exe size") == "legacy", "detect: COMPAT = legacy")
    check(flow(nil) == "legacy", "detect: no redirect_status in io = legacy")
    check(flow("") == "legacy", "detect: empty = legacy")
    local _, st = flow("off")
    check(st.state == "done" and st.text == "sent: placed 1, removed 0 (the game updates its blueprint view in about 30 s)", "detect: legacy text unchanged")
end

-- overlay: the redirect flow reports what it sent
do
    local got
    local f = fake({ redirect = "on", player = inv({}, 3), unit = inv({ S("ITEM_Plate", 5) }, 3),
                     station = { { id = 1, bcls = "BP_OLD", x = 101, y = 0 }, { id = 2, bcls = "BP_OLD", x = 102, y = 0 } } })
    f.io.note_build = function(pl, rm) got = { #pl, #rm } end
    local b = B.new(f.io)
    b:start(plan_for(f, { place = { M("BP_NEW", 1, 0, { ITEM_Plate = 1 }) }, need = { ITEM_Plate = 1 },
        removed = { { id = 1, bcls = "BP_OLD", x = 101, y = 0, refund = {} }, { id = 2, bcls = "BP_OLD", x = 102, y = 0, refund = {} } } }), {})
    check(got and got[1] == 1 and got[2] == 2, "redirect: note_build gets the sent placements and removals")
end

-- ===== container contents restore (after the placements): whole-stack TRANSFER only (action 2) =====
local function tot(slots, item)
    local n = 0
    for _, s in ipairs(slots) do if s.item == item then n = n + s.amount end end
    return n
end
local function new_cont(f)   -- id of the container the Build placed (machine ids > 500 in the fake), lowest first
    local best
    for id in pairs(f.containers) do if id > 500 and (not best or id < best) then best = id end end
    return best
end
local function starts(traces, prefix)   -- some trace line starts with prefix
    for _, t in ipairs(traces) do if t:sub(1, #prefix) == prefix then return true end end
    return false
end
local function cmds_of(f, action)
    local n = 0
    for _, c in ipairs(f.cmd_log) do if c[4] == action then n = n + 1 end end
    return n
end
local function cont_plate(f, id) return tot(f.containers[id].slots, "ITEM_Plate") end
local function cont_at(x, restore) local p = M("BP_ContainerObject_2", x, 0, {}); p.restore = restore; return p end
local function cont_place(restore) return cont_at(5, restore) end
local REDIRECT_ON = "on: redirect=on probe_log=off groups=yes"
local function tracer(f) local t = {}; f.io.trace = function(x) t[#t + 1] = x end; return t end
local function whole_fake(extra)
    local o = { redirect = REDIRECT_ON, player = inv({}, 3), unit = inv({ S("ITEM_Plate", 50), S("ITEM_Plate", 50), S("ITEM_Plate", 20) }, 6), station = {} }
    for k, v in pairs(extra or {}) do o[k] = v end
    return fake(o)
end
local function start_cont(f, restore, opts)
    local b = B.new(f.io)
    local ok = b:start(plan_for(f, { place = { cont_place(restore) }, need = {}, refund = {} }), opts or {})
    return b, ok
end

-- whole stacks 50 + 50 + 20 -> restore 120: three TRANSFERs (2), nothing else
do
    local f = whole_fake()
    local traces = tracer(f)
    local b, ok = start_cont(f, { { name = "ITEM_Plate", count = 120 } })
    local st = run(b, f, 400)
    local cid = new_cont(f)
    check(ok and st.state == "done" and cid and cont_plate(f, cid) == 120 and tot(f.inv.unit.slots, "ITEM_Plate") == 0,
          "restore: 120 Plate back into the new container, unit empty (" .. st.text .. ")")
    check(st.text:find("; restore: restored 120 of 120 items into 1 of 1 container(s)", 1, true) ~= nil, "restore: status text")
    check(#f.cmd_log == 3 and cmds_of(f, 2) == 3 and #f.violations == 0 and f.cmd_log[1][1] == 202 and f.cmd_log[1][2] == cid + 5000,
          "restore whole stacks: 3 TRANSFER (2) unit -> container INVENTORY id, no other action, no violation (" .. #f.cmd_log .. " sent)")
    check(starts(traces, "restore plan: container id=" .. cid .. " item=ITEM_Plate count=120 moves=3 moved=120 short=0"), "restore whole stacks: plan trace")
    check(starts(traces, "restore unit stacks (start): ") and starts(traces, "restore unit stacks (end): "), "restore: unit stack traces at start and end")
end

-- SM 12, raw Plate 25: slot max 300, 32-slot container = 9600. Unit 32 full stacks of 300 -> all 9600 go in, short 0
do
    local stacks = {}
    for i = 1, 32 do stacks[i] = S("ITEM_Plate", 300, 300) end
    local f = fake({ redirect = REDIRECT_ON, player = inv({}, 3), unit = inv(stacks, 32), station = {}, mult = { unit = 12 },
                     raw = { ITEM_Plate = 25 }, max = { ITEM_Plate = 300 }, cont_slots = 32, cont_mult = 12 })
    local traces = tracer(f)
    local b, ok = start_cont(f, { { name = "ITEM_Plate", count = 9600 } })
    local st = run(b, f, 400)
    local cid = new_cont(f)
    check(ok and st.state == "done" and cid and cont_plate(f, cid) == 9600 and tot(f.inv.unit.slots, "ITEM_Plate") == 0 and #f.violations == 0,
          "restore SM 12: 9600 Plate (32 x 300) into the 32-slot container, unit empty (" .. st.text .. ")")
    check(starts(traces, "restore plan: container id=" .. cid .. " item=ITEM_Plate count=9600 moves=32 moved=9600 short=0"), "restore SM 12: plan trace moved 9600, short 0")
end

-- rounding down: need 30, unit 100 then 40 -> the 100 is skipped (30 < 50), the 40 goes in (30 >= 20)
do
    local f = fake({ redirect = REDIRECT_ON, player = inv({}, 3), unit = inv({ S("ITEM_Plate", 100, 100), S("ITEM_Plate", 40, 100) }, 3),
                     station = {}, max = { ITEM_Plate = 100 }, raw = { ITEM_Plate = 100 } })
    local b, ok = start_cont(f, { { name = "ITEM_Plate", count = 30 } })
    local st = run(b, f, 400)
    local cid = new_cont(f)
    check(ok and st.state == "done" and cid and cont_plate(f, cid) == 40 and f.inv.unit.slots[1].amount == 100 and #f.cmd_log == 1
          and f.cmd_log[1][3] == 1 and #f.violations == 0, "rounding down: 100 skipped (need < half), 40 moved (need >= half) (" .. st.text .. ")")
end

-- rounding up: need 60 and one 100 stack -> the whole stack goes in (60 >= 50), container gets 100
do
    local f = fake({ redirect = REDIRECT_ON, player = inv({}, 3), unit = inv({ S("ITEM_Plate", 100, 100) }, 3), station = {},
                     max = { ITEM_Plate = 100 }, raw = { ITEM_Plate = 100 } })
    local b, ok = start_cont(f, { { name = "ITEM_Plate", count = 60 } })
    local st = run(b, f, 400)
    local cid = new_cont(f)
    check(ok and st.state == "done" and cid and cont_plate(f, cid) == 100 and tot(f.inv.unit.slots, "ITEM_Plate") == 0 and #f.cmd_log == 1,
          "rounding up: need 60 of a 100 stack -> whole stack in (100) (" .. st.text .. ")")
end

-- a stack far above the need is left out with a note, nothing sent: 5050 stack, need 300
do
    local f = fake({ redirect = REDIRECT_ON, player = inv({}, 3), unit = inv({ S("ITEM_Plate", 5050, 5050) }, 3), station = {},
                     max = { ITEM_Plate = 5050 }, raw = { ITEM_Plate = 5050 } })
    local b, ok = start_cont(f, { { name = "ITEM_Plate", count = 300 } })
    local st = run(b, f, 400)
    local cid = new_cont(f)
    check(ok and st.state == "done" and cid and cont_plate(f, cid) == 0 and tot(f.inv.unit.slots, "ITEM_Plate") == 5050 and #f.cmd_log == 0,
          "rounding skip: 300 of a 5050 stack -> nothing sent (" .. st.text .. ")")
    check(st.text:find("; restore: restored 0 of 300 items into 0 of 1 container(s); Plate x300 left out (under half a unit stack)", 1, true) ~= nil, "rounding skip: note text")
end

-- two stacks, need 110 (30 then 100): 2 TRANSFERs, container 130 = 100 + 30 (slot 1 to 100, then slot 2)
do
    local f = fake({ redirect = REDIRECT_ON, player = inv({}, 3), unit = inv({ S("ITEM_Plate", 30, 100), S("ITEM_Plate", 100, 100) }, 3),
                     station = {}, max = { ITEM_Plate = 100 }, raw = { ITEM_Plate = 100 } })
    local b, ok = start_cont(f, { { name = "ITEM_Plate", count = 110 } })
    local st = run(b, f, 400)
    local cid = new_cont(f)
    check(ok and st.state == "done" and cid and cont_plate(f, cid) == 130 and f.containers[cid].slots[1].amount == 100
          and f.containers[cid].slots[2].amount == 30 and #f.cmd_log == 2 and cmds_of(f, 2) == 2 and #f.violations == 0,
          "two transfers: container 100 + 30, unit empty (" .. st.text .. ")")
end

-- partial room: container with one slot (cap 100), unit 80 + 80, need 120 -> 100 in, 60 stay in the unit (partial move)
do
    local f = fake({ redirect = REDIRECT_ON, player = inv({}, 3), unit = inv({ S("ITEM_Plate", 80, 100), S("ITEM_Plate", 80, 100) }, 3),
                     station = {}, max = { ITEM_Plate = 100 }, raw = { ITEM_Plate = 100 }, cont_slots = 1 })
    local b, ok = start_cont(f, { { name = "ITEM_Plate", count = 120 } })
    local st = run(b, f, 400)
    local cid = new_cont(f)
    check(ok and st.state == "done" and cid and cont_plate(f, cid) == 100 and f.inv.unit.slots[2].amount == 60 and #f.cmd_log == 2
          and #f.violations == 0, "partial room: 100 in, 60 stay in the unit (" .. st.text .. ")")
    check(st.text:find("container " .. cid .. " full: Plate x20 left in the unit", 1, true) ~= nil, "partial room: container full note (the 20 the room did not take)")
end

-- container full: one slot -> 50 in (one TRANSFER), the other stacks do not fit, nothing else sent, 70 stay in the unit
do
    local f = whole_fake({ cont_slots = 1 })
    local b = start_cont(f, { { name = "ITEM_Plate", count = 120 } })
    local st = run(b, f, 400)
    local cid = new_cont(f)
    check(st.state == "done" and cid and cont_plate(f, cid) == 50 and tot(f.inv.unit.slots, "ITEM_Plate") == 70
          and st.text:find("restored 50 of 120 items into 1 of 1 container(s)", 1, true) ~= nil
          and st.text:find("container " .. cid .. " full: Plate x70 left in the unit", 1, true) ~= nil, "restore full: 50 in, then container full (" .. st.text .. ")")
    check(#f.cmd_log == 1 and cmds_of(f, 2) == 1 and #f.violations == 0, "restore full: one TRANSFER, nothing else sent, no violation")
end

-- unit short of an item: skipped with a note before anything is sent, the Build is still done
do
    local f = fake({ redirect = REDIRECT_ON, player = inv({}, 3), unit = inv({ S("ITEM_Plate", 50), S("ITEM_Plate", 50) }, 3), station = {} })
    local b, ok = start_cont(f, { { name = "ITEM_Plate", count = 120 } })
    local st = run(b, f, 400)
    local cid = new_cont(f)
    check(ok and st.state == "done" and cont_plate(f, cid) == 0 and tot(f.inv.unit.slots, "ITEM_Plate") == 100 and #f.cmd_log == 0,
          "restore short: contents shortage does not block the Build, nothing sent (" .. st.text .. ")")
    check(st.text:find("; restore: restored 0 of 120 items into 0 of 1 container(s); Plate x120 not restored (unit has 100)", 1, true) ~= nil, "restore short: note text")
end

-- ICE REPRO (user test 2026-11-07): earlier items fill the container slots, later ice gets only the room left.
-- Container 4 slots (cap 150): Plate 450 fills 3 slots, ice wants 6 stacks -> 1 stack fits. The shortage is noted
-- (the old planner dropped it silently: plan remainder=0 short=N, no note).
do
    local slots = {}
    for i = 1, 3 do slots[#slots + 1] = S("ITEM_Plate", 150, 150) end
    for i = 1, 6 do slots[#slots + 1] = S("ITEM_WaterIce", 150, 150) end
    local f = fake({ redirect = REDIRECT_ON, player = inv({}, 3), unit = inv(slots, 9), station = {},
                     max = { ITEM_Plate = 150, ITEM_WaterIce = 150 }, raw = { ITEM_Plate = 150, ITEM_WaterIce = 150 }, cont_slots = 4 })
    local b, ok = start_cont(f, { { name = "ITEM_Plate", count = 450 }, { name = "ITEM_WaterIce", count = 900 } })
    local st = run(b, f, 400)
    local cid = new_cont(f)
    check(ok and st.state == "done" and cid and cont_plate(f, cid) == 450 and tot(f.containers[cid].slots, "ITEM_WaterIce") == 150,
          "ice repro: plate 3 stacks, ice 1 stack (the room left) (" .. st.text .. ")")
    check(st.text:find("container " .. cid .. " full: WaterIce x750 left in the unit", 1, true) ~= nil and tot(f.inv.unit.slots, "ITEM_WaterIce") == 750 and #f.violations == 0,
          "ice repro: shortage noted, 750 ice stay in the unit (" .. st.text .. ")")
end

-- ICE with room: 3 Plate stacks + 6 ice stacks into 10 slots -> 9 transfers, ice 900, no note
do
    local slots = {}
    for i = 1, 3 do slots[#slots + 1] = S("ITEM_Plate", 150, 150) end
    for i = 1, 6 do slots[#slots + 1] = S("ITEM_WaterIce", 150, 150) end
    local f = fake({ redirect = REDIRECT_ON, player = inv({}, 3), unit = inv(slots, 9), station = {},
                     max = { ITEM_Plate = 150, ITEM_WaterIce = 150 }, raw = { ITEM_Plate = 150, ITEM_WaterIce = 150 }, cont_slots = 10 })
    local b = start_cont(f, { { name = "ITEM_Plate", count = 450 }, { name = "ITEM_WaterIce", count = 900 } })
    local st = run(b, f, 400)
    local cid = new_cont(f)
    check(cid and tot(f.containers[cid].slots, "ITEM_WaterIce") == 900 and cmds_of(f, 2) == 9 and st.text:find("full", 1, true) == nil,
          "ice with room: 6 ice stacks + 3 plate stacks, 9 transfers, no note (" .. st.text .. ")")
end

-- stall: nothing shows -> all 3 commands sent, no further command, STALL after STALL_MS (30000) with no change
do
    local f = whole_fake({ stall_after = 0 })
    local b = start_cont(f, { { name = "ITEM_Plate", count = 120 } })
    local st = run(b, f, 400)
    local cid = new_cont(f)
    local last = f.cmd_log[#f.cmd_log] and f.cmd_log[#f.cmd_log][5] or 0
    check(st.state == "done" and #f.cmd_log == 3 and cid and cont_plate(f, cid) == 0 and f.clock - last >= 30000 and f.clock - last <= 30250
          and st.text:find("restore stalled at pipeline (3 of 3 commands sent), no change for 30 s", 1, true) ~= nil,
          "stall: no change for 30 s after the last send -> note, nothing more sent (" .. st.text .. ")")
    check(#f.violations == 0, "stall: no violation")
end

-- stall partial: the first TRANSFER shows (50), the other two do not -> STALL
do
    local f = whole_fake({ stall_after = 1 })
    local b = start_cont(f, { { name = "ITEM_Plate", count = 120 } })
    local st = run(b, f, 400)
    local cid = new_cont(f)
    check(st.state == "done" and #f.cmd_log == 3 and cid and cont_plate(f, cid) == 50
          and st.text:find("restore stalled at pipeline (3 of 3 commands sent)", 1, true) ~= nil,
          "stall partial: 50 shown, 2 transfers not, STALL (" .. st.text .. ")")
end

-- live inflow of the same item into the container (+5 Plate per read after the 3 TRANSFERs): the lower bound confirms, verify done
do
    local f = whole_fake()
    local orig = f.io.read_machine_inv
    f.io.read_machine_inv = function(id)
        local c = f.containers[id]
        if c and id > 500 and #f.cmd_log >= 3 then c.slots[4].item = "ITEM_Plate"; c.slots[4].amount = c.slots[4].amount + 5 end
        return orig(id)
    end
    local b = start_cont(f, { { name = "ITEM_Plate", count = 120 } })
    local st = run(b, f, 400)
    local cid = new_cont(f)
    check(st.state == "done" and cid and cont_plate(f, cid) > 120 and st.text:find("stalled", 1, true) == nil and #f.violations == 0,
          "inflow: container above the model (lower bound) confirms, no stall (" .. st.text .. ")")
end

-- restore drain: the unit matches, the container loses 5 Plate per read (belts take it) -> drained, not a stall
do
    local f = whole_fake()
    local orig = f.io.read_machine_inv
    f.io.read_machine_inv = function(id)
        local c = f.containers[id]
        if c and id > 500 and #f.cmd_log >= 3 then
            local s = c.slots[1]
            s.amount = math.max(0, s.amount - 5)
            if s.amount == 0 then s.item = "" end
        end
        return orig(id)
    end
    local traces = tracer(f)
    local b = start_cont(f, { { name = "ITEM_Plate", count = 120 } })
    local st = run(b, f, 400)
    local cid = new_cont(f)
    check(st.state == "done" and cid and st.text:find("stalled", 1, true) == nil and st.text:find("check both inventories", 1, true) == nil
          and #f.violations == 0 and tot(f.inv.unit.slots, "ITEM_Plate") == 0,
          "drain: container below the model and falling, unit matches -> no stall (" .. st.text .. ")")
    check(cid and starts(traces, "restore drain: container id=" .. cid) and starts(traces, "restore drained containers: " .. cid),
          "drain: drain and drained-containers traces name the container")
end

-- live inflow, nothing applied (unit unchanged): +1 Plate per read keeps the container moving, the stall clock still fires
-- at 8 s after the last send, and the note names the first mismatch (the unit, then the container)
do
    local f = whole_fake({ stall_after = 0 })
    local orig = f.io.read_machine_inv
    f.io.read_machine_inv = function(id)
        local c = f.containers[id]
        if c and id > 500 then c.slots[1].item = "ITEM_Plate"; c.slots[1].amount = c.slots[1].amount + 1 end
        return orig(id)
    end
    local b = start_cont(f, { { name = "ITEM_Plate", count = 120 } })
    local st = run(b, f, 400)
    local cid = new_cont(f)
    local last = f.cmd_log[#f.cmd_log] and f.cmd_log[#f.cmd_log][5] or 0
    check(st.state == "done" and #f.cmd_log == 3 and f.clock - last >= 30000 and f.clock - last <= 30250
          and st.text:find("restore stalled at pipeline (3 of 3 commands sent), no change for 30 s", 1, true) ~= nil
          and cid and st.text:find("(first mismatch: unit: Plate exp 0 got 120 | container id " .. cid .. ": Plate exp ", 1, true) ~= nil,
          "stall with inflow: unit unchanged -> STALL after 8 s, first mismatch named (" .. st.text .. ")")
end

-- slow game, no false stall: every command shows 6 s after its send (under the 8 s idle limit), restore verified
do
    local f = whole_fake({ delay = 6000 })
    local b = start_cont(f, { { name = "ITEM_Plate", count = 120 } })
    local st = run(b, f, 800)
    local cid = new_cont(f)
    check(st.state == "done" and cid and cont_plate(f, cid) == 120 and st.text:find("stalled", 1, true) == nil and #f.violations == 0,
          "no false stall: 6 s lag, restore 120 verified, no stall note (" .. st.text .. ")")
end

-- delay 800 ms: the batch lands after 800 ms, the verify waits for it (never two batches in flight)
do
    local f = whole_fake()
    f.delay = 800
    local b, ok = start_cont(f, { { name = "ITEM_Plate", count = 120 } })
    local st = run(b, f, 800)
    local cid = new_cont(f)
    check(ok and st.state == "done" and cid and cont_plate(f, cid) == 120 and #f.cmd_log == 3 and f.inflight == 0 and #f.violations == 0,
          "delay 800 ms: restore 120, verify waits for the batch (" .. st.text .. ")")
end

-- refused send, retried then skipped: command 1 refused 6 times (1 + RETRY_MAX 5) -> skipped, commands 2 and 3 go on;
-- the verify drops the skipped move (unit keeps 50, container gets 70), no stall
do
    local f = whole_fake()
    f.fail_next = 6
    local b = start_cont(f, { { name = "ITEM_Plate", count = 120 } })
    local st = run(b, f, 400)
    local cid = new_cont(f)
    check(st.state == "done" and cid and cont_plate(f, cid) == 70 and tot(f.inv.unit.slots, "ITEM_Plate") == 50 and f.attempts == 8,
          "retry then skip: command 1 refused 6 times and skipped, commands 2 and 3 go on (" .. st.text .. ")")
    check(st.text:find("1 command(s) skipped (refused)", 1, true) ~= nil and st.text:find("stalled", 1, true) == nil and #f.violations == 0,
          "retry then skip: note counts the skipped command, verified, no abort")
end

-- every command refused: each skipped after 6 attempts, the restore still ends, nothing moved, the note counts all 3
do
    local f = whole_fake()
    f.refuse_after = 0
    local b = start_cont(f, { { name = "ITEM_Plate", count = 120 } })
    local st = run(b, f, 400)
    local cid = new_cont(f)
    check(st.state == "done" and cid and cont_plate(f, cid) == 0 and f.attempts == 18 and tot(f.inv.unit.slots, "ITEM_Plate") == 120,
          "all refused: 3 commands skipped after 6 tries each, restore ends, nothing moved (" .. st.text .. ")")
    check(st.text:find("3 command(s) skipped (refused)", 1, true) ~= nil and st.text:find("stalled", 1, true) == nil,
          "all refused: note counts 3 skipped")
end

-- container not ready: unreadable for 3 polls -> the first command after 2 ready reads in a row
do
    local f = whole_fake({ unready = 3 })
    local t0 = f.clock
    local b = start_cont(f, { { name = "ITEM_Plate", count = 120 } })
    local st = run(b, f, 400)
    local cid = new_cont(f)
    check(st.state == "done" and cid and cont_plate(f, cid) == 120 and f.first_unready == 0 and f.cmd_log[1] and f.cmd_log[1][5] - t0 >= 1250,
          "container not ready: 3 polls not ready, first command after 2 ready reads (" .. st.text .. ")")
end

-- container never ready: CONT_MS, then the stall note, nothing sent
do
    local f = whole_fake({ unready = 1e9 })
    local t0 = f.clock
    local b = start_cont(f, { { name = "ITEM_Plate", count = 120 } })
    local st = run(b, f, 800)
    check(st.state == "done" and #f.cmd_log == 0 and f.clock - t0 >= 60000
          and st.text:find("restore stalled: container ids not found (new 1, placed 1)", 1, true) ~= nil, "container never ready: stall note after CONT_MS, nothing sent (" .. st.text .. ")")
end

-- RESTORE_MS passed (clock jump) during the verify: timeout note, nothing more sent
do
    local f = whole_fake({ stall_after = 0 })
    local b = start_cont(f, { { name = "ITEM_Plate", count = 120 } })
    local n = 0
    while b:status().state == "working" and #f.cmd_log == 0 and n < 400 do
        f.clock = f.clock + 250
        b:tick(f.clock)
        n = n + 1
    end
    local sent = #f.cmd_log
    f.clock = f.clock + 300001
    b:tick(f.clock)
    local st = b:status()
    check(st.state == "done" and sent == 3 and #f.cmd_log == sent and st.text:find("restore stalled: timeout after 300 s", 1, true) ~= nil,
          "restore timeout: 300 s passed -> note, nothing more sent (" .. st.text .. ")")
end

-- refused send, retried: the same command is sent again on the next tick; 2 refusals then success -> all 3 applied
do
    local f = whole_fake()
    f.fail_next = 2
    local b, ok = start_cont(f, { { name = "ITEM_Plate", count = 120 } })
    local st = run(b, f, 400)
    local cid = new_cont(f)
    check(ok and st.state == "done" and cid and cont_plate(f, cid) == 120 and f.attempts == 5 and #f.violations == 0,
          "retry then succeed: 2 refusals, the same command goes again, 120 in (" .. st.text .. ")")
    check(not st.text:find("refused", 1, true), "retry then succeed: no refused note")
end

-- speed: 20 containers x 5 Plate from 20 stacks of 5 -> one TRANSFER each, done within 10 ticks of 250 ms
do
    local slots = {}
    for i = 1, 20 do slots[i] = S("ITEM_Plate", 5, 5) end
    local f = fake({ redirect = REDIRECT_ON, player = inv({}, 3), unit = inv(slots, 20), station = {}, max = { ITEM_Plate = 5 }, raw = { ITEM_Plate = 5 } })
    local places = {}
    for i = 1, 20 do places[i] = cont_at(i * 2, { { name = "ITEM_Plate", count = 5 } }) end
    local b = B.new(f.io)
    local ok = b:start(plan_for(f, { place = places, need = {}, refund = {} }), {})
    local t0 = f.clock
    local st = run(b, f, 60)
    local ids = f.io.container_ids()
    local all = #ids == 20
    for _, id in ipairs(ids) do if cont_plate(f, id) ~= 5 then all = false end end
    check(ok and st.state == "done" and all and tot(f.inv.unit.slots, "ITEM_Plate") == 0 and #f.violations == 0 and f.clock - t0 <= 10 * 250,
          "speed: 20 containers x 5 Plate done in " .. tostring((f.clock - t0) / 250) .. " ticks, " .. #f.cmd_log .. " commands (" .. st.text .. ")")
end

-- progress: 1100 containers x 1 Plate -> 1000 sent in the first tick (RESTORE_CMD_PER_TICK), status line shows it, then 100
do
    local slots = {}
    for i = 1, 1100 do slots[i] = S("ITEM_Plate", 1, 50) end
    local places = {}
    for i = 1, 1100 do places[i] = cont_at(i * 2, { { name = "ITEM_Plate", count = 1 } }) end
    local f = fake({ redirect = REDIRECT_ON, player = inv({}, 3), unit = inv(slots, 1100), station = {} })
    local b = B.new(f.io)
    local ok = b:start(plan_for(f, { place = places, need = {}, refund = {} }), {})
    local texts, n = {}, 0
    while b:status().state == "working" and n < 2000 do
        f.clock = f.clock + 250
        b:tick(f.clock)
        n = n + 1
        if #f.cmd_log > 0 and #texts < 1 then texts[1] = b:status().text end
    end
    local st = b:status()
    local ids = f.io.container_ids()
    check(ok and st.state == "done" and #ids == 1100 and #f.cmd_log == 1100 and cmds_of(f, 2) == 1100 and #f.violations == 0,
          "progress: 1100 transfers, all sent and shown (" .. st.text .. ")")
    check(texts[1] and texts[1]:find("restoring [#########-] 91%  (1,000 of 1,100 commands)", 1, true) ~= nil,
          "progress: first tick status line " .. tostring(texts[1]))
end

-- cancel during the restore: the first tick sent 1000 (the cap), cancel -> nothing after it
do
    local slots = {}
    for i = 1, 1100 do slots[i] = S("ITEM_Plate", 1, 50) end
    local places = {}
    for i = 1, 1100 do places[i] = cont_at(i * 2, { { name = "ITEM_Plate", count = 1 } }) end
    local f = fake({ redirect = REDIRECT_ON, player = inv({}, 3), unit = inv(slots, 1100), station = {} })
    local b = B.new(f.io)
    b:start(plan_for(f, { place = places, need = {}, refund = {} }), {})
    local n = 0
    while b:status().state == "working" and #f.cmd_log == 0 and n < 2000 do
        f.clock = f.clock + 250
        b:tick(f.clock)
        n = n + 1
    end
    local before = #f.cmd_log
    local okc = b:cancel()
    for _ = 1, 40 do f.clock = f.clock + 250; b:tick(f.clock) end
    local st = b:status()
    check(before == 1000 and okc and st.state == "error" and starts_with(st.text, "cancelled") and #f.cmd_log == before,
          "cancel during the restore: 1000 sent, none after the cancel (" .. st.text .. ")")
end

-- mode off (restore_off.txt): nothing sent, a note says where the switch is
do
    local f = whole_fake()
    f.mode = "off"
    local b = start_cont(f, { { name = "ITEM_Plate", count = 120 } })
    local st = run(b, f, 400)
    local cid = new_cont(f)
    check(st.state == "done" and #f.cmd_log == 0 and cid and cont_plate(f, cid) == 0 and tot(f.inv.unit.slots, "ITEM_Plate") == 120
          and st.text:find("; restore: restore is off (restore_off.txt in Mods/BlueprintUnit)", 1, true) ~= nil, "mode off: nothing sent, note (" .. st.text .. ")")
end

-- Chk_Restore unchecked (opts.restore = false): off, nothing sent, the note names the checkbox; checked or no box: restore on
do
    local f = whole_fake()
    local b = start_cont(f, { { name = "ITEM_Plate", count = 120 } }, { restore = false })
    local st = run(b, f, 400)
    check(st.state == "done" and #f.cmd_log == 0 and st.text:find("restore is off (Chk_Restore unchecked)", 1, true) ~= nil,
          "checkbox unchecked: restore off, nothing sent (" .. st.text .. ")")
    local f2 = whole_fake()
    local b2 = start_cont(f2, { { name = "ITEM_Plate", count = 120 } }, { restore = true })
    local st2 = run(b2, f2, 400)
    check(st2.state == "done" and #f2.cmd_log == 3, "checkbox checked: restore on (" .. st2.text .. ")")
    local f3 = whole_fake()
    local b3 = start_cont(f3, { { name = "ITEM_Plate", count = 120 } }, {})
    local st3 = run(b3, f3, 400)
    check(st3.state == "done" and #f3.cmd_log == 3, "no checkbox widget (opts without restore): restore on (" .. st3.text .. ")")
end

-- legacy flow (no redirect): the last placement restores too, whole stacks
do
    local f = fake({ player = inv({}, 3), unit = inv({ S("ITEM_Plate", 50), S("ITEM_Plate", 50), S("ITEM_Plate", 20) }, 6), station = {} })
    local b, ok = start_cont(f, { { name = "ITEM_Plate", count = 120 } })
    local st = run(b, f, 400)
    local cid = new_cont(f)
    check(ok and st.state == "done" and cid and cont_plate(f, cid) == 120 and #f.violations == 0 and cmds_of(f, 2) == 3,
          "restore legacy: 120 back after the last placement (" .. st.text .. ")")
end

-- progress text helpers
do
    check(B.pure.progress(1234, 2468) == "restoring [#####-----] 50%  (1,234 of 2,468 commands)", "progress text: 50 pct with commas")
    check(B.pure.commas(1234567) == "1,234,567" and B.pure.commas(999) == "999", "commas: thousands separators")
    check(B.pure.bar(0, 100) == "[----------] 0%" and B.pure.bar(100, 100) == "[##########] 100%", "bar: 0 pct and 100 pct")
end

-- container ids never show: 60 s, then a note; the Build itself stays done
do
    local f = fake({ redirect = REDIRECT_ON, player = inv({}, 3), unit = inv({ S("ITEM_Plate", 50) }, 3), station = {}, drop_place = true })
    local b = start_cont(f, { { name = "ITEM_Plate", count = 50 } })
    local st = run(b, f, 800)
    check(st.state == "done" and st.text:find("; restore: restore stalled: container ids not found (new 0, placed 1)", 1, true) ~= nil,
          "restore: container ids never show -> stalled note (" .. st.text .. ")")
end

-- removed container: contents remembered before the first send (session memory, cell key)
do
    local f = fake({ redirect = REDIRECT_ON, player = inv({}, 3), unit = inv({}, 3),
                     station = { { id = 8, bcls = "BP_ContainerObject_2", x = 1, y = 0, h = 0, rot = 0 } },
                     containers = { [8] = { slots = { S("ITEM_Plate", 8), E(), E() } } } })
    local b = B.new(f.io)
    local ok = b:start(plan_for(f, { removed = { { id = 8, bcls = "BP_ContainerObject_2", x = 1, y = 0, h = 0, rot = 0, refund = {} } } }), {})
    local list = f.remembered["BP_ContainerObject_2|1|0|0|0"]
    check(ok and list and #list == 1 and list[1].name == "ITEM_Plate" and list[1].count == 8 and f.remember_at == 0,
          "memory: removed container contents remembered before the first send")
    run(b, f)
end

-- total check: machine cost only; refund contents do not count as supply (refund_cost = machine refund)
do
    local f = fake({ redirect = REDIRECT_ON, player = inv({}, 3), unit = inv({}, 3), station = { { id = 1, bcls = "BP_OLD", x = 101, y = 0 } } })
    local ok2, msg2 = B.new(f.io):start(plan_for(f, { place = { M("BP_NEW", 1, 0, {}) }, need = { ITEM_Plate = 5 }, refund = { ITEM_Plate = 8 }, refund_cost = {},
        removed = { { id = 1, bcls = "BP_OLD", x = 101, y = 0, refund = {} } } }), {})
    check(not ok2 and msg2 == "error: not enough items: Plate x5" and f.calls.rm == 0, "total check: removed contents are not supply (" .. tostring(msg2) .. ")")
    local f3 = fake({ redirect = REDIRECT_ON, player = inv({}, 3), unit = inv({}, 3), station = {} })
    local ok3 = start_cont(f3, { { name = "ITEM_Plate", count = 500 } })
    check(ok3, "total check: contents shortage never blocks the Build")
end

-- failed recipe/port changes (io.send_changes second result) reach the final status text, legacy and redirect
do
    local on = "on: redirect=on probe_log=off groups=yes"
    for _, fl in ipairs({ { "legacy", "off" }, { "redirect", on } }) do
        local function final(failc)
            local f = fake({ redirect = fl[2], player = inv({}, 3), unit = inv({ S("ITEM_Plate", 5) }, 3) })
            f.io.send_changes = function() return 1, failc end
            local b = B.new(f.io)
            b:start(plan_for(f, { place = { M("BP_A", 0, 0, { ITEM_Plate = 1 }) }, need = { ITEM_Plate = 1 } }), {})
            return run(b, f)
        end
        local st = final(2)
        check(st.state == "done" and st.text:sub(-#"; 2 recipe/port change(s) failed") == "; 2 recipe/port change(s) failed",
              fl[1] .. ": 2 failed changes in final text (" .. st.text .. ")")
        st = final(0)
        check(st.state == "done" and st.text:find("failed", 1, true) == nil, fl[1] .. ": no failed changes, no suffix (" .. st.text .. ")")
    end
end

-- ===== split route (io.split present): SORT the unit, then exact pieces (split into an empty unit slot + one TRANSFER) =====
local function spl(o)   -- fake with io.split (spec.split); plate stacks cap 100 unless o says otherwise
    local t = { redirect = REDIRECT_ON, player = inv({}, 3), station = {}, max = { ITEM_Plate = 100 }, raw = { ITEM_Plate = 100 }, split = true }
    for k, v in pairs(o) do t[k] = v end
    return fake(t)
end
local function churn(f, dur)   -- the unit's ITEM_Junk slot changes on every unit read for dur ms after the first SORT
    local base = f.io.read_inv
    f.io.read_inv = function(which)
        if which == "unit" and f.sort_at and f.clock < f.sort_at + dur then
            for _, s in ipairs(f.inv.unit.slots) do if s.item == "ITEM_Junk" then s.amount = s.amount == 1 and 2 or 1 end end
        end
        return base(which)
    end
end

-- exact N: Plate 100 + 100, need 120 -> SORT once, one split of 20, 2 TRANSFERs, unit keeps 80, no violation
do
    local f = spl({ unit = inv({ S("ITEM_Plate", 100, 100), S("ITEM_Plate", 100, 100) }, 4) })
    local tr = tracer(f)
    local b, ok = start_cont(f, { { name = "ITEM_Plate", count = 120 } })
    local st = run(b, f, 400)
    local cid = new_cont(f)
    check(ok and st.state == "done" and cid and cont_plate(f, cid) == 120 and tot(f.inv.unit.slots, "ITEM_Plate") == 80 and #f.violations == 0,
          "split exact: container 120 exact, unit keeps 80, no violation (" .. st.text .. ")")
    check(cmds_of(f, 5) == 1 and #f.splits == 1 and f.splits[1][3] == 20 and cmds_of(f, 2) == 2,
          "split exact: 1 SORT, 1 split of 20, 2 TRANSFERs")
    check(st.text:find("; restore: restored 120 of 120 items into 1 of 1 container(s)", 1, true) ~= nil
          and starts(tr, "restore plan (split): container id=" .. cid .. " item=ITEM_Plate count=120 splits=1 moved=120 short=0"),
          "split exact: status text and plan trace")
end

-- need 250 over three 100 stacks (3 empty slots): 100, 100, then a split of 50 -> container 250, unit keeps 50
do
    local f = spl({ unit = inv({ S("ITEM_Plate", 100, 100), S("ITEM_Plate", 100, 100), S("ITEM_Plate", 100, 100) }, 6) })
    local b = start_cont(f, { { name = "ITEM_Plate", count = 250 } })
    local st = run(b, f, 400)
    local cid = new_cont(f)
    check(cid and cont_plate(f, cid) == 250 and tot(f.inv.unit.slots, "ITEM_Plate") == 50 and #f.splits == 1 and f.splits[1][3] == 50
          and cmds_of(f, 2) == 3 and #f.violations == 0, "split 250 of 3 stacks: container 250, unit 50, one split of 50 (" .. st.text .. ")")
end

-- two containers, each needs 20 of the same 100 stack: two splits, each into a different empty unit slot
do
    local f = spl({ unit = inv({ S("ITEM_Plate", 100, 100), S("ITEM_Plate", 100, 100), S("ITEM_Plate", 100, 100) }, 6) })
    local b = B.new(f.io)
    b:start(plan_for(f, { place = { cont_at(5, { { name = "ITEM_Plate", count = 20 } }), cont_at(7, { { name = "ITEM_Plate", count = 20 } }) },
                         need = {}, refund = {} }), {})
    local st = run(b, f, 400)
    local ids = f.io.container_ids()
    check(#ids == 2 and cont_plate(f, ids[1]) == 20 and cont_plate(f, ids[2]) == 20 and #f.splits == 2 and f.splits[1][4] ~= f.splits[2][4]
          and #f.violations == 0, "split two containers: 20 + 20, two splits into distinct empty slots (" .. st.text .. ")")
end

-- unit short: Plate 70 for need 120 -> 70 in, a note, no split
do
    local f = spl({ unit = inv({ S("ITEM_Plate", 70, 100) }, 3) })
    local b = start_cont(f, { { name = "ITEM_Plate", count = 120 } })
    local st = run(b, f, 400)
    local cid = new_cont(f)
    check(cid and cont_plate(f, cid) == 70 and tot(f.inv.unit.slots, "ITEM_Plate") == 0 and #f.splits == 0 and #f.violations == 0
          and st.text:find("plan reduced: unit has 70 of 120 for Plate (short 50)", 1, true) ~= nil, "split unit short: 70 in, note, no split (" .. st.text .. ")")
end

-- plan reduced: unit has 30, job wants 50 -> 30 in, note names have / want / short, no old wording
do
    local f = spl({ unit = inv({ S("ITEM_Plate", 30, 100) }, 3) })
    local b = start_cont(f, { { name = "ITEM_Plate", count = 50 } })
    local st = run(b, f, 400)
    local cid = new_cont(f)
    check(cid and cont_plate(f, cid) == 30 and #f.violations == 0
          and st.text:find("plan reduced: unit has 30 of 50 for Plate (short 20)", 1, true) ~= nil
          and st.text:find("not restored (unit has", 1, true) == nil, "plan reduced: 30 in, note 'unit has 30 of 50 (short 20)' (" .. st.text .. ")")
end

-- top-up from the player inventory after the unit: unit 30 whole, then 90 split out of the player's 100 stack
do
    local f = spl({ unit = inv({ S("ITEM_Plate", 30, 100) }, 3), player = inv({ S("ITEM_Plate", 100, 100) }, 3) })
    local b = start_cont(f, { { name = "ITEM_Plate", count = 120 } })
    local st = run(b, f, 400)
    local cid = new_cont(f)
    check(cid and cont_plate(f, cid) == 120 and tot(f.inv.unit.slots, "ITEM_Plate") == 0 and tot(f.inv.player.slots, "ITEM_Plate") == 10
          and #f.splits == 1 and f.splits[1][1] == 101 and f.splits[1][3] == 90 and #f.violations == 0
          and st.text:find("Plate x120: 30 from unit, 90 from player", 1, true) ~= nil and st.text:find("short", 1, true) == nil,
          "player top-up: 30 from unit, 90 split from player, no short (" .. st.text .. ")")
end

-- unit 30 + player 50 < 120: container 80, both emptied, note with the remaining short
do
    local f = spl({ unit = inv({ S("ITEM_Plate", 30, 100) }, 3), player = inv({ S("ITEM_Plate", 50, 100) }, 3) })
    local b = start_cont(f, { { name = "ITEM_Plate", count = 120 } })
    local st = run(b, f, 400)
    local cid = new_cont(f)
    check(cid and cont_plate(f, cid) == 80 and tot(f.inv.unit.slots, "ITEM_Plate") == 0 and tot(f.inv.player.slots, "ITEM_Plate") == 0
          and #f.splits == 0 and #f.violations == 0 and st.text:find("Plate x120: 30 from unit, 50 from player, short 40", 1, true) ~= nil,
          "player top-up short: 80 in, both empty, note short 40 (" .. st.text .. ")")
end

-- unit has enough (100 + 100 for need 120): the player stack is not touched, no "from player" note
do
    local f = spl({ unit = inv({ S("ITEM_Plate", 100, 100), S("ITEM_Plate", 100, 100) }, 4), player = inv({ S("ITEM_Plate", 100, 100) }, 3) })
    local b = start_cont(f, { { name = "ITEM_Plate", count = 120 } })
    local st = run(b, f, 400)
    local cid = new_cont(f)
    check(cid and cont_plate(f, cid) == 120 and tot(f.inv.player.slots, "ITEM_Plate") == 100 and #f.violations == 0
          and st.text:find("from player", 1, true) == nil, "unit first: 120 from the unit, player untouched (" .. st.text .. ")")
end

-- rounded route (no io.split): unit only, the player stack is not used
do
    local f = whole_fake({ player = inv({ S("ITEM_Plate", 100) }, 3), unit = inv({ S("ITEM_Plate", 50) }, 3) })
    local b = start_cont(f, { { name = "ITEM_Plate", count = 120 } })
    local st = run(b, f, 400)
    local cid = new_cont(f)
    check(cid and cont_plate(f, cid) == 0 and tot(f.inv.player.slots, "ITEM_Plate") == 100 and #f.violations == 0
          and st.text:find("not restored (unit has 50)", 1, true) ~= nil, "rounded route: unit only, player untouched (" .. st.text .. ")")
end

-- every split refused: the split is skipped (its TRANSFER passed), the unit part lands, no stall
do
    local f = spl({ unit = inv({ S("ITEM_Plate", 30, 100) }, 3), player = inv({ S("ITEM_Plate", 100, 100) }, 3) })
    f.split_fail_n = 99
    local b = start_cont(f, { { name = "ITEM_Plate", count = 120 } })
    local st = run(b, f, 400)
    local cid = new_cont(f)
    check(cid and cont_plate(f, cid) == 30 and tot(f.inv.player.slots, "ITEM_Plate") == 100 and #f.violations == 0
          and st.text:find("1 command(s) skipped (refused)", 1, true) ~= nil and st.text:find("stalled", 1, true) == nil,
          "player split refused: 30 in, player kept, skipped note, no stall (" .. st.text .. ")")
end

-- player whole-stack TRANSFER refused (command 2, the player's 90): skipped, not counted in skip_u, so the unit verify still passes
-- (refuse_after = 2: the SORT is logged first, then the unit TRANSFER goes through, the player TRANSFER is refused)
do
    local f = spl({ unit = inv({ S("ITEM_Plate", 30, 100) }, 3), player = inv({ S("ITEM_Plate", 90, 100) }, 3) })
    f.refuse_after = 2
    local b = start_cont(f, { { name = "ITEM_Plate", count = 120 } })
    local st = run(b, f, 400)
    local cid = new_cont(f)
    check(st.state == "done" and cid and cont_plate(f, cid) == 30 and tot(f.inv.unit.slots, "ITEM_Plate") == 0
          and tot(f.inv.player.slots, "ITEM_Plate") == 90 and #f.violations == 0, "player TRANSFER refused: 30 in, player kept (" .. st.text .. ")")
    check(st.text:find("1 command(s) skipped (refused)", 1, true) ~= nil and st.text:find("stalled", 1, true) == nil
          and st.text:find("mismatch", 1, true) == nil, "player TRANSFER refused: skipped note, no stall or mismatch (" .. st.text .. ")")
end

-- player has no free slot for the split: unit 30 in, player 100 + Gear stack fill it -> 90 not restored, note names the player slot
do
    local f = spl({ unit = inv({ S("ITEM_Plate", 30, 100) }, 3), player = inv({ S("ITEM_Plate", 100, 100), S("ITEM_Gear", 10, 50) }, 2) })
    local b = start_cont(f, { { name = "ITEM_Plate", count = 120 } })
    local st = run(b, f, 400)
    local cid = new_cont(f)
    check(cid and cont_plate(f, cid) == 30 and tot(f.inv.unit.slots, "ITEM_Plate") == 0 and tot(f.inv.player.slots, "ITEM_Plate") == 100
          and #f.splits == 0 and #f.violations == 0, "player no free slot: 30 in, player kept (" .. st.text .. ")")
    check(st.text:find("Plate x90 not restored (no free player slot)", 1, true) ~= nil, "player no free slot: note (" .. st.text .. ")")
end

-- 11 containers, each Plate x120, unit and player empty: 11 per-item notes aggregate into one summary line
do
    local f = spl({ unit = inv({}, 3), player = inv({}, 3) })
    local b = B.new(f.io)
    local places = {}
    for i = 1, 11 do places[i] = cont_at(i, { { name = "ITEM_Plate", count = 120 } }) end
    b:start(plan_for(f, { place = places, need = {}, refund = {} }), {})
    local st = run(b, f, 400)
    check(st.text:find("11 container items", 1, true) ~= nil and st.text:find("items short in total", 1, true) ~= nil
          and st.text:find("plan reduced: unit has", 1, true) == nil, "aggregate 11 reduced notes: one summary line (" .. st.text .. ")")
end

-- 10 containers, same setup: per-item note still shown
do
    local f = spl({ unit = inv({}, 3), player = inv({}, 3) })
    local b = B.new(f.io)
    local places = {}
    for i = 1, 10 do places[i] = cont_at(i, { { name = "ITEM_Plate", count = 120 } }) end
    b:start(plan_for(f, { place = places, need = {}, refund = {} }), {})
    local st = run(b, f, 400)
    check(st.text:find("plan reduced: unit has 0 of 120 for Plate (short 120)", 1, true) ~= nil, "10 reduced notes: per-item text kept (" .. st.text .. ")")
end

-- container room 50 (one slot), unit 30 whole + player 100 split 20 (room left) -> container 50, note from unit and player, full note
do
    local f = spl({ unit = inv({ S("ITEM_Plate", 30, 100) }, 3), player = inv({ S("ITEM_Plate", 100, 100) }, 3),
                    raw = { ITEM_Plate = 50 }, max = { ITEM_Plate = 50 }, cont_slots = 1 })
    local b = start_cont(f, { { name = "ITEM_Plate", count = 120 } })
    local st = run(b, f, 400)
    local cid = new_cont(f)
    check(cid and cont_plate(f, cid) == 50 and tot(f.inv.unit.slots, "ITEM_Plate") == 0 and tot(f.inv.player.slots, "ITEM_Plate") == 80
          and #f.splits == 1 and f.splits[1][1] == 101 and f.splits[1][3] == 20 and #f.violations == 0,
          "player room: container 50, player split 20 (" .. st.text .. ")")
    check(st.text:find("Plate x120: 30 from unit, 20 from player", 1, true) ~= nil
          and st.text:find("container " .. tostring(cid) .. " full: Plate x70", 1, true) ~= nil, "player room: note 30/20 and full note x70 (" .. st.text .. ")")
end

-- container room 50 (one slot, cap 50), unit 40 + 40, need 80 -> 40 direct, 10 split, container 50, unit keeps 30, full note
do
    local f = spl({ unit = inv({ S("ITEM_Plate", 40, 100), S("ITEM_Plate", 40, 100) }, 4), raw = { ITEM_Plate = 50 }, max = { ITEM_Plate = 50 }, cont_slots = 1 })
    local b = start_cont(f, { { name = "ITEM_Plate", count = 80 } })
    local st = run(b, f, 400)
    local cid = new_cont(f)
    check(cid and cont_plate(f, cid) == 50 and tot(f.inv.unit.slots, "ITEM_Plate") == 30 and #f.splits == 1 and f.splits[1][3] == 10 and #f.violations == 0
          and st.text:find("container " .. cid .. " full: Plate x30 left in the unit", 1, true) ~= nil, "split room: container 50, unit keeps 30, full note (" .. st.text .. ")")
end

-- no free unit slot: Plate 100 + Gear 10 fill the unit, need 30 -> nothing moved, note
do
    local f = spl({ unit = inv({ S("ITEM_Plate", 100, 100), S("ITEM_Gear", 10, 50) }, 2) })
    local b = start_cont(f, { { name = "ITEM_Plate", count = 30 } })
    local st = run(b, f, 400)
    local cid = new_cont(f)
    check(cid and cont_plate(f, cid) == 0 and tot(f.inv.unit.slots, "ITEM_Plate") == 100 and #f.splits == 0 and cmds_of(f, 2) == 0
          and st.text:find("; restore: restored 0 of 30 items into 0 of 1 container(s); Plate x30 not restored (no free unit slot)", 1, true) ~= nil, "split no free slot: nothing moved, note (" .. st.text .. ")")
end

-- split refused every time: 6 tries, skipped; its TRANSFER is not sent; the restore is done, nothing moved, no violation
do
    local f = spl({ unit = inv({ S("ITEM_Plate", 100, 100) }, 3) })
    f.split_fail_n = 1e9
    local b = start_cont(f, { { name = "ITEM_Plate", count = 30 } })
    local st = run(b, f, 400)
    local cid = new_cont(f)
    check(st.state == "done" and cid and cont_plate(f, cid) == 0 and tot(f.inv.unit.slots, "ITEM_Plate") == 100 and #f.splits == 6
          and cmds_of(f, 2) == 0 and #f.violations == 0 and st.text:find("1 command(s) skipped (refused)", 1, true) ~= nil
          and st.text:find("stalled", 1, true) == nil, "split refused 6 times: skipped, TRANSFER not sent, done (" .. st.text .. ")")
end

-- split refused once: retried on the next tick, 30 delivered, nothing skipped
do
    local f = spl({ unit = inv({ S("ITEM_Plate", 100, 100) }, 3) })
    f.split_fail_n = 1
    local b = start_cont(f, { { name = "ITEM_Plate", count = 30 } })
    local st = run(b, f, 400)
    local cid = new_cont(f)
    check(st.state == "done" and cid and cont_plate(f, cid) == 30 and tot(f.inv.unit.slots, "ITEM_Plate") == 70 and #f.splits == 2
          and #f.violations == 0 and st.text:find("skipped", 1, true) == nil and st.text:find("stalled", 1, true) == nil,
          "split refused once: retried, 30 delivered (" .. st.text .. ")")
end

-- no io.split: rounded route as before, no SORT sent
do
    local f = whole_fake()
    local b = start_cont(f, { { name = "ITEM_Plate", count = 120 } })
    local st = run(b, f, 400)
    local cid = new_cont(f)
    check(cid and cont_plate(f, cid) == 120 and cmds_of(f, 5) == 0 and #f.cmd_log == 3, "no io.split: rounded route, no SORT, 3 TRANSFERs (" .. st.text .. ")")
end

-- SORT settles: no change for 1500 ms after the SORT (noop_sort = the game never sorts), then the restore runs
do
    local f = spl({ unit = inv({ S("ITEM_Plate", 50, 100), S("ITEM_Plate", 50, 100), S("ITEM_Plate", 20, 100) }, 3) })
    f.noop_sort = true
    local tr = tracer(f)
    local b = start_cont(f, { { name = "ITEM_Plate", count = 120 } })
    local st = run(b, f, 400)
    local cid = new_cont(f)
    local gap = f.cmd_log[2] and f.cmd_log[2][5] - f.cmd_log[1][5]
    check(st.state == "done" and cid and cont_plate(f, cid) == 120 and cmds_of(f, 5) == 1 and gap and gap >= 1500 and gap < 15000
          and starts(tr, "restore sort: unit settled"), "sort settle: runs 1500+ ms after the SORT, not before (gap " .. tostring(gap) .. ")")
end

-- SORT keeps changing for 4 s, then settles: the restore waits, then runs
do
    local f = spl({ unit = inv({ S("ITEM_Plate", 50, 100), S("ITEM_Plate", 50, 100), S("ITEM_Plate", 20, 100), S("ITEM_Junk", 1, 100) }, 4) })
    churn(f, 4000)
    local tr = tracer(f)
    local b = start_cont(f, { { name = "ITEM_Plate", count = 120 } })
    local st = run(b, f, 400)
    local cid = new_cont(f)
    local gap = f.cmd_log[2] and f.cmd_log[2][5] - f.cmd_log[1][5]
    check(st.state == "done" and cid and cont_plate(f, cid) == 120 and gap and gap >= 4500 and starts(tr, "restore sort: unit settled")
          and not starts(tr, "restore sort: cap"), "sort changing 4 s: waits, then settles and runs (gap " .. tostring(gap) .. ")")
end

-- SORT never settles (changes until 14 s): the 15 s cap ends the wait and the restore runs
do
    local f = spl({ unit = inv({ S("ITEM_Plate", 50, 100), S("ITEM_Plate", 50, 100), S("ITEM_Plate", 20, 100), S("ITEM_Junk", 1, 100) }, 4) })
    churn(f, 14000)
    local tr = tracer(f)
    local b = start_cont(f, { { name = "ITEM_Plate", count = 120 } })
    local st = run(b, f, 800)
    local cid = new_cont(f)
    local gap = f.cmd_log[2] and f.cmd_log[2][5] - f.cmd_log[1][5]
    check(cid and st.state == "done" and cont_plate(f, cid) == 120 and gap and gap >= 14500 and starts(tr, "restore sort: cap reached")
          and not starts(tr, "restore sort: unit settled"), "sort cap: 15 s wait, trace, restore runs (gap " .. tostring(gap) .. ")")
end

-- SORT refused every time: 6 tries (RETRY_MAX + 1), note, the restore goes on
do
    local f = spl({ unit = inv({ S("ITEM_Plate", 50, 100), S("ITEM_Plate", 50, 100), S("ITEM_Plate", 20, 100) }, 3) })
    f.refuse_sort = true
    local b = start_cont(f, { { name = "ITEM_Plate", count = 120 } })
    local st = run(b, f, 400)
    local cid = new_cont(f)
    check(st.state == "done" and cid and cont_plate(f, cid) == 120 and cmds_of(f, 5) == 6 and #f.violations == 0
          and st.text:find("unit not sorted (SORT refused)", 1, true) ~= nil, "SORT refused: 6 tries, note, restore goes on (" .. st.text .. ")")
end

-- cancel during the SORT wait: the SORT is the last command
do
    local f = spl({ unit = inv({ S("ITEM_Plate", 50, 100), S("ITEM_Plate", 50, 100), S("ITEM_Plate", 20, 100) }, 3) })
    f.noop_sort = true
    local b = start_cont(f, { { name = "ITEM_Plate", count = 120 } })
    local n = 0
    while b:status().state == "working" and #f.cmd_log == 0 and n < 400 do f.clock = f.clock + 250; b:tick(f.clock); n = n + 1 end
    local before = #f.cmd_log
    b:cancel()
    for _ = 1, 40 do f.clock = f.clock + 250; b:tick(f.clock) end
    local st = b:status()
    check(before == 1 and st.state == "error" and starts_with(st.text, "cancelled") and #f.cmd_log == before, "cancel during the SORT wait: nothing sent after it (" .. st.text .. ")")
end

-- cancel during the pipeline: 1100 whole-slot TRANSFERs after the SORT, 1000 go in the first send, cancel -> nothing after
do
    local slots = {}
    for i = 1, 1100 do slots[i] = S("ITEM_Plate", 1, 50) end
    local places = {}
    for i = 1, 1100 do places[i] = cont_at(i * 2, { { name = "ITEM_Plate", count = 1 } }) end
    local f = spl({ unit = inv(slots, 1100), max = { ITEM_Plate = 50 }, raw = { ITEM_Plate = 50 } })
    local b = B.new(f.io)
    b:start(plan_for(f, { place = places, need = {}, refund = {} }), {})
    local n = 0
    while b:status().state == "working" and #f.cmd_log < 2 and n < 2000 do f.clock = f.clock + 250; b:tick(f.clock); n = n + 1 end
    local before = #f.cmd_log
    b:cancel()
    for _ = 1, 40 do f.clock = f.clock + 250; b:tick(f.clock) end
    local st = b:status()
    check(before == 1001 and st.state == "error" and starts_with(st.text, "cancelled") and #f.cmd_log == before,
          "cancel during the pipeline: SORT + 1000 sent, none after the cancel (" .. st.text .. ")")
end

-- split no-op (returns true, changes nothing): the model says the unit gave up 30 -> the verify never matches -> STALL
do
    local f = spl({ unit = inv({ S("ITEM_Plate", 100, 100) }, 3) })
    f.split_noop = true
    local b = start_cont(f, { { name = "ITEM_Plate", count = 30 } })
    local st = run(b, f, 800)
    local cid = new_cont(f)
    check(st.state == "done" and cid and cont_plate(f, cid) == 0 and tot(f.inv.unit.slots, "ITEM_Plate") == 100
          and st.text:find("restore stalled at pipeline (2 of 2 commands sent)", 1, true) ~= nil, "split no-op: STALL, nothing more sent (" .. st.text .. ")")
end

-- split vs queued TRANSFER: the game applies a TRANSFER late (delay), io.split at once. Container 5 takes the whole first
-- stack (TRANSFER queued), container 7 needs 20 of the 30 stack -> the split must not pick slot 1 (emptied in the model only)
do
    local f = spl({ unit = inv({ S("ITEM_Plate", 100, 100), S("ITEM_Plate", 30, 100) }, 4), delay = 500 })
    local b = B.new(f.io)
    b:start(plan_for(f, { place = { cont_at(5, { { name = "ITEM_Plate", count = 100 } }), cont_at(7, { { name = "ITEM_Plate", count = 20 } }) },
                         need = {}, refund = {} }), {})
    local st = run(b, f, 400)
    local ids = f.io.container_ids()
    check(st.state == "done" and #ids == 2 and cont_plate(f, ids[1]) == 100 and cont_plate(f, ids[2]) == 20
          and tot(f.inv.unit.slots, "ITEM_Plate") == 10 and #f.violations == 0 and #f.splits == 1 and f.splits[1][4] == 2,
          "split race: split goes to the empty slot 3, not the slot a queued TRANSFER empties (" .. st.text .. ")")
end

-- verify poll: game applies 3 s late, 2 containers. Polls every 2 s after the first 250 ms, confirmed containers not read again
do
    local f = spl({ unit = inv({ S("ITEM_Plate", 100, 100), S("ITEM_Plate", 100, 100) }, 4), delay = 3000 })
    local reads = {}
    local base = f.io.read_machine_inv
    f.io.read_machine_inv = function(id) reads[id] = (reads[id] or 0) + 1; return base(id) end
    local b = B.new(f.io)
    b:start(plan_for(f, { place = { cont_at(5, { { name = "ITEM_Plate", count = 100 } }), cont_at(7, { { name = "ITEM_Plate", count = 100 } }) },
                         need = {}, refund = {} }), {})
    local st = run(b, f, 400)
    local ids = f.io.container_ids()
    local worst = math.max(reads[ids[1]] or 0, reads[ids[2]] or 0)
    check(st.state == "done" and #ids == 2 and cont_plate(f, ids[1]) == 100 and cont_plate(f, ids[2]) == 100 and #f.violations == 0
          and worst <= 8, "verify poll: container reads per container " .. worst .. " max over a 3 s wait (" .. st.text .. ")")
end

-- config check (stage 17): the raw game view must show each placed machine with the config bytes sent
do
    local CFG = "\1\0\2\0\0\0"
    local function cfg_run(over)
        local m = M("BP_Splitter", 0, 0, { ITEM_Plate = 1 })
        m.cfg, m.h, m.rot = CFG, 0, 0   -- plan machines carry h/rot (cell key)
        local f = fake(over)
        local b = B.new(f.io)
        b:start(plan_for(f, { place = { m }, need = { ITEM_Plate = 1 } }), {})
        local t0 = f.clock
        local st = run(b, f, 1000)
        return st, f.clock - t0
    end
    local st1 = cfg_run({ player = inv({}, 2), unit = inv({ S("ITEM_Plate", 10) }, 2), game_cfg = function(c) return c:sub(1, 2) end })
    check(st1.state == "done" and st1.text:find("config not applied for 1 machines (sent 6 bytes, game has 2)", 1, true) ~= nil,
          "config check: game keeps 2 of 6 bytes -> note (" .. st1.text .. ")")
    local st2 = cfg_run({ player = inv({}, 2), unit = inv({ S("ITEM_Plate", 10) }, 2) })
    check(st2.state == "done" and st2.text == "sent: placed 1, removed 0 (the game updates its blueprint view in about 30 s)" and not st2.text:find("config", 1, true),
          "config check: game keeps the same bytes -> no note (" .. st2.text .. ")")
    local st3, waited = cfg_run({ player = inv({}, 2), unit = inv({ S("ITEM_Plate", 10) }, 2), drop_place = true })
    check(st3.state == "done" and not st3.text:find("config", 1, true) and waited >= 120000 and waited < 130000,
          "config check: machine never shows -> no note after 120 s (" .. st3.text .. ")")
end

-- ===== creative restore rounds (io.give_creative): gives into the player in rounds sized to free slots, then the split pipeline =====
do
    -- a: 250 over 3 empty player slots -> gives 200 then 50
    local f = spl({ creative = true, give = true, player = inv({}, 3), unit = inv({}, 4) })
    local b = start_cont(f, { { name = "ITEM_Plate", count = 250 } })
    local st = run(b, f, 800)
    local cid = new_cont(f)
    check(st.state == "done" and cid ~= nil and cont_plate(f, cid) == 250 and #f.gives == 2 and f.gives[1][2] == 200 and f.gives[2][2] == 50
          and #f.violations == 0 and tot(f.inv.player.slots, "ITEM_Plate") == 0
          and st.text:find("restored 250 of 250 items into 1 of 1 container(s)", 1, true) ~= nil,
          "creative rounds: 250 -> gives 200 then 50, container 250 (" .. st.text .. ")")
end
do
    -- b: two containers of 100 in one round (6 free slots) -> one give of 200
    local f = spl({ creative = true, give = true, player = inv({}, 6), unit = inv({}, 4) })
    local b = B.new(f.io)
    b:start(plan_for(f, { place = { cont_at(5, { { name = "ITEM_Plate", count = 100 } }), cont_at(7, { { name = "ITEM_Plate", count = 100 } }) }, need = {}, refund = {} }), {})
    local st = run(b, f, 800)
    local ids = {}
    for id in pairs(f.containers) do if id > 500 then ids[#ids + 1] = id end end
    table.sort(ids)
    check(st.state == "done" and #f.gives == 1 and f.gives[1][2] == 200 and #ids == 2 and cont_plate(f, ids[1]) == 100 and cont_plate(f, ids[2]) == 100
          and st.text:find("restored 200 of 200 items into 2 of 2", 1, true) ~= nil,
          "creative rounds: two containers -> one give of 200, 100 each (" .. st.text .. ")")
end
do
    -- c: non-creative with give present -> no give, old split route
    local f = spl({ give = true, player = inv({}, 3), unit = inv({ S("ITEM_Plate", 100, 100), S("ITEM_Plate", 100, 100), S("ITEM_Plate", 100, 100) }, 6) })
    local b = start_cont(f, { { name = "ITEM_Plate", count = 250 } })
    local st = run(b, f, 400)
    local cid = new_cont(f)
    check(st.state == "done" and #f.gives == 0 and cid ~= nil and cont_plate(f, cid) == 250 and tot(f.inv.unit.slots, "ITEM_Plate") == 50,
          "creative rounds: non-creative never gives (" .. st.text .. ")")
end
do
    -- d: creative without io.give_creative -> old split route, no give
    local f = spl({ creative = true, player = inv({}, 3), unit = inv({ S("ITEM_Plate", 100, 100), S("ITEM_Plate", 100, 100), S("ITEM_Plate", 100, 100) }, 6) })
    local b = start_cont(f, { { name = "ITEM_Plate", count = 250 } })
    local st = run(b, f, 400)
    local cid = new_cont(f)
    check(st.state == "done" and f.gives == nil and cid ~= nil and cont_plate(f, cid) == 250,
          "creative rounds: no give_creative -> split route as before (" .. st.text .. ")")
end
do
    -- e: give refused -> note, nothing restored
    local f = spl({ creative = true, give = true, player = inv({}, 3), unit = inv({}, 4) })
    f.give_fail = true
    local b = start_cont(f, { { name = "ITEM_Plate", count = 250 } })
    local st = run(b, f, 800)
    local cid = new_cont(f)
    check(st.state == "done" and cid ~= nil and cont_plate(f, cid) == 0 and st.text:find("creative give failed: Plate x200 (give refused)", 1, true) ~= nil
          and st.text:find("creative give failed: Plate x50 (give refused)", 1, true) ~= nil,
          "creative rounds: refused gives -> one note per round, container 0 (" .. st.text .. ")")
end
do
    -- f: give accepted but nothing shows -> STALL note after STALL_MS, run ends
    local f = spl({ creative = true, give = true, player = inv({}, 3), unit = inv({}, 4) })
    f.give_noop = true
    local b = start_cont(f, { { name = "ITEM_Plate", count = 250 } })
    local st = run(b, f, 800)
    check(st.state == "done" and st.text:find("creative items did not show in the player inventory", 1, true) ~= nil,
          "creative rounds: give shows nothing -> stall note, done (" .. st.text .. ")")
end
do
    -- g: player full at the start -> nothing given, player items untouched
    local f = spl({ creative = true, give = true, player = inv({ S("ITEM_Other", 100, 100), S("ITEM_Other", 100, 100), S("ITEM_Other", 100, 100) }, 3), unit = inv({}, 4) })
    local b = start_cont(f, { { name = "ITEM_Plate", count = 250 } })
    local st = run(b, f, 800)
    local cid = new_cont(f)
    check(st.state == "done" and #f.gives == 0 and cid ~= nil and cont_plate(f, cid) == 0
          and st.text:find("player inventory full, free some slots", 1, true) ~= nil and tot(f.inv.player.slots, "ITEM_Other") == 300,
          "creative rounds: player full -> no give, note, player items kept (" .. st.text .. ")")
end
do
    -- h: 2 free player slots (2 others hold 200) -> each give fits (free - 1 staging slot) * 100 = 100, 3 rounds
    local f = spl({ creative = true, give = true, player = inv({ S("ITEM_Other", 100, 100), S("ITEM_Other", 100, 100), E(), E() }, 4), unit = inv({}, 4) })
    local b = start_cont(f, { { name = "ITEM_Plate", count = 250 } })
    local st = run(b, f, 800)
    local cid = new_cont(f)
    local fit = true
    for _, g in ipairs(f.gives) do if g[2] > 100 then fit = false end end
    check(st.state == "done" and fit and #f.gives >= 2 and cid ~= nil and cont_plate(f, cid) == 250 and #f.violations == 0
          and tot(f.inv.player.slots, "ITEM_Other") == 200,
          "creative rounds: partly full player -> every give <= 100, container 250 (" .. st.text .. ")")
end

-- ===== Station Build: station blocks go in first (one send, polled), then the factory; refusals before any send =====
local BLK = { class = "BPO_Station_02", gx = 2, gy = 0, h = 0, rot = 0 }
local function blocks_fake(spec)
    local f = fake(spec)
    f.sent_blocks, f.blocks_out, f.shown_at = 0, nil, 0
    f.io.station_build_capable = function() return spec.capable ~= false, "Station Build needs MSCore 0.8.0 or newer." end
    f.io.send_blocks = function(_, blocks, ids)
        f.sent_blocks = f.sent_blocks + 1
        f.block_ids = ids
        if spec.block_send_fail then return false, "add_block failed" end
        f.blocks_out = f.blocks_out or {}
        for _, b in ipairs(blocks) do f.blocks_out[#f.blocks_out + 1] = b end
        f.shown_at = f.clock + (spec.block_delay or 0)
        return true
    end
    f.io.scan_blocks = function()
        local out = {}
        if f.blocks_out and not spec.block_never and f.clock >= f.shown_at then
            for i, b in ipairs(f.blocks_out) do out[i] = { class = b.class, gx = b.gx, gy = b.gy, h = b.h, rot = b.rot } end
        end
        return out
    end
    return f
end
local function with_blocks(f, need_blocks, need_cost, refuse)
    local p = plan_for(f, { place = { M("BP_A", 0, 0, { ITEM_Plate = 1 }) }, need = { ITEM_Plate = 1 } })
    p.blocks, p.block_need, p.block_count, p.block_refuse = need_blocks, need_cost, #need_blocks, refuse
    return p
end

-- placed after one send: machines wait for the blocks, then go; exactly one send
do
    local f = blocks_fake({ player = inv({}, 2), unit = inv({ S("ITEM_Plate", 10) }, 2), block_delay = 1000 })
    local b = B.new(f.io)
    local ok = b:start(with_blocks(f, { BLK }, { ITEM_Plate = 2 }), {})
    check(ok and f.sent_blocks == 1 and f.calls.pl == 0 and b:status().state == "working", "station blocks: one send at start, no machine placed yet")
    local st = run(b, f)
    check(st.state == "done" and f.sent_blocks == 1 and f.calls.pl == 1, "station blocks: shown, then factory placed, still one send (" .. st.text .. ")")
    check(f.block_ids.primary == 202 and f.block_ids.player == 101 and f.block_ids.editing == 0, "station blocks: ids unit=primary, player, editing 0")
end

-- shortfall in the plan: no refusal any more, blocks sent
do
    local f = blocks_fake({ player = inv({}, 2), unit = inv({ S("ITEM_Plate", 10) }, 2) })
    local b = B.new(f.io)
    local ok = b:start(with_blocks(f, { BLK }, { ITEM_Plate = 2 }, { { item = "ITEM_Plate", need = 2, have = 0 } }), {})
    check(ok == true and f.sent_blocks == 1 and b:status().state == "working", "station blocks: shortage does not refuse, one send")
end

-- block cost is not in the total check: 3 machine + 2 block needed, 4 held -> started
do
    local f = blocks_fake({ player = inv({}, 2), unit = inv({ S("ITEM_Plate", 4) }, 2) })
    local b = B.new(f.io)
    local p = with_blocks(f, { BLK }, { ITEM_Plate = 2 })
    p.need = { ITEM_Plate = 3 }
    local ok = b:start(p, {})
    check(ok == true and f.sent_blocks == 1, "station blocks: block cost not in the total check, blocks sent")
end

-- unplaced floor: refused before any send, factory not built
do
    local f = blocks_fake({ player = inv({}, 2), unit = inv({ S("ITEM_Plate", 10) }, 2) })
    local b = B.new(f.io)
    local p = with_blocks(f, { BLK }, { ITEM_Plate = 2 })
    p.block_unplaced = { { class = "BPO_X", gx = 1, gy = 2, h = 0 } }
    local ok, msg = b:start(p, {})
    check(not ok and f.sent_blocks == 0 and msg:find("cannot be placed", 1, true) and msg:find("The factory was not built.", 1, true),
          "station blocks: unplaced floor refused, nothing sent (" .. msg .. ")")
end

-- blocks never show: STALL after 30 s with no progress, not sent again
do
    local f = blocks_fake({ block_never = true, player = inv({}, 2), unit = inv({ S("ITEM_Plate", 10) }, 2) })
    local b = B.new(f.io)
    local t0 = f.clock
    b:start(with_blocks(f, { BLK }, { ITEM_Plate = 2 }), {})
    local st = run(b, f)
    local waited = f.clock - t0
    check(st.state == "error" and st.text:find("The station blocks stopped appearing: no new block for 30 s (1 still missing); nothing was resent.", 1, true)
          and waited >= 30000 and waited <= 31000 and f.sent_blocks == 1 and f.calls.pl == 0, "station blocks: never shown -> stall after 30 s, no resend (" .. st.text .. ")")
end

-- progress: one block more every 20 s (3 blocks) -> not a stall, done after 60 s
do
    local f = blocks_fake({ player = inv({}, 2), unit = inv({ S("ITEM_Plate", 10) }, 2) })
    f.io.scan_blocks = function()
        local out = {}
        if not f.blocks_out then return out end
        local k = math.min(3, math.floor((f.clock - f.shown_at) / 20000))
        for i = 1, k do local bb = f.blocks_out[i]; out[i] = { class = bb.class, gx = bb.gx, gy = bb.gy, h = bb.h, rot = bb.rot } end
        return out
    end
    local b = B.new(f.io)
    local t0 = f.clock
    local ok = b:start(with_blocks(f, { BLK, { class = "BPO_Station_02", gx = 4, gy = 0, h = 0, rot = 0 }, { class = "BPO_Station_02", gx = 6, gy = 0, h = 0, rot = 0 } }, { ITEM_Plate = 2 }), {})
    local st = run(b, f, 1200)
    check(ok and st.state == "done" and f.calls.pl == 1 and f.clock - t0 >= 60000, "station blocks: slow progress (20 s per block) is not a stall (" .. st.text .. ")")
end

-- cap: one block every 20 s (no 30 s stall) but 100 blocks need ~2000 s -> the 10 min cap stops the block phase, no factory
do
    local f = blocks_fake({ player = inv({}, 2), unit = inv({ S("ITEM_Plate", 10) }, 2) })
    local many = {}
    for i = 1, 100 do many[i] = { class = "BPO_Station_02", gx = 2 * i, gy = 0, h = 0, rot = 0 } end
    f.io.scan_blocks = function()
        local out = {}
        if not f.blocks_out then return out end
        local k = math.min(#f.blocks_out, math.floor((f.clock - f.shown_at) / 20000))
        for i = 1, k do local bb = f.blocks_out[i]; out[i] = { class = bb.class, gx = bb.gx, gy = bb.gy, h = bb.h, rot = bb.rot } end
        return out
    end
    local b = B.new(f.io)
    local t0 = f.clock
    local ok = b:start(with_blocks(f, many, { ITEM_Plate = 2 }), {})
    local st = run(b, f, 6000)
    local waited = f.clock - t0
    check(ok and st.state == "error" and st.text:find("did not all appear within 10 min", 1, true) and waited >= 600000 and waited <= 601000
          and f.sent_blocks == 1 and f.calls.pl == 0, "station blocks: progress never stalls, 10 min cap stops the block phase (" .. st.text .. ")")
end

-- batches: 250 blocks -> 3 sends (100, 100, 50); removals only with the first send
do
    local f = blocks_fake({ player = inv({}, 2), unit = inv({ S("ITEM_Plate", 10) }, 2) })
    local removes = {}
    f.io.send_blocks = function(_, blocks, ids, rem)
        f.sent_blocks = f.sent_blocks + 1
        removes[#removes + 1] = #rem
        f.blocks_out = f.blocks_out or {}
        for _, bb in ipairs(blocks) do f.blocks_out[#f.blocks_out + 1] = bb end
        f.shown_at = f.clock
        return true
    end
    local many = {}
    for i = 1, 250 do many[i] = { class = "BPO_Station_02", gx = i * 2, gy = 0, h = 0, rot = 0 } end
    local b = B.new(f.io)
    local p = with_blocks(f, many, { ITEM_Plate = 2 })
    p.block_remove = { { class = "BPO_Old", gx = 9, gy = 0, h = 0, rot = 0 } }
    local ok = b:start(p, {})
    local st = run(b, f, 2000)
    check(ok and st.state == "done" and f.sent_blocks == 3 and removes[1] == 1 and removes[2] == 0 and removes[3] == 0 and f.calls.pl == 1,
          "station blocks: 250 blocks in 3 batches, removes with the first only (" .. st.text .. ")")
end

-- forced shortage: block cost not in the total check, unit holds none, blocks still sent, factory placed
do
    local f = blocks_fake({ creative = false, player = inv({ S("ITEM_Plate", 10) }, 2), unit = inv({}, 2) })
    local b = B.new(f.io)
    local ok = b:start(with_blocks(f, { BLK }, { ITEM_Plate = 100 }), {})
    local st = run(b, f)
    check(ok and f.sent_blocks == 1 and st.state == "done", "station blocks: forced shortage, blocks sent, done (" .. st.text .. ")")
end

-- send fails: start refuses, no resend, no machine placed
do
    local f = blocks_fake({ block_send_fail = true, player = inv({}, 2), unit = inv({ S("ITEM_Plate", 10) }, 2) })
    local b = B.new(f.io)
    local ok, msg = b:start(with_blocks(f, { BLK }, { ITEM_Plate = 2 }), {})
    check(not ok and f.sent_blocks == 1 and f.calls.pl == 0 and msg:find("The station blocks could not be sent; nothing was resent.", 1, true),
          "station blocks: send failure -> error, not resent (" .. msg .. ")")
end

-- creative: no total check, blocks still sent
do
    local f = blocks_fake({ creative = true, player = inv({}, 2), unit = inv({}, 2) })
    local b = B.new(f.io)
    local ok = b:start(with_blocks(f, { BLK }, { ITEM_Plate = 100 }), {})
    check(ok and f.sent_blocks == 1, "station blocks: creative skips the total check, blocks sent")
end

-- removal: the send gets the removes, the poll waits until the removed block is gone as well as the added one shows
do
    local f = blocks_fake({ block_delay = 1000, player = inv({}, 2), unit = inv({ S("ITEM_Plate", 10) }, 2) })
    local removed_gone_at = 3000
    local live_old = { class = "BPO_Old", gx = 9, gy = 0, h = 0, rot = 0 }
    f.io.send_blocks = function(_, blocks, ids, removes)
        f.sent_blocks = f.sent_blocks + 1
        f.sent_removes = removes
        f.blocks_out, f.shown_at = blocks, f.clock + 1000
        return true
    end
    local base_scan = f.io.scan_blocks
    f.io.scan_blocks = function()
        local out = base_scan()
        if f.clock < removed_gone_at then out[#out + 1] = { class = live_old.class, gx = 9, gy = 0, h = 0, rot = 0 } end
        return out
    end
    local b = B.new(f.io)
    local p = with_blocks(f, { BLK }, { ITEM_Plate = 2 })
    p.block_remove = { live_old }
    local ok = b:start(p, {})
    local st = run(b, f)
    check(ok and f.sent_removes and #f.sent_removes == 1 and f.sent_removes[1] == live_old, "station removes: passed to the one send")
    check(st.state == "done" and f.sent_blocks == 1 and f.calls.pl == 1 and f.clock >= removed_gone_at,
          "station removes: waits until the removed block is gone, then factory (" .. st.text .. ")")
end

-- removal never goes away: STALL after 30 s with no progress, not sent again, message as before
do
    local f = blocks_fake({ player = inv({}, 2), unit = inv({ S("ITEM_Plate", 10) }, 2) })
    f.io.send_blocks = function(_, blocks, ids, removes) f.sent_blocks = f.sent_blocks + 1; f.blocks_out, f.shown_at = blocks, f.clock; return true end
    local base_scan = f.io.scan_blocks
    f.io.scan_blocks = function() local out = base_scan(); out[#out + 1] = { class = "BPO_Old", gx = 9, gy = 0, h = 0, rot = 0 }; return out end
    local b = B.new(f.io)
    local p = with_blocks(f, { BLK }, { ITEM_Plate = 2 })
    p.block_remove = { { class = "BPO_Old", gx = 9, gy = 0, h = 0, rot = 0 } }
    b:start(p, {})
    local st = run(b, f)
    check(st.state == "error" and st.text:find("The station blocks stopped appearing: no new block for 30 s (1 still missing); nothing was resent.", 1, true)
          and f.sent_blocks == 1 and f.calls.pl == 0, "station removes: removed block never gone -> stall, no resend (" .. st.text .. ")")
end

-- MSCore without the 0.8.0 natives: refused before any send
do
    local f = blocks_fake({ capable = false, player = inv({}, 2), unit = inv({ S("ITEM_Plate", 10) }, 2) })
    local b = B.new(f.io)
    local ok, msg = b:start(with_blocks(f, { BLK }, { ITEM_Plate = 2 }), {})
    check(not ok and f.sent_blocks == 0 and msg == "error: Station Build needs MSCore 0.8.0 or newer.", "station blocks: old MSCore refused (" .. msg .. ")")
end

-- ===== redirect switch: on only while our build runs (enable(true) before the status read, enable(false) once per end) =====
local function count(t, v) local n = 0; for _, x in ipairs(t) do if x == v then n = n + 1 end end; return n end
local RON2 = "on: redirect=on probe_log=off groups=yes"
local function removed_one(id) return { { id = id, bcls = "BP_OLD", x = 100, y = 0 } } end
-- the R table of a builder: upvalue of builder:tick (test only)
local function run_of(b)
    for i = 1, 40 do
        local name, v = debug.getupvalue(b.tick, i)
        if name == nil then break end
        if name == "R" then return v end
    end
end

-- finish, redirect flow: enable(true) before the status, enable(false) exactly once at the end
do
    local f = fake({ redirect = RON2, player = inv({ S("ITEM_Plate", 5) }, 3), unit = inv({}, 3) })
    local b = B.new(f.io)
    local ok = b:start(plan_for(f, { place = { M("BP_A", 0, 0, { ITEM_Plate = 1 }) }, need = { ITEM_Plate = 1 } }), {})
    local st = run(b, f)
    check(ok and st.flow == "redirect" and f.rd_log[1] == "status" and f.rd_log[2] == "enable:true" and f.rd_log[3] == "status",
          "redirect switch: enable(true) before status, flow redirect (" .. table.concat(f.rd_log, ",") .. ")")
    check(st.state == "done" and count(f.rd_log, "enable:false") == 1 and f.rd_log[#f.rd_log] == "enable:false",
          "redirect switch: enable(false) once on finish")
end

-- finish, legacy flow (status off): still enabled first, then released once
do
    local f = fake({ redirect = "off", player = inv({ S("ITEM_Plate", 5) }, 3), unit = inv({}, 3) })
    local b = B.new(f.io)
    b:start(plan_for(f, { place = { M("BP_A", 0, 0, { ITEM_Plate = 1 }) }, need = { ITEM_Plate = 1 } }), {})
    local st = run(b, f)
    check(st.flow == "legacy" and f.rd_log[2] == "enable:true" and count(f.rd_log, "enable:false") == 1,
          "redirect switch: legacy flow enabled then released once (" .. table.concat(f.rd_log, ",") .. ")")
end

-- start_fail after the enable (legacy refund unknown): released
do
    local f = fake({ redirect = "off", player = inv({}, 3), unit = inv({}, 3) })
    local b = B.new(f.io)
    local p = plan_for(f, { removed = removed_one(1), need = {} })
    p.removed[1].refund = nil
    local ok, msg = b:start(p, {})
    check(not ok and msg:find("refund unknown", 1, true) and count(f.rd_log, "enable:true") == 1 and count(f.rd_log, "enable:false") == 1
          and f.rd_log[#f.rd_log] == "enable:false", "redirect switch: start_fail after enable released once (" .. tostring(msg) .. ")")
end

-- mid-run fail (whole-run timeout): released once
do
    local f = fake({ redirect = "off", player = inv({ S("ITEM_Plate", 1) }, 10), unit = inv({ S("ITEM_Plate", 4) }, 2), noop_moves = true })
    local b = B.new(f.io)
    b:start(plan_for(f, { place = { M("BP_A", 0, 0, { ITEM_Plate = 3 }), M("BP_B", 5, 0, { ITEM_Plate = 2 }) }, need = { ITEM_Plate = 5 } }), {})
    b:tick(1250)
    b:tick(1000 + 300001)
    check(b:status().state == "error" and count(f.rd_log, "enable:false") == 1, "redirect switch: fail mid-run releases once (" .. b:status().text .. ")")
end

-- cancel: released once, a second cancel and later ticks release nothing more
do
    local f = fake({ redirect = "off", player = inv({ S("ITEM_Plate", 1) }, 10), unit = inv({ S("ITEM_Plate", 4) }, 2), noop_moves = true })
    local b = B.new(f.io)
    b:start(plan_for(f, { place = { M("BP_A", 0, 0, { ITEM_Plate = 3 }), M("BP_B", 5, 0, { ITEM_Plate = 2 }) }, need = { ITEM_Plate = 5 } }), {})
    b:tick(1250)
    b:cancel()
    b:cancel()
    b:tick(9000)
    check(count(f.rd_log, "enable:false") == 1, "redirect switch: cancel releases once (" .. table.concat(f.rd_log, ",") .. ")")
end

-- nothing to build: enabled by the start, released before it returns
do
    local f = fake({ redirect = RON2, player = inv({}, 3), unit = inv({}, 3) })
    local b = B.new(f.io)
    local ok, msg = b:start(plan_for(f, {}), {})
    check(ok and msg == "ok nothing to build" and f.rd_log[#f.rd_log] == "enable:false" and count(f.rd_log, "enable:false") == 1,
          "redirect switch: nothing to build leaves it off (" .. table.concat(f.rd_log, ",") .. ")")
end

-- refused before anything is enabled (no plan): no enable call at all
do
    local f = fake({ redirect = RON2, player = inv({}, 3), unit = inv({}, 3) })
    local b = B.new(f.io)
    local ok, msg = b:start(nil, {})
    check(not ok and msg == "error: import first" and #f.rd_log == 0, "redirect switch: refused before enable -> no enable call")
end

-- redirect already on before the build (opt-in file, another mod): the build leaves it on, it never switches off what it did not switch on
do
    local f = fake({ redirect = RON2, rd_initial = RON2, player = inv({ S("ITEM_Plate", 5) }, 3), unit = inv({}, 3) })
    local b = B.new(f.io)
    local ok = b:start(plan_for(f, { place = { M("BP_A", 0, 0, { ITEM_Plate = 1 }) }, need = { ITEM_Plate = 1 } }), {})
    local st = run(b, f)
    check(ok and st.state == "done" and count(f.rd_log, "enable:false") == 0 and f.rd_state == RON2,
          "redirect switch: already on before the build -> never switched off (" .. table.concat(f.rd_log, ",") .. ")")
end

-- io without redirect_enable (old MSCore): treated as off, no error, flow still from the status
do
    local f = fake({ no_enable = true, redirect = RON2, player = inv({ S("ITEM_Plate", 5) }, 3), unit = inv({}, 3) })
    local b = B.new(f.io)
    local ok = b:start(plan_for(f, { place = { M("BP_A", 0, 0, { ITEM_Plate = 1 }) }, need = { ITEM_Plate = 1 } }), {})
    local st = run(b, f)
    check(ok and st.state == "done" and st.flow == "redirect" and count(f.rd_log, "enable:true") == 0 and count(f.rd_log, "enable:false") == 0,
          "redirect switch: no redirect_enable in io = off, no error, no enable calls")
end

-- enable raises: the build still runs, release never throws
do
    local f = fake({ redirect = "off", enable_error = true, player = inv({ S("ITEM_Plate", 5) }, 3), unit = inv({}, 3) })
    local b = B.new(f.io)
    local ok = b:start(plan_for(f, { place = { M("BP_A", 0, 0, { ITEM_Plate = 1 }) }, need = { ITEM_Plate = 1 } }), {})
    local okr = pcall(run, b, f)
    local st = b:status()
    check(ok and okr and st.state == "done" and count(f.rd_log, "enable:false") == 1, "redirect switch: enable raises -> build goes on, release does not throw")
end

-- safety net: the flag is still ours while no build runs -> the next tick turns it off, once
do
    local f = fake({ redirect = "off", player = inv({ S("ITEM_Plate", 5) }, 3), unit = inv({}, 3) })
    local b = B.new(f.io)
    b:start(plan_for(f, { place = { M("BP_A", 0, 0, { ITEM_Plate = 1 }) }, need = { ITEM_Plate = 1 } }), {})
    run(b, f)
    local R = run_of(b)
    check(R and R.redirect_ours == false and count(f.rd_log, "enable:false") == 1, "safety net: finished run already released")
    R.redirect_ours = true   -- as if a terminal path had missed the release
    b:tick(f.clock + 1000)
    b:tick(f.clock + 2000)
    check(R.redirect_ours == false and count(f.rd_log, "enable:false") == 2, "safety net: idle tick releases the leftover flag once")
end

-- ===== dock names: Station Build named docks are renamed after the block and its dock child show (stage 19) =====
-- spec.dock_after: the dock child shows this many ms after the station send (nil = never)
local function dock_fake(spec)
    local f = blocks_fake(spec)
    f.ren_calls, f.sent_at = {}, 0
    local send0 = f.io.send_blocks
    f.io.send_blocks = function(...) f.sent_at = f.clock; return send0(...) end
    f.io.send_renames = function(list)
        local copy = {}
        for i, rn in ipairs(list) do copy[i] = rn end
        f.ren_calls[#f.ren_calls + 1] = copy
        return spec.ren_ok or #list, spec.ren_fail or 0
    end
    f.io.dock_found = function(rn)
        if spec.dock_reason then return false, spec.dock_reason end
        if spec.dock_after ~= nil and f.clock >= f.sent_at + spec.dock_after and rn.id ~= nil then return true, nil end
        return false, "not found yet"
    end
    local base_scan = f.io.scan_blocks
    f.io.scan_blocks = function()   -- live block ids: 500 + index; child machine ids (mids): 900 + index
        local out = base_scan()
        for i, b in ipairs(out) do b.id = 500 + i; b.mids = { 900 + i } end
        return out
    end
    return f
end
local DOCK_BLK = { class = "BPO_Dock", gx = 2, gy = 0, h = 0, rot = 0, name = "Gate" }
local DOCK_RN = { bcls = "BPO_Dock", cls = "BPO_StationBlockDock", gx = 2, gy = 0, h = 0, name = "Gate" }
local function dock_plan(f)
    local p = with_blocks(f, { DOCK_BLK }, { ITEM_Plate = 2 })
    p.block_renames = { DOCK_RN }
    return p
end

-- block shows at the first poll, dock child 1 s later (2 dock polls): renamed once with the live block id
do
    local f = dock_fake({ player = inv({}, 2), unit = inv({ S("ITEM_Plate", 10) }, 2), dock_after = 1000 })
    local b = B.new(f.io)
    local ok = b:start(dock_plan(f), {})
    local st = run(b, f)
    check(ok and st.state == "done" and #f.ren_calls == 1 and #f.ren_calls[1] == 1, "dock names: one rename sent (" .. st.text .. ")")
    check(f.ren_calls[1] and f.ren_calls[1][1].id == 501 and f.ren_calls[1][1].name == "Gate" and f.ren_calls[1][1].cls == "BPO_StationBlockDock",
          "dock names: id is the fresh live block id, class is the dock child")
    check(f.ren_calls[1] and type(f.ren_calls[1][1].mids) == "table" and f.ren_calls[1][1].mids[1] == 901,
          "dock names: mids come from the fresh live block (Station Build placed block resolves via mids)")
    check(st.text:find("renamed 1 dock(s)", 1, true) ~= nil and f.sent_blocks == 1 and f.calls.pl == 1,
          "dock names: status says renamed 1 dock(s), one send, factory still runs after")
end

-- dock child never shows: 'not applied: dock not found' after 10 s, nothing sent, the run still finishes
do
    local f = dock_fake({ player = inv({}, 2), unit = inv({ S("ITEM_Plate", 10) }, 2) })
    local b = B.new(f.io)
    local ok = b:start(dock_plan(f), {})
    local t0 = f.clock
    local st = run(b, f)
    check(ok and st.state == "done" and #f.ren_calls == 0 and st.text:find("; 1 dock name(s) not applied: dock not found", 1, true) ~= nil,
          "dock names: dock never shows -> not applied, dock not found (" .. st.text .. ")")
    check(f.clock - t0 >= 10000 and f.clock - t0 < 11000 and f.calls.pl == 1, "dock names: given up after 10 s, factory still placed")
end

-- name already equal in the game: the rename reports nothing applied, so no dock text in the status
do
    local f = dock_fake({ player = inv({}, 2), unit = inv({ S("ITEM_Plate", 10) }, 2), dock_after = 0, ren_ok = 0, ren_fail = 0 })
    local b = B.new(f.io)
    b:start(dock_plan(f), {})
    local st = run(b, f)
    check(st.state == "done" and #f.ren_calls == 1 and not st.text:find("dock", 1, true),
          "dock names: name already equal -> no dock text (" .. st.text .. ")")
end

-- rename-only run (nothing else to change): start sends the renames and finishes with the rename text
do
    local f = fake({ player = inv({}, 2), unit = inv({}, 2) })
    local calls = {}
    f.io.send_renames = function(list) calls[#calls + 1] = #list; return 1, 0 end
    local b = B.new(f.io)
    local p = plan_for(f, {})
    p.renames = { { cls = "BPO_StationBlockDock", gx = 0, gy = 0, h = 0, name = "A", id = 77 } }
    local ok, msg = b:start(p, {})
    check(ok and msg == "ok dock names" and b:status().state == "done" and b:status().text == "dock names: renamed 1, 0 not applied" and #calls == 1,
          "dock names only: sent and finished with rename text (" .. b:status().text .. ")")
    local f2 = fake({ player = inv({}, 2), unit = inv({}, 2) })
    f2.io.send_renames = function() return 0, 0 end
    local b2 = B.new(f2.io)
    local p2 = plan_for(f2, {})
    p2.renames = { { cls = "BPO_StationBlockDock", gx = 0, gy = 0, h = 0, name = "A", id = 77 } }
    local ok2, msg2 = b2:start(p2, {})
    check(ok2 and msg2 == "ok dock names" and b2:status().text == "dock names already set", "dock names only: all already set -> 'dock names already set'")
    local f3 = fake({ player = inv({}, 2), unit = inv({}, 2) })
    f3.io.send_renames = function() error("must not be called") end
    local b3 = B.new(f3.io)
    local ok3, msg3 = b3:start(plan_for(f3, {}), {})
    check(ok3 and msg3 == "ok nothing to build" and b3:status().text == "nothing to build", "no renames: still 'nothing to build'")
end

-- normal path: a placement with live named docks sends the renames once, in the changes send
do
    local f = fake({ player = inv({}, 2), unit = inv({ S("ITEM_Plate", 10) }, 2) })
    local calls = {}
    f.io.send_renames = function(list) calls[#calls + 1] = #list; return 1, 0 end
    local b = B.new(f.io)
    local p = plan_for(f, { place = { M("BP_A", 0, 0, { ITEM_Plate = 1 }) }, need = { ITEM_Plate = 1 } })
    p.renames = { { cls = "BPO_StationBlockDock", gx = 0, gy = 0, h = 0, name = "A", id = 77 } }
    b:start(p, {})
    local st = run(b, f)
    check(st.state == "done" and #calls == 1 and st.text:find("renamed 1 dock(s)", 1, true) ~= nil, "dock names: normal path sends the live renames once (" .. st.text .. ")")
end

-- fractional ms clock (io.now is a float ms clock): the station-block trace used %d on now - t_blocks and raised, aborting the tick
do
    local f = dock_fake({ player = inv({}, 2), unit = inv({ S("ITEM_Plate", 10) }, 2), dock_after = 1000, block_delay = 1000 })
    f.clock = 678.123
    local b = B.new(f.io)
    local ok = b:start(dock_plan(f), {})
    local err
    for _ = 1, 80 do
        f.clock = f.clock + 333.3
        local okt, e = pcall(b.tick, b, f.clock)
        if not okt then err = e break end
        if b:status().state ~= "working" then break end
    end
    local st = b:status()
    check(ok and not err and st.state == "done" and #f.ren_calls == 1 and f.calls.pl == 1,
          "fractional ms: no error in the station block stage, dock rename sent (" .. tostring(err or st.text) .. ")")
end

-- permanent reason (io.dock_found): the dock fails at the first check, no polling, reason in the status, factory still runs
do
    local f = dock_fake({ player = inv({}, 2), unit = inv({ S("ITEM_Plate", 10) }, 2), dock_reason = "dock names need MSCore >= 0.8.3" })
    local seen = {}
    f.io.dock_found = function() seen[#seen + 1] = f.clock; return false, "dock names need MSCore >= 0.8.3" end
    local b = B.new(f.io)
    local ok = b:start(dock_plan(f), {})
    local st = run(b, f)
    check(ok and st.state == "done" and #f.ren_calls == 0 and st.text:find("; 1 dock name(s) not applied: dock names need MSCore >= 0.8.3", 1, true) ~= nil,
          "dock names: permanent reason -> not applied with that reason (" .. st.text .. ")")
    check(#seen == 1 and f.calls.pl == 1, "dock names: permanent reason checked once, no 10 s wait, factory still placed")
end

-- the block shows at once, its dock child machine ids come in later: every poll re-reads them, the dock is found then
do
    local f = dock_fake({ player = inv({}, 2), unit = inv({ S("ITEM_Plate", 10) }, 2) })
    local base = f.io.scan_blocks
    f.io.scan_blocks = function()
        local out = base()
        for _, b2 in ipairs(out) do b2.mids = (f.clock >= f.sent_at + 1500) and { 999 } or {} end
        return out
    end
    f.io.dock_found = function(rn)
        if rn.mids and rn.mids[1] == 999 then return true, nil end
        return false, "not found yet"
    end
    local b = B.new(f.io)
    local ok = b:start(dock_plan(f), {})
    local st = run(b, f)
    check(ok and st.state == "done" and #f.ren_calls == 1 and f.ren_calls[1][1].mids[1] == 999 and st.text:find("renamed 1 dock(s)", 1, true) ~= nil,
          "dock names: mids re-read each poll, late dock child found (" .. st.text .. ")")
end

-- two named docks fail with different permanent reasons: the status names the first one, both counted
do
    local f = dock_fake({ player = inv({}, 2), unit = inv({ S("ITEM_Plate", 10) }, 2) })
    local BLK2 = { class = "BPO_Dock", gx = 4, gy = 0, h = 0, rot = 0, name = "Two" }
    local RN2 = { bcls = "BPO_Dock", cls = "BPO_StationBlockDock", gx = 4, gy = 0, h = 0, name = "Two" }
    local p = with_blocks(f, { DOCK_BLK, BLK2 }, { ITEM_Plate = 2 })
    p.block_renames = { DOCK_RN, RN2 }
    f.io.dock_found = function(rn) if rn.gx == 2 then return false, "first reason" end; return false, "second reason" end
    local b = B.new(f.io)
    b:start(p, {})
    local st = run(b, f)
    check(st.state == "done" and st.text:find("; 2 dock name(s) not applied: first reason", 1, true) ~= nil, "dock names: two failures -> first reason in status (" .. st.text .. ")")
end

-- placed block, mids not registered on polls 1-2 (no child machine ids yet), filled on poll 3: polled, renamed once
do
    local f = dock_fake({ player = inv({}, 2), unit = inv({ S("ITEM_Plate", 10) }, 2) })
    local base = f.io.scan_blocks
    f.io.scan_blocks = function()
        local out = base()
        for _, b2 in ipairs(out) do b2.mids = (f.dock_polls or 0) >= 2 and { 901 } or {} end
        return out
    end
    f.dock_polls = 0
    f.io.dock_found = function(rn)
        f.dock_polls = f.dock_polls + 1
        if rn.mids and #rn.mids > 0 then return true, nil end
        return false, "block has no child machine ids (needs MSCore 0.8.3 build with mids)"
    end
    local b = B.new(f.io)
    b:start(dock_plan(f), {})
    local st = run(b, f)
    check(st.state == "done" and f.dock_polls == 3 and #f.ren_calls == 1 and f.ren_calls[1][1].mids[1] == 901,
          "dock names: mids empty on polls 1-2, filled on 3 -> polled, renamed once (" .. st.text .. ")")
    check(st.text:find("renamed 1 dock(s)", 1, true) ~= nil and f.calls.pl == 1, "dock names: mids late -> status renamed 1, factory placed")
end

-- placed block, mids never registered: polled until 10 s, then 'dock not found (block has no child machine ids)', nothing sent
do
    local f = dock_fake({ player = inv({}, 2), unit = inv({ S("ITEM_Plate", 10) }, 2) })
    local base = f.io.scan_blocks
    f.io.scan_blocks = function()
        local out = base()
        for _, b2 in ipairs(out) do b2.mids = {} end
        return out
    end
    local seen = 0
    f.io.dock_found = function() seen = seen + 1; return false, "block has no child machine ids (needs MSCore 0.8.3 build with mids)" end
    local b = B.new(f.io)
    b:start(dock_plan(f), {})
    local t0 = f.clock
    local st = run(b, f)
    check(st.state == "done" and #f.ren_calls == 0 and seen > 1 and st.text:find("; 1 dock name(s) not applied: dock not found (block has no child machine ids)", 1, true) ~= nil,
          "dock names: mids never filled -> dock not found after polling (" .. st.text .. ")")
    check(f.clock - t0 >= 10000 and f.clock - t0 < 11000 and f.calls.pl == 1, "dock names: mids never filled -> given up after 10 s, factory still placed")
end

-- permanent reasons fail on the first check (no polling): MSCore without rename/read, two docks for one block
for _, why in ipairs({ "dock names need MSCore >= 0.8.3", "2 dock matches for block" }) do
    local f = dock_fake({ player = inv({}, 2), unit = inv({ S("ITEM_Plate", 10) }, 2) })
    local seen = 0
    f.io.dock_found = function() seen = seen + 1; return false, why end
    local b = B.new(f.io)
    b:start(dock_plan(f), {})
    local st = run(b, f)
    check(st.state == "done" and seen == 1 and #f.ren_calls == 0 and st.text:find("; 1 dock name(s) not applied: " .. why, 1, true) ~= nil,
          "dock names: '" .. why .. "' -> immediate, not applied (" .. st.text .. ")")
end

-- send_renames counts that are nil: no throw in the tick, nothing counted
do
    local f = dock_fake({ player = inv({}, 2), unit = inv({ S("ITEM_Plate", 10) }, 2), dock_after = 0 })
    f.io.send_renames = function() return nil, nil end
    local b = B.new(f.io)
    b:start(dock_plan(f), {})
    local st = run(b, f)
    check(st.state == "done" and not st.text:find("dock", 1, true), "dock names: nil counts in dock wait -> no throw, no dock text (" .. st.text .. ")")
    local f2 = fake({ player = inv({}, 2), unit = inv({ S("ITEM_Plate", 10) }, 2) })
    f2.io.send_renames = function() return nil end
    local b2 = B.new(f2.io)
    local p2 = plan_for(f2, { place = { M("BP_A", 0, 0, { ITEM_Plate = 1 }) }, need = { ITEM_Plate = 1 } })
    p2.renames = { { cls = "BPO_StationBlockDock", gx = 0, gy = 0, h = 0, name = "A", id = 77 } }
    b2:start(p2, {})
    local st2 = run(b2, f2)
    check(st2.state == "done" and not st2.text:find("dock", 1, true), "dock names: nil counts in the changes send -> no throw (" .. st2.text .. ")")
end

-- reasons in the rename-only and normal-path status texts
do
    local f = fake({ player = inv({}, 2), unit = inv({}, 2) })
    f.io.send_renames = function() return 0, 1, "dock not found" end
    local b = B.new(f.io)
    local p = plan_for(f, {})
    p.renames = { { cls = "BPO_StationBlockDock", gx = 0, gy = 0, h = 0, name = "A", id = 77 } }
    b:start(p, {})
    check(b:status().text == "dock names: renamed 0, 1 not applied: dock not found", "dock names only: reason in text (" .. b:status().text .. ")")
    local f2 = fake({ player = inv({}, 2), unit = inv({}, 2) })
    f2.io.send_renames = function() return nil, nil end
    local b2 = B.new(f2.io)
    local p2 = plan_for(f2, {})
    p2.renames = { { cls = "BPO_StationBlockDock", gx = 0, gy = 0, h = 0, name = "A", id = 77 } }
    b2:start(p2, {})
    check(b2:status().text == "dock names already set", "dock names only: nil counts -> already set (" .. b2:status().text .. ")")
    local f3 = fake({ player = inv({ S("ITEM_Plate", 5) }, 2), unit = inv({ S("ITEM_Plate", 10) }, 2) })
    f3.io.send_renames = function() return 1, 1, "dock not found" end
    local b3 = B.new(f3.io)
    local p3 = plan_for(f3, { place = { M("BP_A", 0, 0, { ITEM_Plate = 1 }) }, need = { ITEM_Plate = 1 } })
    p3.renames = { { cls = "BPO_StationBlockDock", gx = 0, gy = 0, h = 0, name = "A", id = 77 } }
    b3:start(p3, {})
    local st3 = run(b3, f3)
    check(st3.text:find("renamed 1 dock(s); 1 dock name(s) not applied: dock not found", 1, true) ~= nil, "dock names: normal path reason in text (" .. st3.text .. ")")
end

-- kept container top-up (no placement): restore job runs on the kept container id (303), unit shortage gives a note
local function kept_topup(f, restore)
    local b = B.new(f.io)
    local p = plan_for(f, { need = {}, refund = {} })
    p.kept = { { bcls = "BP_ContainerObject_2", x = 5, y = 0, id = 303, restore = restore } }
    return b, b:start(p, {})
end
do
    local f = whole_fake({ containers = { [303] = { slots = inv({}, 4) } } })
    local traces = tracer(f)
    local b, ok = kept_topup(f, { { name = "ITEM_Plate", count = 120 } })
    local st = run(b, f, 400)
    check(ok and st.state == "done" and cont_plate(f, 303) == 120 and tot(f.inv.unit.slots, "ITEM_Plate") == 0 and #f.violations == 0
          and #f.cmd_log == 3 and f.cmd_log[1][2] == 303 + 5000,
          "topup kept: 120 Plate into kept container 303 (job id = kept id), 3 TRANSFERs (" .. st.text .. ")")
    check(starts(traces, "restore plan: container id=303 item=ITEM_Plate count=120"), "topup kept: restore plan trace names id 303")
end
do
    local f = whole_fake({ unit = inv({ S("ITEM_Plate", 50), S("ITEM_Plate", 50) }, 3), containers = { [303] = { slots = inv({}, 4) } } })
    local b, ok = kept_topup(f, { { name = "ITEM_Plate", count = 120 } })
    local st = run(b, f, 400)
    check(ok and st.state == "done" and cont_plate(f, 303) == 0 and #f.cmd_log == 0 and st.text:find("; restore: restored 0 of 120 items into 0 of 1 container(s); Plate x120 not restored (unit has 100)", 1, true) ~= nil,
          "topup kept: unit shortage -> nothing sent, note (" .. st.text .. ")")
end
-- legacy flow (redirect off), top-up only, no placements/removals: must still run the restore for the kept container
do
    local f = whole_fake({ redirect = "off", containers = { [303] = { slots = inv({}, 4) } } })
    local b, ok = kept_topup(f, { { name = "ITEM_Plate", count = 120 } })
    local st = run(b, f, 400)
    check(ok and st.state == "done" and cont_plate(f, 303) == 120, "topup kept, legacy flow: 120 Plate into kept container 303 (" .. st.text .. ")")
end
-- start gate: a kept NON-container with a restore list does not count as a top-up (nothing to build, nothing sent)
do
    local f = whole_fake({ containers = { [303] = { slots = inv({}, 4) } } })
    local b = B.new(f.io)
    local p = plan_for(f, { need = {}, refund = {} })
    p.kept = { { bcls = "BP_Smelter_1", x = 5, y = 0, id = 303, restore = { { name = "ITEM_Plate", count = 120 } } } }
    local ok, msg = b:start(p, {})
    local st = run(b, f, 400)
    check(ok and msg == "ok nothing to build" and st.state == "done" and #f.cmd_log == 0, "topup gate: non-container kept restore ignored (" .. tostring(msg) .. ")")
end
-- expected vs filled: 3 kept containers want 50 Plate each, unit holds 50 -> only the first gets items
do
    local f = whole_fake({ unit = inv({ S("ITEM_Plate", 50) }, 3),
                           containers = { [303] = { slots = inv({}, 4) }, [304] = { slots = inv({}, 4) }, [305] = { slots = inv({}, 4) } } })
    local b = B.new(f.io)
    local p = plan_for(f, { need = {}, refund = {} })
    p.kept = {
        { bcls = "BP_ContainerObject_2", x = 5, y = 0, id = 303, restore = { { name = "ITEM_Plate", count = 50 } } },
        { bcls = "BP_ContainerObject_2", x = 6, y = 0, id = 304, restore = { { name = "ITEM_Plate", count = 50 } } },
        { bcls = "BP_ContainerObject_2", x = 7, y = 0, id = 305, restore = { { name = "ITEM_Plate", count = 50 } } },
    }
    local tr = tracer(f)
    b:start(p, {})
    local st = run(b, f, 400)
    check(st.state == "done" and cont_plate(f, 303) == 50 and cont_plate(f, 304) == 0 and cont_plate(f, 305) == 0
          and st.text:find("into 1 of 3 container(s)", 1, true) ~= nil, "restore summary: 3 containers expected, 1 filled (" .. st.text .. ")")
    check(starts(tr, "restore summary: expected 150 items in 3 containers, delivered 50 items into 1 containers, short "),
          "restore summary: trace counts (" .. st.text .. ")")
end

print(("RESULT %d passed, %d failed"):format(pass, failn))
os.exit(failn == 0 and 0 or 1)
