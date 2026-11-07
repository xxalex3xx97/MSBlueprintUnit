-- bpu_build: pure Lua port of the bp_build flow (mb_bpprobe.hpp: bb_* helpers, bp_build_cmd, bp_build_tick).
-- No game globals. Every game call goes through the injected `io` table (see B.new).
-- Lua side: slots and machines are 1-based. io.send_move gets the 0-based game slot index.
-- Items are matched by item name (ITEM_HullPlate), same keys as plan.need / plan.refund.
-- Checks run in start() before the first command. Removals go in batches sized by the free player room (a refund lands in
-- the player inventory): a batch waits for its refund, moves the unneeded refund to the unit, the next batch waits for that
-- room to come back. A stall ends the run with a note. After the last command the run is done.
-- Waits only where a later command needs an earlier one applied: staged items before the BuildInputs that charge them,
-- a removal before a placement on the same cell, the charge before the next chunk (frees player space).

local B = {}

local TOTAL_MS = 300000   -- whole run
local STAGE_MS = 3000     -- staging round stalls after this
local CHARGE_MS = 5000    -- chunk charge (needed before the next chunk only) must show within this
local REFUND_MAX_MS = 2000   -- removal batch: its refund must show in the player inventory within this, else STALL
local DRAIN_MS = 2000        -- refund moved to the unit must leave the player within this (not after the last batch), else STALL
local SETTLE_MS = 500        -- last removal before a placement on its cell, not confirmed by a refund: settle from the send
local POLL_MS = 250
local RESERVE = 1            -- empty player slots kept back from every removal batch (safety margin)
local CARRY_CAP = 6          -- carriers in a batch add 1 reserved slot each, up to this many

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

-- true when the needs fit the slots with `reserve` empty slots kept back. No new slot needed = always fits.
local function room_ok(slots, needs, reserve)
    local f = refund_fit(slots, needs)
    return f.need == 0 or f.need <= f.empty - reserve
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

-- both inventories summed per item (player + unit): staging moves keep it, a charge lowers it
local function both_totals(ps, us)
    local t = totals(ps)
    for k, v in pairs(totals(us)) do t[k] = get(t, k) + v end
    return t
end

local function any_refund(refund)
    for _, v in pairs(refund) do if v > 0 then return true end end
    return false
end

-- true when every refund item (refund > 0) rose by its amount since `before`. No refund items -> false.
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

-- Refund items the build does not need (need 0 or absent): these may leave the player (free room).
local function moveset(refund, need)
    local set = {}
    for k, v in pairs(refund) do
        if v > 0 and get(need, k) <= 0 then set[k] = true end
    end
    return set
end

