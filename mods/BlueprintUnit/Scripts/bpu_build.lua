-- bpu_build: pure Lua port of the bp_build flow (mb_bpprobe.hpp: bb_* helpers, bp_build_cmd, bp_build_tick).
-- No game globals. Every game call goes through the injected `io` table (see B.new).
-- Lua side: slots and machines are 1-based. io.send_move gets the 0-based game slot index.
-- Items are matched by item name (ITEM_HullPlate), same keys as plan.need / plan.refund.

local B = {}

local TOTAL_MS = 300000   -- whole run
local STAGE_MS = 10000    -- staging round, moveout
local PLACE_MS = 20000    -- chunk placed on the station
local REMOVE_TRIES = 60   -- x 1 s

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
        tries = 0, rounds = 0, stage_rounds = 0,
        t_next = 0, t_start = 0, t_stage = 0, t_issue = 0,
        unit_inv = 0, player_inv = 0, creative = false, chg_sent = false,
        rneed = {}, remove_ids = {}, costs = {},
        chunk_from = 1, chunk_to = 1, counted_from = nil, chunks = 0, chunks_done = 0,
        chunk_need = {}, snap = {}, issued = {},
        placed = 0, removed = 0, moved_out = 0, moved_in = 0, verify_p = -1, verify_n = 0,
        base = {}, rem = {}, want = {},   -- live count per bcls at start, planned removals per bcls, placed per bcls (cumulative)
        base_total = 0, base_ids = {},    -- live machine count and id set at start (diagnostics: new ids)
    }
end

-- live machines per bcls
local function count_by(list)
    local c = {}
    for _, m in ipairs(list) do c[m.bcls] = get(c, m.bcls) + 1 end
    return c
end

-- expected live count of a class: start count - removed + placed so far. Position is not part of it.
local function expected_of(R, bcls)
    return get(R.base, bcls) - get(R.rem, bcls) + get(R.want, bcls)
end

-- pass rule: live total (all classes) >= start total - planned removals + placed so far. Class and position never fail a build.
local function expected_total(R)
    return R.base_total - #R.remove_ids + R.placed
end

