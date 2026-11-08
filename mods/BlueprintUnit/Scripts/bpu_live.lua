-- bpu_live: game adapter for Blueprint Unit. The only file that reads UE4SS globals (FindAllOf, FindFirstOf).
-- Every game read is pcall-guarded. valid(o) = o:IsValid() == true, so tests can pass plain tables.
-- Pure modules (bpu_plan, bpu_build) never see this file; they get the values it returns.
-- Never call ForEach on a TrivialObject: each() checks for it first (P0 R1d).

local L = {}
local Blk = require("bpu_blocks")
L.mscore = nil  -- set by main.lua (the MSCore handle, factory_native.read_station)

-- Trace trail for native crashes: print + append to <mod dir>bpu_trace.log (open/append/flush/close per call).
local MOD_DIR = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "../"   -- Mods/BlueprintUnit/, not the process cwd
local TRACE_PATH = MOD_DIR .. "bpu_trace.log"
-- ponytail: cap bpu_trace.log: truncate at start when over 2 MB
pcall(function()
    local f = io.open(TRACE_PATH, "rb")
    if f then
        local n = f:seek("end"); f:close()
        if n and n > 2 * 1024 * 1024 then local w = io.open(TRACE_PATH, "wb"); if w then w:close() end end
    end
end)
local function TRACE(m)
    m = tostring(m)
    print("[BPUnit] " .. m)
    pcall(function()
        local f = io.open(TRACE_PATH, "a")
        if f then
            f:write(os.date("%Y-%m-%d %H:%M:%S ") .. m .. "\n")
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
            local ts = os.date("%Y-%m-%d %H:%M:%S ")
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
    local tl = { "find_unit block=" .. tostring(idOf(block)) .. " cands=" .. table.concat(cands, ",") .. " nconts=" .. #conts }
    for _, c in ipairs(conts) do
        tl[#tl + 1] = "  cont id=" .. tostring(idOf(c)) .. " parent=" .. tostring(unw(rd(c, "ParentID"))) .. " inv=" .. tostring(idOf(rd(c, "Inventory")))
    end
    TRACE_MANY(tl)
    local bid = idOf(block)
    local pool = {}
    for _, sid in ipairs(cands) do
        for _, c in ipairs(conts) do
            if unw(rd(c, "ParentID")) == sid then pool[#pool + 1] = c end
        end
        if #pool > 0 then break end
    end
    local cont
    if #pool == 1 then
        cont = pool[1]
    elseif #pool > 1 and type(bid) == "number" then
        -- ponytail: ID order guess (unit container id = smallest container id above its block id); confirm with the trace
        for _, c in ipairs(pool) do
            local cid = idOf(c)
            if type(cid) == "number" and cid > bid and (not cont or cid < idOf(cont)) then cont = c end
        end
    elseif #pool == 0 and #conts == 1 then
        cont = conts[1]
    end
    if not cont then return nil, "no Blueprint Unit container for block " .. tostring(bid) .. " on station " .. tostring(cands[1]) end
    TRACE("find_unit chosen cont=" .. tostring(idOf(cont)) .. " pool=" .. #pool)
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

-- Live overlay. The game's blueprint view (station.Blueprint.Machines, read_station) lags ~30 s behind a build, so after a
-- build run (io.note_build) its placed machines and removed ids are merged into every fresh read: placed machines not
-- matched in the fresh read by (bcls,x,y,h,rot) are added with a negative id, removed ids are dropped. A batch ends as soon
-- as the fresh read shows all its placed machines and none of its removed ids, or after OV_MS. Module level: survives reopen.
L.now = function() return os.clock() * 1000 end   -- ms clock (tests replace it)
local OV_MS = 120000
local OV = {}   -- batches { t = ms, placed = {plan machines}, removed = {ids} }

function L.note_build(placed, removed)
    if #placed + #removed == 0 then return end
    OV[#OV + 1] = { t = L.now(), placed = placed, removed = removed }
end

local function cell_key(e) return tostring(e.bcls) .. "|" .. tostring(e.x) .. "|" .. tostring(e.y) .. "|" .. tostring(e.h) .. "|" .. tostring(e.rot) end

-- fresh = read_machines list (not modified). Returns a new list: fresh minus removed ids, plus virtual placed machines.
function L.overlay(fresh)
    if #OV == 0 then return fresh end
    local now = L.now()
    local byKey, ids = {}, {}
    for k, e in ipairs(fresh) do
        if e.id ~= nil then ids[e.id] = true end
        local key = cell_key(e)
        byKey[key] = byKey[key] or {}
        table.insert(byKey[key], k)
    end
    local used, gone, virt, active = {}, {}, {}, {}
    for _, b in ipairs(OV) do
        if now - b.t < OV_MS then
            local complete = true
            for _, p in ipairs(b.placed) do
                local hit
                for _, k in ipairs(byKey[cell_key(p)] or {}) do
                    if not used[k] then hit = k break end
                end
                if hit then used[hit] = true else complete = false; virt[#virt + 1] = p end
            end
            for _, id in ipairs(b.removed) do
                if ids[id] then complete = false end
                gone[id] = true
            end
            if not complete then active[#active + 1] = b end
        end
    end
    OV = active
    local out = {}
    for _, e in ipairs(fresh) do if not gone[e.id] then out[#out + 1] = e end end
    for i, p in ipairs(virt) do
        local v = {}
        for k, x in pairs(p) do v[k] = x end
        v.id = -i
        v.cls = v.cls or v.bcls
        out[#out + 1] = v
    end
    return out
end

-- container contents memory: cell key bcls|x|y|h|rot -> list {name, count}. Session only (not saved), survives L.reset.
local MEM = {}
function L.remember(key, list) MEM[key] = list end
function L.memory()
    local out = {}
    for k, v in pairs(MEM) do out[k] = v end
    return out
end

-- inventory map (item -> amount) as a list {name, count}, item order
local function contents_list(inv)
    local map = {}
    for _, s in ipairs(inv.slots or {}) do
        if s.item ~= "" and s.amount > 0 then map[s.item] = (map[s.item] or 0) + s.amount end
    end
    local names = {}
    for k in pairs(map) do names[#names + 1] = k end
    table.sort(names)
    local out = {}
    for _, k in ipairs(names) do out[#out + 1] = { name = k, count = map[k] } end
    return out
end

-- Station Build needs the MSCore 0.8.0 natives (add_block, remove_block, pending, read_block_class). Returns true, or false + reason.
function L.station_build_capable()
    local M = L.mscore
    local N, FN = M and M.native, M and M.factory_native
    if N and N.add_block and N.remove_block and N.pending and N.read_block_class
        and FN and FN.add_block and FN.remove_block and FN.pending and FN.read_block_class then
        return true
    end
    return false, "Station Build needs MSCore 0.8.0 or newer."
end

-- class defaults per class path (read once, cached): {station, bounds, cost={ITEM=n}} | nil.
-- BlockBounds comes raw (65536 = 1.0). MSCore native read_block_class (0.8.0).
local BINFO = {}
local function static_info(path)
    if BINFO[path] == nil then
        local FN = L.mscore and L.mscore.factory_native
        local ok, info = false, nil
        if FN and FN.read_block_class then ok, info = pcall(FN.read_block_class, path) end
        local r = false
        if ok and type(info) == "table" and info.min and info.max then
            local cost = {}
            for _, c in ipairs(info.cost or {}) do cost[c.item] = c.amount end
            -- BlockBounds raw/65536 is 4x the grid unit horizontally and 2x vertically (probe 2026-11-08: Station_01 spans 16 but its blocks sit 4 apart,
            -- Station_02A spans 32 at 8 apart; heights span 4 per level of 2). The game keeps each box a hair under its size so inclusive compares do not touch.
            local s, sxy, sz = 65536, 4, 2
            r = { station = info.station == true, cost = cost,
                  bounds = { x0 = info.min.x / s / sxy, x1 = info.max.x / s / sxy, y0 = info.min.y / s / sxy, y1 = info.max.y / s / sxy,
                             z0 = info.min.z / s / sz, z1 = info.max.z / s / sz } }
        end
        BINFO[path] = r
    end
    return BINFO[path] or nil
end

-- research state of one block class, Lua only: DMSWorld:GetResearchState():IsBlockUnlocked(class object).
-- Returns true | false | nil (unknown: bpu_blocks skips it), plus a detail text for the trace. Every step is pcall-guarded.
local function unlock_state(path)
    local okw, world = pcall(FindFirstOf, "DMSWorld")
    if not okw or not valid(world) then return nil, "world=no (" .. (okw and "not valid" or tostring(world)) .. ")" end
    local okr, rs = pcall(function() return world:GetResearchState() end)
    if not okr or rs == nil then return nil, "world=yes state=failed: " .. tostring(rs) end
    local oko, obj = pcall(StaticFindObject, path)
    if not oko or not valid(obj) then return nil, "world=yes state=yes obj=no (" .. (oko and "not valid" or tostring(obj)) .. ")" end
    local oku, r = pcall(function() return rs:IsBlockUnlocked(obj) end)
    if not oku then return nil, "world=yes state=yes obj=yes IsBlockUnlocked failed: " .. tostring(r) end
    r = unw(r)
    if type(r) ~= "boolean" then return nil, "world=yes state=yes obj=yes IsBlockUnlocked returned " .. type(r) end
    return r, "world=yes state=yes obj=yes"
end

-- block_info for one snapshot: static info (cached) + unlocked read once per class path per snapshot, traced
local function block_info_for(unl)
    return function(cls, path)
        local info = path and static_info(path)
        if not info then return nil end
        if unl[path] == nil then
            local v, detail = unlock_state(path)
            unl[path] = { v = v }
            TRACE(("block unlock %s (%s): %s -> unlocked=%s"):format(tostring(cls), tostring(path), detail, tostring(v)))
            local bb = info.bounds   -- probe: raw box in /65536 units, to settle units and the touching-edge rule
            if bb then TRACE(("block bounds %s: x %s..%s y %s..%s z %s..%s station=%s"):format(tostring(cls), bb.x0, bb.x1, bb.y0, bb.y1, bb.z0, bb.z1, tostring(info.station))) end
        end
        return { station = info.station, unlocked = unl[path].v, cost = info.cost, bounds = info.bounds }
    end
end

-- player + unit stock: {ITEM_X = n}
local function have_totals(U, player)
    local have = {}
    local function add(inv)
        if not inv then return end
        local r = L.read_inv(inv)
        if not (r and r.ok) then return end
        for _, s in ipairs(r.slots) do
            if s.item ~= "" and s.amount > 0 then have[s.item] = (have[s.item] or 0) + s.amount end
        end
    end
    add(U.unit_inv)
    add(rd(player, "Inventory"))
    return have
end

-- opts (Station Build only): { station_build = true, player = <player object> } adds block_info (lazy per class), have, creative.
function L.snapshot(U, F, opts)
    cache = nil
    local st = U.station_obj
    if opts and opts.station_build then
        local okc, why = L.station_build_capable()
        if not okc then error(why, 0) end
    end
    TRACE("snapshot start station=" .. tostring(U.station))
    local blocks = L.read_blocks(st)
    TRACE("snapshot blocks=" .. #blocks)
    local bl = {}
    for i, b in ipairs(blocks) do
        bl[i] = ("blk %d class=%s gx=%s gy=%s h=%s rot=%s"):format(i, tostring(b.class), tostring(b.gx), tostring(b.gy), tostring(b.h), tostring(b.rot))
    end
    TRACE_MANY(bl)
    local existing = L.overlay(L.read_machines(st))
    TRACE("snapshot machines=" .. #existing)
    -- containers: live contents (refund list, restore memory); a failed read leaves e.contents nil
    local cmap
    for _, e in ipairs(existing) do
        if tostring(e.bcls or ""):find("Container", 1, true) and e.id then
            cmap = cmap or L.container_invs()
            local inv = cmap[e.id]
            if inv then
                local r = L.read_inv(inv)
                if r.ok then e.contents = contents_list(r) end
            end
        end
    end
    local recipes = L.read_recipes()
    TRACE("snapshot recipes=" .. count(recipes))
    local buildables = L.read_buildables(F)
    TRACE("snapshot buildables=" .. count(buildables))
    local snap = { station = U.station, blocks = blocks, existing = existing, recipes = recipes, buildables = buildables,
                   items = L.item_names(), memory = L.memory() }
    if opts and opts.station_build then
        local player = opts.player or L.player()
        snap.block_info = block_info_for({})
        snap.have = have_totals(U, player)
        snap.creative = L.creative(player, nil)
        TRACE("snapshot station build: have items=" .. count(snap.have))
    end
    return snap
end

-- raw MaxStackSize of an Item UObject (cached per name; false when unreadable). nil = unknown.
local RAW = {}
local TRACED = {}
function L.item_raw(name)
    if RAW[name] == nil then
        local o = L.item_by_name(name)
        local v = (o and valid(o)) and unw(rd(o, "MaxStackSize")) or nil
        RAW[name] = (type(v) == "number" and v > 0) and v or false
    end
    return RAW[name] or nil
end

-- MSCore 0.7.3 native read: factory_native.read_inventory(id) -> slots {item="ITEM_X" | "", amount, max}, or nil, err.
-- ok=false when the inventory is invalid, MSCore is older than 0.7.3, or the native read fails (err says why).
-- Slot max = effective max in this inventory: raw MaxStackSize (native, or the Item UObject when native <= 1) * StackMultiplier.
-- mult = StackMultiplier (SM 2 = x2, SM 8 = x8, unit SM 202 = x202). SM unreadable -> 2 (x2, the game baseline).
function L.read_inv(inv)
    if not valid(inv) then return { ok = false, slots = {} } end
    local id = unw(rd(inv, "ID"))
    local FN = L.mscore and L.mscore.factory_native
    if not (FN and FN.read_inventory) then
        return { ok = false, id = id, slots = {}, err = "MSCore 0.7.3 or newer is needed (factory_native.read_inventory missing)" }
    end
    local s, err = FN.read_inventory(id)
    if not s then return { ok = false, id = id, slots = {}, err = err } end
    local sm = unw(rd(inv, "StackMultiplier"))
    if type(sm) ~= "number" or sm <= 0 then sm = 2 end
    for _, sl in ipairs(s) do
        if sl.item ~= "" then
            local raw, src = sl.max, "native"
            if not raw or raw <= 1 then
                raw, src = L.item_raw(sl.item), "item"
                if not raw then raw, src = (sl.max or 1), "native-fallback" end
            end
            sl.max = math.floor(raw * sm)
            local key = tostring(id) .. "|" .. sl.item
            if not TRACED[key] then
                TRACED[key] = true
                TRACE(("maxstack inv=%s item=%s raw=%s (%s) sm=%s effective=%s"):format(tostring(id), sl.item, tostring(raw), src, tostring(sm), tostring(sl.max)))
            end
        end
    end
    return { ok = true, id = id, slots = s, mult = sm, sm = sm }
end

-- machine ID -> Inventory UObject of every ContainerObject in the world (the unit's own container skipped).
-- Plain UObject reads, like find_unit. Used to size removal batches by container contents.
function L.container_invs()
    local map = {}
    for _, c in ipairs(FindAllOf("ContainerObject") or {}) do
        if valid(c) and nm(c):find("^Default__") == nil and clsname(c) ~= "BP_BPUnitStoreObj_01" then
            local id = unw(rd(c, "ID"))
            local inv = rd(c, "Inventory")
            if id ~= nil and inv ~= nil then map[id] = inv end
        end
    end
    return map
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

-- pin the modification cost in the game's own HUD: SetPinnedCostInput.CreateInputSetPinnedCost(ItemStack[]) -> ctl:AddInputCommand(player.ID, cmd).
-- stacks = { {name="ITEM_x", n=amount}, ... }; {} = unpin. Returns ok, err|ret. Every call is traced (UNKNOWNs settle from the trace).
function L.send_pin(ctl, player, stacks)
    if not valid(ctl) then ctl = FindFirstOf("DMSPlayerController") end
    if not valid(ctl) then return false, "no controller" end
    if not valid(player) then return false, "no player" end
    local arr = {}
    for _, s in ipairs(stacks) do
        local it = L.item_by_name(s.name)
        if it then arr[#arr + 1] = { Item = it, Amount = s.n } end
    end
    local okc, cmd = pcall(function()
        return StaticFindObject("/Script/MainSequence.Default__SetPinnedCostInput"):CreateInputSetPinnedCost(arr)
    end)
    TRACE(("pin create n=%d -> ok=%s cmd=%s"):format(#arr, tostring(okc), tostring(cmd)))
    if not okc or not valid(cmd) then return false, "CreateInputSetPinnedCost failed: " .. tostring(cmd) end
    local id = unw(rd(player, "ID"))
    local oks, r = pcall(function() ctl:AddInputCommand(id, cmd) return true end)
    TRACE(("pin send receiver=%s -> ok=%s ret=%s"):format(tostring(id), tostring(oks), tostring(r)))
    return oks, r
end

-- live item names (ITEM_X) from the Item objects; plan matches Contents names against them
function L.item_names()
    L.item_by_name("")   -- builds the name cache
    local out = {}
    for n in pairs(ITEMS or {}) do out[#out + 1] = n end
    table.sort(out)
    return out
end

function L.reset()
    cache = nil
    BUILDABLES = nil
    ITEMS = nil
    RAW, TRACED = {}, {}
    BINFO = {}
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
        local ok, res = pcall(function() return L.overlay(L.read_machines(st)) end)
        if not ok then return nil, tostring(res) end
        return res
    end
    -- raw station read (config check after a Build): fresh native read, no live overlay
    function io.scan_raw(station)
        local st = find_by_id(station)
        if not st then return nil, "station not found" end
        cache = nil
        return L.read_machines(st)
    end
    io.fingerprint = Plan.fingerprint
    function io.read_inv(which)
        if which == "player" then return L.read_inv(rd(player, "Inventory")) end
        return L.read_inv(U.unit_inv)
    end
    function io.item_max(name) return L.item_raw(name) end   -- raw MaxStackSize, nil when unknown; bpu_build applies the inventory multiplier
    -- MSCore 0.7.5 refund/charge redirect status: string starting with 'on' = active. Anything else (missing native, error) = 'off ...'.
    function io.redirect_status()
        local N = L.mscore and L.mscore.native
        local fn = (N and N.redirect_status) or rawget(_G, "MSCoreNative_redirect_status")
        if type(fn) ~= "function" then return "off (redirect_status missing, MSCore older than 0.7.5)" end
        local okc, r = pcall(fn)
        if okc and type(r) == "string" then return r end
        return "off (redirect_status failed)"
    end
    -- MSCore redirect switch: on only while a Blueprint Unit build runs (bpu_build release_redirect turns it off). Returns the status.
    function io.redirect_enable(on)
        local N = L.mscore and L.mscore.native
        local fn = (N and N.redirect_enable) or rawget(_G, "MSCoreNative_redirect_enable")
        local st
        if type(fn) ~= "function" then
            st = "off (redirect_enable missing)"
        else
            local okc, r = pcall(fn, on and true or false)
            st = (okc and type(r) == "string") and r or "off (redirect_enable failed)"
        end
        TRACE(("redirect_enable(%s) -> %s"):format(tostring(on and true or false), st))
        return st
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
    -- one shift-click as the game sends it (the UI's own path; native inv_move sends receiver 0 which the game drops).
    function io.send_move(prim, sec, slot0)
        local c = ctx.ctl
        if not valid(c) then c = FindFirstOf("DMSPlayerController") end
        if not valid(c) then return false, "no controller" end
        local p, s0 = unw(prim), unw(sec)
        local function fire(pr, se, a)
            return call(function()
                c:AddInventoryInteraction({ PrimaryInventoryID = pr, SecondaryInventoryID = se, SlotIndex = slot0, Action = a })
                return true
            end)
        end
        local ok1, r1 = fire(p, s0, 2)
        TRACE(("inv_move A press(primary=%s, secondary=%s, slot0=%d, action=2) -> ok=%s ret=%s"):format(
            tostring(p), tostring(s0), slot0, tostring(ok1), tostring(r1)))
        if not ok1 then return false, r1 end
        local ok2, r2 = fire(p, 0, 3)
        TRACE(("inv_move A release(primary=%s, secondary=0, slot0=%d, action=3) -> ok=%s ret=%s"):format(
            tostring(p), slot0, tostring(ok2), tostring(r2)))
        return ok2, r2
    end
    -- contents of a machine's inventory: nil = not a container, ok=false = unreadable. Cached map, rebuilt once on a miss.
    local cmap
    function io.read_machine_inv(machine_id)
        local inv = cmap and cmap[machine_id]
        if inv == nil then
            cmap = L.container_invs()
            inv = cmap[machine_id]
        end
        if inv == nil then return nil end
        return L.read_inv(inv)
    end
    -- restore mode: "off" when Mods/BlueprintUnit/restore_off.txt exists, else "on". The Chk_Restore checkbox is applied by the builder (opts.restore).
    function io.restore_mode()
        local f = _G.io.open(MOD_DIR .. "restore_off.txt", "rb")
        if f then f:close() return "off" end
        return "on"
    end

    function io.send_inv(prim, sec, slot0, action)
        local c = ctx.ctl
        if not valid(c) then c = FindFirstOf("DMSPlayerController") end
        if not valid(c) then return false, "no controller" end
        local ok, r = call(function()
            c:AddInventoryInteraction({ PrimaryInventoryID = unw(prim), SecondaryInventoryID = unw(sec), SlotIndex = slot0, Action = action })
            return true
        end)
        TRACE(("inv_cmd action=%d primary=%s secondary=%s slot0=%d -> ok=%s ret=%s"):format(action, tostring(unw(prim)),
            tostring(unw(sec)), slot0, tostring(ok), tostring(r)))
        return ok, r
    end
    -- split route (MSCore 0.7.6 inv_split native): exact split inside one inventory, src0 -> dst0 (0-based). Local edit, not a
    -- game command. Only defined when the native exists (absent = the restore keeps the rounded whole-stack path).
    local function split_fn()
        local f = (native and native.inv_split) or rawget(_G, "MSCoreNative_inv_split")
        if type(f) == "function" then return f end
        return nil
    end
    if split_fn() then
        function io.split(inv, src0, amount, dst0)
            local fn = split_fn()
            if not fn then return false, "inv_split gone" end
            local ok, r = call(fn, unw(inv), src0, amount, dst0)
            TRACE(("inv_split inv=%s src0=%d amount=%d dst0=%d -> ok=%s ret=%s"):format(tostring(unw(inv)), src0, amount, dst0,
                tostring(ok), tostring(r)))
            return ok, r
        end
    end
    -- ids of every container in the world (sorted). Used to find the containers a Build just placed.
    function io.container_ids()
        local out = {}
        for id in pairs(L.container_invs()) do out[#out + 1] = id end
        table.sort(out)
        return out
    end
    function io.remember(key, list) L.remember(key, list) end
    function io.send_remove(id)
        if type(id) == "number" and id < 0 then return false, "machine not in the game view yet" end   -- overlay id
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
    -- Station Build (MSCore 0.8.0): one remove/add sequence through factory_native (bpu_blocks send), every native call traced
    function io.station_build_capable() return L.station_build_capable() end
    function io.send_blocks(station, blocks, ids, removes)
        local FN = native
        if not (FN and FN.add_block and FN.remove_block and FN.pending) then return false, "MSCore 0.8.0 natives missing" end
        local traced = {
            pending = function(st, apply, reset, p, pl, ed)
                local ok, err = FN.pending(st, apply, reset, p, pl, ed)
                TRACE(("station blocks: pending station=%s apply=%s reset=%s primary=%s player=%s editing=%s -> ok=%s err=%s"):format(
                    tostring(st), tostring(apply), tostring(reset), tostring(p), tostring(pl), tostring(ed), tostring(ok), tostring(err)))
                return ok, err
            end,
            remove_block = function(st, cls, x, y, h, rot)
                local ok, err = FN.remove_block(st, cls, x, y, h, rot)
                TRACE(("station blocks: remove_block %s at %s,%s,h%s rot%s -> ok=%s err=%s"):format(tostring(cls), tostring(x),
                    tostring(y), tostring(h), tostring(rot), tostring(ok), tostring(err)))
                return ok, err
            end,
            add_block = function(st, cls, x, y, h, rot)
                local ok, err = FN.add_block(st, cls, x, y, h, rot)
                TRACE(("station blocks: add_block %s at %s,%s,h%s rot%s -> ok=%s err=%s"):format(tostring(cls), tostring(x),
                    tostring(y), tostring(h), tostring(rot), tostring(ok), tostring(err)))
                return ok, err
            end,
        }
        removes = removes or {}
        local ok, err = Blk.send(traced, station, blocks, ids, removes)
        TRACE(("station blocks: send %d add(s), %d remove(s) -> ok=%s err=%s"):format(#blocks, #removes, tostring(ok), tostring(err)))
        return ok, err
    end
    -- live station blocks, fresh native read (no cache): the poll of a Station Build run
    function io.scan_blocks(station)
        local st = find_by_id(station)
        if not st then return nil, "station not found" end
        local ok, res = pcall(function() cache = nil; return L.read_blocks(st) end)
        if not ok then return nil, tostring(res) end
        return res
    end
    function io.now() return L.now() end
    function io.note_build(placed, removed) L.note_build(placed, removed) end
    io.trace = TRACE
    return io
end

return L
