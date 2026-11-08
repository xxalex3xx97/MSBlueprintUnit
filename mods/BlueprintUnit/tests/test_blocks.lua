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
check("classify notes count", #r.notes == 7)
check("classify notes text", r.notes[1] == "Gone at 1,0,0: class not in this game")
check("classify skip occupied", r.notes[6] == "Ok at 9,9,0: cell occupied or overlaps a block already placed")
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

print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