-- classes (set) whose live count is below expected: { {bcls, expected, live}, ... } and the total short count.
local function short_classes(R, classes, live)
    local lc, out, total = count_by(live), {}, 0
    for _, k in ipairs(sorted_keys(classes)) do
        local e, l = expected_of(R, k), get(lc, k)
        if l < e then
            out[#out + 1] = { bcls = k, expected = e, live = l }
            total = total + (e - l)
        end
    end
    return out, total
end

-- first machine of class bcls in list (the wanted cell), or nil
local function first_of(list, bcls)
    for _, m in ipairs(list) do if m.bcls == bcls then return m end end
    return nil
end

-- io (injected, plain Lua values). Every send_* returns true when the game accepted it.
--   io.scan(station) -> machines {id,bcls,x,y,...} | nil, err
--   io.fingerprint(machines) -> same value as plan.fp (bpu_plan fingerprint)
--   io.read_inv('player'|'unit') -> { slots = { {item=,amount=,max=} | {item=""} }, id=, ok= }
--   io.unit_ids() -> { unit_id=, player_id= }     io.creative() -> bool     io.costs(place) -> { cost map per machine }
--   io.send_remove(id) | io.send_move(prim_id, sec_id, slot0, action) | io.send_place(machine) | io.send_changes(chg)
--   io.now() -> ms
--   io.trace(text) optional: diagnostics only (position differs from plan, nearest live machines on a count miss)
-- plan (from bpu_plan): station, fp, place, kept, chg, removed={ {id=,bcls=} }, need, refund (ITEM -> n), recChanged, valid.
function B.new(io)
    local R = new_run(nil)

    local function counts()
        return ("placed %d, removed %d, moved_out %d, moved_in %d"):format(R.placed, R.removed, R.moved_out, R.moved_in)
    end
    local function set_status(state, text) R.state = state; R.text = text end
    local function trace(msg) if io.trace then io.trace(msg) end end
    -- up to 3 live machines of class bcls nearest to the wanted machine wm (trace only)
    local function trace_near(wm, bcls, live)
        if not wm then return end
        local c = {}
        for _, m in ipairs(live) do if m.bcls == bcls then c[#c + 1] = m end end
        local function d2(m) return ((m.x or 0) - wm.x) ^ 2 + ((m.y or 0) - wm.y) ^ 2 end
        table.sort(c, function(a, b) return d2(a) < d2(b) end)
        if #c == 0 then trace(("no live %s on the station"):format(bcls)) end
        for i = 1, math.min(3, #c) do
            local m = c[i]
            trace(("near %s@(%d,%d): id=%s x=%s y=%s h=%s rot=%s"):format(bcls, wm.x, wm.y,
                tostring(m.id), tostring(m.x), tostring(m.y), tostring(m.h), tostring(m.rot)))
        end
    end
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
    -- ends the run with error|msg (counts). Returns false.
    local function fail(msg)
        R.state = "error"
        R.text = msg .. " (" .. counts() .. ")"
        R.active = false
        R.stage = 0
        return false
    end
    local function start_fail(msg)
        fail(msg)
        return false, "error: " .. msg
    end

    -- inventory slots normalized: item "" when empty, amount/max always numbers
    local function norm(inv)
        local slots = {}
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
    local function send_move(prim, sec, i)
        return io.send_move(prim, sec, i - 1, 2) and true or false
    end

    -- DisassembleInput per planned removal. Stage 2 then waits until they are gone.
    local function send_removals(now)
        local sent = 0
        for _, id in ipairs(R.remove_ids) do
            if io.send_remove(id) then sent = sent + 1 end
        end
        R.removed = sent
        if sent ~= #R.remove_ids then
            return fail(("removal refused for %d machines"):format(#R.remove_ids - sent))
        end
        R.stage = 2
        R.tries = 0
        R.t_next = now + 1500
        set_status("working", ("removing %d machines"):format(sent))
    end

    local function send_changes_once()
        if not R.chg_sent then
            io.send_changes(R.plan.chg)
            R.chg_sent = true
        end
    end

    -- all chunks placed: config changes, then verify at +3 s (stage 7)
    local function finish(now)
        send_changes_once()
        R.stage = 7
        R.t_next = now + 3000
        set_status("working", "verifying at +3 s")
    end

    -- BuildInput for chunk [chunk_from, chunk_to). Stage 6 waits for the machines.
    local function place_chunk(now)
        send_changes_once()
        local count, n = R.chunk_to - R.chunk_from, 0
        for k = R.chunk_from, R.chunk_to - 1 do
            local m = R.plan.place[k]
            if io.send_place(m) then
                n = n + 1
                R.want[m.bcls] = get(R.want, m.bcls) + 1
            end
        end
        R.placed = R.placed + n
        if n ~= count then
            return fail(("BuildInput refused for %d machines in chunk %d"):format(count - n, R.chunks_done + 1))
        end
        R.stage = 6
        R.t_stage = now
        R.t_next = now + 500
        set_status("working", ("placed chunk %d (%d machines), waiting"):format(R.chunks_done + 1, count))
    end

    -- stage 4: size the chunk by free player space, move what the player lacks in from the unit (or place at once).
    local function chunk_start(now)
        local P = R.plan
        local n_place = #P.place
        if R.chunk_from > n_place then return finish(now) end
        local ps, us, err = read_both()
        if not ps then return fail(err) end
        local n = R.creative and (n_place - R.chunk_from + 1) or chunk_len(R.costs, R.chunk_from, ps, maxes(ps, us))
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
            if not send_move(R.unit_inv, R.player_inv, i) then return fail("InventoryInput refused") end
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

    -- stage 6: live total (all classes) >= expected total -> next chunk at once. Class/position only traced.
    -- PLACE_MS without the total -> fail with expected vs live totals.
    local function place_wait(now)
        local P = R.plan
        local ex, err = io.scan(P.station)
        if not ex then return fail(err or "live read fault while placing") end
        local want, live = expected_total(R), #ex
        local slice = {}
        for k = R.chunk_from, R.chunk_to - 1 do slice[#slice + 1] = P.place[k] end
        if live >= want then
            local pres, missing = present(slice, ex)
            if pres < #slice then
                trace(("chunk %d: count met, %d of %d at planned cells (position differs from plan): %s"):format(R.chunks_done + 1, pres, #slice, missing))
            end
            trace_diag(ex, slice)
            R.chunks_done = R.chunks_done + 1
            R.chunk_from = R.chunk_to
            R.stage_rounds = 0
            R.stage = 4
            R.t_next = now
            return
        end
        if now - R.t_stage > PLACE_MS then
            trace_diag(ex, slice)
            for _, s in ipairs(short_classes(R, R.want, ex)) do trace_near(first_of(P.place, s.bcls), s.bcls, ex) end
            return fail(("chunk %d: %d machines not placed (total expected %d, live %d)"):format(R.chunks_done + 1, want - live, want, live))
        end
        R.t_next = now + 500
    end

    -- stage 3: refund stacks the build does not need must leave the player. Re-issued every 2 s, 3 rounds; 10 s -> fail.
    local function moveout_wait(now)
        local ps, _, err = read_both()
        if not ps then return fail(err) end
        local mo = moveout_slots(ps, moveset(R.plan.refund, R.plan.need))
        if #mo == 0 then
            R.stage = 4
            R.t_next = now
            return
        end
        if now - R.t_stage > STAGE_MS then return fail("refund stacks could not be moved into the unit (unit full?)") end
        if R.rounds < 3 and now - R.t_issue >= 2000 then
            R.rounds = R.rounds + 1
            R.t_issue = now
            for _, s in ipairs(mo) do
                if not send_move(R.player_inv, R.unit_inv, s) then return fail("InventoryInput refused") end
            end
        end
        R.t_next = now + 250
    end

    -- stage 2: waits until the removed machines are gone (60 checks, 1 s apart). Then the unneeded refund goes to the unit (stage 3) or stage 4.
    local function removal_wait(now)
        local ex, err = io.scan(R.plan.station)
        if not ex then return fail(err or "live read fault after removal") end
        local here, left = {}, 0
        for _, e in ipairs(ex) do here[e.id] = true end
        for _, id in ipairs(R.remove_ids) do
            if here[id] then left = left + 1 end
        end
        if left > 0 then
            R.tries = R.tries + 1
            if R.tries < REMOVE_TRIES then
                set_status("working", ("removing, %d left"):format(left))
                R.t_next = now + 1000
                return
            end
            return fail(("%d machines still present after removal"):format(left))
        end
        local ps, _, err2 = read_both()
        if not ps then return fail(err2) end
        local mo = R.creative and {} or moveout_slots(ps, moveset(R.plan.refund, R.plan.need))
        if #mo == 0 then
            R.stage = 4
            R.t_next = now
            set_status("working", "removal done")
            return
        end
        for _, s in ipairs(mo) do
            if not send_move(R.player_inv, R.unit_inv, s) then return fail("InventoryInput refused") end
        end
        R.moved_out = R.moved_out + #mo
        R.stage = 3
        R.tries = 0
        R.rounds = 0
        R.t_stage = now
        R.t_issue = now
        R.t_next = now + 250
        set_status("working", ("moved %d refund stacks to the unit"):format(#mo))
    end

    -- stage 1: waits until the refund fits the player inventory, 10 s max, then removals go.
    local function room_wait(now)
        local ps, _, err = read_both()
        if not ps then return fail(err) end
        local rerr = refund_check(R.rneed, ps)
        if rerr == "" then return send_removals(now) end
        if now - R.t_stage > STAGE_MS then return fail(rerr) end
        R.t_next = now + 500
    end

    -- stage 7: +3 s verify over placed + kept machines.
    local function verify_final()
        local P = R.plan
        local ex = io.scan(P.station)
        local chk = {}
        for _, m in ipairs(P.place) do chk[#chk + 1] = m end
        for _, m in ipairs(P.kept) do chk[#chk + 1] = m end
        R.active = false
        R.stage = 0
        if not ex then
            R.state = "error"
            R.text = "verify could not read the station (" .. counts() .. ")"
            return
        end
        local want, live = expected_total(R), #ex
        local short = math.max(want - live, 0)
        R.verify_p, R.verify_n = math.max(#chk - short, 0), #chk
        trace_diag(ex, P.place)
        if short > 0 then
            local classes = {}
            for k in pairs(R.want) do classes[k] = true end
            for _, m in ipairs(P.kept) do classes[m.bcls] = true end
            for _, s in ipairs(short_classes(R, classes, ex)) do trace_near(first_of(chk, s.bcls), s.bcls, ex) end
            R.state = "error"
            R.text = ("verify missing %d machines: total expected %d, live %d (%s)"):format(short, want, live, counts())
            return
        end
        local pex = present(chk, ex)
        local off = #chk - pex
        if off > 0 then trace(("verify: count met, %d of %d at planned cells (position differs from plan)"):format(pex, #chk)) end
        R.state = "done"
        R.text = counts() .. (off > 0 and (" (%d position differs from plan)"):format(off) or "")
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
        R.base = count_by(ex)
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
        R.rem = count_by(P.removed)
        if #P.place == 0 and #R.remove_ids == 0 and #P.chg == 0 then
            R.state = "done"
            R.text = "nothing to build"
            return true, "ok nothing to build"
        end

        R.active = true
        if #R.remove_ids > 0 then
            R.rneed = build_rneed(P.refund, maxes(ps, us))
            if refund_check(R.rneed, ps) == "" then
                send_removals(now)
            else
                -- refund does not fit: move the unneeded refund stacks to the unit, stage 1 re-checks
                local mo = R.creative and {} or moveout_slots(ps, moveset(P.refund, P.need))
                for _, s in ipairs(mo) do
                    if not send_move(R.player_inv, R.unit_inv, s) then return start_fail("InventoryInput refused") end
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
        elseif s == 6 then place_wait(now)
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
            verify = (R.verify_p < 0 and "-" or tostring(R.verify_p)) .. "/" .. R.verify_n,
        }
    end

    return builder
end

-- pure helpers, exposed for the tests
B.pure = {
    totals = totals, maxes = maxes, list = list, shortfall = shortfall, total_check = total_check,
    stage_moves = stage_moves, moveout_slots = moveout_slots, moveset = moveset, refund_fit = refund_fit,
    refund_check = refund_check, chunk_len = chunk_len, present = present,
}

return B
