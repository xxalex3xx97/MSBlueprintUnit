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
        station = spec.station or {}, next_id = 100, creative = spec.creative or false,
        max = spec.max or {}, refund_of = spec.refund_of or {}, max_per_move = spec.max_per_move,
        noop_moves = spec.noop_moves,
        inv = { player = { id = 101, slots = spec.player }, unit = { id = 202, slots = spec.unit } },
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
        return { slots = slots, id = v.id, ok = true }
    end
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
    function io.send_move(prim, sec, slot, action)
        f.calls.mv = f.calls.mv + 1
        f.moves[#f.moves + 1] = { prim, sec, slot, action }
        if action ~= 2 then return false end
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
            for item, n in pairs(cost) do take(f.inv.player.slots, item, n) end
        end
        f.next_id = f.next_id + 1
        f.station[#f.station + 1] = { id = f.next_id, bcls = m.bcls, x = m.x, y = m.y, h = 0, rot = 0 }
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

    local pl = { E(), S("ITEM_HullPlate", 3), S("ITEM_Other", 2) }
    check(same(P.moveout_slots(pl, { ITEM_HullPlate = true }), { 2 }), "moveout: only slots with the set items")
    check(same(P.moveset({ ITEM_A = 2, ITEM_B = 3 }, { ITEM_B = 2 }), { ITEM_A = true }), "moveset: refund not needed moves, needed item stays")

    local maxA = { ITEM_A = 100 }
    check(P.chunk_len({ { ITEM_A = 150 } }, 1, { E() }, maxA) == 0, "chunk: 1 free slot, A 150 max 100 -> 0")
    local c60 = { { ITEM_A = 60 }, { ITEM_A = 60 } }
    check(P.chunk_len(c60, 1, { E(), E() }, { ITEM_A = 50 }) == 1, "chunk: 2 free slots, A 60 max 50 -> 1 per chunk")
    check(P.chunk_len(c60, 1, { S("ITEM_A", 50), S("ITEM_A", 50), S("ITEM_A", 20) }, { ITEM_A = 50 }) == 2, "chunk: 120 A already held -> 2")
    local c100 = { { ITEM_A = 100 }, { ITEM_A = 100 }, { ITEM_A = 100 }, { ITEM_A = 100 } }
    check(P.chunk_len(c100, 1, { S("ITEM_A", 100, 100), S("ITEM_A", 100, 100), S("ITEM_A", 100, 100), S("ITEM_A", 100, 100) }, maxA) == 4, "chunk: player holds all -> full length")
    local c5 = { { ITEM_A = 5 }, { ITEM_A = 5 }, { ITEM_A = 5 } }
    check(P.chunk_len(c5, 1, inv({}, 10), { ITEM_A = 50 }) == 3, "chunk: ample slots -> all")

    local w1 = { bcls = "BP_A", x = 1, y = 1 }
    local w2 = { bcls = "BP_A", x = 3, y = 1 }
    local w3 = { bcls = "BP_B", x = 5, y = 5 }
    local pres, miss = P.present({ w1, w2, w3 }, { w1, w2 })
    check(pres == 2 and miss == "BP_B@(5,5)", "present: 2 of 3, missing BP_B@(5,5)")
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
    check(st.state == "done" and st.placed == 2 and st.moved_in == 1 and st.chunk == "1/1" and st.verify == "2/2", "plain: staged from unit, placed 2, verify 2/2")
    check(f.calls.rm == 0 and f.calls.pl == 2 and same(f.moves[1], { 202, 101, 0, 2 }), "plain: no removals, unit->player quick move slot 0 action 2")
end

-- removal with refund moved out to the unit
do
    local f = fake({ player = inv({ S("ITEM_Plate", 1) }, 3), unit = inv({}, 3),
                     station = { { id = 7, bcls = "BP_OLD", x = 0, y = 0 } }, refund_of = { [7] = { ITEM_Gear = 2 } } })
    local b = B.new(f.io)
    local plan = plan_for(f, { place = { M("BP_NEW", 0, 0, { ITEM_Plate = 1 }) }, need = { ITEM_Plate = 1 },
                               refund = { ITEM_Gear = 2 }, removed = { { id = 7, bcls = "BP_OLD" } } })
    b:start(plan, {})
    local st = run(b, f)
    check(st.state == "done" and st.removed == 1 and st.moved_out == 1 and st.placed == 1 and st.verify == "1/1", "removal: refund moved out, machine replaced, verify 1/1")
end

-- refund does not fit at start -> move out, stage 1 re-check, removal, move out again
do
    local f = fake({ player = inv({ S("ITEM_Gear", 50, 50), S("ITEM_Junk", 50, 50) }, 2),
                     unit = inv({ E(), S("ITEM_Plate", 1), E() }, 3),
                     station = { { id = 7, bcls = "BP_OLD", x = 0, y = 0 } }, refund_of = { [7] = { ITEM_Gear = 2 } } })
    local b = B.new(f.io)
    local plan = plan_for(f, { place = { M("BP_NEW", 0, 0, { ITEM_Plate = 1 }) }, need = { ITEM_Plate = 1 },
                               refund = { ITEM_Gear = 2 }, removed = { { id = 7, bcls = "BP_OLD" } } })
    b:start(plan, {})
    local st = run(b, f)
    check(st.state == "done" and st.moved_out == 2 and st.removed == 1 and st.moved_in == 1 and st.placed == 1, "refund room: stage 1 path, moved_out 2, placed 1")
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
    check(st.state == "done" and st.chunk == "2/2" and st.placed == 2 and st.moved_in == 2 and st.verify == "2/2", "chunking: 2 chunks of 1, placed 2, verify 2/2")
end

-- missing items -> refused before any change
do
    local f = fake({ player = inv({}, 1), unit = inv({ S("ITEM_Plate", 3) }, 1) })
    local b = B.new(f.io)
    local ok, msg = b:start(plan_for(f, { place = { M("BP_A", 0, 0, { ITEM_Plate = 10 }) }, need = { ITEM_Plate = 10 } }), {})
    local st = b:status()
    check(not ok and msg == "error: not enough items: Plate x7" and st.state == "error" and
          st.text == "not enough items: Plate x7 (placed 0, removed 0, moved_out 0, moved_in 0)", "missing: refused with 'not enough items: Plate x7'")
    check(f.calls.rm == 0 and f.calls.mv == 0 and f.calls.pl == 0 and f.calls.ch == 0, "missing: no removal, move or place call")
end

-- station changed since import -> refused before any change
do
    local f = fake({ player = inv({}, 2), unit = inv({ S("ITEM_Plate", 5) }, 1), station = { { id = 3, bcls = "BP_X", x = 0, y = 0 } } })
    local b = B.new(f.io)
    local plan = plan_for(f, { place = { M("BP_A", 0, 0, { ITEM_Plate = 1 }) }, need = { ITEM_Plate = 1 } })
    table.insert(f.station, { id = 4, bcls = "BP_Y", x = 2, y = 0 })
    local ok = b:start(plan, {})
    check(not ok and b:status().text == "station changed since import, import again (placed 0, removed 0, moved_out 0, moved_in 0)", "station changed: refused")
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
    check(ok and st.state == "done" and st.placed == 2 and st.moved_in == 0 and f.calls.mv == 0 and st.verify == "2/2", "creative: placed without moves or cost check")
end

-- cancel and busy
do
    local f = fake({ player = inv({ S("ITEM_Plate", 1) }, 10), unit = inv({ S("ITEM_Plate", 4) }, 2) })
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
    local f = fake({ player = inv({ S("ITEM_Plate", 1) }, 10), unit = inv({ S("ITEM_Plate", 4) }, 2) })
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
    check(st.state == "done" and st.moved_in == 2 and st.placed == 1 and st.verify == "1/1" and f.inv.unit.slots[1].amount == 10,
          "partial moves: 2 rounds of 20, unit keeps 10, placed 1")
end

-- room_wait path: refund does not fit at start, removal goes out on the tick that finds room (now is the tick's time)
do
    local f = fake({ player = inv({ S("ITEM_Gear", 50, 50), S("ITEM_Junk", 50, 50) }, 2),
                     unit = inv({ E(), S("ITEM_Plate", 1), E() }, 3),
                     station = { { id = 7, bcls = "BP_OLD", x = 0, y = 0 } }, refund_of = { [7] = { ITEM_Gear = 2 } } })
    local b = B.new(f.io)
    b:start(plan_for(f, { place = { M("BP_NEW", 0, 0, { ITEM_Plate = 1 }) }, need = { ITEM_Plate = 1 },
                          refund = { ITEM_Gear = 2 }, removed = { { id = 7, bcls = "BP_OLD" } } }), {})
    local rm_at
    for t = 1250, 30000, 250 do
        b:tick(t)
        if rm_at == nil and f.calls.rm == 1 then rm_at = t end
    end
    local st = b:status()
    check(rm_at ~= nil and rm_at >= 1500 and f.calls.rm == 1 and st.state == "done" and st.removed == 1,
          "room_wait: removal sent once on a tick at or after 1500 (now passed in), done")
end

print(("RESULT %d passed, %d failed"):format(pass, failn))
os.exit(failn == 0 and 0 or 1)
