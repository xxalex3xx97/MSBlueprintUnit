-- bpu_live: game adapter for Blueprint Unit. The only file that reads UE4SS globals (FindAllOf, FindFirstOf).
-- Every game read is pcall-guarded. valid(o) = o:IsValid() == true, so tests can pass plain tables.
-- Pure modules (bpu_plan, bpu_build) never see this file; they get the values it returns.
-- Never call ForEach on a TrivialObject: each() checks for it first (P0 R1d).

local L = {}

-- Trace trail for native crashes: print + append to <mod dir>pu_trace.log (open/append/flush/close per call).
local TRACE_PATH = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "../bpu_trace.log"
local function TRACE(m)
    m = tostring(m)
    print("[BPUnit] " .. m)
    pcall(function()
        local f = io.open(TRACE_PATH, "a")
        if f then
            f:write(os.date("%H:%M:%S ") .. m .. "\n")
            f:flush()
            f:close()
        end
    end)
end
L.trace = TRACE

-- per-field trace for late machine entries only (crash hunt); i < TRACE_FROM writes nothing
local TRACE_FROM = 2100
local function MT(i, m)
    if i and i >= TRACE_FROM then TRACE("m" .. i .. " " .. m) end
end

-- many lines, one io open (prints each line too)
local function TRACE_MANY(lines)
    for _, m in ipairs(lines) do print("[BPUnit] " .. m) end
    pcall(function()
        local f = io.open(TRACE_PATH, "a")
        if f then
            local ts = os.date("%H:%M:%S ")
            for _, m in ipairs(lines) do f:write(ts .. m .. "\n") end
            f:flush()
            f:close()
        end
    end)
end

local function rd(o, k)
    if o == nil then return nil end
    local ok, v = pcall(function() return o[k] end)
    if ok then return v end
    return nil
end

local function unw(x)
    if type(x) == "userdata" then
        local ok, r = pcall(function() return x:get() end)
        if ok and r ~= nil then return r end
    end
    return x
end

local function valid(o)
    if type(o) ~= "table" and type(o) ~= "userdata" then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v == true
end

local function nm(o)
    local ok, s = pcall(function() return o:GetFName():ToString() end)
    if ok and type(s) == "string" then return s end
    return ""
end

-- "/Game/Path/BP_X.BP_X_C" or "BlueprintGeneratedClass /Game/BP_X.BP_X_C" -> "BP_X"
local function short(s)
    s = tostring(s or "")
    s = s:match("([^/\\ ]+)$") or s
    s = s:match("^.*%.(.+)$") or s
    return (s:gsub("_C$", ""))
end

-- class short name of a UObject via GetClass():GetFName() (proven in P0 cls()).
-- Never call on struct values (Blocks / Machines / slot / ItemCost entries): structs have no GetClass.
local function clsname(o)
    local ok, s = pcall(function() return o:GetClass():GetFName():ToString() end)
    if ok and type(s) == "string" then return short(s) end
    return ""
end

-- array walker. Lua table: ipairs (a table holding only .get is unwrapped first).
-- userdata: ForEach when it exists; else a:get() once and retry; last resort GetArrayNum + index loop.
local function each(a, fn, depth)
    depth = depth or 0
    if a == nil or depth > 2 then return end
    if type(a) == "table" then
        if a[1] == nil and type(rawget(a, "get")) == "function" then
            return each(a:get(), fn, depth + 1)
        end
        for _, e in ipairs(a) do fn(e) end
        return
    end
    if type(a) ~= "userdata" then return end
    local okF, fe = pcall(function() return a.ForEach end)
    if okF and type(fe) == "function" then
        -- collect inside the native callback (no field reads there), process after it returns
        local items, n = {}, 0
        a:ForEach(function(_, e) n = n + 1; items[n] = unw(e) end)
        for i = 1, n do fn(items[i]) end
        return
    end
    local okG, g = pcall(function() return a:get() end)
    if okG and g ~= nil and g ~= a then return each(g, fn, depth + 1) end
    local okN, n = pcall(function() return a:GetArrayNum() end)
    if okN and type(n) == "number" then
        for i = 1, n do
            local okI, e = pcall(function() return a[i] end)
            if okI then fn(unw(e)) end
        end
    end
