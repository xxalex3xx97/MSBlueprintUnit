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
check("blocks: message", err == "Blocks are not on the grid: BPO_Station_01@(2,0,h0);")

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
-- same machine as NEW (not live): still refused by the floor check
p, err = P.plan(one_container(200, 200), live(), F)
check("outside new: refused", p == nil)
check("outside new: floor message", err ~= nil and err:find("outside every floor of its layer: DAT_Container_2", 1, true) ~= nil)
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

print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
