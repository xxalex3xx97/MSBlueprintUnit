-- test_plan.lua: bpu_plan checks (probe selftest numbers). Run: lua test_plan.lua (from any dir). Exit code 1 when a check fails.
-- Factory module = tests/fixtures/mscore_factory_snapshot.lua (copy of MSCore; must track MSCore).
local dir = (arg and arg[0] or ""):match("^(.*[/\\])") or "./"
package.path = dir .. "../Scripts/?.lua;" .. package.path
local P = require("bpu_plan")
local F = dofile(dir .. "fixtures/mscore_factory_snapshot.lua")

local pass, fail = 0, 0
local function check(name, cond)
    if cond then pass = pass + 1; print("PASS " .. name) else fail = fail + 1; print("FAIL " .. name) end
end
local function read(name)
    local f = assert(io.open(dir .. "fixtures/" .. name, "rb"))
    local s = f:read("a")
    f:close()
    return s
end

local BUILDABLES = {
    DAT_ConveyorBelt = { bcls = "BP_ConveyorBeltObject", cost = { ITEM_A = 2 } },
    DAT_Splitter = { bcls = "BP_Splitter", cost = { ITEM_A = 1, ITEM_B = 3 } },
    DAT_Refinery = { bcls = "BP_RefineryObject", cost = { ITEM_A = 5 } },
    DAT_UndergroundBelt_2 = { bcls = "BP_UndergroundBeltObject_2", cost = { ITEM_A = 4 } },
    DAT_Dock = { bcls = "BP_DockObject", cost = {} },
    DAT_ItemCrate = { bcls = "BP_ItemCrateObject", cost = {} },
    DAT_Teleporter = { bcls = "BP_TeleporterObject", cost = { ITEM_A = 9 } },
    DAT_Container_2 = { bcls = "BP_ContainerObject_2", cost = {} },
}

-- live station: one BPO_Station_01 block at (0,0) (floor +-14), recipes as bpu_live reports them
local function live(over)
    local l = {
        station = 42,
        blocks = { { class = "BPO_Station_01", gx = 0, gy = 0, h = 0, rot = 0 } },
        existing = {},
        recipes = { REC_TitaniumPlates = "TitaniumPlates" },
        buildables = BUILDABLES,
    }
    for k, v in pairs(over or {}) do l[k] = v end
    return l
end
local function ex(id, bcls, dat, x, y, cfg)
    return { id = id, cls = bcls, bcls = bcls, dat = dat, x = x, y = y, h = 0, rot = 0, cfg = cfg }
end
local function plan_of(file, over)
    return P.plan(read(file), live(over), F)
end

-- empty blueprint on an empty station
local p = plan_of("empty.json")
check("empty: valid plan", p and p.valid and p.station == 42)
check("empty: nothing to do", p and p.counts.place == 0 and p.counts.keep == 0 and p.counts.remove == 0)
check("empty: summary text", p and P.summary(p) == "place 0, keep 0, remove 0, recipe changes 0")

-- two belts on empty station: placed, cost 2 each
p = plan_of("belts2.json")
check("belts2: place 2", p and p.counts.place == 2 and p.counts.remove == 0)
check("belts2: need A 4", p and p.need.ITEM_A == 4 and next(p.refund) == nil)
check("belts2: machine fields", p and p.place[1].bcls == "BP_ConveyorBeltObject" and p.place[1].dat == "DAT_ConveyorBelt" and p.place[1].w == 1)