end

-- Transform -> gx, gy, h, rot. Only Transform{GridLocation{X,Y},Height,GridRotation} is read (P0 R1b/R1c).
-- Struct field reads per entry type (all in P0 order, all after the native ForEach returns):
--   Blocks:    Class, Transform.{GridLocation.X, GridLocation.Y, Height, GridRotation}
--   Machines:  MachineID (else ID), Class, Transform.{...same...}, SerializedMachineConfig (bytes)
--   ItemCost:  Item, Amount (P0 R2)
local function xf(e, i)
    MT(i, "xf Transform")
    local t = rd(e, "Transform")
    MT(i, "xf GridLocation")
    local gl = unw(rd(t, "GridLocation"))
    MT(i, "xf X")
    local x = unw(rd(gl, "X"))
    MT(i, "xf Y")
    local y = unw(rd(gl, "Y"))
    MT(i, "xf Height")
    local h = unw(rd(t, "Height"))
    MT(i, "xf GridRotation")
    local rot = unw(rd(t, "GridRotation"))
    return x, y, h, rot
end

local function bp_arr(st, key)
    return rd(rd(st, "Blueprint"), key)
end

local function idOf(o)
    return unw(rd(o, "ID"))
end

local function find_by_id(sid)
    for _, s in ipairs(FindAllOf("StationObject") or {}) do
        if valid(s) and nm(s):find("^Default__") == nil and idOf(s) == sid then return s end
    end
    return nil
end

-- first station with Blueprint.Blocks, BP_StationObject_C preferred
local function fallback_station()
    local pick
    for _, s in ipairs(FindAllOf("StationObject") or {}) do
        if valid(s) and nm(s):find("^Default__") == nil then
            local n = 0
            each(bp_arr(s, "Blocks"), function() n = n + 1 end)
            if n > 0 and (pick == nil or (clsname(s) == "BP_StationObject" and clsname(pick) ~= "BP_StationObject")) then
                pick = s
            end
        end
    end
    return pick
end

