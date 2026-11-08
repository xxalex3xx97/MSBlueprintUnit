-- bpu_build: pure Lua port of the bp_build flow (mb_bpprobe.hpp: bb_* helpers, bp_build_cmd, bp_build_tick).
-- No game globals. Every game call goes through the injected `io` table (see B.new).
-- Lua side: slots and machines are 1-based. io.send_move gets the 0-based game slot index.
-- Items are matched by item name (ITEM_HullPlate), same keys as plan.need / plan.refund.
-- Two flows, chosen at start() by io.redirect_status() (MSCore 0.7.5 refund/charge redirect, string starting with 'on'):
--   redirect: refunds land in the unit and the build charge takes unit first, player second. After the checks every
--     DisassembleInput then every BuildInput is sent FIFO, at most CMD_PER_TICK per tick, no waits (only SETTLE_MS once
--     between the last removal and a placement when a placement overlaps a removed machine). Done after the last send.
--   legacy (old MSCore / redirect off): the staged flow below, untouched.
-- Checks run in start() before the first command. Removals go in batches sized by the free player room (a refund lands in
-- the player inventory): a batch waits for its refund, moves the unneeded refund to the unit, the next batch waits for that
-- room to come back. A stall ends the run with a note. After the last command the run is done.
-- Waits only where a later command needs an earlier one applied: staged items before the BuildInputs that charge them,
-- a removal before a placement on the same cell, the charge before the next chunk (frees player space).
-- Restore (both flows, after the last placement): containers with plan.restore get their items from the unit inventory.
-- Split route (io.split present, MSCore 0.7.6): the unit is sorted first (SORT, action 5, then settle), then each piece is
-- exact: a whole unit slot is one TRANSFER (action 2); a part of a slot is io.split into a free unit slot, then one TRANSFER.
-- Rounded route (no io.split, older MSCore): whole-stack TRANSFERs (action 2) only, rounded to the nearest stack
-- (see the restore section); no SORT. Commands go out FIFO, RESTORE_CMD_PER_TICK per tick, no waits between them;
-- then one verify with a progress stall check (STALL_MS). Restore is on unless
-- Mods/BlueprintUnit/restore_off.txt exists or the Chk_Restore checkbox is unchecked (io.restore_mode, opts.restore).
-- Shortages and full containers are noted; a Build never fails because of contents. Steps are traced in bpu_trace.log.

local B = {}

local TOTAL_MS = 300000   -- whole run
local STAGE_MS = 3000     -- staging round stalls after this
local CHARGE_MS = 5000    -- chunk charge (needed before the next chunk only) must show within this
local REFUND_MAX_MS = 2000   -- removal batch: its refund must show in the player inventory within this, else STALL
local DRAIN_MS = 2000        -- refund moved to the unit must leave the player within this (not after the last batch), else STALL
local SETTLE_MS = 500        -- last removal before a placement on its cell, not confirmed by a refund: settle from the send
local POLL_MS = 250
local CMD_PER_TICK = 150         -- redirect flow: commands sent per tick (FIFO), never the whole plan in one frame
local RESTORE_CMD_PER_TICK = 1000 -- restore pipeline: TRANSFER commands sent per tick (FIFO, no waits between them)
local PIPE_POLL_MS = 2000    -- restore pipeline: verify poll (unit read + unconfirmed containers only), not every 250 ms
local RETRY_MAX = 5          -- restore: a refused send is retried on the next tick this many times, then the restore stops
local RESERVE = 1            -- empty player slots kept back from every removal batch (safety margin)
local CARRY_CAP = 6          -- carriers in a batch add 1 reserved slot each, up to this many
local CONT_MS = 60000        -- restore: new container ids and ready containers must show within this after the last placement
local STALL_MS = 8000       -- restore: no change in the restored items for this long after the last send -> STALL (never a fixed wait)
local CONT_READY_POLLS = 2   -- restore: container contents readable on this many polls in a row before the first step
local RESTORE_MS = 300000    -- restore: whole restore phase cap
local SORT_SETTLE_MS = 1500  -- split route: unit inventory unchanged for this long after the SORT -> settled
local SORT_MS = 15000        -- split route: SORT wait cap (still changing after this -> go on)
local CFG_MS = 120000        -- config check (stage 17): placed machines must show in the raw game view within this (= bpu_live OV_MS)

local function get(m, k) return m[k] or 0 end