-- Slots (slot order) holding one of the items in set (set[item] = true). Whole stacks.
local function moveout_slots(slots, set)
    local out = {}
    for i, s in ipairs(slots) do
        if s.item ~= "" and s.amount > 0 and set[s.item] then out[#out + 1] = i end
    end
    return out
end

-- removed conveyor, splitter or underground: its items come back to the player on top of the refund
local function is_carrier(bcls)
    local s = tostring(bcls or "")
    return s:find("Conveyor", 1, true) ~= nil or s:find("Splitter", 1, true) ~= nil or s:find("Underground", 1, true) ~= nil
end

-- a placed machine on the cell of a removed machine: that placement must wait for the removal
local function overlaps(removed, place)
    local cells = {}
    for _, m in ipairs(removed) do cells[tostring(m.x) .. "|" .. tostring(m.y)] = true end
    for _, m in ipairs(place) do
        if cells[tostring(m.x) .. "|" .. tostring(m.y)] then return true end
    end
    return false
end

local function new_run(plan)
    return {
        plan = plan, active = false, state = "idle", text = "", stage = 0,
        stage_rounds = 0, overlap = false,
        t_next = 0, t_start = 0, t_stage = 0,
        unit_inv = 0, player_inv = 0, creative = false, chg_sent = false,
        rem_list = {}, rem_pos = 1, batch_refund = {}, batch_set = {}, t_removed = 0, removal_confirmed = false,
        drain = {}, costs = {}, emp = nil,   -- rem_list = { {id, bcls, refund = cost map} } in removal order; batch = rem_pos..last sent
        chunk_from = 1, chunk_to = 1, counted_from = nil, chunks = 0, chunks_done = 0,
        chunk_need = {}, before = {}, rem_before = {}, snap = {}, issued = {},
        placed = 0, removed = 0, moved_in = 0, refund_moved = false,
        placed_list = {}, removed_list = {},   -- machines actually sent (io.note_build: live overlay)
    }
end

-- io (injected, plain Lua values). Every send_* returns true when the game accepted it.
--   io.scan(station) -> machines {id,bcls,x,y,...} | nil, err
--   io.fingerprint(machines) -> same value as plan.fp (bpu_plan fingerprint); a failure is traced, never blocks
--   io.read_inv('player'|'unit') -> { slots = { {item=,amount=,max=} | {item=""} }, id=, ok= }
--   io.unit_ids() -> { unit_id=, player_id= }     io.creative() -> bool     io.costs(place) -> { cost map per machine }
--   io.send_remove(id) | io.send_move(prim_id, sec_id, slot0, action) | io.send_place(machine) | io.send_changes(chg)
--   io.now() -> ms
--   io.note_build(placed, removed) optional: run end with machines placed (plan entries) / removed (live ids)
--   io.trace(text) optional: diagnostics only
-- plan (from bpu_plan): station, fp, place, kept, chg, removed={ {id=,bcls=,x=,y=} }, need, refund (ITEM -> n), recChanged, valid.
function B.new(io)
    local R = new_run(nil)

    local function counts()
        return ("placed %d, removed %d, moved_in %d"):format(R.placed, R.removed, R.moved_in)
    end
    local function set_status(state, text) R.state = state; R.text = text end
    local function trace(msg) if io.trace then io.trace(msg) end end
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
    -- one quick move = the game's press+release pair (io.send_move sends and traces both). i is 1-based.
    -- io.send_move gets the 0-based slot (i - 1). tag (optional): trace the send result.
    local function send_move(prim, sec, i, tag)
        local ok, ret = io.send_move(prim, sec, i - 1)
        ok = ok and true or false
        if tag then
            trace(("%s: pair(primary=%s, secondary=%s, slot0=%d) -> sent=%s ret=%s"):format(tag,
                tostring(prim), tostring(sec), i - 1, tostring(ok), tostring(ret)))
        end
        return ok
    end

    -- run ends with a short note (no more removals, no placements). Removed machines stay in the live overlay.
    local function stall(detail)
        R.state = "error"
        R.text = (R.removed > 0 and ("stopped after %d removals: "):format(R.removed) or "") .. detail
        R.active = false
        R.stage = 0
        mark_changed()
        return false
    end

    local function send_changes_once()
        if not R.chg_sent then
            io.send_changes(R.plan.chg)
            R.chg_sent = true
        end
    end

    -- last command sent: the run is done at once (no charge poll, no verify)
    local function finish()
        send_changes_once()
        R.active = false
        R.stage = 0
        R.state = "done"
        if R.refund_moved then
            R.text = ("sent: placed %d, removed %d, refund moved to the unit (the game updates its blueprint view in about 30 s)"):format(R.placed, R.removed)
        else
            R.text = ("sent: placed %d, removed %d (the game updates its blueprint view in about 30 s)"):format(R.placed, R.removed)
        end
        mark_changed()
    end

    -- chunk accepted (charged, or creative): next chunk at once
    local function chunk_done(now)
        R.chunk_from = R.chunk_to
        R.stage_rounds = 0
        R.stage = 4
        R.t_next = now
    end

    -- BuildInput for chunk [chunk_from, chunk_to). The last chunk ends the run; an earlier one waits for its charge.
    local function place_chunk(now)
        send_changes_once()
        local last = R.chunk_to > #R.plan.place
        if not R.creative and not last then
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
        R.chunks_done = R.chunks_done + 1   -- accepted = sent (counts the last chunk too)
        if last then return finish() end
        if R.creative then return chunk_done(now) end   -- creative: no charge to wait for
        R.stage = 6
        R.t_stage = now
        R.t_next = now + POLL_MS
        set_status("working", ("placed chunk %d (%d machines), waiting for the charge"):format(R.chunks_done, count))
    end

    -- stage 4: size the chunk by free player space, stage what the player lacks from the unit (or place at once).
    local function chunk_start(now)
        local P = R.plan
        local n_place = #P.place
        if R.chunk_from > n_place then return finish() end
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
        R.t_next = now + POLL_MS
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
        R.t_next = now + POLL_MS
    end

    -- stage 6: only between chunks. The next chunk is staged once player+unit items dropped by the chunk cost.
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
            return fail(("chunk %d: items were not charged (sim did not accept the build)"):format(R.chunks_done))
        end
        R.t_next = now + POLL_MS
    end

    -- all removals sent. A placement on a removed cell waits for the removal: a refund already seen confirms it,
    -- else SETTLE_MS from the last send. Then the placements (chunk_start).
    local function after_removals(now)
        if R.overlap and not R.removal_confirmed and now < R.t_removed + SETTLE_MS then
            R.stage = 9
            R.t_next = R.t_removed + SETTLE_MS
            return
        end
        return chunk_start(now)
    end

    local send_batches   -- forward (batch -> move -> drain -> next batch)

    -- stage 2: the batch refund must show in the player inventory (REFUND_MAX_MS, else STALL).
    -- The refund items the build does not need leave the player (move_out). Nothing moves in creative.
    local function move_out(now, ps, us)
        local mo = R.creative and {} or moveout_slots(ps, R.batch_set)
        if #mo == 0 then return send_batches(now) end
        local moved = {}
        for _, s in ipairs(mo) do moved[ps[s].item] = get(moved, ps[s].item) + ps[s].amount end
        if not room_ok(us, build_rneed(moved, capmap(io, us, ps)), 0) then
            return stall("the unit inventory is full, empty it and Build again")
        end
        for _, s in ipairs(mo) do
            trace(("moveout: chosen slot0=%d item=%s amount=%d"):format(s - 1, ps[s].item, ps[s].amount))
        end
        for _, s in ipairs(mo) do
            if not send_move(R.player_inv, R.unit_inv, s, "moveout") then return fail("InventoryInput refused") end
        end
        local sent = {}
        for _, s in ipairs(mo) do sent[#sent + 1] = tostring(s - 1) end
        trace("moveout verify: slots=" .. table.concat(sent, ","))
        R.refund_moved = true
        -- a later batch needs the room back: wait for it (stage 8). The last batch goes on at once, as before.
        if R.rem_pos > #R.rem_list then return after_removals(now) end
        R.drain = moved
        R.stage = 8
        R.t_stage = now
        R.t_next = now + POLL_MS
    end

    -- trace only: per item, held now - before the batch - batch refund (batch refund items and every other item)
    local function batch_extra(held)
        local seen, keys, parts = {}, {}, {}
        for _, src in ipairs({ R.batch_refund, held, R.rem_before }) do
            for k in pairs(src) do
                if not seen[k] then seen[k] = true; keys[#keys + 1] = k end
            end
        end
        table.sort(keys)
        for _, k in ipairs(keys) do
            local x = get(held, k) - get(R.rem_before, k) - get(R.batch_refund, k)
            if x ~= 0 then parts[#parts + 1] = ("%s %+d"):format(k, x) end
        end
        trace("batch extra: " .. (#parts > 0 and table.concat(parts, ", ") or "none"))
    end

    local function arrival_wait(now)
        local ps, us, err = read_both()
        if not ps then return fail(err) end
        if not refund_arrived(R.batch_refund, totals(ps), R.rem_before) then
            if now - R.t_stage >= REFUND_MAX_MS then
                return stall("the refund did not show in the player inventory within 2 s, check the game, then Build again")
            end
            R.t_next = now + POLL_MS
            return
        end
        R.removal_confirmed = true
        batch_extra(totals(ps))
        return move_out(now, ps, us)
    end

    -- stage 8: the moved refund must leave the player (DRAIN_MS, else STALL). Then the next batch.
    local function drain_wait(now)
        local ps, _, err = read_both()
        if not ps then return fail(err) end
        local held = totals(ps)
        for item in pairs(R.drain) do
            if get(held, item) > 0 then
                if now - R.t_stage >= DRAIN_MS then
                    for _, k in ipairs(sorted_keys(R.drain)) do trace(("drain stall: held[%s]=%d"):format(k, get(held, k))) end
                    return stall("the game did not apply the move (see bpu_trace.log: ourcmd recv must equal uicmd recv)")
                end
                R.t_next = now + POLL_MS
                return
            end
        end
        return send_batches(now)
    end

    -- machine contents: nil = not a container, false = unreadable, else map (item -> amount), total, inv
    local function contents_of(entry)
        if not io.read_machine_inv then return nil, 0 end
        local inv = io.read_machine_inv(entry.id)
        if inv == nil then return nil, 0 end
        if not inv.ok then return false, 0 end
        local map, total = {}, 0
        for _, s in ipairs(inv.slots or {}) do
            if (s.item or "") ~= "" and (s.amount or 0) > 0 then
                map[s.item] = get(map, s.item) + s.amount
                total = total + s.amount
            end
        end
        return map, total, inv
    end

    -- stage 10 starter: a container with items at the head of the removal list is emptied into the unit first.
    local function start_empty(now, entry)
        local map, total, read = contents_of(entry)
        if not map then return stall(("container id %s cannot be read, Build again"):format(tostring(entry.id))) end
        if total == 0 then return send_batches(now) end
        local ps, us, err = read_both()
        if not ps then return fail(err) end
        if not room_ok(us, build_rneed(map, capmap(io, us, ps)), 0) then
            return stall(("the unit inventory is full, empty it and Build again (container id %s holds items)"):format(tostring(entry.id)))
        end
        local sent = 0
        for i, s in ipairs(read.slots or {}) do
            if (s.item or "") ~= "" and (s.amount or 0) > 0 then
                sent = sent + 1
                if not send_move(read.id, R.unit_inv, i, "cempty") then return fail("InventoryInput refused") end
            end
        end
        R.stage = 10
        R.t_stage = now
        R.t_next = now + POLL_MS
        R.emp = { entry = entry, slots = sent }
        set_status("working", ("emptying container id %s into the unit"):format(tostring(entry.id)))
    end

    -- stage 10: the container's items must leave it. Empty -> it is an ItemCost-only removal (send_batches).
    local function empty_wait(now)
        local e = R.emp
        local map, total, inv = contents_of(e.entry)
        if not map then return fail(("container id %s cannot be read, Build again"):format(tostring(e.entry.id))) end
        if total == 0 then
            R.emp = nil
            return send_batches(now)
        end
        if now - R.t_stage >= DRAIN_MS then
            local n_now = 0
            for _, s in ipairs(inv.slots or {}) do
                if (s.item or "") ~= "" and (s.amount or 0) > 0 then n_now = n_now + 1 end
            end
            if n_now == e.slots then
                return stall("the game did not move the container items (see bpu_trace.log: ourcmd recv must equal uicmd recv)")
            end
            return stall("the unit inventory is full, empty it and Build again")
        end
        R.t_next = now + POLL_MS
    end

    -- next batch: the longest run of removals from rem_pos whose cumulative refund fits the player inventory
    -- (RESERVE + carriers in the batch, up to CARRY_CAP, empty slots kept back). A container with items ends the batch:
    -- at the head it is returned as the third value (emptied first), later it waits for its turn.
    -- Returns the last index (rem_pos - 1 = none), the batch refund map, the head container, and a stall text (unreadable head).
    local function pick_batch(ps, us)
        local maxOf = capmap(io, ps, us)
        local cum, to, ncar = {}, R.rem_pos - 1, 0
        for k = R.rem_pos, #R.rem_list do
            local e = R.rem_list[k]
            local c, total = contents_of(e)
            if c == false then
                if k == R.rem_pos then return to, cum, nil, ("container id %s cannot be read, Build again"):format(tostring(e.id)) end
                break
            end
            if total > 0 then
                if k == R.rem_pos then return to, cum, e end
                break
            end
            local trial = {}
            for item, v in pairs(cum) do trial[item] = v end
            for item, v in pairs(e.refund) do trial[item] = get(trial, item) + v end
            local nc = ncar + (is_carrier(e.bcls) and 1 or 0)
            if not room_ok(ps, build_rneed(trial, maxOf), RESERVE + math.min(nc, CARRY_CAP)) then break end
            cum, to, ncar = trial, k, nc
        end
        trace(("pick: n=%d carriers=%d reserve=%d"):format(to - R.rem_pos + 1, ncar, RESERVE + math.min(ncar, CARRY_CAP)))
        return to, cum
    end

    -- sends removal batches. A batch with refund waits for it (stage 2). A batch without refund: the next one at once.
    -- Stops at a wait, a stall, or after the last removal (after_removals).
    send_batches = function(now)
        while R.rem_pos <= #R.rem_list do
            local ps, us, err = read_both()
            if not ps then return fail(err) end
            local to, cum, head, bad = pick_batch(ps, us)
            if bad then return stall(bad) end
            if to < R.rem_pos then
                if head then return start_empty(now, head) end
                local m = R.rem_list[R.rem_pos]
                return stall(("the refund of %s (id %s) does not fit the player inventory, empty your inventory and Build again"):format(m.bcls, tostring(m.id)))
            end
            local refused = 0
            for k = R.rem_pos, to do
                if io.send_remove(R.rem_list[k].id) then
                    R.removed = R.removed + 1
                    R.removed_list[#R.removed_list + 1] = R.rem_list[k].id
                else
                    refused = refused + 1
                end
            end
            R.rem_pos = to + 1
            if refused > 0 then return fail(("removal refused for %d machines"):format(refused)) end
            R.t_removed = now
            R.removal_confirmed = false
            R.batch_refund, R.batch_set = cum, moveset(cum, R.plan.need)
            R.rem_before = totals(ps)
            set_status("working", ("removing %d of %d machines"):format(R.removed, #R.rem_list))
            if any_refund(cum) then
                R.stage = 2
                R.t_stage = now
                R.t_next = now + POLL_MS
                return
            end
        end
        return after_removals(now)
    end

    local builder = {}

    -- start(plan, opts): checks station, totals, creative; sends the first removal batch. Nothing is sent on a refusal.
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
        -- staleness: a fingerprint failure is traced and treated as ok; a mismatch refuses the build
        local fok, fpv = pcall(io.fingerprint, ex)
        if not fok then
            trace("fingerprint failed, staleness check skipped: " .. tostring(fpv))
        elseif fpv ~= P.fp then
            return start_fail("station changed since import, import again")
        end
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
        for _, m in ipairs(P.removed) do
            -- per-machine refund is what the batches are sized by: without it a batch could overflow the player
            if type(m.refund) ~= "table" then return start_fail("refund unknown for " .. tostring(m.bcls) .. ", import again") end
            R.rem_list[#R.rem_list + 1] = { id = m.id, bcls = m.bcls, refund = m.refund }
        end
        if #P.place == 0 and #P.removed == 0 and #P.chg == 0 then
            R.state = "done"
            R.text = "nothing to build"
            return true, "ok nothing to build"
        end

        R.active = true
        R.overlap = overlaps(P.removed, P.place)
        if #R.rem_list > 0 then
            send_batches(now)   -- first batch sent here (a refusal before any command: start returns false)
        else
            chunk_start(now)    -- no removal: the placements go back to back
        end
        if R.state == "error" then return false, "error: " .. R.text end
        return true, "ok build started"
    end

    -- tick(now_ms): one step when t_next has passed. Call every 250-500 ms.
    function builder:tick(now)
        if not R.active or now < R.t_next then return end
        if now - R.t_start > TOTAL_MS then return fail("timeout after 300 s") end
        local s = R.stage
        if s == 2 then arrival_wait(now)
        elseif s == 4 or s == 9 then chunk_start(now)
        elseif s == 5 then staging_wait(now)
        elseif s == 6 then charge_wait(now)
        elseif s == 8 then drain_wait(now)
        elseif s == 10 then empty_wait(now)
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
            recipe = P and P.recChanged or 0, moved_in = R.moved_in,
            chunk = R.chunks_done .. "/" .. R.chunks,
        }
    end

    return builder
end

-- pure helpers, exposed for the tests
B.pure = {
    totals = totals, maxes = maxes, list = list, shortfall = shortfall, total_check = total_check,
    stage_moves = stage_moves, refund_fit = refund_fit, room_ok = room_ok, chunk_len = chunk_len,
    overlaps = overlaps,
}

return B