-- Station id candidates, best first. GetFrame (pcall) first, then block.ParentID, then the block's own ID as a
-- last-resort key (matches a container only by coincidence). No reads on Blocks entries (structs): no ID scan.
local function station_ids(block)
    local out, seen = {}, {}
    local function add(v)
        if v ~= nil and not seen[v] then seen[v] = true; out[#out + 1] = v end
    end
    local okF, fr = pcall(function() return block:GetFrame() end)
    if okF and fr then add(idOf(fr)) end
    add(unw(rd(block, "ParentID")))
    add(idOf(block))
    return out
end

-- block: the station block the console is on. Container: BP_BPUnitStoreObj_01 with ParentID == a station id.
function L.find_unit(block, player_hint)
    if not valid(block) then return nil, "no block" end
    local cands = station_ids(block)
    local conts = {}
    for _, c in ipairs(FindAllOf("ContainerObject") or {}) do
        if valid(c) and clsname(c) == "BP_BPUnitStoreObj_01" then conts[#conts + 1] = c end
    end
    local cont
    for _, sid in ipairs(cands) do
        for _, c in ipairs(conts) do
            if unw(rd(c, "ParentID")) == sid then cont = c break end
        end
        if cont then break end
    end
    if not cont and #conts == 1 then cont = conts[1] end
    if not cont then return nil, "no Blueprint Unit container on station " .. tostring(cands[1]) end
    local station_id = unw(rd(cont, "ParentID"))
    local unit_inv = rd(cont, "Inventory")
    if unit_inv == nil then return nil, "unit inventory unreadable" end
    local st = find_by_id(station_id) or fallback_station()
    if not st then return nil, "station object not found" end
    return { block = block, cont = cont, unit_inv = unit_inv, station = station_id, station_obj = st }
end

function L.player()
    return FindFirstOf("DMSPlayerObject")
end

-- Blocks entries are structs: only Class (object property, P0 R1b path), Transform. No GetClass, no ID.
function L.read_blocks(st)
    local out = {}
    each(bp_arr(st, "Blocks"), function(e)
        local gx, gy, h, rot = xf(e)
        out[#out + 1] = { class = short(nm(rd(e, "Class"))), gx = gx, gy = gy, h = h, rot = rot }
    end)
    return out
end

local function cfg_bytes(e, i)
    MT(i, "cfg SerializedMachineConfig")
    local bytes = rd(e, "SerializedMachineConfig")
    if bytes == nil then return nil end
    local ok, s = pcall(function()
        local t = {}
        MT(i, "cfg bytes walk")
        each(bytes, function(b) t[#t + 1] = string.char(unw(b)) end)
        return table.concat(t)
    end)
    if ok then return s end
    return nil
end

-- Machines entries are structs: MachineID (ID fallback as P0 R1c), Class (object property), Transform, SerializedMachineConfig.
function L.read_machines(st)
    local out, i, idkey = {}, 0, nil
    each(bp_arr(st, "Machines"), function(e)
        i = i + 1
        if i == 1 or i % 50 == 0 then TRACE("machine[" .. i .. "] reading") end
        -- a missing struct field throws inside UE4SS (traceback, can crash): decide the id field once on entry 1, then read only it
        if idkey == nil then
            idkey = "ID"
            if unw(rd(e, "ID")) == nil then idkey = "MachineID" end
            TRACE("machine id field=" .. idkey)
        end
        MT(i, "id")
        local id = unw(rd(e, idkey))
        MT(i, "class")
        local cls = short(nm(rd(e, "Class")))
        MT(i, "class=" .. cls)
        local x, y, h, rot = xf(e, i)
        out[#out + 1] = { id = id, cls = cls, bcls = cls, x = x, y = y, h = h, rot = rot, cfg = cfg_bytes(e, i) }
        MT(i, "done")
    end)
    TRACE("read_machines done n=" .. #out)
    return out
end

local BUILDABLES
function L.read_buildables(F)
    if BUILDABLES then return BUILDABLES end
    BUILDABLES = {}
    for _, b in ipairs(FindAllOf("Buildable") or {}) do
        local name = nm(b)
        if valid(b) and name ~= "" and name:find("^Default__") == nil then
            local cost = {}
            each(rd(b, "ItemCost"), function(c)
                cost[nm(rd(c, "Item"))] = unw(rd(c, "Amount"))
            end)
            BUILDABLES[name] = { bcls = clsname(b), cost = cost }
        end
    end
    return BUILDABLES
end

-- Recipe.Name is an FText: ToString() gives the text the game shows and the plan keys on.
L._recobj = {}
function L.read_recipes()
    local out = {}
    L._recobj = {}
    for _, r in ipairs(FindAllOf("Recipe") or {}) do
        if valid(r) then
            local okT, t = pcall(function() return rd(r, "Name"):ToString() end)
            if okT and type(t) == "string" then
                out[nm(r)] = t
                if L._recobj[t] == nil then L._recobj[t] = r end
            end
        end
    end
    return out
end

local function count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

function L.snapshot(U, F)
    local st = U.station_obj
    TRACE("snapshot start station=" .. tostring(U.station))
    local blocks = L.read_blocks(st)
    TRACE("snapshot blocks=" .. #blocks)
    local bl = {}
    for i, b in ipairs(blocks) do
        bl[i] = ("blk %d class=%s gx=%s gy=%s h=%s rot=%s"):format(i, tostring(b.class), tostring(b.gx), tostring(b.gy), tostring(b.h), tostring(b.rot))
    end
    TRACE_MANY(bl)
    local existing = L.read_machines(st)
    TRACE("snapshot machines=" .. #existing)
    local recipes = L.read_recipes()
    TRACE("snapshot recipes=" .. count(recipes))
    local buildables = L.read_buildables(F)
    TRACE("snapshot buildables=" .. count(buildables))
    return { station = U.station, blocks = blocks, existing = existing, recipes = recipes, buildables = buildables }
end

-- slots: GetItemSlots() first, else ItemSlots property. ok=false when the inventory is invalid or unreadable.
function L.read_inv(inv)
    if not valid(inv) then return { ok = false, slots = {} } end
    local okG, src = pcall(function() return inv:GetItemSlots() end)
    if not (okG and src ~= nil) then src = rd(inv, "ItemSlots") end
    local slots = {}
    local okE = pcall(function()
        each(src, function(s)
            local it = rd(s, "Item")
            local item, mx = "", 1
            if valid(it) then
                item = nm(it)
                mx = unw(rd(it, "MaxStackSize")) or 1
            end
            slots[#slots + 1] = { item = item, amount = unw(rd(s, "Amount")) or 0, max = mx }
        end)
    end)
    return { ok = okE and src ~= nil, id = unw(rd(inv, "ID")), slots = slots }
end

function L.creative(player, ctl)
    local v = unw(rd(player, "bCreative"))
    if v == nil then v = unw(rd(ctl, "bCreative")) end
    return v == true
end

local ITEMS
function L.item_by_name(name)
    if not ITEMS then
        ITEMS = {}
        for _, o in ipairs(FindAllOf("Item") or {}) do
            if valid(o) then
                local n = nm(o)
                if ITEMS[n] == nil then ITEMS[n] = o end
            end
        end
    end
    return ITEMS[name]
end

function L.reset()
    BUILDABLES = nil
    ITEMS = nil
    L._recobj = {}
end

local function call(f, ...)
    local ok, a, b = pcall(f, ...)
    if not ok then return false, tostring(a) end
    return a and true or false, b
end

-- ctx = { unit=U, player=, ctl=, F=, native=, plan_mod=Plan, buildables= (optional, else read_buildables) }
function L.make_io(ctx)
    local U, player, native, Plan = ctx.unit, ctx.player, ctx.native, ctx.plan_mod
    local bld = ctx.buildables or L.read_buildables(ctx.F)
    local io = {}

    function io.scan(station)
        local st = find_by_id(station)
        if not st then return nil, "station not found" end
        local ok, res = pcall(L.read_machines, st)
        if not ok then return nil, tostring(res) end
        return res
    end
    io.fingerprint = Plan.fingerprint
    function io.read_inv(which)
        if which == "player" then return L.read_inv(rd(player, "Inventory")) end
        return L.read_inv(U.unit_inv)
    end
    function io.unit_ids()
        return { unit_id = unw(rd(U.unit_inv, "ID")), player_id = unw(rd(rd(player, "Inventory"), "ID")) }
    end
    function io.creative() return L.creative(player, ctx.ctl) end
    function io.costs(place)
        local out = {}
        for i, m in ipairs(place) do
            local b = bld[m.bdat]
            out[i] = b and b.cost or {}
        end
        return out
    end
    function io.send_move(prim, sec, slot0, action)
        return call(native.inv_move, prim, sec, slot0, action)
    end
    function io.send_remove(id)
        return call(native.disassemble, id, 0)
    end
    function io.send_place(m)
        return call(native.place, U.station, m.bdat, m.x, m.y, m.h, m.rot, m.cfg)
    end
    function io.send_changes(chg)
        local okc, failc = 0, 0
        for _, c in ipairs(chg) do
            local ok = true
            if c.recipe then
                local r, err = call(native.set_recipe, c.m.id, L._recobj[c.newRec], 0, "")
                if not r then
                    ok = false
                    print(("[BPUnit] set_recipe %s failed: %s"):format(tostring(c.m.id), tostring(err)))
                end
            end
            for _, p in ipairs(c.ports or {}) do
                local r, err = call(native.port, c.m.id, p.index)
                if not r then
                    ok = false
                    print(("[BPUnit] port %s on %s failed: %s"):format(tostring(p.index), tostring(c.m.id), tostring(err)))
                end
            end
            if ok then okc = okc + 1 else failc = failc + 1 end
        end
        print(("[BPUnit] config changes: %d ok, %d failed"):format(okc, failc))
        return okc, failc
    end
    function io.now() return os.clock() * 1000 end
    return io
end

return L