local function sorted_keys(m)
    local ks = {}
    for k in pairs(m) do ks[#ks + 1] = k end
    table.sort(ks)
    return ks
end

-- slot = { item = "ITEM_X" | "", amount = n, max = stack size }. Empty slot: item "".
-- nil amount counts as 0; the first one per run is traced (nil_hook, set by B.new) with the caller, so the source shows.
local nil_hook = nil
local function totals(slots)
    local t = {}
    for i, s in ipairs(slots) do
        local item, amount = s.item or "", s.amount
        if amount == nil and item ~= "" and nil_hook then nil_hook(i, item) end
        amount = amount or 0
        if item ~= "" and amount > 0 then t[item] = get(t, item) + amount end
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

-- Effective MaxStackSize per item in one inventory (inv = normalized slots): io.item_max (raw) * StackMultiplier.
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

-- progress text (status line): "[#####-----] 50%" (10 cells); commas: "1,234"
local function pct_of(done, total) return total > 0 and math.floor(done * 100 / total + 0.5) or 100 end
local function commas(n)
    local s = tostring(math.floor(n))
    local r = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (r:gsub("^,", ""))
end
local function bar(done, total)
    local pct = pct_of(done, total)
    local n = math.floor(pct / 10 + 0.5)
    return ("[%s%s] %d%%"):format(("#"):rep(n), ("-"):rep(10 - n), pct)
end
-- "restoring [#####-----] 50%  (1,234 of 2,468 commands)<tail>"
local function progress(done, total, tail)
    return ("restoring %s  (%s of %s commands)%s"):format(bar(done, total), commas(done), commas(total), tail or "")
end

-- restore model (pipeline): where n items of item go into slots: same-item stacks below cap first, then empty slots.
-- groups = { {slot=, n=} } in fill order, left = items that do not fit. Does not change slots.
local function sim_put(slots, item, n, cap)
    local groups = {}
    for i, s in ipairs(slots) do
        if n <= 0 then break end
        if s.item == item and s.amount > 0 and s.amount < cap then
            local k = math.min(cap - s.amount, n)
            groups[#groups + 1] = { slot = i, n = k }
            n = n - k
        end
    end
    for i, s in ipairs(slots) do
        if n <= 0 then break end
        if s.amount <= 0 then
            local k = math.min(cap, n)
            groups[#groups + 1] = { slot = i, n = k }
            n = n - k
        end
    end
    return groups, n
end

-- free room for one more item (cap per slot): below-cap stacks of the item, then empty slots
local function room_of(slots, item, cap)
    local r = 0
    for _, s in ipairs(slots) do
        if s.amount <= 0 then r = r + cap
        elseif s.item == item and s.amount < cap then r = r + cap - s.amount end
    end
    return r
end

-- applies sim_put groups to the model slots
local function sim_apply(slots, item, groups)
    for _, g in ipairs(groups) do
        local s = slots[g.slot]
        s.item, s.amount = item, s.amount + g.n
    end
end

-- true when both item maps (item -> amount) are equal
local function same_totals(a, b)
    for k, v in pairs(a) do if get(b, k) ~= v then return false end end
    for k, v in pairs(b) do if get(a, k) ~= v then return false end end
    return true
end

local function copy_slots(inv)
    local o = { mult = inv.mult }
    for i, s in ipairs(inv) do o[i] = { item = s.item, amount = s.amount, max = s.max } end
    return o
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

-- a container (its contents are restored after the Build)
local function is_container(bcls)
    return tostring(bcls or ""):find("Container", 1, true) ~= nil
end

-- cell key of container memory: bcls|x|y|h|rot (same format as bpu_plan)
local function ckey(e)
    return tostring(e.bcls) .. "|" .. tostring(e.x) .. "|" .. tostring(e.y) .. "|" .. tostring(e.h) .. "|" .. tostring(e.rot)
end

local function shortname(item) return (item:gsub("^ITEM_", "")) end

-- inventory map (item -> amount) as list {name, count}, item order
local function as_list(map)
    local out = {}
    for _, k in ipairs(sorted_keys(map)) do
        if map[k] > 0 then out[#out + 1] = { name = k, count = map[k] } end
    end
    return out
end

local function new_run(plan)
    return {
        plan = plan, active = false, state = "idle", text = "", stage = 0, flow = "legacy",
        cids_before = {}, cplaced = {}, base = "",   -- restore: container ids before the Build, placed containers in order, text of the Build part
        rjobs = {}, jobs_set = false, cready = 0, rnotes = {}, rseen = {}, rcount = 0, rcont = 0,
        restore_on = false, t_restore = 0, ui_restore = nil, t_progress = 0, pipe_sig = nil,
        queue = {}, qpos = 1, nrem = 0,
        stage_rounds = 0, overlap = false,
        t_next = 0, t_start = 0, t_stage = 0,
        unit_inv = 0, player_inv = 0, creative = false, chg_sent = false, chg_failed = 0,
        rem_list = {}, rem_pos = 1, batch_refund = {}, batch_set = {}, t_removed = 0, removal_confirmed = false,
        drain = {}, costs = {}, emp = nil,   -- rem_list = { {id, bcls, refund = cost map} } in removal order; batch = rem_pos..last sent
        chunk_from = 1, chunk_to = 1, counted_from = nil, chunks = 0, chunks_done = 0,
        chunk_need = {}, before = {}, rem_before = {}, snap = {}, issued = {},
        placed = 0, removed = 0, moved_in = 0, refund_moved = false,
        placed_list = {}, removed_list = {},   -- machines actually sent (io.note_build: live overlay)
        cfg_want = {}, t_cfg = 0, base_text = "", marked = false,   -- config check (stage 17): placed machines with a config
    }
end

-- io (injected, plain Lua values). Every send_* returns true when the game accepted it.
--   io.scan(station) -> machines {id,bcls,x,y,...} | nil, err
--   io.fingerprint(machines) -> same value as plan.fp (bpu_plan fingerprint); a failure is traced, never blocks
--   io.read_inv('player'|'unit') -> { slots = { {item=,amount=,max=} | {item=""} }, id=, ok= }
--   io.unit_ids() -> { unit_id=, player_id= }     io.creative() -> bool     io.costs(place) -> { cost map per machine }
--   io.send_remove(id) | io.send_move(prim_id, sec_id, slot0, action) | io.send_place(machine) | io.send_changes(chg)
--   restore only: io.send_inv(prim, sec, slot0, action) (one raw command: TRANSFER 2; SORT 5 on the unit, split route only)
--   | io.container_ids() -> ids
--   restore split route (optional, MSCore 0.7.6): io.split(inv, src0, amount, dst0) -> ok, err. Local edit of one inventory,
--   not a game command. Present = split route (stage 13 SORT, then exact pieces); absent = rounded whole-stack route.
--   io.restore_mode() -> "on" | "off" (optional; absent = "on"). builder:start(plan, { restore = true|false|nil }): the checkbox
--   io.remember(cell_key, list {name,count}) (optional, session memory of removed containers) | io.read_machine_inv(id) (contents)
--   io.now() -> ms
--   io.note_build(placed, removed) optional: run end with machines placed (plan entries) / removed (live ids)
--   io.scan_raw(station) optional: raw station machines (no overlay, has cfg); config check after the run (stage 17)
--   io.trace(text) optional: diagnostics only
-- plan (from bpu_plan): station, fp, place, kept, chg, removed={ {id=,bcls=,x=,y=} }, need, refund (ITEM -> n), recChanged, valid.
function B.new(io)
    local R = new_run(nil)

    local function counts()
        return ("placed %d, removed %d, moved_in %d"):format(R.placed, R.removed, R.moved_in)
    end
    local function set_status(state, text) R.state = state; R.text = text end
    local function trace(msg) if io.trace then io.trace(msg) end end
    local nil_traced = false
    nil_hook = function(i, item)   -- totals() saw a nil amount: once per run, with the caller (level 3 = caller of totals)
        if nil_traced then return end
        nil_traced = true
        local info = debug.getinfo(3, "Sl")
        trace(("totals: nil amount at slot %d item %s, caller %s:%s"):format(i, item,
            info and info.short_src or "?", info and tostring(info.currentline) or "?"))
    end
    -- any end (done, error, cancel) with placed or removed machines: io.note_build keeps them as a live overlay
    local function mark_changed()
        if R.marked then return end   -- once per run (end_run, then a cancel in the config check must not add a second batch)
        R.marked = true
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
        local slots = { mult = inv.mult or 1 }   -- StackMultiplier of this inventory (capmap)
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
            local _, failc = io.send_changes(R.plan.chg)
            R.chg_failed = failc or 0
            R.chg_sent = true
        end
    end

    -- config part of the status text: "; N recipe/port change(s) failed". Empty when all changes went through.
    local function chg_suffix()
        if R.chg_failed > 0 then return ("; %d recipe/port change(s) failed"):format(R.chg_failed) end
        return ""
    end

    -- restore part of the status text: "; restore: restored N items into K container(s); notes". Empty when no restore ran.
    local function restore_suffix()
        if not R.restore_on then return "" end
        local parts = {}
        if R.rcount > 0 then parts[#parts + 1] = ("restored %s items into %s container(s)"):format(R.rcount, R.rcont) end
        for _, n in ipairs(R.rnotes) do parts[#parts + 1] = n end
        if #parts == 0 then return "" end
        return "; restore: " .. table.concat(parts, "; ")
    end

    -- the run ends with base (the Build text) + restore part. Placed machines with a config go to the config check
    -- (stage 17) first; the run is done after it.
    local function end_run(base)
        R.base_text = base .. restore_suffix() .. chg_suffix()
        mark_changed()
        R.cfg_want = {}
        if io.scan_raw then
            for _, pl in ipairs(R.placed_list) do
                if pl.cfg and pl.cfg ~= "" and not tostring(pl.bcls):lower():find("underground", 1, true) then   -- underground cfg is never in the game view
                    R.cfg_want[#R.cfg_want + 1] = pl
                end
            end
        end
        if #R.cfg_want > 0 then
            R.stage = 17
            R.t_cfg = io.now()
            R.t_next = R.t_cfg + PIPE_POLL_MS
            set_status("working", R.base_text .. "; checking the machine configs in the game")
            return
        end
        R.active = false
        R.stage = 0
        R.state = "done"
        R.text = R.base_text
    end

    -- Build text of the legacy flow
    local function legacy_text()
        if R.refund_moved then
            return ("sent: placed %d, removed %d, refund moved to the unit (the game updates its blueprint view in about 30 s)"):format(R.placed, R.removed)
        end
        return ("sent: placed %d, removed %d (the game updates its blueprint view in about 30 s)"):format(R.placed, R.removed)
    end

    -- last command sent (legacy, no restore): the run is done at once (no charge poll, no verify)
    local function finish()
        send_changes_once()
        end_run(legacy_text())
    end

    -- all placements sent: with containers that have contents to restore, wait for their new ids (stage 12); else done
    local function after_place(now, base)
        send_changes_once()
        R.base = base
        R.cplaced = {}
        local want = 0
        for _, pl in ipairs(R.placed_list) do
            if is_container(pl.bcls) then
                R.cplaced[#R.cplaced + 1] = pl
                if pl.restore and #pl.restore > 0 then want = want + 1 end
            end
        end
        if want == 0 then return end_run(base) end
        local mode = io.restore_mode and io.restore_mode() or "on"
        if R.ui_restore == false and mode == "on" then mode = "off" end   -- Chk_Restore unchecked
        R.restore_on = true
        if mode == "off" then
            R.rnotes[#R.rnotes + 1] = R.ui_restore == false and "restore is off (Chk_Restore unchecked)" or "restore is off (restore_off.txt in Mods/BlueprintUnit)"
            return end_run(base)
        end
        R.stage = 12
        R.t_stage = now
        R.t_next = now + POLL_MS
        set_status("working", "restoring container contents: waiting for the new containers")
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
        if last then return after_place(now, legacy_text()) end
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
                    return stall("the game did not apply the move (see bpu_trace.log)")
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
                return stall("the game did not move the container items (see bpu_trace.log)")
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

    -- ===== redirect flow: send everything, no waits =====
    -- queue = removals (live ids) then placements (plan entries). One slice of CMD_PER_TICK per call; true when anything was sent.
    local function send_queue(now)
        local q = R.queue
        local sent = 0
        while R.qpos <= #q and sent < CMD_PER_TICK do
            local c = q[R.qpos]
            if c.rm then
                if not io.send_remove(c.rm) then return fail("removal refused for machine id " .. tostring(c.rm)) end
                R.removed = R.removed + 1
                R.removed_list[#R.removed_list + 1] = c.rm
                R.t_removed = now
            else
                -- a placement on a removed cell waits once for the removals (SETTLE_MS from the last one)
                if R.overlap and R.removed > 0 and now < R.t_removed + SETTLE_MS then
                    R.t_next = R.t_removed + SETTLE_MS
                    return
                end
                send_changes_once()
                if not io.send_place(c.pl) then return fail(("BuildInput refused for the machine at %s,%s"):format(tostring(c.pl.x), tostring(c.pl.y))) end
                R.placed = R.placed + 1
                R.placed_list[#R.placed_list + 1] = c.pl
            end
            R.qpos = R.qpos + 1
            sent = sent + 1
        end
        if R.qpos > #q then
            R.chunks, R.chunks_done = 1, 1
            return after_place(now, ("sent: placed %d, removed %d (refund goes into the unit; the game updates its blueprint view in about 30 s)"):format(R.placed, R.removed))
        end
        set_status("working", ("sending commands: %d of %d (%d%%)"):format(R.qpos - 1, #q, pct_of(R.qpos - 1, #q)))
        R.stage = 11
        R.t_next = now   -- next slice on the next tick, no waiting
    end

    -- ===== restore container contents (after the last placement, both flows) =====
    -- TRANSFER only (action 2): Primary = unit inventory, Secondary = container INVENTORY id, SlotIndex = unit slot.
    -- No cursor, no TAKE (0), no PLACE_SINGLE (1), no put-back: the game never holds an item during the restore.
    -- Split route (io.split present): stage 13 sorts the unit (SORT, action 5: the only non-TRANSFER command, see
    -- io.send_inv) and waits until it settles. Stage 15 plans exact pieces: a whole unit slot is one TRANSFER; a part of
    -- a slot is io.split into a free unit slot (local edit, not a game command), then one TRANSFER of that slot.
    -- Rounded route (no io.split, older MSCore): the rounding below.
    -- Rounding per container item (need = count, unit slots in slot order, a = slot amount): a slot is moved when
    -- 2*need >= a (the whole stack goes in, rounds up), skipped when 2*need < a (rounds down; the next slot is looked at).
    -- A move is capped by the container room: moved = min(a, room). A partial move leaves the rest in the unit.
    -- The item stops at need <= 0, when the container has no room, or when no unit slot is left. Nothing is dropped
    -- silently: every shortage has a note.
    -- Stage 12: new container ids (not in cids_before, ascending) are matched to the placed containers in placement order.
    -- Probe: only the first item of the first container with contents, at most 5 (same rounding).
    -- Stage 15: the plan is built from one fresh read and sent FIFO, RESTORE_CMD_PER_TICK per tick, no waits between commands.
    -- Stage 16: verify (restored items only). No change for STALL_MS after the last send -> STALL note, nothing more sent.
    -- Hard cap: RESTORE_MS from the start of the restore phase.

    -- stage 12: new container ids (not in cids_before, ascending) are matched to the placed containers in placement order.
    local function cont_wait(now)
        if not R.jobs_set then
            local ids = io.container_ids and io.container_ids() or {}
            local new = {}
            for _, id in ipairs(ids) do if not R.cids_before[id] then new[#new + 1] = id end end
            table.sort(new)
            if #new ~= #R.cplaced then
                R.cready = 0
                if now - R.t_stage >= CONT_MS then
                    R.rnotes[#R.rnotes + 1] = ("restore stalled: container ids not found (new %s, placed %s)"):format(#new, #R.cplaced)
                    return end_run(R.base)
                end
                R.t_next = now + POLL_MS
                return
            end
            trace("restore: new container ids " .. (#new > 0 and table.concat(new, ",") or "none") .. " for the placed containers in order")
            local jobs = {}
            for i, pl in ipairs(R.cplaced) do
                if pl.restore and #pl.restore > 0 then jobs[#jobs + 1] = { id = new[i], items = pl.restore } end
            end
            R.rjobs, R.jobs_set = jobs, true
        end
        local ready = true
        for _, job in ipairs(R.rjobs) do
            local inv = io.read_machine_inv and io.read_machine_inv(job.id)
            if not (inv and inv.ok and #(inv.slots or {}) > 0) then ready = false end
        end
        R.cready = ready and R.cready + 1 or 0
        if R.cready >= CONT_READY_POLLS then
            R.t_restore = now
            if io.split then
                R.stage, R.t_stage = 13, now   -- split route: sort the unit first
                R.t_next = now
                set_status("working", "sorting the unit inventory")
                return
            end
            R.stage = 15   -- plan + send
            R.t_next = now
            set_status("working", "restoring container contents")
            return
        end
        if now - R.t_stage >= CONT_MS then
            R.rnotes[#R.rnotes + 1] = ("restore stalled: container ids not found (new %s, placed %s)"):format(#R.rjobs, #R.cplaced)
            return end_run(R.base)
        end
        R.t_next = now + POLL_MS
    end

    local function slots_text(slots)
        local parts = {}
        for _, s in ipairs(slots) do
            local item, amount = s.item or "", s.amount or 0
            parts[#parts + 1] = (item ~= "" and amount > 0) and (shortname(item) .. ":" .. amount) or "-"
        end
        return table.concat(parts, " ")
    end
    local function rs_note(text) R.rnotes[#R.rnotes + 1] = text end
    -- end of the restore phase
    local function restore_end()
        -- unit stacks at the end (read only: a failed read is not an error here)
        if io.read_inv then
            local ps2, us2 = read_both()
            if ps2 then trace("restore unit stacks (end): " .. slots_text(us2)) end
        end
        if (R.skipped or 0) > 0 then rs_note(("%s command(s) skipped (refused)"):format(R.skipped)) end
        end_run(R.base)
    end
    -- rcount / rcont (containers that got items, by container id)
    local function delivered(n, id)
        R.rcount = R.rcount + n
        if n > 0 and not R.rseen[id] then R.rseen[id] = true; R.rcont = R.rcont + 1 end
    end
    -- stage 13 (split route): SORT the unit inventory (action 5, primary = unit, secondary 0, slot 0), then wait until the
    -- unit shows no change for SORT_SETTLE_MS (cap SORT_MS from the stage start). A refused SORT is retried, then the restore goes on.
    local function unit_sig(us)
        local parts = {}
        for i, s in ipairs(us) do parts[i] = s.item .. ":" .. s.amount end
        return table.concat(parts, ",")
    end
    local function sort_go(now)
        R.stage, R.t_next = 15, now
        set_status("working", "restoring container contents")
    end
    local function sort_wait(now)
        if now - R.t_restore > RESTORE_MS then
            rs_note("restore stalled: timeout after 300 s")
            return restore_end()
        end
        if not R.sort_sent then
            local ok, err = io.send_inv(R.unit_inv, 0, 0, 5)
            if not ok then
                R.fails = (R.fails or 0) + 1
                trace(("restore sort: SORT refused (attempt %s, error: %s)"):format(R.fails, tostring(err)))
                if R.fails <= RETRY_MAX then R.t_next = now; return end
                R.fails = 0
                rs_note("unit not sorted (SORT refused)")
                return sort_go(now)
            end
            R.fails, R.sort_sent, R.sort_sig, R.sort_t = 0, true, nil, now
            trace("restore sort: SORT sent (action 5, primary=unit inventory)")
            R.t_next = now + POLL_MS
            return
        end
        local ps, us, err = read_both()
        if not ps then return fail(err) end
        local sig = unit_sig(us)
        if sig ~= R.sort_sig then R.sort_sig, R.sort_t = sig, now end
        if now - R.sort_t >= SORT_SETTLE_MS then
            trace("restore sort: unit settled")
            return sort_go(now)
        end
        if now - R.t_stage >= SORT_MS then
            trace("restore sort: cap reached, still changing, going on")
            return sort_go(now)
        end
        R.t_next = now + POLL_MS
    end

    -- split route: lowest-index empty unit slot not already used as staging in this plan (ponytail: ceiling = free unit slots, no reuse)
    local function empty_dst(um, used)
        for i, s in ipairs(um) do
            if s.amount <= 0 and not used[i] then return i end
        end
        return nil
    end

    -- stage 15 plan, split route (same shape as pipe_build). Per container item: need = count (the unit total caps it).
    -- Unit slots in slot order: take = min(slot amount, need, container room). take == slot -> one TRANSFER of that slot.
    -- take < slot -> split { src0, take, dst0 } into a free empty unit slot, then one TRANSFER of dst0 (pair links them).
    local function pipe_build_split(us)
        local pq, pm = {}, { unit = copy_slots(us), touched = {}, jobs = {}, split = true, full = {} }
        local um = pm.unit
        local used, npair = {}, 0
        for _, job in ipairs(R.rjobs) do
            local map, _, cinv = contents_of(job)
            local cid = cinv and cinv.id
            if not map then
                rs_note(("container id %s cannot be read"):format(tostring(job.id)))
            elseif cid == nil or cid == job.id or cid == R.unit_inv or cid == R.player_inv then
                -- a machine id or an unknown id is never a command target (the game derefs a null inventory)
                rs_note(("container id %s: inventory id unknown, not restored"):format(tostring(job.id)))
            else
                local cn = norm(cinv)
                local cmax = capmap(io, cn, um)
                local jm = { id = job.id, slots = cn, short = {}, moved = 0 }
                pm.jobs[#pm.jobs + 1] = jm
                for _, it in ipairs(job.items) do
                    local need = it.count
                    local have = get(totals(um), it.name)
                    if have < need then
                        rs_note(("plan reduced: unit has %s of %s for %s (short %s)"):format(commas(have), commas(it.count), shortname(it.name), commas(it.count - have)))
                        jm.short[#jm.short + 1] = { name = it.name, count = need - have }
                        need = have
                    end
                    pm.touched[it.name] = true
                    local cap, moved_item, nsplit, why = cmax[it.name], 0, 0, nil
                    for i, s in ipairs(um) do
                        if need <= 0 or why then break end
                        if s.item == it.name and s.amount > 0 then
                            local room = room_of(cn, it.name, cap)
                            if room <= 0 then break end
                            local take = math.min(s.amount, need, room)
                            local dst = i
                            if take < s.amount then
                                dst = empty_dst(um, used)
                                if not dst then why = "noslot"; break end
                                used[dst] = true
                                npair, nsplit = npair + 1, nsplit + 1
                                pq[#pq + 1] = { kind = "split", src = i - 1, amount = take, dst = dst - 1, pair = npair,
                                    job = job.id, item = it.name, moved = take }
                            end
                            pq[#pq + 1] = { kind = "transfer", prim = R.unit_inv, sec = cid, slot0 = dst - 1, action = 2,
                                pair = (dst ~= i) and npair or nil, job = job.id, item = it.name, moved = take }
                            -- the TRANSFER empties dst only when the game ticks, but io.split acts at once: a slot a queued
                            -- TRANSFER touches is never a split destination in this pass (else "split into a non-empty slot")
                            used[dst] = true
                            sim_apply(cn, it.name, sim_put(cn, it.name, take, cap))
                            s.amount = s.amount - take   -- the staged part left the slot (split), or the whole slot went (TRANSFER)
                            if s.amount <= 0 then s.item, s.amount = "", 0 end
                            need, moved_item = need - take, moved_item + take
                        end
                    end
                    jm.moved = jm.moved + moved_item
                    if need > 0 then
                        if why == "noslot" then
                            rs_note(("%s x%s not restored (no free unit slot)"):format(shortname(it.name), need))
                        elseif room_of(cn, it.name, cap) <= 0 then
                            pm.full[#pm.full + 1] = { id = job.id, item = it.name, left = need }
                        end
                    end
                    trace(("restore plan (split): container id=%s item=%s count=%s splits=%s moved=%s short=%s"):format(
                        tostring(job.id), it.name, tostring(it.count), tostring(nsplit), tostring(moved_item), tostring(math.max(need, 0))))
                end
            end
        end
        return pq, pm
    end

    -- stage 15 plan: TRANSFER commands from one fresh read (models of the unit and of each container). Nothing is sent here.
    -- pm = { unit = model slots, touched = { item = true }, jobs = { {id, slots = model, short = {}, moved = n} } }
    local function pipe_build(us)
        if io.split then return pipe_build_split(us) end
        local pq, pm = {}, { unit = copy_slots(us), touched = {}, jobs = {}, full = {} }
        local um = pm.unit
        local function add(prim, sec, slot0, job_id, item, moved)
            pq[#pq + 1] = { kind = "transfer", prim = prim, sec = sec, slot0 = slot0, action = 2, job = job_id, item = item, moved = moved }
        end
        for _, job in ipairs(R.rjobs) do
            local map, _, cinv = contents_of(job)
            local cid = cinv and cinv.id
            if not map then
                rs_note(("container id %s cannot be read"):format(tostring(job.id)))
            elseif cid == nil or cid == job.id or cid == R.unit_inv or cid == R.player_inv then
                -- a machine id or an unknown id is never a command target (the game derefs a null inventory)
                rs_note(("container id %s: inventory id unknown, not restored"):format(tostring(job.id)))
            else
                local cn = norm(cinv)
                local cmax = capmap(io, cn, um)
                local jm = { id = job.id, slots = cn, short = {}, moved = 0 }
                pm.jobs[#pm.jobs + 1] = jm
                for _, it in ipairs(job.items) do
                    local have = get(totals(um), it.name)
                    if have < it.count then
                        rs_note(("%s x%s not restored (unit has %s)"):format(shortname(it.name), it.count, have))
                    else
                        pm.touched[it.name] = true
                        local cap, need, nmoves, moved_item = cmax[it.name], it.count, 0, 0
                        for i, s in ipairs(um) do
                            if need <= 0 then break end
                            if s.item == it.name and s.amount > 0 and 2 * need >= s.amount then
                                local room = room_of(cn, it.name, cap)
                                if room <= 0 then break end
                                local moved = math.min(s.amount, room)
                                add(R.unit_inv, cid, i - 1, job.id, it.name, moved)
                                local groups = sim_put(cn, it.name, moved, cap)
                                sim_apply(cn, it.name, groups)
                                s.amount = s.amount - moved
                                if s.amount <= 0 then s.item, s.amount = "", 0 end
                                need, nmoves, moved_item = need - moved, nmoves + 1, moved_item + moved
                            end
                        end
                        if need > 0 then
                            jm.short[#jm.short + 1] = { name = it.name, count = need }
                            local left_slot = false
                            for _, s in ipairs(um) do if s.item == it.name and s.amount > 0 then left_slot = true break end end
                            if room_of(cn, it.name, cap) <= 0 then
                                pm.full[#pm.full + 1] = { id = job.id, item = it.name, left = need }
                            elseif left_slot then
                                rs_note(("%s x%s left out (under half a unit stack)"):format(shortname(it.name), need))
                            else
                                rs_note(("%s x%s not restored (unit has %s)"):format(shortname(it.name), need, get(totals(um), it.name)))
                            end
                        end
                        jm.moved = jm.moved + moved_item
                        trace(("restore plan: container id=%s item=%s count=%s moves=%s moved=%s short=%s"):format(
                            tostring(job.id), it.name, tostring(it.count), tostring(nmoves), tostring(moved_item), tostring(math.max(need, 0))))
                    end
                end
            end
        end
        return pq, pm
    end

    -- the model matches the game. Unit: the restored items equal the model. Container (confirmed once, not read again):
    -- at least the model amount of every touched item (lower bound, so live inflow of the same item does not block it).
    -- sig = unit totals of the touched items + unit slots. Container totals are not in it: inflow never resets the stall clock.
    -- detail = first unconfirmed container (expected vs got per touched item) and the unit when it differs; for traces/notes.
    local function geq(t, e)
        for k, v in pairs(e) do if t[k] < v then return false end end
        return true
    end
    local function pipe_state(us)
        local names = sorted_keys(R.pm.touched)
        local function only(t) local o = {} for _, k in ipairs(names) do o[k] = get(t, k) end return o end
        local function rows(act, exp)
            local o = {}
            for _, k in ipairs(names) do o[#o + 1] = ("%s exp %s got %s"):format(shortname(k), tostring(exp[k]), tostring(act[k])) end
            return table.concat(o, ", ")
        end
        local uT = only(totals(us))
        local parts, why, udet, cdet = {}, nil, nil, nil
        for _, k in ipairs(names) do parts[#parts + 1] = k .. "=" .. uT[k] end
        local eU = totals(R.pm.unit)
        for k, v in pairs(R.skip_u or {}) do eU[k] = get(eU, k) + v end   -- skipped moves never left the unit
        local eUo = only(eU)
        if not same_totals(uT, eUo) then why, udet = "unit", "unit: " .. rows(uT, eUo) end
        local unit_ok = (why == nil)
        -- a container that matched its model once is not read again (jm.confirmed)
        R.last_reads, R.last_slow, R.last_confirmed = 0, 0, 0
        for _, jm in ipairs(R.pm.jobs) do
            if jm.confirmed then R.last_confirmed = R.last_confirmed + 1 end
            local map
            if not jm.confirmed then
                local t0 = io.now()
                map = contents_of(jm)
                R.last_reads, R.last_slow = R.last_reads + 1, math.max(R.last_slow, io.now() - t0)
            end
            if not jm.confirmed and not map then
                why = why or ("container " .. tostring(jm.id) .. " unreadable")
                cdet = cdet or ("container id " .. tostring(jm.id) .. ": unreadable")
            elseif not jm.confirmed then
                local cT = only(map)
                local eC = totals(jm.slots)
                for k, v in pairs((R.skip_c or {})[jm.id] or {}) do eC[k] = get(eC, k) - v end
                local eCo = only(eC)
                -- drain: the unit matches the model, the container did not go up since the last read, no move of it was skipped
                local rose = false
                if jm.prev then
                    for _, k in ipairs(names) do if cT[k] > jm.prev[k] then rose = true end end
                end
                if geq(cT, eCo) then jm.confirmed = true
                elseif unit_ok and jm.prev and not rose and (R.skip_c or {})[jm.id] == nil then
                    jm.confirmed, jm.drained = true, true
                    trace(("restore drain: container id=%s treated as drained (%s)"):format(tostring(jm.id), rows(cT, eCo)))
                else
                    why = why or ("container " .. tostring(jm.id))
                    cdet = cdet or ("container id " .. tostring(jm.id) .. ": " .. rows(cT, eCo))
                end
                jm.prev = cT
            end
        end
        -- split route, nothing skipped: the unit slots must match the model too (slot layout after the sort and the splits)
        if R.pm.split and why == nil and (R.skipped or 0) == 0 and unit_sig(us) ~= unit_sig(R.pm.unit) then why = "unit slots" end
        local lines = {}
        if udet then lines[#lines + 1] = udet end
        if cdet then lines[#lines + 1] = cdet end
        local sig = table.concat(parts, ";") .. "|" .. unit_sig(us)
        return why == nil, why, sig, #lines > 0 and table.concat(lines, " | ") or nil
    end

    -- verified (or nothing to send): count what the containers got, end the restore
    local function pipe_finish()
        local drained = {}
        for _, jm in ipairs(R.pm.jobs) do if jm.drained then drained[#drained + 1] = tostring(jm.id) end end
        if #drained > 0 then trace("restore drained containers: " .. table.concat(drained, ",")) end
        for _, jm in ipairs(R.pm.jobs) do
            local sk = 0
            for _, v in pairs((R.skip_c or {})[jm.id] or {}) do sk = sk + v end
            delivered(jm.moved - sk, jm.id)
        end
        restore_end()
    end

    -- clamp notes: each container-item the room cut short (full[] from the planner): one note each, or one summary above 10
    local function full_notes(list)
        if #list <= 10 then
            for _, f in ipairs(list) do
                rs_note(("container %s full: %s x%s left in the unit"):format(tostring(f.id), shortname(f.item), commas(f.left)))
            end
        elseif #list > 0 then
            local left = 0
            for _, f in ipairs(list) do left = left + f.left end
            rs_note(("%s containers full, %s items left in the unit"):format(#list, commas(left)))
        end
    end

    -- stage 15: send up to RESTORE_CMD_PER_TICK commands (FIFO). The plan is built on the first call, from a fresh read.
    local function pipe_send(now)
        if not R.pm then
            local ps, us, err = read_both()
            if not ps then return fail(err) end
            trace("restore unit stacks (start): " .. slots_text(us))
            R.pq, R.pm = pipe_build(us)
            full_notes(R.pm.full)
            R.qpos = 1
            trace(("restore pipeline: %s command(s) for %s container(s), %s per tick"):format(
                tostring(#R.pq), tostring(#R.pm.jobs), tostring(RESTORE_CMD_PER_TICK)))
            if #R.pq == 0 then return pipe_finish() end
        end
        local sent = 0
        while R.qpos <= #R.pq and sent < RESTORE_CMD_PER_TICK do
            local c = R.pq[R.qpos]
            local ok, err
            if c.kind == "split" then
                local t0 = io.now()
                trace(("restore split: before src0=%s amount=%s dst0=%s at %s ms"):format(tostring(c.src), tostring(c.amount), tostring(c.dst), tostring(t0)))
                ok, err = io.split(R.unit_inv, c.src, c.amount, c.dst)
                trace(("restore split: after sent=%s err=%s, %s ms"):format(tostring(ok), tostring(err), tostring(io.now() - t0)))
            elseif c.pair and R.dead and R.dead[c.pair] then
                ok = true   -- its split was skipped: nothing is staged, so this TRANSFER is passed (not sent, not counted)
            else
                ok, err = io.send_inv(c.prim, c.sec, c.slot0, c.action)
            end
            if ok then
                R.fails = 0
                R.qpos, sent = R.qpos + 1, sent + 1
            else
                -- refused (not applied): the same command goes again on the next tick, up to RETRY_MAX times
                R.fails = (R.fails or 0) + 1
                trace(("restore pipe: refused command %s of %s (attempt %s, error: %s)"):format(
                    R.qpos, #R.pq, R.fails, tostring(err)))
                if R.fails <= RETRY_MAX then
                    R.t_next = now
                    return
                end
                -- retries used up: skip it (its move never happened, the model drops it), the restore goes on
                R.skipped = (R.skipped or 0) + 1
                R.skip_u = R.skip_u or {}
                R.skip_u[c.item] = get(R.skip_u, c.item) + c.moved
                R.skip_c = R.skip_c or {}
                R.skip_c[c.job] = R.skip_c[c.job] or {}
                R.skip_c[c.job][c.item] = get(R.skip_c[c.job], c.item) + c.moved
                if c.kind == "split" then R.dead = R.dead or {}; R.dead[c.pair] = true end   -- its TRANSFER is passed, not sent
                trace(("restore pipe: command %s of %s SKIPPED after %s refusals (error: %s)"):format(
                    R.qpos, #R.pq, R.fails, tostring(err)))
                R.fails = 0
                R.qpos = R.qpos + 1
            end
        end
        trace(("restore pipeline: sent %s, %s of %s"):format(tostring(sent), tostring(R.qpos - 1), tostring(#R.pq)))
        if R.qpos > #R.pq then
            R.t_progress, R.t_sent, R.stage = now, now, 16
            trace("restore pipeline: all commands sent, waiting for the game to show them")
            R.t_next = now + POLL_MS   -- first verify soon (usually already shown), then every PIPE_POLL_MS
        else
            set_status("working", progress(R.qpos - 1, #R.pq))
            R.t_next = now   -- next slice on the next tick, no wait
        end
    end

    -- stage 16: the model must show. Progress = any change of the restored items; no change for STALL_MS -> STALL note,
    -- nothing more is sent. The status line stays at 100 % sent while the game catches up.
    local function pipe_wait(now)
        if now - R.t_restore > RESTORE_MS then
            trace("restore pipeline: TIMEOUT, first mismatch: " .. tostring(R.last_detail))
            rs_note("restore stalled: timeout after 300 s" .. (R.last_detail and (" (first mismatch: " .. R.last_detail .. ")") or ""))
            return restore_end()
        end
        local tr0 = io.now()
        local ps, us, err = read_both()
        if not ps then return fail(err) end
        local unit_ms = io.now() - tr0
        local good, why, sig, detail = pipe_state(us)
        R.polls = (R.polls or 0) + 1
        trace(("restore poll: %s ms since the last send, unit read %s ms, containers read %s (slowest %s ms, %s of %s confirmed), mismatch %s"):format(
            tostring(now - R.t_sent), tostring(unit_ms), tostring(R.last_reads), tostring(R.last_slow),
            tostring(R.last_confirmed), tostring(#R.pm.jobs), tostring(why)))
        if R.pipe_sig == nil then R.pipe_sig = sig   -- baseline: the stall clock runs from the last send
        elseif sig ~= R.pipe_sig then R.pipe_sig, R.t_progress = sig, now end
        R.last_detail = detail
        -- mismatch trace: when it changes, at most once per 5 polls
        if detail and detail ~= R.mis_last and R.polls - (R.mis_poll or -5) >= 5 then
            trace("restore mismatch: " .. detail)
            R.mis_last, R.mis_poll = detail, R.polls
        end
        if good then
            trace("restore pipeline: verified (unit and containers show the model)")
            return pipe_finish()
        end
        if now - R.t_progress >= STALL_MS then
            trace(("restore pipeline: STALL, no change for %s ms (mismatch: %s)"):format(tostring(now - R.t_progress), tostring(why)))
            trace("restore pipeline: first mismatch: " .. tostring(detail))
            rs_note(("restore stalled at pipeline (%s of %s commands sent), no change for %d s, check both inventories by hand%s"):format(
                commas(R.qpos - 1), commas(#R.pq), math.floor(STALL_MS / 1000), detail and (" (first mismatch: " .. detail .. ")") or ""))
            return restore_end()
        end
        set_status("working", progress(#R.pq, #R.pq, ", waiting for the game"))
        R.t_next = now + PIPE_POLL_MS
    end

    -- stage 17, config check: the RAW game view (io.scan_raw, not the live overlay, which shows the sent config) must hold
    -- each placed machine with a config. Cell-key match; polls until all show or CFG_MS. Compares the ones shown by config
    -- length (game vs bytes sent). None shown (timeout or never placed) = no note.
    local function cfg_finish(matched)
        local n, first, shown = 0, nil, 0
        for i, w in ipairs(R.cfg_want) do
            local e = matched[i]
            if e then
                shown = shown + 1
                local sent, got = #w.cfg, type(e.cfg) == "string" and #e.cfg or 0
                if got ~= sent then
                    n = n + 1
                    first = first or { sent = sent, got = got, cls = w.bcls, x = w.x, y = w.y }
                end
            end
        end
        trace(("config check: %d of %d placed machines shown, %d with a different config"):format(shown, #R.cfg_want, n))
        local text = R.base_text
        if n > 0 then
            trace(("config check: first mismatch %s@(%s,%s) sent %d bytes, game has %d"):format(tostring(first.cls), tostring(first.x), tostring(first.y), first.sent, first.got))
            text = text .. ("; config not applied for %d machines (sent %d bytes, game has %d)"):format(n, first.sent, first.got)
        end
        R.active = false
        R.stage = 0
        R.state = "done"
        R.text = text
    end
    local function cfg_wait(now)
        local okr, raw = pcall(io.scan_raw, R.plan.station)
        local matched = {}
        if okr and type(raw) == "table" then
            local byKey = {}
            for _, e in ipairs(raw) do
                local k = ckey(e)
                byKey[k] = byKey[k] or {}
                table.insert(byKey[k], e)
            end
            for i, w in ipairs(R.cfg_want) do
                local list = byKey[ckey(w)]
                if list and #list > 0 then matched[i] = table.remove(list, 1) end
            end
        else
            trace("config check: raw read failed: " .. tostring(raw))
        end
        local shown = 0
        for i = 1, #R.cfg_want do if matched[i] then shown = shown + 1 end end
        if shown == #R.cfg_want or now - R.t_cfg > CFG_MS then return cfg_finish(matched) end
        set_status("working", R.base_text .. ("; checking the machine configs in the game (%d of %d shown)"):format(shown, #R.cfg_want))
        R.t_next = now + PIPE_POLL_MS
    end

    local builder = {}

    -- start(plan, opts): checks station, totals, creative; sends the first removal batch. Nothing is sent on a refusal.
    -- opts = { restore = true | false | nil } (Chk_Restore; nil = no checkbox, restore on).
    function builder:start(plan, opts)
        if R.active then return false, "error: busy: another build is running" end
        R = new_run(nil)
        if type(opts) == "table" then R.ui_restore = opts.restore end   -- Chk_Restore: true / false, nil = no checkbox (on)
        if not plan or not plan.valid then return start_fail("import first") end
        local P = {
            station = plan.station, fp = plan.fp,
            place = plan.place or {}, kept = plan.kept or {}, chg = plan.chg or {},
            removed = plan.removed or {}, need = plan.need or {}, refund = plan.refund or {},
            refund_cost = plan.refund_cost or plan.refund or {},   -- total check: machine refund only (contents are not counted)
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
            local terr = total_check(P.need, P.refund_cost, totals(ps), totals(us))
            if terr ~= "" then return start_fail(terr) end
        end
        local rs = "off"
        if io.redirect_status then
            local okr, rv = pcall(io.redirect_status)
            if okr and type(rv) == "string" then rs = rv end
        end
        R.flow = (rs:sub(1, 2) == "on") and "redirect" or "legacy"
        trace("build flow: " .. R.flow .. " (redirect status: " .. rs .. ")")
        if R.flow == "redirect" then
            -- only pre-check: the unit must hold the refund (optimistic when an item's max stack is unknown)
            local rmax = setmetatable({}, { __index = function(_, k)
                local raw = io.item_max and io.item_max(k)
                if raw and raw > 0 then return math.floor(raw * (us.mult or 1)) end
                return 1000000   -- unknown max stack: assume it fits
            end })
            if any_refund(P.refund) and not room_ok(us, build_rneed(P.refund, rmax), 0) then
                return start_fail("the unit inventory is full, empty it and Build again")
            end
            for _, m in ipairs(P.removed) do R.queue[#R.queue + 1] = { rm = m.id } end
            for _, m in ipairs(P.place) do R.queue[#R.queue + 1] = { pl = m } end
        end
        for _, m in ipairs(R.flow == "legacy" and P.removed or {}) do
            -- per-machine refund is what the batches are sized by: without it a batch could overflow the player
            if type(m.refund) ~= "table" then return start_fail("refund unknown for " .. tostring(m.bcls) .. ", import again") end
            R.rem_list[#R.rem_list + 1] = { id = m.id, bcls = m.bcls, refund = m.refund }
        end
        if #P.place == 0 and #P.removed == 0 and #P.chg == 0 then
            R.state = "done"
            R.text = "nothing to build"
            return true, "ok nothing to build"
        end

        -- before the first send: remember the contents of removed containers (session memory, by cell), and the container ids
        -- that exist now (restore finds the new ones after the placements)
        for _, e in ipairs(P.removed) do
            if is_container(e.bcls) then
                local map = contents_of(e)
                if map then
                    local list = as_list(map)
                    if io.remember then io.remember(ckey(e), list) end
                    trace(("remember: %s contents %d item(s)"):format(ckey(e), #list))
                end
            end
        end
        local want_restore = false
        for _, m in ipairs(P.place) do
            if is_container(m.bcls) and m.restore and #m.restore > 0 then want_restore = true end
        end
        if want_restore and io.container_ids then
            local okc, ids = pcall(io.container_ids)
            if okc and type(ids) == "table" then
                for _, id in ipairs(ids) do R.cids_before[id] = true end
            else
                trace("restore: container ids unreadable before the build")
            end
        end

        R.active = true
        R.overlap = overlaps(P.removed, P.place)
        if R.flow == "redirect" then
            R.stage = 11
            send_queue(now)   -- first slice sent here (a refusal before any command: start returns false)
        elseif #R.rem_list > 0 then
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
        if R.stage < 12 and now - R.t_start > TOTAL_MS then return fail("timeout after 300 s") end
        local s = R.stage
        if s == 11 then send_queue(now)
        elseif s == 12 then cont_wait(now)
        elseif s == 13 then sort_wait(now)
        elseif s == 15 then pipe_send(now)
        elseif s == 16 then pipe_wait(now)
        elseif s == 17 then cfg_wait(now)
        elseif s == 2 then arrival_wait(now)
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
            chunk = R.chunks_done .. "/" .. R.chunks, flow = R.flow,
        }
    end

    return builder
end

-- pure helpers, exposed for the tests
B.pure = {
    totals = totals, maxes = maxes, list = list, shortfall = shortfall, total_check = total_check,
    stage_moves = stage_moves, refund_fit = refund_fit, room_ok = room_ok, chunk_len = chunk_len,
    overlaps = overlaps, progress = progress, bar = bar, commas = commas,
}

return B
