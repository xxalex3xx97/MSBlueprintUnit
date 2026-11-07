-- test_live: bpu_live on a fake game (plain tables), then plan -> build on belts2.json through Live.make_io.
-- Run: lua test_live.lua (from any dir). Exit code 1 when a check fails.
local dir = (arg and arg[0] or ""):match("^(.*[/\\])") or "./"
package.path = dir .. "../Scripts/?.lua;" .. package.path
local Live = require("bpu_live")
local P = require("bpu_plan")
local F = dofile(dir .. "fixtures/mscore_factory_snapshot.lua")

local pass, fail = 0, 0
local function check(cond, name)
    if cond then pass = pass + 1; print("PASS " .. name) else fail = fail + 1; print("FAIL " .. name) end
end
local function read(name)
    local f = assert(io.open(dir .. "fixtures/" .. name, "rb"))
    local s = f:read("a")
    f:close()
    return s
end

-- fake game: FindAllOf / FindFirstOf over `world` (class name -> list)
local world = {}
function FindAllOf(c) return world[c] end
function FindFirstOf(c) local l = world[c]; return l and l[1] or nil end

local function alive() return true end
-- UObject stand-in: class is behind GetClass():GetFName() (as in the game, P0 cls()); there is no Class property.
local function named(s, extra)
    local o = { IsValid = alive, GetFName = function() return { ToString = function() return s end } end }
    for k, v in pairs(extra or {}) do o[k] = v end
    local c = o.Class
    o.Class = nil
    o.GetClass = function() return c or named("?") end
    return o
end
-- MSCore 0.7.2 native read_station + 0.7.3 native read_inventory: Live takes its data from here (no Lua struct reads).
-- fakeMachines / fakeInv (id -> slot structs) are what make_world sets; fakeCalls counts read_station calls.
local fakeCalls = 0
local fakeInv = {}
local fakeMachines = {
    { id = 10, cls = "BP_ConveyorBeltObject", bcls = "BP_ConveyorBeltObject", x = 1, y = 1, h = 0, rot = 0, cfg = "\1\2\255" },
    { id = 11, cls = "BP_Splitter", bcls = "BP_Splitter", x = 3, y = 1, h = 0, rot = 0, cfg = "" },
    { id = 12, cls = "BP_ConveyorBeltObject", bcls = "BP_ConveyorBeltObject", x = 5, y = 1, h = 0, rot = 0 },
}
Live.mscore = { factory_native = { read_station = function(sid)
    fakeCalls = fakeCalls + 1
    return { { class = "BPO_Station_01", gx = 0, gy = 0, h = 0, rot = 0 } }, fakeMachines
end,
-- native shape: {item="ITEM_X" | "", amount, max} per slot; the fake keeps game-like slot structs {Item, Amount}
read_inventory = function(id)
    local src = fakeInv[id]
    if not src then return nil, "no inventory " .. tostring(id) end
    local out = {}
    for i, d in ipairs(src) do
        if d.Item then
            out[i] = { item = d.Item:GetFName():ToString(), amount = d.Amount, max = d.NativeMax or d.Item.MaxStackSize }
        else
            out[i] = { item = "", amount = 0, max = 1 }
        end
    end
    return out
end } }
-- native machine entry (read_station shape)
local function rm(id, cls, x, y, cfg, h, rot)
    return { id = id, cls = cls, bcls = cls, x = x, y = y, h = h or 0, rot = rot or 0, cfg = cfg }
end
local function iname(it) return it:GetFName():ToString() end
local function slot(name, amount)
    return { Item = name and named(name, { MaxStackSize = 50 }) or nil, Amount = amount or 0 }
end
-- a Buildable keeps a real "Class" PROPERTY (the machine class it builds); its UClass is "Buildable"
local function bld(dat, cls, cost)
    local o = named(dat, { ItemCost = cost })
    o.Class = named(cls)
    return o
end