-- identical to station: keep all, place 0, nothing paid
p = plan_of("belts2.json", { existing = { ex(10, "BP_ConveyorBeltObject", "DAT_ConveyorBelt", 1, 1), ex(11, "BP_ConveyorBeltObject", "DAT_ConveyorBelt", 3, 1) } })
check("identical: keep 2, place 0", p and p.counts.keep == 2 and p.counts.place == 0 and p.counts.remove == 0)
check("identical: kept ids copied", p and p.kept[1].id == 10 and p.kept[2].id == 11)
check("identical: no cost rows", p and #P.cost_rows(p) == 0 and P.removes_text(p) == "")

-- one belt moved: place 1, remove 1, net cost 0
p = plan_of("belt_moved.json", { existing = { ex(10, "BP_ConveyorBeltObject", "DAT_ConveyorBelt", 1, 1) } })
check("moved: place 1 remove 1", p and p.counts.place == 1 and p.counts.remove == 1)
local rows = p and P.cost_rows(p) or {}
check("moved: net cost 0", #rows == 1 and rows[1].name == "ITEM_A" and rows[1].net == 0 and rows[1].need == 2 and rows[1].refund == 2)
check("moved: removes text", p and P.removes_text(p) == "removes: 1 belt")
check("moved: summary", p and P.summary(p) == "place 1, keep 0, remove 1 (refund A x2), recipe changes 0")

-- probe numbers: 2 placed (A:2 each) + 1 removed splitter (A:1, B:3) -> need A 4, refund A 1 B 3, net A 3 B -3
p = plan_of("belts2.json", { existing = { ex(20, "BP_Splitter", "DAT_Splitter", 1, 1) } })
check("net: place 2 remove 1", p and p.counts.place == 2 and p.counts.remove == 1)
check("net: need A 4, refund A 1 B 3", p and p.need.ITEM_A == 4 and p.refund.ITEM_A == 1 and p.refund.ITEM_B == 3)
rows = p and P.cost_rows(p) or {}
check("net: rows A 3, B -3 sorted", #rows == 2 and rows[1].name == "ITEM_A" and rows[1].net == 3 and rows[2].name == "ITEM_B" and rows[2].net == -3)
check("net: summary", p and P.summary(p) == "place 2, keep 0, remove 1 (refund A x1, B x3), recipe changes 0")
check("net: stale id listed", p and #p.stale_ids == 1 and p.stale_ids[1] == 20)

-- recipe-only change on a kept refinery: chg 1, nothing placed, nothing paid
local cfg_old = F.encode_cfg({ recipe = "HullPlates", ports = { true, true, true, true } })
p = plan_of("refinery_recipe.json", { existing = { ex(30, "BP_RefineryObject", "DAT_Refinery", 1, 1, cfg_old) } })
check("recipe: chg 1, place 0, remove 0", p and #p.chg == 1 and p.counts.place == 0 and p.counts.remove == 0 and p.counts.recipe == 1)
check("recipe: old/new names", p and p.chg[1].oldRec == "HullPlates" and p.chg[1].newRec == "TitaniumPlates" and p.chg[1].m.id == 30)
check("recipe: cost 0", p and #P.cost_rows(p) == 0)
-- same recipe: no change
local cfg_same = F.encode_cfg({ recipe = "TitaniumPlates", ports = { true, true, true, true } })
p = plan_of("refinery_recipe.json", { existing = { ex(30, "BP_RefineryObject", "DAT_Refinery", 1, 1, cfg_same) } })
check("recipe: same recipe = keep, no chg", p and p.counts.keep == 1 and #p.chg == 0)

-- underground pair: ONE machine at the entrance, Length 3, exit cell not placed
p = plan_of("ug_pair.json")
check("ug: place 1, exit cell 1", p and p.counts.place == 1 and #p.cells == 1)
check("ug: entrance at -7, exit at -3", p and p.place[1].x == -7 and p.cells[1].x == -3)
check("ug: cfg 01 00 Length 3", p and p.place[1].cfg == "\1\0\3\0\0\0")
check("ug: cost of one machine", p and p.need.ITEM_A == 4)

-- stacked floors: same x,y at h0 and h8, different Length per floor. Each entrance pairs with the exit on its own floor.
do
    local stacked = '{"Version":2,"Blocks":[],"DefaultMachines":[' ..
        '{"Class":"BP_UndergroundBeltObject_2","DefaultName":"DAT_UndergroundBelt_2","Transform":{"GridLocation":{"X":-7,"Y":1},"Height":0,"GridRotation":0}},' ..
        '{"Class":"BP_UndergroundBeltObject_2","DefaultName":"DAT_UndergroundBelt_2","Transform":{"GridLocation":{"X":-7,"Y":1},"Height":8,"GridRotation":0}},' ..
        '{"Class":"BP_UndergroundBeltObject_2","DefaultName":"DAT_UndergroundBelt_2","Transform":{"GridLocation":{"X":-3,"Y":1},"Height":0,"GridRotation":0}},' ..
        '{"Class":"BP_UndergroundBeltObject_2","DefaultName":"DAT_UndergroundBelt_2","Transform":{"GridLocation":{"X":-1,"Y":1},"Height":8,"GridRotation":0}}]}'
    local ps, es = P.plan(stacked, live(), F)
    check("stacked ug: plan ok, no bail", ps ~= nil and es == nil)
    check("stacked ug: 2 entrances, 2 exit cells", ps and ps.counts.place == 2 and #ps.cells == 2)
    local e0, e8
    for _, m in ipairs(ps and ps.place or {}) do if m.h == 0 then e0 = m elseif m.h == 8 then e8 = m end end
    check("stacked ug: h0 entrance Length 3", e0 ~= nil and e0.cfg == "\1\0\3\0\0\0")
    check("stacked ug: h8 entrance Length 4", e8 ~= nil and e8.cfg == "\1\0\4\0\0\0")
    local c0, c8
    for _, c in ipairs(ps and ps.cells or {}) do if c.h == 0 then c0 = c elseif c.h == 8 then c8 = c end end
    check("stacked ug: h0 exit at -3, h8 exit at -1", c0 ~= nil and c0.x == -3 and c8 ~= nil and c8.x == -1)
end

-- ConfigHex recipe: verbatim bytes, recipe not looked up
p = plan_of("refinery_hex.json", { recipes = {} })
check("confighex: verbatim cfg, no recipe lookup", p and p.place[1].cfg == "\1\0\255")

-- recipe site id resolved through live.recipes; unknown site refused
p = plan_of("refinery_recipe.json", { recipes = {} })
check("recipe: missing live recipe refused", p == nil)
local _, err = P.plan(read("refinery_recipe.json"), live({ recipes = {} }), F)
check("recipe: error text", err == "recipe not found: titaniumore>titaniumplates")
check("recipe: resolved name stored", plan_of("refinery_recipe.json").place[1].recipe == "TitaniumPlates")

-- conflict with a never-removed machine (ItemCrate) = refused
p, err = P.plan(read("belts2.json"), live({ existing = { ex(40, "BP_ItemCrateObject", "DAT_ItemCrate", 1, 1) } }), F)
check("conflict: ItemCrate in the way refused", p == nil and err ~= nil and err:find("sync refused", 1, true) ~= nil)

-- stale: belt not in blueprint removed; Dock never removed
p = plan_of("empty.json", { existing = {
    ex(50, "BP_DockObject", "DAT_Dock", 9, 9),
    ex(51, "BP_ConveyorBeltObject", "DAT_ConveyorBelt", 5, 5),
} })
check("stale: belt removed, dock kept", p and p.counts.remove == 1 and p.stale_ids[1] == 51 and p.removed[1].id == 51)
check("stale: removes text", p and P.removes_text(p) == "removes: 1 belt")

-- blocks not on the grid: whole paste refused
p, err = P.plan(read("block_off_grid.json"), live(), F)
check("blocks: refused", p == nil)
check("blocks: message", err == "These blocks are not on the station grid: Station 1x1 at (2, 0), level 0. Fix them in the blueprint or tick Station Build.")

-- hidden Teleporter never placed (skipped with note)
p = plan_of("teleporter.json")
check("teleporter: only the belt placed", p and p.counts.place == 1 and p.place[1].bcls == "BP_ConveyorBeltObject")
check("teleporter: note", p and #p.notes >= 1 and p.notes[1]:find("Teleporter", 1, true) ~= nil)

-- bad height refused, nothing planned
p, err = P.plan(read("bad_height.json"), live(), F)
check("bad height: refused", p == nil and err == "machine Height not a multiple of 8: BP_ConveyorBeltObject")

-- summary / removes / cost text helpers on hand-made plans
check("summary: 7 refund items show 5 + '+2 more'", P.summary({ counts = { place = 0, keep = 0, remove = 3, recipe = 0 },
    refund = { ITEM_a = 1, ITEM_b = 2, ITEM_c = 3, ITEM_d = 4, ITEM_e = 5, ITEM_f = 6, ITEM_g = 7 } })
    == "place 0, keep 0, remove 3 (refund a x1, b x2, c x3, d x4, e x5, +2 more), recipe changes 0")
check("summary: no refund items = none", P.summary({ counts = { place = 0, keep = 0, remove = 1, recipe = 0 }, refund = {} })
    == "place 0, keep 0, remove 1 (refund none), recipe changes 0")
check("summary: no refund part when R=0", P.summary({ counts = { place = 2, keep = 1, remove = 0, recipe = 0 }, refund = {} })
    == "place 2, keep 1, remove 0, recipe changes 0")
check("removes: belts and splitter", P.removes_text({ removes = { BP_ConveyorBeltObject = 3, BP_Splitter = 1 } }) == "removes: 3 belts, 1 splitter")
check("removes: large container", P.removes_text({ removes = { BP_ContainerObject_2 = 1 } }) == "removes: 1 large container")
check("removes: none = empty", P.removes_text({ removes = {} }) == "")

-- fingerprint: stable, changes when one machine moves or goes
local e1 = ex(7, "BP_Splitter", "DAT_Splitter", 1, 1)
local e2 = ex(8, "BP_Splitter", "DAT_Splitter", 3, 1)
local e2m = ex(8, "BP_Splitter", "DAT_Splitter", 5, 1)
local fa = P.fingerprint({ e1, e2 })
check("fingerprint: stable", fa == P.fingerprint({ e1, e2 }))
check("fingerprint: moved machine changes it", fa ~= P.fingerprint({ e1, e2m }))
check("fingerprint: removed machine changes it", fa ~= P.fingerprint({ e1 }))

-- overlay-style entries (virtual machines: negative ids, string/float coordinates, nil fields): no error, stable
do
    local ov1 = { id = -1, bcls = "BP_A", x = 0.5, y = "3", rot = 0 }
    local ov2 = { id = -2, bcls = nil, x = nil, y = 4, h = 1, rot = "2" }
    local okv, fv = pcall(P.fingerprint, { e1, ov1, ov2 })
    check("fingerprint: overlay-style entries ok, stable", okv and fv == P.fingerprint({ e1, ov1, ov2 }) and fv ~= fa)
    check("fingerprint: overlay machine added changes it", fv ~= P.fingerprint({ e1, ov1 }))
    -- root cause: Lua 5.4 coerces numeric strings for + and *, never for ~ / &. A string byte raises the game error.
    local sb = string.byte
    string.byte = function(...) return tostring(sb(...)) end
    local okp, fp2 = pcall(P.fingerprint, { e1, ov1, ov2 })
    string.byte = sb
    check("fingerprint: string.byte returning strings, same value (arithmetic coerces)", okp and fp2 == fv)
    local okb, msgb = pcall(function() return 5 ~ tostring(65) end)
    check("root cause: '~' on a string operand raises 'bitwise operation on a string value'",
          not okb and tostring(msgb):find("bitwise operation on a string value", 1, true) ~= nil)
end

-- floor check only for placed machines: a live container outside every floor, identical in the JSON, is kept (no validation)
local function one_container(x, y)
    return '{"Version":2,"Blocks":[],"DefaultMachines":[{"Class":"BP_ContainerObject_2","DefaultName":"DAT_Container_2","Transform":{"GridLocation":{"X":' .. x .. ',"Y":' .. y .. '},"Height":0,"GridRotation":0}}]}'
end
p, err = P.plan(one_container(200, 200), live({ existing = { ex(60, "BP_ContainerObject_2", "DAT_Container_2", 200, 200) } }), F)
check("outside keep: plan ok", p ~= nil and err == nil)
check("outside keep: counted as keep", p and p.counts.keep == 1 and p.counts.place == 0 and p.counts.remove == 0)
-- website-only root key "SiteOnly": ignored whatever its shape, and absence is fine
for _, so in ipairs({ '{"InfiniteContainers":[8,386]}', '[]', '"x"', '5', 'null', '{}' }) do
    local t = one_container(200, 200):gsub('^{', '{"SiteOnly":' .. so .. ',')
    local pp, ee = P.plan(t, live({ existing = { ex(60, "BP_ContainerObject_2", "DAT_Container_2", 200, 200) } }), F)
    check("SiteOnly " .. so .. ": ignored", pp ~= nil and ee == nil)
end
-- same machine as NEW (not live): placed anyway (the game does not check floors), with a note
p, err = P.plan(one_container(200, 200), live(), F)
check("outside new: plan ok, placed", p ~= nil and err == nil and p.counts.place == 1)
local noted = false
for _, n in ipairs(p and p.notes or {}) do if n == "1 placed outside the modeled floors: DAT_Container_2 x1" then noted = true end end
check("outside new: placed note", noted)
-- placed belt overlapping a kept container: still checked (kept-vs-kept is not)
local ov = '{"Version":2,"Blocks":[],"DefaultMachines":[' ..
    '{"Class":"BP_ContainerObject_2","DefaultName":"DAT_Container_2","Transform":{"GridLocation":{"X":12,"Y":12},"Height":0,"GridRotation":0}},' ..
    '{"Class":"BP_ConveyorBeltObject","DefaultName":"DAT_ConveyorBelt","Transform":{"GridLocation":{"X":13,"Y":13},"Height":0,"GridRotation":0}}]}'
p, err = P.plan(ov, live({ existing = { ex(61, "BP_ContainerObject_2", "DAT_Container_2", 12, 12) } }), F)
check("kept vs placed: overlap still refused", p == nil and err ~= nil and err:find("overlap:", 1, true) ~= nil)

-- stress: 3000 belts over four 60x60 floors (BPO_Station_02 at gx,gy 0/8)
do
    local blocks = {}
    local bl_live = {}
    for _, gy in ipairs({ 0, 8 }) do
        for _, gx in ipairs({ 0, 8 }) do
            blocks[#blocks + 1] = string.format('{"Class":"BPO_Station_02","GridLocation":{"X":%d,"Y":%d},"Height":0,"GridRotation":0}', gx, gy)
            bl_live[#bl_live + 1] = { class = "BPO_Station_02", gx = gx, gy = gy, h = 0, rot = 0 }
        end
    end
    local machines = {}
    for i = 0, 2999 do
        local b, j = i // 900, i % 900
        local bx, by = (b % 2) * 8, (b // 2) * 8
        local x = bx * 8 + (-29 + 2 * (j % 30))
        local y = by * 8 + (-29 + 2 * (j // 30))
        machines[#machines + 1] = string.format('{"Class":"BP_ConveyorBeltObject","DefaultName":"DAT_ConveyorBelt","Transform":{"GridLocation":{"X":%d,"Y":%d},"Height":0,"GridRotation":0}}', x, y)
    end
    local text = '{"Version":2,"Blocks":[' .. table.concat(blocks, ",") .. '],"DefaultMachines":[' .. table.concat(machines, ",") .. "]}"
    local t0 = os.clock()
    local sp, serr = P.plan(text, live({ blocks = bl_live }), F)
    local dt = os.clock() - t0
    print(string.format("info: 3000-machine plan in %.3f s (%s)", dt, tostring(serr)))
    check("stress: 3000 placed", sp and sp.counts.place == 3000)
    check("stress: time under 2 s", dt < 2.0)
end

-- live list holding a non-table entry (a number): dropped once in build; the two real machines still match
local okn, pn = pcall(P.plan, read("belts2.json"), live({ existing = { ex(10, "BP_ConveyorBeltObject", "DAT_ConveyorBelt", 1, 1), 5, ex(11, "BP_ConveyorBeltObject", "DAT_ConveyorBelt", 3, 1) } }), F)
check("non-table live entry: no error, both belts kept", okn and pn and pn.valid and pn.counts.keep == 2 and pn.counts.place == 0)

-- ===== container contents: Contents parse, restore source (JSON / memory), refund contents, cost rows =====
local ITEMS = { "ITEM_IronOre", "ITEM_Plate" }
local function cont_doc(contents_json, x, y, cls, dat)
    local c = contents_json and (',"Contents":' .. contents_json) or ""
    return '{"Version":2,"Blocks":[],"DefaultMachines":[{"Class":"' .. (cls or "BP_ContainerObject_2") .. '","DefaultName":"' .. (dat or "DAT_Container_2")
        .. '","Transform":{"GridLocation":{"X":' .. x .. ',"Y":' .. y .. '},"Height":0,"GridRotation":0}' .. c .. '}]}'
end
local function row_of(rows, name)
    for _, r in ipairs(rows or {}) do if r.name == name then return r end end
end

-- container cells on the station floor (+-14); off the floor the placement is skipped with a note
local pc, perr = P.plan(cont_doc('[{"Item":"ironore","Count":120}]', 2, 2), live({ items = ITEMS }), F)
check("contents: plan ok", pc ~= nil and perr == nil)
check("contents: restore IronOre 120 on the placed container", pc and pc.restore.ITEM_IronOre == 120 and pc.place[1].restore[1].name == "ITEM_IronOre" and pc.place[1].restore[1].count == 120)
check("contents: need stays machine cost only", pc and next(pc.need) == nil)
local rr = pc and row_of(P.cost_rows(pc), "ITEM_IronOre")
check("contents: cost row need 120 refund 0 net 120", rr and rr.need == 120 and rr.refund == 0 and rr.net == 120)

local pn, nerr = P.plan(cont_doc('[{"Item":"unobtainium","Count":5}]', 2, 2), live({ items = ITEMS }), F)
check("contents: unknown item skipped with a note, plan ok", pn ~= nil and nerr == nil and tostring(table.concat(pn.notes, ";")):find("Contents item skipped (unknown): unobtainium", 1, true) ~= nil)
-- singular site id resolves to the plural live item
local ps1 = P.plan(cont_doc('[{"Item":"reinforcedplate","Count":7}]', 2, 2), live({ items = { "ITEM_ReinforcedPlates", "ITEM_IronOre" } }), F)
local rp = ps1 and ps1.restore and ps1.restore["ITEM_ReinforcedPlates"]
check("contents: singular id reinforcedplate = ITEM_ReinforcedPlates", ps1 ~= nil and rp == 7)

local pci = P.plan(cont_doc('[{"Item":"Iron Ore","Count":3},{"Item":"ITEM_ironore","Count":4}]', 2, 2), live({ items = ITEMS }), F)
check("contents: case/space/ITEM_ insensitive, duplicates summed", pci and pci.restore.ITEM_IronOre == 7)

local pb = P.plan(cont_doc('[{"Item":"ironore","Count":5}]', 1, 1, "BP_ConveyorBeltObject", "DAT_ConveyorBelt"), live({ items = ITEMS }), F)
check("contents: on a non-container = note, nothing restored", pb and next(pb.restore) == nil and tostring(table.concat(pb.notes, ";")):find("Contents ignored", 1, true) ~= nil)
-- per-container SiteOnly (website sim data) and Contents[].Infinite: both ignored, Contents still read
do
    local t = '{"Version":2,"Blocks":[],"DefaultMachines":[{"Class":"BP_ContainerObject_2","DefaultName":"DAT_Container_2","Transform":{"GridLocation":{"X":2,"Y":2},"Height":0,"GridRotation":0},"Contents":[{"Item":"ironore","Count":125,"Infinite":false}],"SiteOnly":{"Infinite":[{"Item":"warpfuel","Count":0}]}}],"SiteOnly":{"x":1}}'
    local pp, ee = P.plan(t, live({ items = ITEMS }), F)
    check("per-container SiteOnly + Infinite flag: plan ok", pp ~= nil and ee == nil)
end

local pj = P.plan(cont_doc('[{"Item":"ironore","Count":120}]', 2, 2), live({ items = ITEMS, memory = { ["BP_ContainerObject_2|2|2|0|0"] = { { name = "ITEM_Plate", count = 7 } } } }), F)
check("contents: JSON wins over memory", pj and pj.restore.ITEM_IronOre == 120 and pj.restore.ITEM_Plate == nil)
local pm = P.plan(cont_doc(nil, 2, 2), live({ items = ITEMS, memory = { ["BP_ContainerObject_2|2|2|0|0"] = { { name = "ITEM_Plate", count = 7 } } } }), F)
check("contents: no JSON -> memory of the same cell", pm and pm.restore.ITEM_Plate == 7 and pm.place[1].restore[1].name == "ITEM_Plate")

-- removed container with live contents: refund list (merged), refund_cost stays machine only
local old = ex(60, "BP_ContainerObject_2", "DAT_Container_2", 300, 300)
old.contents = { { name = "ITEM_Plate", count = 7 } }
local pr = P.plan(read("empty.json"), live({ items = ITEMS, existing = { old } }), F)
check("refund contents: removed container listed", pr and pr.counts.remove == 1 and pr.refund.ITEM_Plate == 7)
check("refund contents: refund_cost has no contents", pr and pr.refund_cost.ITEM_Plate == nil)
check("refund contents: refund row 7", pr and row_of(P.cost_rows(pr), "ITEM_Plate") and row_of(P.cost_rows(pr), "ITEM_Plate").refund == 7)
check("refund contents: summary text lists Plate x7", pr and P.summary(pr):find("refund Plate x7", 1, true) ~= nil)

-- cost rows: restore (need) and removed contents (refund) together
local old2 = ex(61, "BP_ContainerObject_2", "DAT_Container_2", 300, 300)
old2.contents = { { name = "ITEM_Plate", count = 7 } }
local pmix = P.plan(cont_doc('[{"Item":"ironore","Count":120}]', 2, 2), live({ items = ITEMS, existing = { old2 } }), F)
local rows = pmix and P.cost_rows(pmix) or {}
local ri, rp = row_of(rows, "ITEM_IronOre"), row_of(rows, "ITEM_Plate")
check("cost rows: IronOre need 120 net 120", ri and ri.need == 120 and ri.net == 120)
check("cost rows: Plate refund 7 net -7", rp and rp.refund == 7 and rp.net == -7)

-- off-floor underground pair: placed anyway (one machine + exit cell), note counts the machine.
-- A live Dock on the exit cell refused the plan (never-removed machine in the way), so the case has no live Dock.
do
    local ugout = '{"Version":2,"Blocks":[],"DefaultMachines":[' ..
        '{"Class":"BP_UndergroundBeltObject_2","DefaultName":"DAT_UndergroundBelt_2","Transform":{"GridLocation":{"X":21,"Y":1},"Height":0,"GridRotation":0}},' ..
        '{"Class":"BP_UndergroundBeltObject_2","DefaultName":"DAT_UndergroundBelt_2","Transform":{"GridLocation":{"X":25,"Y":1},"Height":0,"GridRotation":0}}]}'
    local pu, eu = P.plan(ugout, live(), F)
    check("off-floor ug: plan ok", pu ~= nil and eu == nil)
    check("off-floor ug: placed 1, exit cell 1, no removal", pu and pu.counts.place == 1 and #pu.cells == 1 and pu.counts.remove == 0)
    local nu = false
    for _, n in ipairs(pu and pu.notes or {}) do if n:find("placed outside the modeled floors", 1, true) then nu = true end end
    check("off-floor ug: placed note", nu)
end

-- negative ids (bpu_live overlay, not in the game view yet): never removed, never stale
p = plan_of("empty.json", { existing = { ex(-1, "BP_ConveyorBeltObject", "DAT_ConveyorBelt", 5, 5) } })
check("virtual stale: not removed, not in stale_ids", p and p.counts.remove == 0 and #p.removed == 0 and #p.stale_ids == 0)
-- negative id in the way of a placement: refused up front (send_remove would refuse it mid-build)
p, err = P.plan(read("belts2.json"), live({ existing = { { id = -2, cls = "BP_ConveyorBeltObject", bcls = "BP_ConveyorBeltObject", dat = "DAT_ConveyorBelt", x = 1, y = 1, h = 0, rot = 2 } } }), F)
check("virtual conflict: refused, not queued", p == nil and err ~= nil and err:find("not in the game view yet", 1, true) ~= nil)

-- ===== off-floor placement notes and restore note =====
local RESTORE_NOTE = "items on belts and in machines are not restored (the blueprint holds container contents only)"
local function has_note(pl, text)
    for _, n in ipairs(pl and pl.notes or {}) do if n == text then return true end end
    return false
end
-- placed container with contents on the floor: restore note; belts-only doc (no contents): no restore note
check("restore note: container contents on the floor", has_note(pc, RESTORE_NOTE))
check("restore note: none without container contents", not has_note(plan_of("belts2.json"), RESTORE_NOTE))

-- empty block list: every machine placed off-floor, exactly one note with N = machine count
local nb_doc = '{"Version":2,"Blocks":[],"DefaultMachines":[' ..
    '{"Class":"BP_ConveyorBeltObject","DefaultName":"DAT_ConveyorBelt","Transform":{"GridLocation":{"X":1,"Y":1},"Height":0,"GridRotation":0}},' ..
    '{"Class":"BP_ConveyorBeltObject","DefaultName":"DAT_ConveyorBelt","Transform":{"GridLocation":{"X":3,"Y":1},"Height":0,"GridRotation":0}}]}'
p, err = P.plan(nb_doc, live({ blocks = {} }), F)
check("no blocks: plan ok, both placed", p ~= nil and err == nil and p.counts.place == 2)
local n_placed_notes = 0
for _, n in ipairs(p and p.notes or {}) do if n:find("placed outside the modeled floors", 1, true) then n_placed_notes = n_placed_notes + 1 end end
check("no blocks: one placed note, N = 2", n_placed_notes == 1 and has_note(p, "2 placed outside the modeled floors: DAT_ConveyorBelt x2"))

-- integration: Main_Base-style station; every machine on a modeled floor, so no off-floor note
do
    local B = {
        { "BPO_Station_02A", 2, 42, 0, 0 }, { "BPO_Station_02A", 2, -42, 0, 0 },
        { "BPO_Station_02A", 14, 10, 4, 0 }, { "BPO_Station_02A", -2, 10, 4, 0 },
        { "BPO_Dock_2", 2, 50, 0, 1 }, { "BPO_Dock_2", 2, -50, 0, 3 },
        { "BPO_ElevatorBlock_03", 16, 16, 0, 0 }, { "BPO_ElevatorBlock_03", -4, 16, 0, 0 },
    }
    local dblocks, lblocks = {}, {}
    for i, b in ipairs(B) do
        dblocks[i] = ('{"Class":"%s","GridLocation":{"X":%d,"Y":%d},"Height":%d,"GridRotation":%d}'):format(b[1], b[2], b[3], b[4], b[5])
        lblocks[i] = { class = b[1], gx = b[2], gy = b[3], h = b[4], rot = b[5] }
    end
    local function mach(cls, dat, x, y)
        return ('{"Class":"%s","DefaultName":"%s","Transform":{"GridLocation":{"X":%d,"Y":%d},"Height":0,"GridRotation":0}}'):format(cls, dat, x, y)
    end
    local ms = {
        mach("BP_ContainerObject_2", "DAT_Container_2", 8, 386),
        mach("BP_ContainerObject_2", "DAT_Container_2", 24, 386),
        mach("BP_ContainerObject_2", "DAT_Container_2", 8, 376),
        mach("BP_ConveyorBeltObject", "DAT_ConveyorBelt", 5, 367),
        mach("BP_ConveyorBeltObject", "DAT_ConveyorBelt", 37, -367),
        mach("BP_ConveyorBeltObject", "DAT_ConveyorBelt", 123, 111),
        mach("BP_ConveyorBeltObject", "DAT_ConveyorBelt", -27, 111),
    }
    local text = '{"Version":2,"Blocks":[' .. table.concat(dblocks, ",") .. '],"DefaultMachines":[' .. table.concat(ms, ",") .. "]}"
    local pi, ei = P.plan(text, live({ blocks = lblocks }), F)
    check("integration: plan ok", pi ~= nil and ei == nil)
    check("integration: every machine placed", pi ~= nil and pi.counts.place == #ms)
    local off_note = false
    for _, n in ipairs(pi and pi.notes or {}) do
        if n:find("skipped (outside", 1, true) or n:find("placed outside", 1, true) then off_note = true end
    end
    check("integration: no off-floor note", pi ~= nil and not off_note)
end

-- kept splitter: live cfg bytes vs the blueprint ConfigHex. Different (or empty/missing live cfg) = counted; equal = not
local function split_json(hex)
    return '{"Version":2,"Blocks":[],"DefaultMachines":[{"Class":"BP_Splitter","DefaultName":"DAT_Splitter","ConfigHex":"' .. hex ..
        '","Transform":{"GridLocation":{"X":1,"Y":1},"Height":0,"GridRotation":0}}]}'
end
local OLD_SPLIT_NOTE = "1 kept splitters have different port settings than the blueprint (not changed)"
local NEW_SPLIT_NOTE = "1 splitters replaced (config differed)"
local function has_note(pp, text)
    for _, n in ipairs(pp and pp.notes or {}) do
        if n == text then return true end
    end
    return false
end
local function split_kept(live_cfg)
    return P.plan(split_json("0102"), live({ existing = { ex(7, "BP_Splitter", "DAT_Splitter", 1, 1, live_cfg) } }), F)
end
local ps1, pe1 = split_kept("\1\3")
check("kept splitter: differing live cfg -> removed and placed again", ps1 ~= nil and pe1 == nil and ps1.counts.keep == 0 and ps1.counts.place == 1 and ps1.counts.remove == 1)
check("kept splitter: differing live cfg -> replaced note", has_note(ps1, NEW_SPLIT_NOTE))
local ps2 = split_kept("")
check("kept splitter: empty live cfg counts as different", has_note(ps2, OLD_SPLIT_NOTE))
local ps3 = split_kept(nil)
check("kept splitter: no live cfg counts as different", has_note(ps3, OLD_SPLIT_NOTE))
local ps4 = split_kept("\1\2")
check("kept splitter: same bytes -> still kept, no note", ps4 ~= nil and ps4.counts.keep == 1 and ps4.counts.place == 0 and ps4.counts.remove == 0
    and not has_note(ps4, NEW_SPLIT_NOTE) and not has_note(ps4, OLD_SPLIT_NOTE))

-- Station Build (opts.station_build): missing station blocks are classified, not refused
local SB_BOUNDS = { x0 = 0, x1 = 0, y0 = 0, y1 = 0, z0 = 0, z1 = 0 }
local SB_INFO = {
    BPO_Station_01 = { station = true, unlocked = true, bounds = SB_BOUNDS, cost = { ITEM_A = 2 } },
    BPO_Station_02 = { station = true, unlocked = true, bounds = SB_BOUNDS, cost = { ITEM_B = 1 } },
}
local function sb_info(cls) return SB_INFO[cls] end
local function sb_json(...)
    local parts = { ... }
    return '{"Version":2,"Blocks":[' .. table.concat(parts, ",") .. '],"DefaultMachines":[]}'
end
local function sb_block(cls, x, y, h)
    return '{"Class":"/Game/B/' .. cls .. '.' .. cls .. '_C","GridLocation":{"X":' .. x .. ',"Y":' .. y .. '},"Height":' .. h .. ',"GridRotation":0}'
end
local function sb_plan(text, over, trace)
    local l = live({ block_info = sb_info, have = { ITEM_A = 10, ITEM_B = 10 } })
    for k, v in pairs(over or {}) do l[k] = v end
    return P.plan(text, l, F, { station_build = true, trace = trace })
end
local function has_note(p, s)
    for _, n in ipairs(p and p.notes or {}) do if n:find(s, 1, true) then return true end end
    return false
end

local trace_lines = {}
local sp = sb_plan(sb_json(sb_block("BPO_Station_01", 2, 0, 0)), nil, function(t) trace_lines[#trace_lines + 1] = t end)
check("sb: valid plan, one block accepted", sp and sp.valid and sp.block_count == 1 and sp.blocks[1].gx == 2)
check("sb: block cost in need rows", sp and sp.block_need.ITEM_A == 2 and #P.cost_rows(sp) == 1 and P.cost_rows(sp)[1].need == 2)
check("sb: summary adds blocks N", sp and P.summary(sp) == "place 0, keep 0, remove 0, recipe changes 0, blocks 1")
check("sb: no refusal when enough", sp and sp.block_refuse == nil)
local self_line = false
for _, t in ipairs(trace_lines) do if t == "station blocks self overlaps: 0" then self_line = true end end
check("sb: trace self overlaps 0", self_line)

-- shortfall: refused only when not creative
local sh = sb_plan(sb_json(sb_block("BPO_Station_01", 2, 0, 0)), { have = { ITEM_A = 1 } })
check("sb: shortfall list", sh and sh.block_refuse and #sh.block_refuse == 1 and sh.block_refuse[1].item == "ITEM_A"
    and sh.block_refuse[1].need == 2 and sh.block_refuse[1].have == 1)
local cr = sb_plan(sb_json(sb_block("BPO_Station_01", 2, 0, 0)), { have = { ITEM_A = 1 }, creative = true })
check("sb: creative skips refusal", cr and cr.block_refuse == nil and cr.block_count == 1)

-- live BPO_Station_01 at 0,0 is not in the file: removed for BPO_Station_02 at 0,0 (refund 2 ITEM_A, cost 1 ITEM_B)
local oc = sb_plan(sb_json(sb_block("BPO_Station_02", 0, 0, 0), sb_block("BPO_Gone", 5, 0, 0)))
check("sb: live block in the way removed, file block accepted", oc and oc.block_count == 1 and #oc.block_remove == 1
    and oc.block_remove[1].class == "BPO_Station_01" and oc.block_refund.ITEM_A == 2)
check("sb: removal note", has_note(oc, "Removed the Station 1x1 that was in the way of a Station 02."))
check("sb: summary adds removed 1", P.summary(oc) == "place 0, keep 0, remove 0, recipe changes 0, blocks 1, removed 1")
check("sb: removed block refund in cost rows, net", P.cost_rows(oc)[1].name == "ITEM_A" and P.cost_rows(oc)[1].refund == 2
    and P.cost_rows(oc)[1].net == -2 and P.cost_rows(oc)[2].name == "ITEM_B" and P.cost_rows(oc)[2].need == 1)
check("sb: unknown class note", has_note(oc, "Skipped Gone: this block type is not in this game."))

-- live block that IS in the file is never removed: file overlaps itself, the second block is skipped as occupied
local inf = sb_plan(sb_json(sb_block("BPO_Station_01", 0, 0, 0), sb_block("BPO_Station_02", 0, 0, 0)))
check("sb: in-file live block not removed, overlapping block skipped", inf and inf.block_count == 0 and #inf.block_remove == 0
    and has_note(inf, "Skipped Station 02: another block of the blueprint already occupies that spot."))
check("sb: no removed count in summary when none", inf and P.summary(inf) == "place 0, keep 0, remove 0, recipe changes 0, blocks 0")

-- research state unknown for every class: one note for the run, nothing placed
local unk = sb_plan(sb_json(sb_block("BPO_Station_01", 2, 0, 0), sb_block("BPO_Station_02", 4, 0, 0)),
    { block_info = function(cls) return { station = true, unlocked = nil, bounds = SB_BOUNDS, cost = {} } end })
check("sb: unknown research for all -> one run note, nothing placed", unk and unk.block_count == 0 and has_note(unk, "Could not read the research state of any station block, so Station Build placed nothing."))

check("sb: unknown research -> per-block note", unk and has_note(unk, "Skipped Station 1x1: its research state could not be read."))

-- off: same file refused as before, nothing added
local off, off_err = P.plan(sb_json(sb_block("BPO_Station_01", 2, 0, 0)), live({ block_info = sb_info }), F, { station_build = false })
check("sb off: still refused", off == nil and off_err:find("These blocks are not on the station grid", 1, true) ~= nil)
local off2 = P.plan(sb_json(sb_block("BPO_Station_01", 2, 0, 0)), live({ block_info = sb_info }), F)
check("sb default (no opts): refused", off2 == nil)

print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
