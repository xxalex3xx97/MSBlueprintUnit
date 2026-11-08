-- bpu_blocks.lua: Station Build block logic. Pure Lua 5.4, no game globals. Places a file's station blocks
-- (MSCore native add_block / remove_block / pending) before the factory is built. Game work happens only via the native passed in.
--
-- API:  B.key(b) -> "class|gx|gy|h"
--       B.name(class) -> player name ("Station 1x1"; fallback: BPO_ stripped, _ to space)
--       B.place_text(b) -> "Station 1x1 at (2, 0), level 0"    B.listing(names, total) -> "a, b and c"
--       B.diff(doc, live) -> { missing = {doc blocks not in live}, extra = {live blocks not in doc} }  (multiset by key)
--       B.missing_after(doc, live, removes) -> missing list + removed blocks still present (done = empty)
--       B.box(info, b) -> {x0,x1,y0,y1,z0,z1} inclusive grid box of block b (info.bounds rotated by b.rot % 4, moved to gx,gy,h)
--       B.overlap(a, b) -> true when two boxes share a cell (inclusive AABB, 3 axes)
--       B.self_overlaps(doc, info_of) -> list of {i=, j=} index pairs of doc blocks whose boxes overlap (trace; expect none)
--       B.classify(missing, live, info_of, have, doc) -> {
--           accept = { {block=, info=, box=}, ... },
--           notes = {player sentences}, raw = {technical lines for bpu_trace.log}, locked = {class, ...},
--           remove = { live block, ... } (live blocks in the way of an accepted block, deduped),
--           cost = {ITEM=n} (added), refund = {ITEM=n} (removed), shortfall = { {item=, need=net, have=}, ... } }
--       B.send(native, station, blocks, ids, removes) -> true | false, err (err is technical: trace it)
--
-- info_of(class, path) -> info | nil. info = { station = bool, unlocked = true|false|nil, bounds = {x0,x1,y0,y1,z0,z1}, cost = {ITEM=n} }
--   (nil = class not in this game; unlocked nil = research state unknown; bounds from MSCore read_block_class)
-- live   = { {class=, gx=, gy=, h=, rot=, path=}, ... }  live station blocks (path = MSCore 7th column; no info = one cell)
-- doc    = the file's station blocks: a live block whose key is in doc is never removed. doc nil = no removals.
-- have   = { ITEM = n, ... }  unit + player stock. Shortfall is reported; the caller decides (creative skips it).
-- ids    = { primary=, player=, editing= }  inventory ids (primary = unit, player = player inventory; editing defaults 0)
-- native = factory_native (add_block, remove_block, pending). Each returns ok, err.

local B = {}

-- player names of station blocks (by class short name). Others: BPO_ stripped, _ to space.
local NAMES = {
    BPO_Station_01 = "Station 1x1", BPO_Station_02A = "Station 2x2", BPO_StationCorner_01 = "Station corner",
    BPO_CommandModule = "Command module", BPO_ShipyardSide = "Shipyard side", BPO_ShipyardCore = "Shipyard core",
    BPO_ShipyardCore_02 = "Shipyard core 2", BPO_Dock = "Dock", BPO_Dock_2 = "Dock 2", BPO_SolarPanelBlock = "Solar panel",
    BPO_ElevatorBlock_03 = "Elevator", BPO_BlueprintUnit = "Blueprint unit",
}

function B.name(cls)
    cls = tostring(cls)
    if NAMES[cls] then return NAMES[cls] end
    local s = cls:gsub("^BPO_", "")
    s = s:gsub("_", " ")
    return s
end

-- player sentences (shown in the window). Technical wording lives in B.RAW (trace only).
B.TEXT = {
    occupied = "another block of the blueprint already occupies that spot",
    no_class = "this block type is not in this game",
    not_station = "it is not a station block",
    unknown = "its research state could not be read",
    shortfall = "Not enough items for the station blocks",
    nothing_built = "nothing was built",
    failed = "The station blocks could not be placed; nothing was resent.",
    stalled = "The station blocks did not all appear within %d s (%d still missing); nothing was resent.",
    sent_failed = "The station blocks could not be sent; nothing was resent.",
    research_all = "Could not read the research state of any station block, so Station Build placed nothing.",
}