-- station 42 (block at 0,0) with container 77 (unit inv 8), decoy container for station 99, player inv 7
local function make_world(machines, uslots, pslots)
    fakeMachines = machines
    fakeInv = { [8] = uslots, [7] = pslots }
    -- no Blueprint table on the station: a Lua struct read of Blocks/Machines would fail
    local st = named("BP_StationObject_C_0", { ID = 42, Class = named("BP_StationObject_C") })
    local unit = { ID = 8, IsValid = alive }
    local pinv = { ID = 7, IsValid = alive }
    local player = named("BP_PlayerObject_C", { bCreative = false, Inventory = pinv })
    world = {
        StationObject = { named("Default__BP_StationObject_C", { ID = 42 }), st },
        ContainerObject = { named("ContainerObject_0", { ID = 78, ParentID = 99, Class = named("BP_BPUnitStoreObj_01_C"), Inventory = { ID = 9, IsValid = alive } }),
                            named("ContainerObject_1", { ID = 77, ParentID = 42, Class = named("BP_BPUnitStoreObj_01_C"), Inventory = unit }) },
        DMSPlayerObject = { player },
        Buildable = {
            bld("DAT_ConveyorBelt", "BP_ConveyorBeltObject_C", { { Item = named("ITEM_A"), Amount = 2 } }),
            bld("DAT_Splitter", "BP_Splitter_C", { { Item = named("ITEM_A"), Amount = 1 }, { Item = named("ITEM_B"), Amount = 3 } }),
            named("DAT_Old", { IsValid = function() return false end }),
            named("Default__DAT_ConveyorBelt", { Class = named("BP_ConveyorBeltObject_C"), ItemCost = {} }),
        },
        Recipe = { named("REC_TitaniumPlates", { Name = { ToString = function() return "TitaniumPlates" end } }) },
        Item = { named("ITEM_A", { MaxStackSize = 50 }), named("ITEM_B", { MaxStackSize = 50 }) },
    }
    Live.reset()
    return { station = st, unit = unit, player = player, pinv = pinv, pslots = pslots, uslots = uslots,
             block = { ID = 42, IsValid = alive }, machines = machines }
end

-------------------------------------------------------------------- reads
local machinesA = {
    rm(10, "BP_ConveyorBeltObject", 1, 1, "\1\2\255"),
    rm(11, "BP_Splitter", 3, 1, ""),
    rm(12, "BP_ConveyorBeltObject", 5, 1, nil),
}
local W = make_world(machinesA, { slot("ITEM_A", 5), slot() }, { slot(), slot() })

local U, uerr = Live.find_unit(W.block, nil)
check(U ~= nil and U.station == 42 and U.unit_inv == W.unit and U.station_obj == W.station, "find_unit: container with ParentID 42, decoy 99 skipped")
check(U ~= nil and U.cont.ID == 77, "find_unit: container id 77")
local U2 = Live.find_unit({ IsValid = alive, GetFrame = function() return { ID = 42, IsValid = alive } end }, nil)
check(U2 ~= nil and U2.station == 42, "find_unit: block id via GetFrame")
local saved = world.ContainerObject
world.ContainerObject = {}
local U3, err3 = Live.find_unit(W.block, nil)
check(U3 == nil and type(err3) == "string", "find_unit: no container -> nil, err")
world.ContainerObject = saved
-- real game: block ID 261217 is not the station id. Station 163811 holds the block (no ID),
-- container 77 has ParentID 163811. The station id comes from the block's GetFrame (first candidate).
local keepWorld = world
local W4 = make_world({}, { slot() }, { slot(), slot() })
W4.station.ID = 163811
world.ContainerObject[2].ParentID = 163811
local U4, e4 = Live.find_unit({ ID = 261217, IsValid = alive, GetFrame = function() return { ID = 163811, IsValid = alive } end }, nil)
check(U4 ~= nil and U4.station == 163811 and U4.cont.ID == 77 and U4.station_obj == W4.station,
    "find_unit: station 163811 via GetFrame; block ID 261217 is not the station " .. tostring(e4))
-- no GetFrame, no ParentID: only the block ID is left (no container matches, 2 containers) -> nil, no struct ID scan
local U5, e5 = Live.find_unit({ ID = 261217, IsValid = alive }, nil)
check(U5 == nil and type(e5) == "string", "find_unit: no station candidate -> nil, err (Blocks never scanned)")
world = keepWorld
fakeMachines = W.machines
Live.reset()

