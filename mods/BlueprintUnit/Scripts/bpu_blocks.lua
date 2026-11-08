-- bpu_blocks.lua: Station Build block logic. Pure Lua 5.4, no game globals. Places a file's station blocks
-- (MSCore native add_block / pending) before the factory is built. Game work happens only via the native passed in.
--
-- API:  B.key(b) -> "class|gx|gy|h"
--       B.diff(doc, live) -> { missing = {doc blocks not in live}, extra = {live blocks not in doc} }  (multiset by key)
--       B.missing_after(doc, live) -> missing list (same as diff(...).missing)
--       B.box(info, b) -> {x0,x1,y0,y1,z0,z1} inclusive grid box of block b (info.bounds rotated by b.rot % 4, moved to gx,gy,h)
--       B.overlap(a, b) -> true when two boxes share a cell (inclusive AABB, 3 axes)
--       B.self_overlaps(doc, info_of) -> list of {i=, j=} index pairs of doc blocks whose boxes overlap (trace; expect none)
--       B.classify(missing, live, info_of, have) -> {
--           accept = { {block=, info=, box=}, ... }, notes = {text, ...}, locked = {class, ...},
--           cost = {ITEM=n}, shortfall = { {item=, need=, have=}, ... } }
--       B.send(native, station, blocks, ids) -> true | false, err
--
-- info_of(class) -> info | nil. info = { station = bool, unlocked = true|false|nil, bounds = {x0,x1,y0,y1,z0,z1}, cost = {ITEM=n} }
--   (nil = class not in this game; unlocked nil = research state unknown; bounds from MSCore read_block_class)
-- live   = { {class=, gx=, gy=, h=, rot=}, ... }  live station blocks (a live block with no info is treated as one cell)
-- have   = { ITEM = n, ... }  unit + player stock. Shortfall is reported; the caller decides (creative skips it).
-- ids    = { primary=, player=, editing= }  inventory ids (primary = unit, player = player inventory; editing defaults 0)
-- native = factory_native (add_block, pending). Both return ok, err.

local B = {}

B.TEXT = {
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
    apply_fail = "apply failed: ",
}

local function ik(v)
    return math.tointeger(v) or v or 0
end

function B.key(b)
    return string.format("%s|%s|%s|%s", tostring(b.class), tostring(ik(b.gx)), tostring(ik(b.gy)), tostring(ik(b.h)))
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

function B.missing_after(doc, live)
    return B.diff(doc, live).missing
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

-- box for a live block with no info: one cell
local function live_box(b, info_of)
    local info = info_of(b.class)
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

-- missing: blocks to place (diff(doc, live).missing). Skip order: no class, not station, locked, unknown,
-- overlap with live or earlier accepted. Cost and shortfall over accepted blocks only.
function B.classify(missing, live, info_of, have)
    local res = { accept = {}, notes = {}, locked = {}, cost = {}, shortfall = {} }
    local live_boxes = {}
    for _, b in ipairs(live or {}) do live_boxes[#live_boxes + 1] = live_box(b, info_of) end
    local locked_seen = {}
    for _, b in ipairs(missing or {}) do
        local info = info_of(b.class)
        local reason
        if not info then
            reason = B.TEXT.no_class
        elseif not info.station then
            reason = B.TEXT.not_station
        elseif info.unlocked == false then
            reason = B.TEXT.locked
            if not locked_seen[b.class] then locked_seen[b.class] = true; res.locked[#res.locked + 1] = b.class end
        elseif info.unlocked == nil then
            reason = B.TEXT.unknown
        end
        local box
        if not reason then
            box = B.box(info, b)
            for _, lb in ipairs(live_boxes) do
                if B.overlap(box, lb) then reason = B.TEXT.occupied; break end
            end
        end
        if not reason then
            for _, a in ipairs(res.accept) do
                if B.overlap(box, a.box) then reason = B.TEXT.overlap_doc; break end
            end
        end
        if reason then
            res.notes[#res.notes + 1] = at(b) .. ": " .. reason
        else
            res.accept[#res.accept + 1] = { block = b, info = info, box = box }
            for item, n in pairs(info.cost or {}) do res.cost[item] = (res.cost[item] or 0) + n end
        end
    end
    table.sort(res.locked)
    local items = {}
    for item in pairs(res.cost) do items[#items + 1] = item end
    table.sort(items)
    for _, item in ipairs(items) do
        local h = (have and have[item]) or 0
        if h < res.cost[item] then
            res.shortfall[#res.shortfall + 1] = { item = item, need = res.cost[item], have = h }
        end
    end
    return res
end

-- order: pending(reset), add_block each, pending(apply). Any failure after reset -> best-effort reset
-- (clears a half-filled Pending). No blocks -> true, nothing sent. ids <= 0 (or station <= 0) -> false before any call.
function B.send(native, station, blocks, ids)
    ids = ids or {}
    if (station or 0) <= 0 or (ids.primary or 0) <= 0 or (ids.player or 0) <= 0 then
        return false, B.TEXT.no_ids
    end
    if not blocks or #blocks == 0 then return true end
    local p, pl, ed = ids.primary, ids.player, ids.editing or 0
    local ok, err = native.pending(station, false, true, p, pl, ed)
    if not ok then return false, B.TEXT.reset_fail .. tostring(err) end
    for _, b in ipairs(blocks) do
        ok, err = native.add_block(station, b.class, ik(b.gx), ik(b.gy), ik(b.h), b.rot or 0)
        if not ok then
            native.pending(station, false, true, p, pl, ed)  -- best effort
            return false, B.TEXT.add_fail .. at(b) .. ": " .. tostring(err)
        end
    end
    ok, err = native.pending(station, true, false, p, pl, ed)
    if not ok then
        native.pending(station, false, true, p, pl, ed)  -- best effort
        return false, B.TEXT.apply_fail .. tostring(err)
    end
    return true
end

return B