-- technical wording (bpu_trace.log, and the old raw note text)
B.RAW = {
    no_class = "class not in this game",
    not_station = "not a station block",
    unknown = "research state unknown, skipped",
    locked = "locked by research, skipped",
    occupied = "cell occupied or overlaps a block already placed",
    overlap_doc = "overlaps another block in this file",
    shortfall = "not enough items for all station blocks, nothing was built",
    no_ids = "inventory ids missing, nothing sent",
    reset_fail = "reset failed: ",
    add_fail = "add_block failed: ",
    remove_fail = "remove_block failed: ",
    apply_fail = "apply failed: ",
}

local function ik(v)
    return math.tointeger(v) or v or 0
end

function B.key(b)
    return string.format("%s|%s|%s|%s", tostring(b.class), tostring(ik(b.gx)), tostring(ik(b.gy)), tostring(ik(b.h)))
end

-- "Station 1x1 at (2, 0), level 0"
function B.place_text(b)
    return string.format("%s at (%d, %d), level %d", B.name(b.class), ik(b.gx), ik(b.gy), ik(b.h))
end

-- "a", "a and b", "a, b and c"; total > #names adds "and N more"
function B.listing(names, total)
    local n = #names
    if n == 0 then return "" end
    local s
    if n == 1 then s = names[1]
    elseif n == 2 then s = names[1] .. " and " .. names[2]
    else s = table.concat(names, ", ", 1, n - 1) .. " and " .. names[n] end
    if total and total > n then s = s .. " and " .. (total - n) .. " more" end
    return s
end