local ms = Live.read_machines(W.station)
check(#ms == 3 and ms[1].id == 10 and ms[2].id == 11 and ms[3].id == 12, "read_machines: ids, array order kept")
check(ms[1].bcls == "BP_ConveyorBeltObject" and ms[1].cls == "BP_ConveyorBeltObject", "read_machines: _C stripped")
check(ms[1].x == 1 and ms[1].y == 1 and ms[1].h == 0 and ms[1].rot == 0, "read_machines: x,y,h,rot")
check(ms[1].cfg == "\1\2\255" and ms[2].cfg == "" and ms[3].cfg == nil, "read_machines: cfg bytes, empty, unreadable=nil")

-- trace trail: the native read writes "read_station done" to <mod dir>bpu_trace.log
do
    local tf = io.open(dir .. "../bpu_trace.log", "r")
    local tt = tf and tf:read("a") or ""
    if tf then tf:close() end
    check(tt:find("read_station done blocks=1 machines=3") ~= nil, "trace: bpu_trace.log written by read_station")
end

-- no MSCore 0.7.2 native read: clear error naming 0.7.2, nothing cached
do
    local saved = Live.mscore
    Live.mscore = {}
    Live.reset()
    local okN, errN = pcall(Live.read_machines, W.station)
    Live.mscore = saved
    Live.reset()
    check(not okN and tostring(errN):find("0.7.2", 1, true) ~= nil, "read_machines without read_station: error names 0.7.2 (" .. tostring(errN) .. ")")
end

local bl = Live.read_blocks(W.station)
check(#bl == 1 and bl[1].class == "BPO_Station_01" and bl[1].gx == 0 and bl[1].gy == 0 and bl[1].h == 0 and bl[1].rot == 0,
      "read_blocks: stand-in unwrapped, class, gx, gy")

local bd = Live.read_buildables(F)
check(bd.DAT_ConveyorBelt and bd.DAT_ConveyorBelt.bcls == "BP_ConveyorBeltObject" and bd.DAT_ConveyorBelt.cost.ITEM_A == 2, "read_buildables: bcls + cost")
check(bd.DAT_Splitter and bd.DAT_Splitter.cost.ITEM_B == 3, "read_buildables: second item cost")
check(bd.DAT_Old == nil and bd.Default__DAT_ConveyorBelt == nil, "read_buildables: invalid and Default__ skipped")
check(Live.read_buildables(F) == bd, "read_buildables: cached")

local rc = Live.read_recipes()
check(rc.REC_TitaniumPlates == "TitaniumPlates" and Live._recobj.TitaniumPlates == world.Recipe[1], "read_recipes: name map + _recobj")

fakeInv = { [8] = W.uslots, [7] = W.pslots }  -- later make_world calls replace it
local ui = Live.read_inv(W.unit)
check(ui.ok and ui.id == 8 and #ui.slots == 2 and ui.slots[1].item == "ITEM_A" and ui.slots[1].amount == 5 and ui.slots[1].max == 50,
      "read_inv: native read_inventory, item name, amount, max")
check(ui.slots[2].item == "" and ui.slots[2].amount == 0, "read_inv: empty slot item \"\"")
local pi = Live.read_inv(W.pinv)
check(pi.ok and pi.id == 7 and #pi.slots == 2, "read_inv: player inventory by id")
check(not Live.read_inv(nil).ok, "read_inv: nil inventory -> ok=false")
check(not Live.read_inv({ ID = 99, IsValid = alive }).ok and Live.read_inv({ ID = 99, IsValid = alive }).err == "no inventory 99",
      "read_inv: native read fails -> ok=false with its err")
do
    local saved = Live.mscore
    Live.mscore = {}
    local nat = Live.read_inv(W.unit)
    Live.mscore = saved
    check(not nat.ok and nat.id == 8 and #nat.slots == 0 and tostring(nat.err):find("0.7.3", 1, true) ~= nil,
          "read_inv without read_inventory: ok=false, error names 0.7.3")
end

check(Live.creative(W.player, {}) == false and Live.creative({}, { bCreative = true }) == true and Live.creative({}, {}) == false,
      "creative: player, then ctl, then false")
check(Live.item_by_name("ITEM_A") == world.Item[1] and Live.item_by_name("ITEM_Z") == nil, "item_by_name: found and nil")

-- effective max: native max 1 (wrong) -> Item MaxStackSize 200; slot max = 200 * StackMultiplier / 2 (SM 8 -> 800, unit SM 202 -> 20200)
do
    local frame = named("ITEM_Frame", { MaxStackSize = 200 })
    world.Item[#world.Item + 1] = frame
    local recobj = Live._recobj   -- Live.reset clears it; later checks need it
    Live.reset()
    fakeInv[55] = { { Item = frame, Amount = 190, NativeMax = 1 }, { Amount = 0 } }
    local r = Live.read_inv({ ID = 55, IsValid = alive, StackMultiplier = 8 })
    check(r.ok and r.mult == 4 and r.slots[1].max == 800 and r.slots[2].max == 1 and Live.item_raw("ITEM_Frame") == 200,
          "read_inv: native max 1 -> Item max 200, SM 8 -> effective 800 (mult 4)")
    local u = Live.read_inv({ ID = 55, IsValid = alive, StackMultiplier = 202 })
    check(u.ok and u.mult == 101 and u.slots[1].max == 20200, "read_inv: unit SM 202 -> effective 20200 (mult 101)")
    local nosm = Live.read_inv({ ID = 55, IsValid = alive })
    check(nosm.ok and nosm.mult == 1 and nosm.slots[1].max == 200, "read_inv: SM unreadable -> 2 (x1)")
    local tf = io.open(dir .. "../bpu_trace.log", "r")
    local tt = tf and tf:read("a") or ""
    if tf then tf:close() end
    check(tt:find("maxstack inv=55 item=ITEM_Frame raw=200 (item) sm=8 effective=800", 1, true) ~= nil,
          "trace: maxstack line with raw, sm, effective")
    world.Item[#world.Item] = nil
    Live.reset()
    Live._recobj = recobj
end

-- one result line: no window write puts the build status into Txt_Summary (it was a second copy of Txt_Status)
do
    local fw = assert(io.open(dir .. "../Scripts/bpu_window.lua", "rb"))
    local src = fw:read("a")
    fw:close()
    local dup = false
    for line in src:gmatch("[^\n]+") do
        if line:find("Txt_Summary", 1, true) and line:find("status()", 1, true) then dup = true end
    end
    check(not dup, "window: build status not written to Txt_Summary (single result line)")
end

-- keep the plan after errors (source checks: bpu_window needs the UE4SS globals, no behavioural fake here)
do
    local fw = assert(io.open(dir .. "../Scripts/bpu_window.lua", "rb"))
    local src = fw:read("a")
    fw:close()
    check(src:find("okT, errT = pcall(", 1, true) ~= nil and src:find("build tick ERROR", 1, true) ~= nil,
          "window: tick error is caught, traced, and ends the run")
    check(src:find("finishBuild replan failed", 1, true) ~= nil and src:find("buildClick replan failed", 1, true) ~= nil,
          "window: replan failures traced")
    check(src:find('if not S.plan and not S.text then setStatus("import first")', 1, true) ~= nil,
          "window: Build says import first only when S.text is nil")
end

-------------------------------------------------------------------- make_io (recording natives)
local calls = {}
local native = {}
function native.inv_move(...) calls[#calls + 1] = { "inv_move", ... }; return true end
function native.disassemble(...) calls[#calls + 1] = { "disassemble", ... }; return true end
function native.place(...) calls[#calls + 1] = { "place", ... }; return true end
function native.set_recipe(...) calls[#calls + 1] = { "set_recipe", ... }; return true end
function native.port(...) calls[#calls + 1] = { "port", ... }; return true end

local ctlcalls = {}
local ctl1 = { IsValid = function() return true end }
function ctl1.AddInventoryInteraction(_, t) ctlcalls[#ctlcalls + 1] = { t.PrimaryInventoryID, t.SecondaryInventoryID, t.SlotIndex, t.Action } end
local io1 = Live.make_io({ unit = U, player = W.player, ctl = ctl1, F = F, native = native, plan_mod = P })
local okm, errm = io1.send_move(7, 8, 0)
check(okm and ctlcalls[1][1] == 7 and ctlcalls[1][2] == 8 and ctlcalls[1][3] == 0 and ctlcalls[1][4] == 2, "send_move: press AddInventoryInteraction(prim, sec, slot0, 2)")
check(ctlcalls[2][1] == 7 and ctlcalls[2][2] == 0 and ctlcalls[2][3] == 0 and ctlcalls[2][4] == 3, "send_move: release AddInventoryInteraction(prim, 0, slot0, 3) right after the press")
check(#calls == 0, "send_move: no native inv_move call")
for i = #calls, 1, -1 do calls[i] = nil end
local okr = io1.send_remove(10)
check(okr and calls[1][1] == "disassemble" and calls[1][2] == 10 and calls[1][3] == 0, "send_remove: disassemble(id, 0)")
local okp = io1.send_place({ bdat = "DAT_ConveyorBelt", x = 5, y = 2, h = 0, rot = 1, cfg = "" })
check(okp and calls[2][1] == "place" and calls[2][2] == 42 and calls[2][3] == "DAT_ConveyorBelt" and calls[2][4] == 5
      and calls[2][5] == 2 and calls[2][6] == 0 and calls[2][7] == 1 and calls[2][8] == "", "send_place: place(station, dat, x, y, h, rot, cfg)")
local cl = io1.costs({ { bdat = "DAT_ConveyorBelt" }, { bdat = "DAT_Splitter" } })
check(cl[1].ITEM_A == 2 and cl[2].ITEM_B == 3, "costs: per machine")
check(io1.creative() == false and io1.unit_ids().unit_id == 8 and io1.unit_ids().player_id == 7, "creative and unit_ids")
check(io1.read_inv("unit").id == 8 and io1.read_inv("player").id == 7, "io.read_inv: unit and player")
check(io1.read_inv("unit").slots[1].item == "ITEM_A" and io1.read_inv("player").slots[2].item == "", "io.read_inv: native slots")
check(#io1.scan(42) == 3 and select(1, io1.scan(999)) == nil and select(2, io1.scan(999)) == "station not found", "scan: by id, station not found")

-- send_changes: recipe once, one port call per index
calls = {}
local okc, failc = io1.send_changes({ { m = { id = 10 }, recipe = true, newRec = "TitaniumPlates",
                                        ports = { { index = 2, want = true }, { index = 5, want = false } } } })
check(okc == 1 and failc == 0, "send_changes: ok count 1")
local nrec, nport = 0, 0
for _, c in ipairs(calls) do
    if c[1] == "set_recipe" then
        nrec = nrec + 1
        check(c[2] == 10 and c[3] == world.Recipe[1] and c[4] == 0 and c[5] == "", "send_changes: set_recipe(machine, recipe obj, 0, \"\")")
    end
    if c[1] == "port" then nport = nport + 1 end
end
check(nrec == 1 and nport == 2 and calls[#calls][3] == 5, "send_changes: set_recipe once, port per index")

-- a throwing native is a failure, not an error
native.port = function() error("boom") end
local okc2, failc2 = io1.send_changes({ { m = { id = 10 }, recipe = false, ports = { { index = 1, want = true } } } })
check(okc2 == 0 and failc2 == 1, "send_changes: thrown native counted as failure")
native.port = function(...) calls[#calls + 1] = { "port", ... }; return true end

-- plan on the station with 3 machines: fingerprint of the live scan equals plan.fp
local planA = P.plan(read("belts2.json"), Live.snapshot(U, F), F)
check(planA and planA.valid and planA.fp == io1.fingerprint(io1.scan(42)), "fingerprint: io.fingerprint(io.scan) == plan.fp")

-------------------------------------------------------------------- integration: plan -> build on the fake station
local W2 = make_world({}, { slot("ITEM_A", 10) }, { slot(), slot() })
local U2b = Live.find_unit(W2.block, nil)
local plan2, perr = P.plan(read("belts2.json"), Live.snapshot(U2b, F), F)
check(plan2 and plan2.valid and plan2.counts.place == 2, "integration: plan belts2 places 2 " .. tostring(perr))

local nextid = 100
local BUILD_CLS = { DAT_ConveyorBelt = "BP_ConveyorBeltObject" }
local BUILD_COST = { DAT_ConveyorBelt = { ITEM_A = 2 } }
local function inv_by(id)
    if id == W2.pinv.ID then return W2.pslots end
    if id == W2.unit.ID then return W2.uslots end
end
local function count(slots, name)
    local n = 0
    for _, d in ipairs(slots) do if d.Item and iname(d.Item) == name then n = n + d.Amount end end
    return n
end
local function take(slots, name, n)
    for _, d in ipairs(slots) do
        if n > 0 and d.Item and iname(d.Item) == name then
            local t = math.min(d.Amount, n)
            d.Amount = d.Amount - t
            n = n - t
            if d.Amount == 0 then d.Item = nil end
        end
    end
end
-- puts item stacks into slots (partial first, then empty); returns what did not fit
local function put(slots, item, n)
    local name = iname(item)
    for _, d in ipairs(slots) do
        if n > 0 and d.Item and iname(d.Item) == name and d.Amount < 50 then
            local add = math.min(50 - d.Amount, n)
            d.Amount = d.Amount + add
            n = n - add
        end
    end
    for _, d in ipairs(slots) do
        if n > 0 and not d.Item then
            local add = math.min(50, n)
            d.Item, d.Amount = item, add
            n = n - add
        end
    end
    return n
end
local mnative = {}
function mnative.inv_move(prim, sec, slot0, action)
    if action == 3 then return true end   -- release: no item effect
    local src, dst = inv_by(prim), inv_by(sec)
    if not src or not dst or action ~= 2 then return false, "bad move" end
    local s = src[slot0 + 1]
    if not s or not s.Item or s.Amount <= 0 then return true end
    local left = put(dst, s.Item, s.Amount)
    s.Amount = left
    if left == 0 then s.Item = nil end
    return true
end
function mnative.place(station, dat, x, y, h, rot, cfg)
    if station ~= 42 or not BUILD_CLS[dat] then return false, "bad place" end
    for name, n in pairs(BUILD_COST[dat]) do
        if count(W2.pslots, name) < n then return false, "not enough " .. name end
    end
    for name, n in pairs(BUILD_COST[dat]) do take(W2.pslots, name, n) end
    nextid = nextid + 1
    table.insert(W2.machines, rm(nextid, BUILD_CLS[dat], x, y, nil, h, rot))
    return true
end
function mnative.disassemble() return false, "not expected" end
function mnative.set_recipe() return true end
function mnative.port() return true end

local B = dofile(dir .. "../Scripts/bpu_build.lua")
local ctl2 = { IsValid = function() return true end }
function ctl2.AddInventoryInteraction(_, t) mnative.inv_move(t.PrimaryInventoryID, t.SecondaryInventoryID, t.SlotIndex, t.Action) end
local io2 = Live.make_io({ unit = U2b, player = W2.player, ctl = ctl2, F = F, native = mnative, plan_mod = P })
local clock = 1000
io2.now = function() return clock end
local b = B.new(io2)
local oks, msgs = b:start(plan2, {})
check(oks, "integration: start ok " .. tostring(msgs))
local n = 0
while b:status().state == "working" and n < 800 do
    clock = clock + 250
    b:tick(clock)
    n = n + 1
end
local st = b:status()
check(st.state == "done" and st.placed == 2 and st.placed == #plan2.place, ("integration: done, placed %d (%s)"):format(st.placed, st.text))
check(st.text == "sent: placed 2, removed 0 (the game updates its blueprint view in about 30 s)" and #W2.machines == 2, "integration: final text, 2 machines on the station")

-- live overlay: the game view is still the pre-build station (empty). Re-import right after the build plans place 0.
do
    fakeMachines = {}
    local live3 = Live.snapshot(U2b, F)
    local plan3, e3 = P.plan(read("belts2.json"), live3, F)
    check(plan3 and plan3.valid and plan3.counts.place == 0 and plan3.counts.remove == 0 and plan3.counts.keep == 2,
        "overlay: re-import right after the build plans place 0, keep 2 " .. tostring(e3))
    local sc = io2.scan(42)
    check(sc and #sc == 2 and sc[1].id < 0 and plan3.fp == io2.fingerprint(sc), "overlay: io.scan and snapshot agree (fingerprint)")
    Live.now = function() return 1e12 end   -- 120 s passed: the overlay ends, the stale view plans place 2 again
    local plan4 = P.plan(read("belts2.json"), Live.snapshot(U2b, F), F)
    check(plan4 and plan4.counts.place == 2 and plan4.counts.keep == 0, "overlay: expired, stale view plans place 2")
end

-- real read path at Main-Base size: 2246 stub machine structs -> Live.snapshot -> P.plan (identity keep, no non-table entries)
do
    local big, parts = {}, {}
    for i = 0, 2245 do
        local x, y = (i % 50) * 2 + 1, (i // 50) * 2 + 1
        big[#big + 1] = rm(1000 + i, "BP_ConveyorBeltObject", x, y, nil)
        parts[#parts + 1] = ('{"Class":"BP_ConveyorBeltObject","DefaultName":"DAT_ConveyorBelt","Transform":{"GridLocation":{"X":%d,"Y":%d},"Height":0,"GridRotation":0}}'):format(x, y)
    end
    local WB = make_world(big, { slot() }, { slot(), slot() })
    local UB = Live.find_unit(WB.block, nil)
    local callsB = fakeCalls
    local liveB = Live.snapshot(UB, F)
    check(fakeCalls == callsB + 1, "snapshot: one read_station call serves blocks and machines")
    local textB = '{"Version":2,"DisplayName":"Big","Blocks":[{"Class":"/Game/Blueprints/BuildingBlocks/BPO_Station_01.BPO_Station_01_C","GridLocation":{"X":0,"Y":0},"Height":0,"GridRotation":0}],"DefaultMachines":[' .. table.concat(parts, ",") .. ']}'
    check(#liveB.existing == 2246 and type(liveB.existing[1]) == "table" and liveB.existing[2246].id == 3245, "snapshot: 2246 machine tables via read_machines")
    local pB, eB = P.plan(textB, liveB, F)
    check(pB and pB.valid and pB.counts.keep == 2246 and pB.counts.place == 0 and pB.counts.remove == 0, "plan: 2246 belts kept by identity, nothing placed/removed " .. tostring(eB))
end

-- live overlay on plain tables: placed merged until the fresh read shows them, removed ids dropped, 120 s end
do
    local t = 0
    Live.now = function() return t end
    local function flush() t = 1e12; Live.overlay({}) end   -- far future: ends every batch
    local A = { bcls = "BP_A", dat = "DAT_A", x = 1, y = 2, h = 0, rot = 0 }
    Live.note_build({ A }, { 5 })
    local o1 = Live.overlay({ { id = 5, bcls = "BP_OLD", x = 9, y = 9, h = 0, rot = 0 }, { id = 7, bcls = "BP_B", x = 3, y = 3, h = 0, rot = 0 } })
    check(#o1 == 2 and o1[1].id == 7 and o1[2].id == -1 and o1[2].bcls == "BP_A" and o1[2].dat == "DAT_A",
        "overlay: placed added with negative id, removed id 5 dropped")
    local o2 = Live.overlay({ { id = 7, bcls = "BP_B", x = 3, y = 3, h = 0, rot = 0 }, { id = 9, bcls = "BP_A", x = 1, y = 2, h = 0, rot = 0 } })
    check(#o2 == 2 and o2[1].id == 7 and o2[2].id == 9, "overlay: fresh read shows the build, no virtual entries")
    check(#Live.overlay({ { id = 7, bcls = "BP_B", x = 3, y = 3, h = 0, rot = 0 } }) == 1, "overlay: batch ended by the fresh read")

    flush(); t = 0
    Live.note_build({ A }, {})
    local f3 = { { id = 4, bcls = "BP_Other", x = 1, y = 2, h = 0, rot = 0 } }
    check(#Live.overlay(f3) == 2, "overlay: other class on the same cell does not match")
    t = 119999
    check(#Live.overlay(f3) == 2, "overlay: still active at 119.999 s")
    t = 120000
    check(#Live.overlay(f3) == 1, "overlay: expired at 120 s")

    flush(); t = 0
    Live.note_build({ A }, {})
    check(#Live.overlay({ { bcls = "X", x = 0, y = 0, h = 0, rot = 0 } }) == 2, "overlay: entry without id does not break the merge")
    flush()
end

check(fakeCalls >= 1, "read_station: native read used (calls: " .. fakeCalls .. ")")
print(("RESULT %d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
