-- test_build: plain asserts for Scripts/bpu_build.lua (pure helpers + build flows on a fake io).
-- Run: lua test_build.lua   (exit 0 = all pass, 1 = failures)
local dir = (arg and arg[0] or ""):match("^(.*)[/\\]") or "."
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
        mult = spec.mult or {},   -- StackMultiplier / 2 per inventory ("player" / "unit")
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

    local io = {}
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
    function io.fingerprint(ex)
        local parts = {}
        for _, m in ipairs(ex) do parts[#parts + 1] = table.concat({ m.id, m.bcls, m.x, m.y }, ":") end
        return table.concat(parts, "|")
    end
    function io.read_inv(which)
        local v = f.inv[which]
        local slots = {}
        for i, s in ipairs(v.slots) do slots[i] = { item = s.item, amount = s.amount, max = s.max } end
        return { slots = slots, id = v.id, ok = true, mult = f.mult[which] }
    end
    if spec.raw then io.item_max = function(k) return spec.raw[k] or 1 end end   -- raw MaxStackSize (live: Item UObject)
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
                for item, n in pairs(f.refund_of[id] or {}) do put(f.inv.player.slots, item, n, mx(item)) end
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
        if not f.creative then
            for item, n in pairs(cost) do if have(f.inv.player.slots, item) < n then return false end end
            if not f.no_charge then for item, n in pairs(cost) do take(f.inv.player.slots, item, n) end end
        end
        if f.drop_place then return true end   -- accepted, never shows up on the station
        f.next_id = f.next_id + 1
        f.placed_at = f.placed_at or f.clock
        local bcls = f.live_bcls or m.bcls
        f.station[#f.station + 1] = { id = f.next_id, bcls = bcls, x = m.x + f.shift_x, y = m.y, h = 0, rot = 0 }
        return true
    end
    function io.send_changes(chg)
        f.calls.ch = f.calls.ch + 1
        return true
    end
    f.io = io
    return f
end

local function plan_for(f, o)
    return {
        valid = true, station = 1, fp = f.io.fingerprint(f.station), name = "T",
        place = o.place or {}, kept = {}, chg = {}, removed = o.removed or {},
        need = o.need or {}, refund = o.refund or {}, recChanged = 0,
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
    check(not ok and st.state == "error" and starts_with(st.text, "not enough inventory space for refunds")
          and f.calls.rm == 0 and f.calls.mv == 0 and f.calls.pl == 0, "refund room: does not fit -> refused at start, nothing sent (" .. msg .. ")")
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
    b:tick(1000 + 300001)
    check(b:status().state == "error" and starts_with(b:status().text, "timeout after 300 s"), "timeout: 300 s cap")
end

-- staging never moves anything -> stalled after 10 s
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
          and f.clock - t0 <= 6000, "chunk 1 not charged: error 'items were not charged' within 5 s (" .. st.text .. " at " .. (f.clock - t0) .. ")")
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
    check(st2.state == "done" and gap2 == 1500 and st2.text == "sent: placed 1, removed 1 (the game updates its blueprint view in about 30 s)",
          "removal: refund not seen, placing at the 1.5 s cap, no move (" .. tostring(gap2) .. " ms)")
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

    local f2 = fake({ station = { { id = 7, bcls = "BP_OLD", x = 0, y = 0 } }, player = inv({ S("ITEM_Plate", 1) }, 3), unit = inv({}, 3) })
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

-- ===== effective stack size: native max 1 is wrong, raw MaxStackSize 200 * StackMultiplier 8 / 2 = 800 per slot =====
local EFF = { raw = { ITEM_Frame = 200, ITEM_Coil = 10 }, max = { ITEM_Frame = 800, ITEM_Coil = 40 }, mult = { player = 4, unit = 101 } }
-- refund 2 frames (merge room in the 190 stack) + 2 coils (1 new slot): fits with 1 free slot. Old max 1 -> refused.
do
    local f = fake(setmetatable({ player = { E(), S("ITEM_Frame", 190, 1) }, unit = inv({}, 3),
                     station = { { id = 7, bcls = "BP_OLD", x = 0, y = 0 } }, refund_of = { [7] = { ITEM_Frame = 2, ITEM_Coil = 2 } } }, { __index = EFF }))
    local b = B.new(f.io)
    b:start(plan_for(f, { removed = { { id = 7, bcls = "BP_OLD" } }, refund = { ITEM_Frame = 2, ITEM_Coil = 2 } }), {})
    local st = run(b, f)
    check(st.state == "done" and st.removed == 1 and not starts_with(st.text, "not enough"),
          "refund eff max: 2 frames (merge) + 2 coils (1 slot) with 1 free slot -> done (" .. st.text .. ")")
end

-- refund does not fit, unit has room: still refused at start (no player->unit moves any more)
do
    local f = fake(setmetatable({ player = { S("ITEM_Junk", 50, 50), S("ITEM_Other", 50, 50) }, unit = inv({}, 6),
                     station = { { id = 7, bcls = "BP_OLD", x = 0, y = 0 } }, refund_of = { [7] = { ITEM_Frame = 5, ITEM_Coil = 10 } } }, { __index = EFF }))
    local b = B.new(f.io)
    b:start(plan_for(f, { removed = { { id = 7, bcls = "BP_OLD" } }, refund = { ITEM_Frame = 5, ITEM_Coil = 10 } }), {})
    local st = run(b, f)
    check(st.state == "error" and starts_with(st.text, "not enough inventory space for refunds") and f.calls.rm == 0 and f.calls.mv == 0,
          "refund room: unit has room, player full -> refused, no moves, nothing removed (" .. st.text .. ")")
end

-- refund does not fit at all: refused at start, nothing removed
do
    local f = fake(setmetatable({ player = { S("ITEM_Junk", 50, 50), S("ITEM_Other", 50, 50) }, unit = inv({ S("ITEM_Plate", 50, 50) }, 1),
                     station = { { id = 7, bcls = "BP_OLD", x = 0, y = 0 } }, refund_of = { [7] = { ITEM_Frame = 5, ITEM_Coil = 10 } } }, { __index = EFF }))
    local b = B.new(f.io)
    b:start(plan_for(f, { removed = { { id = 7, bcls = "BP_OLD" } }, refund = { ITEM_Frame = 5, ITEM_Coil = 10 } }), {})
    local st = run(b, f)
    check(st.state == "error" and starts_with(st.text, "not enough inventory space for refunds") and f.calls.rm == 0,
          "refund room: unit full -> error, nothing removed (" .. st.text .. ")")
end

-- overlap + refund never shows up in the view: the wait is the cap (1.5 s), then the placement is sent; no moveout
do
    local f = fake({ player = inv({ S("ITEM_Plate", 1) }, 3), unit = inv({}, 3),
                     station = { { id = 7, bcls = "BP_OLD", x = 0, y = 0 } } })   -- no refund_of: the refund never shows
    local b = B.new(f.io)
    local t0 = f.clock
    b:start(plan_for(f, { place = { M("BP_NEW", 0, 0, { ITEM_Plate = 1 }) }, need = { ITEM_Plate = 1 },
                          refund = { ITEM_Gear = 2 }, removed = { { id = 7, bcls = "BP_OLD", x = 0, y = 0 } } }), {})
    local st = run(b, f)
    check(st.state == "done" and st.removed == 1 and st.placed == 1 and f.calls.mv == 0 and f.clock - t0 == 1500
          and st.text == "sent: placed 1, removed 1 (the game updates its blueprint view in about 30 s)", "refund never shown: capped at 1.5 s, done, no moveout (" .. st.text .. ")")
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

print(("RESULT %d passed, %d failed"):format(pass, failn))
os.exit(failn == 0 and 0 or 1)
