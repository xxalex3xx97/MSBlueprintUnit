-- test_blocks.lua: bpu_blocks checks (key, diff, box rotation, overlap, classify, send). Run: lua test_blocks.lua. Exit 1 on fail.
local dir = (arg and arg[0] or ""):match("^(.*[/\\])") or "./"
package.path = dir .. "../Scripts/?.lua;" .. package.path
local B = require("bpu_blocks")

local pass, fail = 0, 0
local function check(name, cond)
    if cond then pass = pass + 1; print("PASS " .. name) else fail = fail + 1; print("FAIL " .. name) end
end

-- key / diff
check("key int vs float", B.key({ class = "A", gx = 2.0, gy = 3, h = 0 }) == B.key({ class = "A", gx = 2, gy = 3, h = 0 }))
local d = B.diff({ { class = "A", gx = 0, gy = 0, h = 0 }, { class = "A", gx = 1, gy = 0, h = 0 } },
                 { { class = "A", gx = 0, gy = 0, h = 0 } })
check("diff missing", #d.missing == 1 and d.missing[1].gx == 1 and #d.extra == 0)
d = B.diff({ { class = "A", gx = 0, gy = 0, h = 0 } }, { { class = "A", gx = 0, gy = 0, h = 0 }, { class = "A", gx = 0, gy = 0, h = 0 } })
check("diff duplicate live is extra", #d.missing == 0 and #d.extra == 1)
check("missing_after", #B.missing_after({ { class = "A", gx = 0, gy = 0, h = 0 } }, {}) == 1)

-- box rotation: bounds x 0..1, y 0..0, z 0..0 at origin (5,5,0)
local info = { bounds = { x0 = 0, x1 = 1, y0 = 0, y1 = 0, z0 = 0, z1 = 0 } }
local function bx(rot) return B.box(info, { class = "A", gx = 5, gy = 5, h = 0, rot = rot }) end
local b0 = bx(0)
check("rot0 box", b0.x0 == 5 and b0.x1 == 6 and b0.y0 == 5 and b0.y1 == 5)
local b1 = bx(1)
check("rot1 box", b1.x0 == 5 and b1.x1 == 5 and b1.y0 == 5 and b1.y1 == 6)
local b2 = bx(2)
check("rot2 box", b2.x0 == 4 and b2.x1 == 5 and b2.y0 == 5 and b2.y1 == 5)
local b3 = bx(3)
check("rot3 box", b3.x0 == 5 and b3.x1 == 5 and b3.y0 == 4 and b3.y1 == 5)
check("rot 4 == rot 0", bx(4).x1 == 6)

-- overlap: inclusive, touching cell counts
local a = { x0 = 0, x1 = 1, y0 = 0, y1 = 0, z0 = 0, z1 = 0 }
check("overlap shared cell", B.overlap(a, { x0 = 1, x1 = 2, y0 = 0, y1 = 0, z0 = 0, z1 = 0 }))
check("no overlap next cell", not B.overlap(a, { x0 = 2, x1 = 3, y0 = 0, y1 = 0, z0 = 0, z1 = 0 }))
check("no overlap other height", not B.overlap(a, { x0 = 0, x1 = 1, y0 = 0, y1 = 0, z0 = 1, z1 = 1 }))

-- classify
local infos = {
    Ok = { station = true, unlocked = true, bounds = { x0 = 0, x1 = 0, y0 = 0, y1 = 0, z0 = 0, z1 = 0 }, cost = { ITEM_A = 2 } },
    Pipe = { station = false, unlocked = true, bounds = { x0 = 0, x1 = 0, y0 = 0, y1 = 0, z0 = 0, z1 = 0 }, cost = {} },
    Locked = { station = true, unlocked = false, bounds = { x0 = 0, x1 = 0, y0 = 0, y1 = 0, z0 = 0, z1 = 0 }, cost = {} },
    Unk = { station = true, unlocked = nil, bounds = { x0 = 0, x1 = 0, y0 = 0, y1 = 0, z0 = 0, z1 = 0 }, cost = {} },
    Big = { station = true, unlocked = true, bounds = { x0 = 0, x1 = 1, y0 = 0, y1 = 0, z0 = 0, z1 = 0 }, cost = { ITEM_A = 1, ITEM_B = 3 } },
}
local function info_of(c) return infos[c] end
local missing = {
    { class = "Ok", gx = 0, gy = 0, h = 0, rot = 0 },      -- accepted
    { class = "Gone", gx = 1, gy = 0, h = 0, rot = 0 },    -- no class
    { class = "Pipe", gx = 2, gy = 0, h = 0, rot = 0 },    -- not station
    { class = "Locked", gx = 3, gy = 0, h = 0, rot = 0 },  -- locked
    { class = "Locked", gx = 4, gy = 0, h = 0, rot = 0 },  -- locked again (listed once)
    { class = "Unk", gx = 5, gy = 0, h = 0, rot = 0 },     -- unknown research
    { class = "Ok", gx = 9, gy = 9, h = 0, rot = 0 },      -- occupied by live
    { class = "Ok", gx = 0, gy = 0, h = 1, rot = 0 },      -- accepted (other height, no overlap)
    { class = "Ok", gx = 0, gy = 0, h = 0, rot = 0 },      -- overlaps the first accepted
    { class = "Big", gx = 20, gy = 0, h = 0, rot = 0 },    -- accepted, cost ITEM_A 1 + ITEM_B 3
}
local live = { { class = "Ok", gx = 9, gy = 9, h = 0, rot = 0 } }
local r = B.classify(missing, live, info_of, { ITEM_A = 2, ITEM_B = 2 })
check("classify accepted count", #r.accept == 3)
check("classify notes count", #r.notes == 6)
check("classify notes text", r.notes[1] == "Skipped Gone: this block type is not in this game.")
check("classify raw keeps technical text", r.raw[1] == "Gone at 1,0,0: class not in this game")
check("classify skip occupied", r.notes[4] == "Skipped Ok: another block of the blueprint already occupies that spot.")
check("classify locked: one aggregated note", r.notes[6] == "Skipped 2 blocks locked by research: Locked x2.")
check("classify locked listed once", #r.locked == 1 and r.locked[1] == "Locked")
check("classify cost sum", r.cost.ITEM_A == 2 + 2 + 1 and r.cost.ITEM_B == 3)
check("classify shortfall", #r.shortfall == 2 and r.shortfall[1].item == "ITEM_A" and r.shortfall[1].need == 5
    and r.shortfall[1].have == 2 and r.shortfall[2].item == "ITEM_B")
local r2 = B.classify({ { class = "Ok", gx = 0, gy = 0, h = 0, rot = 0 } }, {}, info_of, { ITEM_A = 5 })
check("no shortfall when enough", #r2.shortfall == 0 and #r2.accept == 1)

-- self_overlaps: two Big blocks on the same row overlap
local so = B.self_overlaps({ { class = "Big", gx = 0, gy = 0, h = 0, rot = 0 }, { class = "Big", gx = 1, gy = 0, h = 0, rot = 0 },
                             { class = "Big", gx = 5, gy = 0, h = 0, rot = 0 } }, info_of)
check("self_overlaps pair", #so == 1 and so[1].i == 1 and so[1].j == 2)

-- send with fake native
local function fake(fail_at)
    local calls = {}
    local n = { calls = calls }
    n.pending = function(st, apply, reset, p, pl, ed)
        calls[#calls + 1] = string.format("pending %s %s", tostring(apply), tostring(reset))
        if fail_at == "reset" and reset and not apply then return false, "boom" end
        if fail_at == "apply" and apply then return false, "nope" end
        return true
    end
    n.add_block = function(st, cls, x, y, h, rot)
        calls[#calls + 1] = "add " .. cls
        if fail_at == "add" then return false, "full" end
        return true
    end
    return n
end
local blks = { { class = "Ok", gx = 0, gy = 0, h = 0, rot = 0 }, { class = "Big", gx = 1, gy = 2, h = 0, rot = 1 } }
local ids = { primary = 7, player = 8, editing = 0 }

local n0 = fake()
local ok0 = B.send(n0, 3, blks, { primary = 0, player = 8 })
check("send id 0 refused before calls", not ok0 and #n0.calls == 0)
local n1 = fake()
check("send ok", B.send(n1, 3, blks, ids) == true)
check("send order", table.concat(n1.calls, ",") == "pending false true,add Ok,add Big,pending true false")
local n2 = fake("add")
local ok2, e2 = B.send(n2, 3, blks, ids)
check("send add fail -> false + reset", not ok2 and e2:find("add_block failed", 1, true) ~= nil
    and n2.calls[#n2.calls] == "pending false true")
local n3 = fake("apply")
local ok3 = B.send(n3, 3, blks, ids)
check("send apply fail -> false + reset", not ok3 and n3.calls[#n3.calls] == "pending false true")
local n4 = fake("reset")
check("send reset fail -> false, no add", not B.send(n4, 3, blks, ids) and #n4.calls == 1)

-- real probe bounds (2026-11-08, raw/65536 then /4): Station_01 spans +-7.99695 -> +-1.99924 in grid units; neighbours 4 apart must not overlap
local s01 = { bounds = { x0 = -7.9969482421875 / 4, x1 = 7.9969482421875 / 4, y0 = -7.9969482421875 / 4, y1 = 7.9969482421875 / 4, z0 = 0, z1 = 3.9969482421875 / 2 } }
local ba = B.box(s01, { gx = 0, gy = 0, h = 0, rot = 0 })
check("probe bounds: neighbour 4 apart does not overlap", not B.overlap(ba, B.box(s01, { gx = 4, gy = 0, h = 0, rot = 0 })))
check("probe bounds: diagonal neighbour does not overlap", not B.overlap(ba, B.box(s01, { gx = 4, gy = 4, h = 0, rot = 0 })))
check("probe bounds: next level (h+2) does not overlap", not B.overlap(ba, B.box(s01, { gx = 0, gy = 0, h = 2, rot = 0 })))
check("probe bounds: 3 apart overlaps", B.overlap(ba, B.box(s01, { gx = 3, gy = 0, h = 0, rot = 0 })))

-- ===== removal: live blocks in the way of a missing JSON block =====
-- probe sizes (2026-11-08): ShipyardSide x -1.99924..0.25, y +-1.99924, z -2..5; Station_01 +-1.99924 xy, z 0..1.99847
local rinfos = {
    Station_01 = { station = true, unlocked = true, bounds = { x0 = -1.99924, x1 = 1.99924, y0 = -1.99924, y1 = 1.99924, z0 = 0, z1 = 1.99847 }, cost = { ITEM_Plate = 2 } },
    Station_02A = { station = true, unlocked = true, bounds = { x0 = -3.99848, x1 = 3.99848, y0 = -3.99848, y1 = 3.99848, z0 = 0, z1 = 1.99847 }, cost = { ITEM_Plate = 6 } },
    ShipyardSide = { station = true, unlocked = true, bounds = { x0 = -1.99924, x1 = 0.25, y0 = -1.99924, y1 = 1.99924, z0 = -2, z1 = 5 }, cost = { ITEM_Plate = 4, ITEM_Frame = 1 } },
    Dock = { station = true, unlocked = true, bounds = { x0 = -1.99924, x1 = 1.99924, y0 = -1.99924, y1 = 1.99924, z0 = 0, z1 = 1.99847 }, cost = {} },
}
local function rinfo_of(c) return rinfos[c] end
local SIDE = { class = "ShipyardSide", gx = 0, gy = 0, h = 0, rot = 0, path = "/Game/ShipyardSide" }
local S1 = { class = "Station_01", gx = 0, gy = 0, h = 0, rot = 0, path = "/Game/Station_01" }

-- the probe case: Station 1x1 where a Shipyard side stands -> side removed, station added
local rr = B.classify({ S1 }, { SIDE }, rinfo_of, {}, { S1 })
check("remove: live side in the way is chosen", #rr.accept == 1 and #rr.remove == 1 and rr.remove[1] == SIDE)
-- fixtures use short names without BPO_: the fallback name applies (real plans carry BPO_ classes, see test_plan)
check("remove: note text", rr.notes[1] == "Removed the ShipyardSide that was in the way of a Station 01.")
check("remove: raw trace text", rr.raw[1] == "removing ShipyardSide at 0,0,0 (overlaps Station_01 at 0,0,0)")
check("remove: net cost = added 2 minus refund 4+1", rr.cost.ITEM_Plate == 2 and rr.refund.ITEM_Plate == 4 and rr.refund.ITEM_Frame == 1)
check("remove: net refund needs nothing", #rr.shortfall == 0)

-- a live block that is itself in the file is never removed: the file overlaps itself, the new block is skipped
local rk = B.classify({ S1 }, { SIDE }, rinfo_of, {}, { S1, SIDE })
check("in file: not removed, skipped as occupied", #rk.remove == 0 and #rk.accept == 0 and rk.notes[1] == "Skipped Station 01: another block of the blueprint already occupies that spot.")

-- net cost: 6 Plate for the new block, 4 Plate + 1 Frame refund -> 2 Plate short when holding 1
local rn = B.classify({ { class = "Station_02A", gx = 0, gy = 0, h = 0, rot = 0 } }, { SIDE }, rinfo_of, { ITEM_Plate = 1 },
                      { { class = "Station_02A", gx = 0, gy = 0, h = 0, rot = 0 } })
check("net: shortfall on net (6-4=2) vs have 1", #rn.shortfall == 1 and rn.shortfall[1].item == "ITEM_Plate" and rn.shortfall[1].need == 2 and rn.shortfall[1].have == 1)
local rn2 = B.classify({ S1 }, { SIDE }, rinfo_of, { ITEM_Plate = 0 }, { S1 })
check("net: removal refund covers a 2 Plate block with 0 held", #rn2.shortfall == 0)

-- removed block stops occupying: Station_01 at h=-2 overlaps the side (removed by the first block) but not the first block
local S1b = { class = "Station_01", gx = 0, gy = 0, h = -2, rot = 0 }
local rg = B.classify({ S1, S1b }, { SIDE }, rinfo_of, {}, { S1, S1b })
check("gone: second block accepted after the side is removed", #rg.accept == 2 and #rg.remove == 1)
check("gone: one note (the removal), no occupied note", #rg.notes == 1 and rg.notes[1]:find("Removed the", 1, true) ~= nil)
-- two missing blocks over the same side: removed once
local rd = B.classify({ S1, { class = "Station_01", gx = 1, gy = 0, h = 0, rot = 0 } }, { SIDE }, rinfo_of, {}, { S1 })
check("dedup: side removed once, second block skipped as overlap", #rd.remove == 1 and #rd.accept == 1 and rd.notes[#rd.notes]:find("another block of the blueprint already occupies", 1, true) ~= nil)
-- probe spacing: a Station 1x1 4 cells away from the side is not in its way; 2 cells away is
local rp = B.classify({ { class = "Station_01", gx = 4, gy = 0, h = 0, rot = 0 } }, { SIDE }, rinfo_of, {}, {})
check("probe: station 4 away from side, no removal", #rp.remove == 0 and #rp.accept == 1)
local rp2 = B.classify({ { class = "Station_01", gx = 2, gy = 0, h = 0, rot = 0 } }, { SIDE }, rinfo_of, {}, { { class = "Station_01", gx = 2, gy = 0, h = 0, rot = 0 } })
check("probe: station 2 away from side overlaps it -> removed", #rp2.remove == 1 and rp2.remove[1] == SIDE)
-- no path: live block is one cell, nothing removed unless the cell is hit
local bare = { class = "ShipyardSide", gx = 0, gy = 0, h = 0, rot = 0 }   -- no path: no info, one cell
local rb = B.classify({ S1 }, { bare }, function(c, p) if p == nil and c == "ShipyardSide" then return nil end return rinfo_of(c) end, {}, { S1 })
check("no path: one-cell live block, removed when hit", #rb.remove == 1 and rb.refund.ITEM_Plate == nil)
-- off (no file): old behaviour, no removal
local ro = B.classify({ S1 }, { SIDE }, rinfo_of, {})
check("off: no file -> occupied, nothing removed", #ro.remove == 0 and #ro.accept == 0)

-- send: pending reset, remove each, add each, ONE apply, in that order
local function rfake(fail_at)
    local n = { calls = {}, applies = 0 }
    n.pending = function(st, apply, reset)
        n.calls[#n.calls + 1] = string.format("pending %s %s", tostring(apply), tostring(reset))
        if apply then n.applies = n.applies + 1 end
        if fail_at == "reset" and reset and not apply then return false, "boom" end
        if fail_at == "apply" and apply then return false, "nope" end
        return true
    end
    n.remove_block = function(st, cls, x, y, h, rot)
        n.calls[#n.calls + 1] = ("remove %s %d,%d,%d r%d"):format(cls, x, y, h, rot)
        if fail_at == "remove" then return false, "not found" end
        return true
    end
    n.add_block = function(st, cls, x, y, h, rot)
        n.calls[#n.calls + 1] = "add " .. cls
        return true
    end
    return n
end
local rids = { primary = 7, player = 8, editing = 0 }
local nr = rfake()
check("send+remove ok", B.send(nr, 3, { S1 }, rids, { SIDE }) == true)
check("send+remove order: reset, remove, add, one apply", table.concat(nr.calls, ",") == "pending false true,remove ShipyardSide 0,0,0 r0,add Station_01,pending true false"
    and nr.applies == 1)
local nf = rfake("remove")
local okf, ef = B.send(nf, 3, { S1 }, rids, { SIDE })
check("send remove fail -> false, reset, no add", not okf and ef:find("remove_block failed", 1, true) ~= nil
    and nf.calls[#nf.calls] == "pending false true" and nf.applies == 0)
local nno = rfake()
B.send(nno, 3, { S1 }, rids)
check("send without removes: no remove_block call", table.concat(nno.calls, ",") == "pending false true,add Station_01,pending true false")

-- wait: added blocks shown but the side still there -> still missing; gone -> done
local live_side = { SIDE }
check("wait: side still present -> not done", #B.missing_after({ S1 }, { S1, SIDE }, { SIDE }) == 1)
check("wait: side gone, block shown -> done", #B.missing_after({ S1 }, { S1 }, { SIDE }) == 0)
check("wait: side still there and block not shown -> 2 missing", #B.missing_after({ S1 }, live_side, { SIDE }) == 2)
check("wait: no removes -> old behaviour", #B.missing_after({ S1 }, {}) == 1)

-- player names and sentence parts
check("name: table entry", B.name("BPO_Station_01") == "Station 1x1" and B.name("BPO_ShipyardCore_02") == "Shipyard core 2")
check("name: fallback strips BPO_ and underscores", B.name("BPO_Thing_Two") == "Thing Two" and B.name("Gone") == "Gone")
check("place_text", B.place_text({ class = "BPO_ShipyardCore_02", gx = -8, gy = 0, h = -4 }) == "Shipyard core 2 at (-8, 0), level -4")
check("listing 1/2/3 and more", B.listing({ "a" }) == "a" and B.listing({ "a", "b" }) == "a and b"
    and B.listing({ "a", "b", "c" }) == "a, b and c" and B.listing({ "a", "b" }, 4) == "a and b and 2 more")

print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
