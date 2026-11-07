-- bpu_live: game adapter for Blueprint Unit. The only file that reads UE4SS globals (FindAllOf, FindFirstOf).
-- Every game read is pcall-guarded. valid(o) = o:IsValid() == true, so tests can pass plain tables.
-- Pure modules (bpu_plan, bpu_build) never see this file; they get the values it returns.
-- Never call ForEach on a TrivialObject: each() checks for it first (P0 R1d).

local L = {}
L.mscore = nil  -- set by main.lua (the MSCore handle, factory_native.read_station)

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
    -- IsValid before GetFName: a native call on a freed UObject crashes the game (access violation), pcall cannot catch it
    local okV, v = pcall(function() return o:IsValid() end)
    if not okV or v ~= true then return "" end
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
    -- index loop first: TArray:ForEach callbacks leave the Lua stack inconsistent in UE4SS (later bogus errors like
    -- "bad argument #2 to 'for iterator'", "index a number value"); GetArrayNum + a[i] does not
    local okC, cnt = pcall(function() return a:GetArrayNum() end)
    if okC and type(cnt) == "number" then
        for i = 1, cnt do
            local okI, e = pcall(function() return a[i] end)
            if okI then fn(unw(e)) end
        end
        return
    end
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

local function idOf(o)
    return unw(rd(o, "ID"))
end

local function find_by_id(sid)
    for _, s in ipairs(FindAllOf("StationObject") or {}) do
        if valid(s) and nm(s):find("^Default__") == nil and idOf(s) == sid then return s end
    end
    return nil
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
    local st = find_by_id(station_id)
    if not st then return nil, "station object not found" end
    return { block = block, cont = cont, unit_inv = unit_inv, station = station_id, station_obj = st }
end

function L.player()
    return FindFirstOf("DMSPlayerObject")
end

-- MSCore 0.7.2 native read: one call per station gives blocks and machines (plain tables, no struct reads).
-- Cached per station id; snapshot() and reset() clear it.
local cache
local function station_data(st)
    local sid = idOf(st)
    if cache and cache.sid == sid then return cache end
    local FN = L.mscore and L.mscore.factory_native
    if not (FN and FN.read_station) then
        error("MSCore 0.7.2 or newer is needed (factory_native.read_station missing)", 0)
    end
    TRACE("read_station native sid=" .. tostring(sid))
    local b, m = FN.read_station(sid)
    if not b then error("read_station: " .. tostring(m), 0) end
    cache = { sid = sid, blocks = b, machines = m }
    TRACE("read_station done blocks=" .. #b .. " machines=" .. #m)
    return cache
end

function L.read_blocks(st)
    return station_data(st).blocks
end

function L.read_machines(st)
    return station_data(st).machines
end

local BUILDABLES
function L.read_buildables(F)
    if BUILDABLES then return BUILDABLES end
    BUILDABLES = {}
    for _, b in ipairs(FindAllOf("Buildable") or {}) do
        -- IsValid first: GetFName on a freed UObject is a native null deref (crash at address 0x18)
        local name = valid(b) and nm(b) or ""
        if name ~= "" and name:find("^Default__") == nil then
            local cost = {}
            TRACE("buildable " .. name)
            each(rd(b, "ItemCost"), function(c)
                cost[nm(rd(c, "Item"))] = unw(rd(c, "Amount"))
            end)
            -- the Buildable's own "Class" PROPERTY = machine class it builds (GetClass() would give "Buildable")
            BUILDABLES[name] = { bcls = short(nm(rd(b, "Class"))), cost = cost }
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
    cache = nil
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

-- MSCore 0.7.3 native read: factory_native.read_inventory(id) -> slots {item="ITEM_X" | "", amount, max}, or nil, err.
-- ok=false when the inventory is invalid, MSCore is older than 0.7.3, or the native read fails (err says why).
function L.read_inv(inv)
    if not valid(inv) then return { ok = false, slots = {} } end
    local id = unw(rd(inv, "ID"))
    local FN = L.mscore and L.mscore.factory_native
    if not (FN and FN.read_inventory) then
        return { ok = false, id = id, slots = {}, err = "MSCore 0.7.3 or newer is needed (factory_native.read_inventory missing)" }
    end
    local s, err = FN.read_inventory(id)
    return { ok = s ~= nil, id = id, slots = s or {}, err = err }
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
    cache = nil
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
