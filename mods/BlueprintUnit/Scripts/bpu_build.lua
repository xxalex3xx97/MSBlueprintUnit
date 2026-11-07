-- bpu_build: pure Lua port of the bp_build flow (mb_bpprobe.hpp: bb_* helpers, bp_build_cmd, bp_build_tick).
-- No game globals. Every game call goes through the injected `io` table (see B.new).
-- Lua side: slots and machines are 1-based. io.send_move gets the 0-based game slot index.
-- Items are matched by item name (ITEM_HullPlate), same keys as plan.need / plan.refund.

local B = {}

local TOTAL_MS = 300000   -- whole run
local STAGE_MS = 10000    -- staging round, moveout
local CHARGE_MS = 5000    -- chunk charge (player+unit items drop by the cost) must show within this
local REMOVE_MS = 3000    -- fixed settle after DisassembleInput (refund may show earlier)
local POLL_MS = 500

local function get(m, k) return m[k] or 0 end

local function sorted_keys(m)
    local ks = {}
    for k in pairs(m) do ks[#ks + 1] = k end
    table.sort(ks)
    return ks
end

-- slot = { item = "ITEM_X" | "", amount = n, max = stack size }. Empty slot: item "".
local function totals(slots)
    local t = {}
    for _, s in ipairs(slots) do
        if s.item ~= "" and s.amount > 0 then t[s.item] = get(t, s.item) + s.amount end
    end
    return t
end

-- Largest MaxStackSize per item over both inventories (1 when unknown).
local function maxes(a, b)
    local m = {}
    for _, slots in ipairs({ a, b }) do
        for _, s in ipairs(slots) do
            if s.item ~= "" and s.max > get(m, s.item) then m[s.item] = s.max end
        end
    end
    return m
end

-- Effective MaxStackSize per item in one inventory (inv = normalized slots): io.item_max (raw) * StackMultiplier/2.
-- Without io.item_max (plain fakes): the largest slot max over both inventories.
local function capmap(io, inv, other)
    if io.item_max then
        return setmetatable({}, { __index = function(_, k)
            return math.floor(math.max(io.item_max(k) or 1, 1) * (inv.mult or 1))
        end })
    end
    return maxes(inv, other)
end

-- Player slots to quick-move out (slot order) when the refund needs room: n stacks, items the build does not need first.
local function stage_out(slots, need, n)
    local out = {}
    for pass = 1, 2 do
        for i, s in ipairs(slots) do
            if #out >= n then return out end
            if s.item ~= "" and s.amount > 0 and ((get(need, s.item) <= 0) == (pass == 1)) then out[#out + 1] = i end
        end
    end
    return out
end

-- "Name xN, ..." (ITEM_ stripped), positive entries only, item order.
local function list(m)
    local parts = {}
    for _, k in ipairs(sorted_keys(m)) do
        if m[k] > 0 then parts[#parts + 1] = (k:gsub("^ITEM_", "")) .. (" x%d"):format(m[k]) end
    end
    return table.concat(parts, ", ")
end

-- need minus what is held, positive part only.
local function shortfall(need, have)
    local out = {}
    for k, v in pairs(need) do
        if v - get(have, k) > 0 then out[k] = v - get(have, k) end
    end
    return out
end

-- "" when player + unit + refund cover every need item; else "not enough items: Name xN, ...".
local function total_check(need, refund, player, unit)
    local short = {}
    for k, v in pairs(need) do short[k] = v - get(player, k) - get(unit, k) - get(refund, k) end
    local s = list(short)
    if s == "" then return "" end
    return "not enough items: " .. s
end

-- Unit slots to quick-move in (slot order) until each item's shortfall is covered. Empty slots skipped. At most max_moves.
local function stage_moves(unit, sf, max_moves)
    local left, out = {}, {}
    for k, v in pairs(sf) do left[k] = v end
    for i, s in ipairs(unit) do
        if #out >= (max_moves or 40) then break end
        if s.item ~= "" and s.amount > 0 and get(left, s.item) > 0 then
            out[#out + 1] = i
            left[s.item] = left[s.item] - s.amount
        end
    end
    return out
end

-- Slots (slot order) holding one of the items in set (set[item] = true).
local function moveout_slots(slots, set)
    local out = {}
    for i, s in ipairs(slots) do
        if s.item ~= "" and s.amount > 0 and set[s.item] then out[#out + 1] = i end
    end
    return out
end

-- Refund items the build does not need (need 0 or absent): these may leave the player (free room).
local function moveset(refund, need)
    local set = {}
    for k, v in pairs(refund) do
        if v > 0 and get(need, k) <= 0 then set[k] = true end
    end
    return set
end

-- needs = list of { item, amount, max }. Partial stacks of the same item fill first, the rest needs empty slots.
-- missing = slots needed beyond the empty ones (0 = fits). max = MaxStackSize only (conservative).
local function refund_fit(slots, needs)
    local f = { need = 0, empty = 0, room = 0, missing = 0 }
    for _, s in ipairs(slots) do if s.amount <= 0 then f.empty = f.empty + 1 end end
    for _, n in ipairs(needs) do
        if n.amount > 0 then
            local mx = math.max(n.max or 1, 1)
            local room = 0
            for _, s in ipairs(slots) do
                if s.item == n.item and s.amount > 0 and s.amount < mx then room = room + (mx - s.amount) end
            end
            local rest = math.max(n.amount - room, 0)
            f.room = f.room + math.min(room, n.amount)
            f.need = f.need + math.floor((rest + mx - 1) / mx)
        end
    end
    f.missing = math.max(f.need - f.empty, 0)
    return f
end

-- Refund list (item, amount, max) from plan.refund, item order.
local function build_rneed(refund, maxOf)
    local out = {}
    for _, k in ipairs(sorted_keys(refund)) do
        if refund[k] > 0 then out[#out + 1] = { item = k, amount = refund[k], max = maxOf[k] or 1 } end
    end
    return out
end

-- "" when the refund fits the player inventory; else the refusal text.
local function refund_check(rneed, slots)
    if #rneed == 0 then return "" end
    local f = refund_fit(slots, rneed)
    if f.missing == 0 then return "" end
    local parts = {}
    for _, n in ipairs(rneed) do parts[#parts + 1] = (n.item .. " x%d"):format(n.amount) end
    return ("not enough inventory space for refunds: need %d more slots (items: %s)"):format(math.max(f.missing, 1), table.concat(parts, ", "))
end

-- Longest run of machines from index `from` whose cumulative cost fits the player's free space.
-- costs = list of cost maps (1-based), maxOf = MaxStackSize per item (1 when absent). 0 = the first machine does not fit.
local function chunk_len(costs, from, player, maxOf)
    local have, cum, n = totals(player), {}, 0
    for k = from, #costs do
        for item, v in pairs(costs[k]) do cum[item] = get(cum, item) + v end
        local needs = {}
        for _, item in ipairs(sorted_keys(cum)) do
            local sh = cum[item] - get(have, item)
            if sh > 0 then needs[#needs + 1] = { item = item, amount = sh, max = maxOf[item] or 1 } end
        end
        if refund_fit(player, needs).missing ~= 0 then break end
        n = k - from + 1
    end
    return n
end

-- How many of `want` are on the station (same bcls + x + y, each existing machine counts once).
-- Returns present count and "Cls@(x,y), ..." of the first 10 missing.
local function present(want, existing)
    local used, pres, parts = {}, 0, {}
    for _, m in ipairs(want) do
        local found = false
        for k, e in ipairs(existing) do
            if not used[k] and e.bcls == m.bcls and e.x == m.x and e.y == m.y then
                used[k] = true
                found = true
                break
            end
        end
        if found then
            pres = pres + 1
        elseif #parts < 10 then
            parts[#parts + 1] = ("%s@(%d,%d)"):format(m.bcls, m.x, m.y)
        end
    end
    return pres, table.concat(parts, ", ")
end

local function new_run(plan)
    return {
        plan = plan, active = false, state = "idle", text = "", stage = 0,
        rounds = 0, stage_rounds = 0,
        t_next = 0, t_start = 0, t_stage = 0, t_issue = 0,
        unit_inv = 0, player_inv = 0, creative = false, chg_sent = false,
        rneed = {}, remove_ids = {}, costs = {},
        chunk_from = 1, chunk_to = 1, counted_from = nil, chunks = 0, chunks_done = 0,
        chunk_need = {}, before = {}, rem_before = {}, snap = {}, issued = {},
        placed = 0, removed = 0, moved_out = 0, moved_in = 0, refund_stayed = false,
        placed_list = {}, removed_list = {},   -- machines actually sent (io.note_build: live overlay)
        base_total = 0, base_ids = {},    -- live machine count and id set at start (diagnostics: new ids)
    }
end

-- both inventories summed per item (player + unit): staging moves keep it, a charge lowers it
local function both_totals(ps, us)
    local t = totals(ps)
    for k, v in pairs(totals(us)) do t[k] = get(t, k) + v end
    return t
end

-- true when every refund item (refund > 0) rose by its amount since `before`. No refund items -> false (the settle time decides).
local function refund_arrived(refund, held, before)
    local any = false
    for k, v in pairs(refund) do
        if v > 0 then
            any = true
            if get(held, k) - get(before, k) < v then return false end
        end
    end
    return any
end

-- pass rule for the +3 s diagnostic only: live total (all classes) >= start total - planned removals + placed so far.
local function expected_total(R)
    return R.base_total - #R.remove_ids + R.placed
end

-- io (injected, plain Lua values). Every send_* returns true when the game accepted it.
--   io.scan(station) -> machines {id,bcls,x,y,...} | nil, err
--   io.fingerprint(machines) -> same value as plan.fp (bpu_plan fingerprint)
--   io.read_inv('player'|'unit') -> { slots = { {item=,amount=,max=} | {item=""} }, id=, ok= }
--   io.unit_ids() -> { unit_id=, player_id= }     io.creative() -> bool     io.costs(place) -> { cost map per machine }
--   io.send_remove(id) | io.send_move(prim_id, sec_id, slot0, action) | io.send_place(machine) | io.send_changes(chg)
--   io.now() -> ms
--   io.note_build(placed, removed) optional: run end with machines placed (plan entries) / removed (live ids)
--   io.trace(text) optional: diagnostics only (position differs from plan, nearest live machines on a count miss)
-- plan (from bpu_plan): station, fp, place, kept, chg, removed={ {id=,bcls=} }, need, refund (ITEM -> n), recChanged, valid.
function B.new(io)
    local R = new_run(nil)

    local function counts()
        return ("placed %d, removed %d, moved_out %d, moved_in %d"):format(R.placed, R.removed, R.moved_out, R.moved_in)
    end
    local function set_status(state, text) R.state = state; R.text = text end
    local function trace(msg) if io.trace then io.trace(msg) end end
    -- diagnostics (trace only): live machines whose id was not in the start scan, and the planned machines given
    local function trace_diag(ex, planned)
        for _, m in ipairs(ex) do
            if not R.base_ids[m.id] then
                trace(("new live: id=%s bcls=%s x=%s y=%s h=%s rot=%s"):format(tostring(m.id), tostring(m.bcls),
                    tostring(m.x), tostring(m.y), tostring(m.h), tostring(m.rot)))
            end
        end
        for _, m in ipairs(planned) do
            trace(("planned: bcls=%s bdat=%s x=%s y=%s h=%s rot=%s"):format(tostring(m.bcls), tostring(m.bdat),
                tostring(m.x), tostring(m.y), tostring(m.h), tostring(m.rot)))
        end
    end
    -- any end (done, error, cancel) with placed or removed machines: io.note_build keeps them as a live overlay
    local function mark_changed()
        if #R.placed_list + #R.removed_list > 0 and io.note_build then io.note_build(R.placed_list, R.removed_list) end
    end
    -- ends the run with error|msg (counts). Returns false.
    local function fail(msg)
        R.state = "error"
        R.text = msg .. " (" .. counts() .. ")"
        R.active = false
        R.stage = 0
        mark_changed()
        return false
    end
    local function start_fail(msg)
        fail(msg)
        return false, "error: " .. msg
    end

    -- inventory slots normalized: item "" when empty, amount/max always numbers
    local function norm(inv)
        local slots = { mult = inv.mult or 1 }   -- StackMultiplier / 2 of this inventory (capmap)
        for i, s in ipairs(inv.slots or {}) do
            slots[i] = { item = s.item or "", amount = s.amount or 0, max = (s.max and s.max > 0) and s.max or 1 }
        end
        return slots
    end
    local function read_both()
        local p = io.read_inv("player")
        if not p or not p.ok then return nil, nil, "player inventory cannot be read" end
        local u = io.read_inv("unit")
        if not u or not u.ok then return nil, nil, "unit inventory cannot be read" end
        return norm(p), norm(u)
    end
    -- one quick move (action 2 = quick move; primary = inventory holding the slot, secondary = destination). i is 1-based.
    -- io.send_move gets the 0-based slot (i - 1). tag (optional): trace the exact args and the send result.
    local function send_move(prim, sec, i, tag)
        local ok, ret = io.send_move(prim, sec, i - 1, 2)
        ok = ok and true or false
        if tag then
            trace(("%s: inv_move(primary=%s, secondary=%s, slot0=%d, action=2) -> sent=%s ret=%s"):format(tag,
                tostring(prim), tostring(sec), i - 1, tostring(ok), tostring(ret)))
        end
        return ok
    end
    -- moveout diagnostics (trace only): both inventories' item totals with the ids; the chosen player slots (slot0 0-based)
    local function trace_totals(tag, ps, us)
        trace(("%s: totals player {%s} unit {%s} (player_inv=%s unit_inv=%s)"):format(tag, list(totals(ps)), list(totals(us)),
            tostring(R.player_inv), tostring(R.unit_inv)))
    end
    local function trace_chosen(ps, mo)
        for _, s in ipairs(mo) do
            trace(("moveout: chosen slot0=%d item=%s amount=%d"):format(s - 1, ps[s].item, ps[s].amount))
        end
    end

    -- DisassembleInput per planned removal. Stage 2 then waits for the refund (or REMOVE_MS). held = totals before.
    local function send_removals(now, held)
        local sent = 0
        for _, id in ipairs(R.remove_ids) do
            if io.send_remove(id) then sent = sent + 1; R.removed_list[#R.removed_list + 1] = id end
        end
        R.removed = sent
        if sent ~= #R.remove_ids then
            return fail(("removal refused for %d machines"):format(#R.remove_ids - sent))
        end
        R.rem_before = held
        R.stage = 2
        R.t_stage = now
        R.t_next = now + POLL_MS
        set_status("working", ("removing %d machines"):format(sent))
    end

    local function send_changes_once()
        if not R.chg_sent then
            io.send_changes(R.plan.chg)
            R.chg_sent = true
        end
    end

    -- all chunks charged: config changes, then the trace-only check at +3 s (stage 7)
    local function finish(now)
        send_changes_once()
        R.stage = 7
        R.t_next = now + 3000
        set_status("working", "finishing")
    end

    -- chunk accepted (charged, or creative): next chunk at once
    local function chunk_done(now)
        R.chunks_done = R.chunks_done + 1
        R.chunk_from = R.chunk_to
        R.stage_rounds = 0
        R.stage = 4
        R.t_next = now
    end

    -- BuildInput for chunk [chunk_from, chunk_to). Totals are read first: stage 6 needs the charge to lower them.
    local function place_chunk(now)
        send_changes_once()
        if not R.creative then
            local ps, us, err = read_both()
            if not ps then return fail(err) end
            R.before = both_totals(ps, us)
        end
        local count, n = R.chunk_to - R.chunk_from, 0
        for k = R.chunk_from, R.chunk_to - 1 do
            if io.send_place(R.plan.place[k]) then n = n + 1; R.placed_list[#R.placed_list + 1] = R.plan.place[k] end
        end
        R.placed = R.placed + n
        if n ~= count then
            return fail(("BuildInput refused for %d machines in chunk %d"):format(count - n, R.chunks_done + 1))
        end
        if R.creative then return chunk_done(now) end   -- creative: no charge to wait for
        R.stage = 6
        R.t_stage = now
        R.t_next = now + POLL_MS
        set_status("working", ("placed chunk %d (%d machines), waiting for the charge"):format(R.chunks_done + 1, count))
    end

    -- stage 4: size the chunk by free player space, move what the player lacks in from the unit (or place at once).
    local function chunk_start(now)
        local P = R.plan
        local n_place = #P.place
        if R.chunk_from > n_place then return finish(now) end
        local ps, us, err = read_both()
        if not ps then return fail(err) end
        local n = R.creative and (n_place - R.chunk_from + 1) or chunk_len(R.costs, R.chunk_from, ps, capmap(io, ps, us))
        if n == 0 then
            return fail(("player inventory full, free slots and build again (%d of %d placed)"):format(R.chunk_from - 1, n_place))
        end
        R.chunk_to = R.chunk_from + n
        if R.counted_from ~= R.chunk_from then
            R.counted_from = R.chunk_from
            R.chunks = R.chunks + 1
        end
        R.chunk_need = {}
        for k = R.chunk_from, R.chunk_to - 1 do
            for item, v in pairs(R.costs[k]) do R.chunk_need[item] = get(R.chunk_need, item) + v end
        end
        local sf = shortfall(R.chunk_need, totals(ps))
        if R.creative or next(sf) == nil then return place_chunk(now) end
        R.issued = stage_moves(us, sf)
        if #R.issued == 0 then return fail("items missing in unit and player: " .. list(sf)) end
        R.snap = us
        for _, i in ipairs(R.issued) do
            if not send_move(R.unit_inv, R.player_inv, i, "staging") then return fail("InventoryInput refused") end
        end
        R.moved_in = R.moved_in + #R.issued
        R.stage = 5
        R.t_stage = now
        R.t_next = now + 250
        set_status("working", ("staging chunk %d: %d stacks from the unit"):format(R.chunks_done + 1, #R.issued))
    end

    -- stage 5: once the player holds the chunk's items, place it. Slots moved -> back to stage 4 (max 6 rounds). Nothing moved for 10 s -> stalled.
    local function staging_wait(now)
        local ps, us, err = read_both()
        if not ps then return fail(err) end
        local sf = shortfall(R.chunk_need, totals(ps))
        if next(sf) == nil then return place_chunk(now) end
        local moved = #R.issued > 0
        for _, i in ipairs(R.issued) do
            local a, b = us[i], R.snap[i]
            if not a or not b or (a.item == b.item and a.amount == b.amount) then
                moved = false
                break
            end
        end
        if moved then
            R.stage_rounds = R.stage_rounds + 1
            if R.stage_rounds > 6 then return fail("staging stalled: " .. list(sf)) end
            R.stage = 4
            R.t_next = now
            return
        end
        if now - R.t_stage > STAGE_MS then return fail("staging stalled: " .. list(sf)) end
        R.t_next = now + 250
    end

    -- stage 6: the chunk is accepted when player+unit items dropped by the chunk cost (the charge). The station view is not read.
    -- CHARGE_MS without the charge -> fail.
    local function charge_wait(now)
        local ps, us, err = read_both()
        if not ps then return fail(err) end
        local held, charged = both_totals(ps, us), true
        for item, v in pairs(R.chunk_need) do
            if get(R.before, item) - get(held, item) < v then charged = false end
        end
        if charged then return chunk_done(now) end
        if now - R.t_stage > CHARGE_MS then
            return fail(("chunk %d: items were not charged (sim did not accept the build)"):format(R.chunks_done + 1))
        end
        R.t_next = now + POLL_MS
    end

    -- stage 3: refund stacks the build does not need must leave the player. Re-issued every 2 s, 3 rounds; 10 s -> fail.
    -- Best effort: not moved within STAGE_MS -> the refund stays in the player inventory and the build goes on (run ends done).
    local function moveout_wait(now)
        local ps, us, err = read_both()
        if not ps then return fail(err) end
        local mo = moveout_slots(ps, moveset(R.plan.refund, R.plan.need))
        trace_totals("moveout poll", ps, us)
        if #mo == 0 then
            R.stage = 4
            R.t_next = now
            return
        end
        if now - R.t_stage > STAGE_MS then
            R.refund_stayed = true
            trace(("moveout: refund not moved into the unit within %d ms, it stays in the player inventory"):format(STAGE_MS))
            R.stage = 4
            R.t_next = now
            set_status("working", "refund stayed in your inventory, continuing")
            return
        end
        if R.rounds < 3 and now - R.t_issue >= 2000 then
            R.rounds = R.rounds + 1
            R.t_issue = now
            trace_chosen(ps, mo)
            for _, s in ipairs(mo) do
                if not send_move(R.player_inv, R.unit_inv, s, "moveout") then return fail("InventoryInput refused") end
            end
        end
        R.t_next = now + 250
    end

    -- stage 2: wait until the refund shows up (every refund item rose by its amount) or REMOVE_MS passed, whichever first.
    -- The station view is not read. Then the unneeded refund goes to the unit (stage 3) or stage 4.
    local function removal_wait(now)
        local ps, us, err = read_both()
        if not ps then return fail(err) end
        local arrived = refund_arrived(R.plan.refund, both_totals(ps, us), R.rem_before)
        if not arrived and now - R.t_stage < REMOVE_MS then
            set_status("working", ("removing %d machines"):format(R.removed))
            R.t_next = now + POLL_MS
            return
        end
        local mo = R.creative and {} or moveout_slots(ps, moveset(R.plan.refund, R.plan.need))
        if #mo == 0 then
            R.stage = 4
            R.t_next = now
            set_status("working", "removal done")
            return
        end
        trace_totals("moveout start", ps, us)
        trace_chosen(ps, mo)
        for _, s in ipairs(mo) do
            if not send_move(R.player_inv, R.unit_inv, s, "moveout") then return fail("InventoryInput refused") end
        end
        R.moved_out = R.moved_out + #mo
        R.stage = 3
        R.rounds = 0
        R.t_stage = now
        R.t_issue = now
        R.t_next = now + 250
        set_status("working", ("moved %d refund stacks to the unit"):format(#mo))
    end

    -- stage 1: the refund must fit the player inventory before removals go. While it does not, player stacks are quick-moved
    -- to the unit (items the build does not need first), one batch per second, as many as slots are missing. 10 s -> fail (unit full).
    local function room_wait(now)
        local ps, us, err = read_both()
        if not ps then return fail(err) end
        local rerr = refund_check(R.rneed, ps)
        if rerr == "" then return send_removals(now, both_totals(ps, us)) end
        if now - R.t_stage > STAGE_MS then return fail(rerr) end
        if now - R.t_issue >= 1000 then
            R.t_issue = now
            local out = stage_out(ps, R.plan.need, math.max(refund_fit(ps, R.rneed).missing, 1))
            for _, s in ipairs(out) do
                if not send_move(R.player_inv, R.unit_inv, s, "room") then return fail("InventoryInput refused") end
                R.moved_out = R.moved_out + 1
            end
            if #out > 0 then set_status("working", ("room for the refund: %d stacks moved to the unit, checking"):format(#out)) end
        end
        R.t_next = now + 500
    end

    -- stage 7 (+3 s): diagnostics only (trace). The station view may still be stale, so it never fails the run.
    local function verify_final()
        local P = R.plan
        R.active = false
        R.stage = 0
        local ex = io.scan(P.station)
        if ex then
            local chk = {}
            for _, m in ipairs(P.place) do chk[#chk + 1] = m end
            for _, m in ipairs(P.kept) do chk[#chk + 1] = m end
            trace(("diag: expected total %d, view total %d"):format(expected_total(R), #ex))
            trace_diag(ex, P.place)
            local pex = present(chk, ex)
            if pex < #chk then trace(("diag: %d of %d at planned cells (position may differ from plan)"):format(pex, #chk)) end
        end
        local txt = ("placed %d machines (the game updates its blueprint view in about 30 s)"):format(R.placed)
        if R.refund_stayed then
            txt = ("removed %d, refund stayed in your inventory (could not move it into the unit); "):format(R.removed) .. txt
        end
        R.state = "done"
        R.text = txt
        mark_changed()
    end

    local builder = {}

    -- start(plan, opts): checks everything first (station, totals, creative, refund room); nothing is sent on a refusal.
    -- opts is accepted for the contract, not used.
    function builder:start(plan, _opts)
        if R.active then return false, "error: busy: another build is running" end
        R = new_run(nil)
        if not plan or not plan.valid then return start_fail("import first") end
        local P = {
            station = plan.station, fp = plan.fp,
            place = plan.place or {}, kept = plan.kept or {}, chg = plan.chg or {},
            removed = plan.removed or {}, need = plan.need or {}, refund = plan.refund or {},
            recChanged = plan.recChanged or 0,
        }
        R.plan = P
        R.state = "working"
        R.text = "checking station"
        local now = io.now()
        R.t_start = now
        R.t_stage = now
        local ex, err = io.scan(P.station)
        if not ex then return start_fail(err or "live read fault") end
        if io.fingerprint(ex) ~= P.fp then return start_fail("station changed since import, import again") end
        R.base_total = #ex
        for _, m in ipairs(ex) do if m.id ~= nil then R.base_ids[m.id] = true end end
        local ps, us, rerr = read_both()
        if not ps then return start_fail(rerr) end
        local ids = io.unit_ids()
        if not ids or not ids.unit_id or not ids.player_id then return start_fail("inventory ids unknown") end
        R.unit_inv, R.player_inv = ids.unit_id, ids.player_id
        R.creative = io.creative() == true
        local cl = io.costs(P.place) or {}
        for k = 1, #P.place do R.costs[k] = cl[k] or {} end
        if not R.creative then
            local terr = total_check(P.need, P.refund, totals(ps), totals(us))
            if terr ~= "" then return start_fail(terr) end
        end
        for _, m in ipairs(P.removed) do R.remove_ids[#R.remove_ids + 1] = m.id end
        if #P.place == 0 and #R.remove_ids == 0 and #P.chg == 0 then
            R.state = "done"
            R.text = "nothing to build"
            return true, "ok nothing to build"
        end

        R.active = true
        if #R.remove_ids > 0 then
            R.rneed = build_rneed(P.refund, capmap(io, ps, us))
            if refund_check(R.rneed, ps) == "" then
                send_removals(now, both_totals(ps, us))
            else
                -- refund does not fit: move the unneeded refund stacks to the unit, stage 1 re-checks
                local mo = R.creative and {} or moveout_slots(ps, moveset(P.refund, P.need))
                trace_totals("moveout start (room)", ps, us)
                trace_chosen(ps, mo)
                for _, s in ipairs(mo) do
                    if not send_move(R.player_inv, R.unit_inv, s, "moveout") then return start_fail("InventoryInput refused") end
                end
                R.moved_out = R.moved_out + #mo
                R.stage = 1
                R.t_stage = now
                R.t_next = now + 500
                set_status("working", ("room for the refund: %d stacks moved to the unit, checking"):format(#mo))
            end
        else
            R.stage = 4
            R.t_next = now
            set_status("working", "staging")
        end
        if not R.active then return false, "error: " .. R.text end
        return true, "ok build started"
    end

    -- tick(now_ms): one step when t_next has passed. Call every 250-500 ms.
    function builder:tick(now)
        if not R.active or now < R.t_next then return end
        if now - R.t_start > TOTAL_MS then return fail("timeout after 300 s") end
        local s = R.stage
        if s == 1 then room_wait(now)
        elseif s == 2 then removal_wait(now)
        elseif s == 3 then moveout_wait(now)
        elseif s == 4 then chunk_start(now)
        elseif s == 5 then staging_wait(now)
        elseif s == 6 then charge_wait(now)
        elseif s == 7 then verify_final()
        else fail("internal: unknown stage " .. s) end
    end

    -- cancel(): stops a running build (error|cancelled). Items already moved stay where they are.
    function builder:cancel()
        if not R.active then return false, "error: no bp_build running" end
        fail("cancelled")
        return true, "ok bp_build cancelled"
    end

    -- status(): snapshot of the run (idle before the first start).
    function builder:status()
        local P = R.plan
        return {
            state = R.state, text = R.text, stage = R.stage,
            placed = R.placed, kept = P and #P.kept or 0, removed = R.removed,
            recipe = P and P.recChanged or 0, moved_out = R.moved_out, moved_in = R.moved_in,
            chunk = R.chunks_done .. "/" .. R.chunks,
        }
    end

    return builder
end

-- pure helpers, exposed for the tests
B.pure = {
    totals = totals, maxes = maxes, list = list, shortfall = shortfall, total_check = total_check,
    stage_moves = stage_moves, moveout_slots = moveout_slots, moveset = moveset, refund_fit = refund_fit,
    refund_check = refund_check, chunk_len = chunk_len, present = present, stage_out = stage_out,
}

return B