-- multiset diff by key: doc entries not matched by live (missing), live entries not matched by doc (extra)
function B.diff(doc, live)
    local cnt = {}
    for _, b in ipairs(live or {}) do
        local k = B.key(b)
        cnt[k] = (cnt[k] or 0) + 1
    end
    local missing = {}
    for _, b in ipairs(doc or {}) do
        local k = B.key(b)
        if cnt[k] and cnt[k] > 0 then cnt[k] = cnt[k] - 1 else missing[#missing + 1] = b end
    end
    -- cnt[k] now = live copies with no doc match; the first such live entries are the extras
    local extra = {}
    for _, b in ipairs(live or {}) do
        local k = B.key(b)
        if cnt[k] > 0 then cnt[k] = cnt[k] - 1; extra[#extra + 1] = b end
    end
    return { missing = missing, extra = extra }
end

-- key + rotation: what remove_block matches (class, X, Y, Height, Rotation)
local function rkey(b)
    return B.key(b) .. "|" .. tostring(ik(b.rot or 0))
end

-- done = empty. Missing doc blocks, plus removed blocks still present (same class, cell and rotation as a live block).
-- ponytail: a live duplicate of a JSON block at a removed cell reads as still present; the game does not make such duplicates.
function B.missing_after(doc, live, removes)
    local miss = B.diff(doc, live).missing
    local cnt = {}
    for _, b in ipairs(live or {}) do local k = rkey(b); cnt[k] = (cnt[k] or 0) + 1 end
    for _, r in ipairs(removes or {}) do
        local k = rkey(r)
        if cnt[k] and cnt[k] > 0 then cnt[k] = cnt[k] - 1; miss[#miss + 1] = r end
    end
    return miss
end

-- rotate bounds by r (0..3), then move by block origin. z is not rotated.
function B.box(info, b)
    local bd = info.bounds
    local r = (b.rot or 0) % 4
    local x0, x1, y0, y1 = bd.x0, bd.x1, bd.y0, bd.y1
    local nx0, nx1, ny0, ny1
    if r == 0 then
        nx0, nx1, ny0, ny1 = x0, x1, y0, y1
    elseif r == 1 then
        nx0, nx1, ny0, ny1 = -y1, -y0, x0, x1
    elseif r == 2 then
        nx0, nx1, ny0, ny1 = -x1, -x0, -y1, -y0
    else
        nx0, nx1, ny0, ny1 = y0, y1, -x1, -x0
    end
    local gx, gy, h = ik(b.gx), ik(b.gy), ik(b.h)
    return {
        x0 = nx0 + gx, x1 = nx1 + gx,
        y0 = ny0 + gy, y1 = ny1 + gy,
        z0 = bd.z0 + h, z1 = bd.z1 + h,
    }
end

-- inclusive AABB: shared cell on all 3 axes
function B.overlap(a, b)
    return a.x0 <= b.x1 and b.x0 <= a.x1
        and a.y0 <= b.y1 and b.y0 <= a.y1
        and a.z0 <= b.z1 and b.z0 <= a.z1
end

-- box for a live block: real bounds when its class info is known (path), else one cell
local function live_box(b, info_of)
    local info = info_of(b.class, b.path)
    if info and info.bounds then return B.box(info, b) end
    local gx, gy, h = ik(b.gx), ik(b.gy), ik(b.h)
    return { x0 = gx, x1 = gx, y0 = gy, y1 = gy, z0 = h, z1 = h }
end

function B.self_overlaps(doc, info_of)
    local boxes, out = {}, {}
    for i, b in ipairs(doc or {}) do
        local info = info_of(b.class)
        if info and info.bounds then boxes[i] = B.box(info, b) end
    end
    for i = 1, #doc do
        for j = i + 1, #doc do
            if boxes[i] and boxes[j] and B.overlap(boxes[i], boxes[j]) then out[#out + 1] = { i = i, j = j } end
        end
    end
    return out
end

local function at(b)
    return string.format("%s at %s,%s,%s", tostring(b.class), tostring(ik(b.gx)), tostring(ik(b.gy)), tostring(ik(b.h)))
end

-- reason key -> player sentence
local FRIENDLY = { no_class = B.TEXT.no_class, not_station = B.TEXT.not_station, unknown = B.TEXT.unknown,
                   occupied = B.TEXT.occupied, overlap_doc = B.TEXT.occupied }

-- missing: blocks to place (diff(doc, live).missing). Skip order: no class, not station, locked, unknown,
-- live block in the file (never removed), overlap with an earlier accepted block. A live block that overlaps an
-- accepted missing block (and is not in the file) is removed; a removed live block no longer occupies its cell.
-- Cost: added blocks (cost) and removed blocks (refund); shortfall on net = cost - refund > have.
function B.classify(missing, live, info_of, have, doc)
    local res = { accept = {}, notes = {}, raw = {}, locked = {}, cost = {}, refund = {}, shortfall = {}, remove = {} }
    local in_doc = {}
    for _, d in ipairs(doc or {}) do in_doc[B.key(d)] = true end
    local keep_all = doc == nil   -- no file given: nothing is removable
    local live_boxes = {}
    for i, b in ipairs(live or {}) do live_boxes[i] = live_box(b, info_of) end
    local gone = {}   -- live index -> removed by an accepted block
    local locked_n = {}   -- class -> count of blocks skipped as locked (one player note)
    local function skip(b, key)
        res.raw[#res.raw + 1] = at(b) .. ": " .. B.RAW[key]
        if FRIENDLY[key] then res.notes[#res.notes + 1] = "Skipped " .. B.name(b.class) .. ": " .. FRIENDLY[key] .. "." end
    end
    for _, b in ipairs(missing or {}) do
        local info = info_of(b.class)
        local reason
        if not info then
            reason = "no_class"
        elseif not info.station then
            reason = "not_station"
        elseif info.unlocked == false then
            reason = "locked"
            if not locked_n[b.class] then res.locked[#res.locked + 1] = b.class end
            locked_n[b.class] = (locked_n[b.class] or 0) + 1
            res.raw[#res.raw + 1] = at(b) .. ": " .. B.RAW.locked
        elseif info.unlocked == nil then
            reason = "unknown"
        end
        local box, hits = nil, {}
        if not reason then
            box = B.box(info, b)
            for i, lb in ipairs(live_boxes) do
                if not gone[i] and B.overlap(box, lb) then hits[#hits + 1] = i end
            end
            for _, i in ipairs(hits) do
                if keep_all or in_doc[B.key(live[i])] then reason = "occupied"; break end
            end
        end
        if not reason then
            for _, a in ipairs(res.accept) do
                if B.overlap(box, a.box) then reason = "overlap_doc"; break end
            end
        end
        if reason == "locked" then
            -- counted above, one note per class at the end
        elseif reason then
            skip(b, reason)
        else
            res.accept[#res.accept + 1] = { block = b, info = info, box = box }
            for item, n in pairs(info.cost or {}) do res.cost[item] = (res.cost[item] or 0) + n end
            for _, i in ipairs(hits) do
                local r = live[i]
                gone[i] = true
                res.remove[#res.remove + 1] = r
                local rinfo = info_of(r.class, r.path)
                for item, n in pairs(rinfo and rinfo.cost or {}) do res.refund[item] = (res.refund[item] or 0) + n end
                res.notes[#res.notes + 1] = "Removed the " .. B.name(r.class) .. " that was in the way of a " .. B.name(b.class) .. "."
                res.raw[#res.raw + 1] = "removing " .. at(r) .. " (overlaps " .. at(b) .. ")"
            end
        end
    end
    if #res.locked > 0 then
        table.sort(res.locked)
        local parts, total = {}, 0
        for _, c in ipairs(res.locked) do
            local n = locked_n[c]
            total = total + n
            parts[#parts + 1] = B.name(c) .. (n > 1 and (" x" .. n) or "")
        end
        res.notes[#res.notes + 1] = ("Skipped %d %s locked by research: %s."):format(total, total == 1 and "block" or "blocks",
            B.listing(parts))
    end
    local items, seen = {}, {}
    for item in pairs(res.cost) do seen[item] = true end
    for item in pairs(res.refund) do seen[item] = true end
    for item in pairs(seen) do items[#items + 1] = item end
    table.sort(items)
    for _, item in ipairs(items) do
        local net = (res.cost[item] or 0) - (res.refund[item] or 0)
        local h = (have and have[item]) or 0
        if net > h then
            res.shortfall[#res.shortfall + 1] = { item = item, need = net, have = h }
        end
    end
    return res
end

-- order: pending(reset), remove_block each, add_block each, pending(apply) (one apply). Any failure after reset ->
-- best-effort reset (clears a half-filled Pending). No blocks and no removes -> true, nothing sent.
-- ids <= 0 (or station <= 0) -> false before any call.
function B.send(native, station, blocks, ids, removes)
    ids = ids or {}
    removes = removes or {}
    if (station or 0) <= 0 or (ids.primary or 0) <= 0 or (ids.player or 0) <= 0 then
        return false, B.RAW.no_ids
    end
    if #(blocks or {}) == 0 and #removes == 0 then return true end
    local p, pl, ed = ids.primary, ids.player, ids.editing or 0
    local ok, err = native.pending(station, false, true, p, pl, ed)
    if not ok then return false, B.RAW.reset_fail .. tostring(err) end
    for _, r in ipairs(removes) do
        ok, err = native.remove_block(station, r.class, ik(r.gx), ik(r.gy), ik(r.h), r.rot or 0)
        if not ok then
            native.pending(station, false, true, p, pl, ed)  -- best effort
            return false, B.RAW.remove_fail .. at(r) .. ": " .. tostring(err)
        end
    end
    for _, b in ipairs(blocks or {}) do
        ok, err = native.add_block(station, b.class, ik(b.gx), ik(b.gy), ik(b.h), b.rot or 0)
        if not ok then
            native.pending(station, false, true, p, pl, ed)  -- best effort
            return false, B.RAW.add_fail .. at(b) .. ": " .. tostring(err)
        end
    end
    ok, err = native.pending(station, true, false, p, pl, ed)
    if not ok then
        native.pending(station, false, true, p, pl, ed)  -- best effort
        return false, B.RAW.apply_fail .. tostring(err)
    end
    return true
end

return B
