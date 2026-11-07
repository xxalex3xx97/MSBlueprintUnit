-- bpu_plan.lua: Blueprint Unit planner. Pure Lua 5.4, no game globals. Port of the dev probe planner (mb_bpprobe.hpp):
-- pp_parse_doc, pp_resolve, pp_site_rec / pp_resolve_recipes, pp_encode_cfg + pp_pair_underground, pp_check_new,
-- pp_split_kept (sync), pp_kept_changes (cfg_diff), pp_stale / pp_plan_removals, pp_fingerprint, pp_import_* text.
--
-- API:  P.plan(text, live, F) -> plan | nil, err
--       P.summary(plan) -> "place N, keep K, remove R (refund Name xN, ..., +M more), recipe changes C"
--       P.removes_text(plan) -> "removes: 3 belts, 1 splitter" ("" when none)
--       P.cost_rows(plan) -> sorted { {name=ITEM_raw, need=, refund=, net=}, ... } (need>0 or refund>0)
--       P.fingerprint(existing) -> FNV-1a 32-bit over id,bcls,x,y,h,rot (plan staleness check)
--       opts (optional) = { trace = fn(text) }: called with diagnostics (missing blocks, keep split, placed-validation failure); never changes the plan
-- F = MSCore factory module (mscore_factory.lua), injected: F.tables, F.block_floor, F.floor_rects, F.validate_place,
--     F.footprint, F.encode_cfg, F.decode_cfg, F.encode_ug. Tests pass a snapshot copy (tests/fixtures).
-- live (injected by bpu_live, this file never touches the game):
--   station   = station id
--   blocks    = { {class=, gx=, gy=, h=, rot=}, ... }          live Blueprint.Blocks
--   existing  = { {id=, cls=, bcls=, dat=, x=, y=, h=, rot=, recipe=, cfg=<bytes|nil>}, ... }  live machines (cfg = live config)
--   recipes   = { [REC object name, e.g. "REC_TitaniumPlates"] = <game Recipe.Name> }
--   buildables= { [dat] = {cost={ITEM_X=n}, bcls=<class short name, optional>, cls=<optional>} }

local JSON = require("bpu_json")
local PT = require("bpu_ports")

local P = {}

-- machines that take a recipe: DAT -> crafter name (recipe site table) and port count (config layout). probe kPasteRecipe.
local RECIPE_MACH = {
    DAT_Assembler = { crafter = "Assembler", ports = 8 },
    DAT_Refinery = { crafter = "Refinery", ports = 4 },
    DAT_EnrichmentChamber = { crafter = "Enrichment", ports = 12 },
    DAT_AdvancedAssembler = { crafter = "AdvancedAssembler", ports = 12 },
    DAT_GrowthChamber = { crafter = "GrowthChamber", ports = 8 },
    DAT_Supercomputer = { crafter = "Supercomputer", ports = 8 },
    DAT_RelicSynthesizer = { crafter = "RelicSynthesizer", ports = 12 },
}

-- underground tiers: DAT, MaxLength (Mk1 8, Mk2 10, Mk3 12)
local UG_TIERS = {
    { dat = "DAT_UndergroundBelt", max = 8 },
    { dat = "DAT_UndergroundBelt_2", max = 10 },
    { dat = "DAT_UndergroundBelt_3", max = 12 },
}

-- classes never removed by sync (substring match on the class short name)
local NEVER_REMOVED = { "Dock", "SolarPanel", "Console", "ItemCrate", "Elevator", "Teleporter" }

-- site recipe rows {crafter, out, ins, rec}: generated from the probe table kPasteRecRows (63 recipes, same order).
local REC_ROWS = {
    {"AdvancedAssembler", "advancedcircuits", "basiccircuit+coolant+detectorarray+superalloy", "REC_AdvancedCircuits"},
    {"AdvancedAssembler", "advancedplates", "chitincomposite+chromaticalloy+multisensor+reinforcedplates", "REC_AdvancedPlates"},
    {"GrowthChamber", "alphaprotein", "biomass+enzyme+nutrients+xenoeukarya", "REC_AlphaProtein"},
    {"Armoury", "backpackmk1", "hullplates+lightweightframe", "REC_BackpackMk1"},
    {"Armoury", "backpackmk2", "graphene+reinforcedplates", "REC_BackpackMk2"},
    {"Armoury", "backpackmk3", "biolattice+superalloyframe", "REC_BackpackMk3"},
    {"Assembler", "basiccircuit", "magneticcoils+siliconwafers", "REC_BasicCircuit"},
    {"Assembler", "basicmotor", "titaniumplates", "REC_BasicMotor"},
    {"GrowthChamber", "betaprotein", "biomass+enzyme+nutrients+xenoarchaea", "REC_BetaProtein"},
    {"GrowthChamber", "biolattice", "alphaprotein+betaprotein+nutrients", "REC_Biolattice"},
    {"Assembler", "capacitor", "nickelplates+titaniumplates", "REC_Capacitor"},
    {"AdvancedAssembler", "chitincomposite", "biolattice+enzyme+graphene+reinforcedglass", "REC_ChitinComposite"},
    {"Enrichment", "chromaticalloy", "iridiumplates+superalloy", "REC_ChromaticAlloy"},
    {"Refinery", "cobaltplates", "cobaltore", "REC_CobaltPlates"},
    {"Assembler", "containmentcoil", "basiccircuit+capacitor+magneticcoils", "REC_ContainmentCoil"},
    {"Enrichment", "coolant", "nitrogengas", "REC_Coolant"},
    {"Assembler", "detectorarray", "basiccircuit+cobaltplates+graphene", "REC_DetectorArray"},
    {"AdvancedAssembler", "emptysimulationmatrix", "advancedcircuits+lonsdaleite", "REC_EmptySimulationMatrix"},
    {"Supercomputer", "encodedsimulationmatrix", "emptysimulationmatrix+stellarsurveydata", "REC_EncodedSimulationMatrix"},
    {"Enrichment", "enrichedcobaltore", "cobaltore", "REC_EnrichedCobaltOre"},
    {"Refinery", "cobaltplates", "enrichedcobaltore", "REC_EnrichedCobaltPlates"},
    {"Enrichment", "enrichedfuel", "hydrogenfuel", "REC_EnrichedFuel"},
    {"Enrichment", "enrichednickelore", "nickelore", "REC_EnrichedNickelOre"},
    {"Refinery", "nickelplates", "enrichednickelore", "REC_EnrichedNickelPlates"},
    {"Enrichment", "enrichedtitaniumore", "titaniumore", "REC_EnrichedTitaniumOre"},
    {"Refinery", "titaniumplates", "enrichedtitaniumore", "REC_EnrichedTitaniumPlates"},
    {"GrowthChamber", "enzyme", "biomass+nutrients+xenobacteria", "REC_Enzyme"},
    {"Armoury", "exoskeletonmk1", "capacitor+servomotor", "REC_ExoskeletonMk1"},
    {"Armoury", "exoskeletonmk2", "coolant+maglevcoupling", "REC_ExoskeletonMk2"},
    {"Armoury", "exoskeletonmk3", "chitincomposite+chromaticalloy", "REC_ExoskeletonMk3"},
    {"Armoury", "exosuit", "advancedplates+backpackmk3+exoskeletonmk3", "REC_Exosuit"},
    {"Refinery", "graphene", "graphite", "REC_Graphene"},
    {"Assembler", "hullplates", "titaniumplates", "REC_HullPlates"},
    {"Refinery", "hydrogenfuel", "waterice", "REC_HydrogenFuel"},
    {"Refinery", "iridiumplates", "iridiumore+titaniumore", "REC_IridiumPlates"},
    {"Assembler", "lightweightframe", "titaniumplates", "REC_LightweightFrame"},
    {"Assembler", "magneticcoils", "nickelplates", "REC_MageticCoils"},
    {"Assembler", "maglevcoupling", "servomotor+superalloy", "REC_MaglevCoupling"},
    {"Assembler", "missile", "containmentcoil+coolant+hullplates", "REC_Missile"},
    {"AdvancedAssembler", "multisensor", "chromaticalloy+encodedsimulationmatrix+lonsdaleite+superconductorcoil", "REC_Multisensor"},
    {"Refinery", "nickelplates", "nickelore", "REC_NickelPlates"},
    {"Enrichment", "nickelore", "protomatter", "REC_NickelSynthesis"},
    {"GrowthChamber", "nutrients", "graphite+silica+waterice", "REC_Nutrients"},
    {"RelicSynthesizer", "protomatter", "", "REC_Protomatter"},
    {"Refinery", "reinforcedglass", "silica", "REC_ReinforcedGlass"},
    {"Assembler", "reinforcedplates", "hullplates+superalloy", "REC_ReinforcedPlates"},
    {"Assembler", "reliccapacitor", "capacitor+relicshard", "REC_RelicCapacitor"},
    {"RelicSynthesizer", "relicshard", "superalloy", "REC_RelicShardSynthesis"},
    {"Assembler", "repairkit", "lightweightframe+nickelplates", "REC_RepairKit"},
    {"Assembler", "repairkitelectric", "capacitor+magneticcoils", "REC_RepairKitElectric"},
    {"Assembler", "repairkithull", "hullplates+lightweightframe", "REC_RepairKitHull"},
    {"AdvancedAssembler", "servoplates", "maglevcoupling+reinforcedplates", "REC_ServoPlates"},
    {"Assembler", "servomotor", "basicmotor+capacitor+lightweightframe", "REC_Servomotor"},
    {"Refinery", "siliconwafers", "silica", "REC_SiliconWafers"},
    {"Enrichment", "superalloy", "enrichedcobaltore+enrichednickelore+enrichedtitaniumore", "REC_Superalloy"},
    {"AdvancedAssembler", "superalloyframe", "superalloy", "REC_SuperalloyFrame"},
    {"Assembler", "superconductorcoil", "containmentcoil+coolant+maglevcoupling", "REC_SuperconductorCoil"},
    {"Refinery", "titaniumplates", "titaniumore", "REC_TitaniumPlates"},
    {"Enrichment", "titaniumore", "protomatter", "REC_TitaniumSynthesis"},
    {"Enrichment", "warpfuel", "containmentcoil+enrichedfuel", "REC_WarpFuel"},
    {"GrowthChamber", "xenoeukarya", "biomass+xenoeukarya", "REC_XenoEukaryaRecycling"},
    {"GrowthChamber", "xenoarchaea", "biomass+xenoarchaea", "REC_XenoarchaeaRecycling"},
    {"GrowthChamber", "xenobacteria", "biomass+xenobacteria", "REC_XenobacteriaRecycling"},
}

---------------------------------------------------------------- helpers
local function bail(msg) error({ bpu = msg }, 0) end

local function is_array(t) return next(t) == nil or t[1] ~= nil end

local function sorted_keys(t)
    local ks = {}
    for k in pairs(t) do ks[#ks + 1] = k end
    table.sort(ks)
    return ks
end

local function copy(t)
    local c = {}
    for k, v in pairs(t) do c[k] = v end
    return c
end

-- "/Game/x/BPO_A.BPO_A_C" -> "BPO_A" (path, '.' suffix and "_C" removed)
local function short(s)
    s = s:match("([^/\\]*)$") or s
    s = s:match("^([^%.]*)") or s
    if #s > 2 and s:sub(-2) == "_C" then s = s:sub(1, -3) end
    return s
end

local function int_field(v, what)
    if type(v) ~= "number" or v ~= math.floor(v) or v < -2147483648 or v > 2147483647 then
        bail("bad or missing number " .. what)
    end
    return math.tointeger(v)
end

local function grid(o, what)
    local gl = o.GridLocation
    if type(gl) ~= "table" then bail("missing GridLocation in " .. what) end
    local x = int_field(gl.X, "GridLocation.X")
    local y = int_field(gl.Y, "GridLocation.Y")
    local h = int_field(o.Height, "Height")
    local rot = int_field(o.GridRotation, "GridRotation")
    return x, y, h, rot
end

-- ConfigHex text -> bytes. nil + why when not even-length hex or over 4096 bytes.
local function hex_cfg(hex)
    if #hex % 2 ~= 0 or hex:find("[^%x]") then return nil, "not even-length hex (0-9 a-f)" end
    if #hex / 2 > 4096 then return nil, "more than 4096 bytes" end
    return (hex:gsub("%x%x", function(p) return string.char(tonumber(p, 16)) end))
end

-- underground config layout: 01 00 + i32 Length -> Length, -1 when not that size
local function cfg_len(b)
    if not b or #b ~= 6 then return -1 end
    return (string.unpack("<i4", b, 3))
end

local function is_ug(m)
    return m.dat ~= nil and m.dat:sub(1, #"DAT_UndergroundBelt") == "DAT_UndergroundBelt"
end

local function where(m)
    return tostring(m.dat) .. "@(" .. m.x .. "," .. m.y .. ",h" .. m.h .. ")"
end

-- positive-area intersection of two footprints (centre x,y, half extents w,h); touching edges do not count
local function overlap(ax, ay, aw, ah, bx, by, bw, bh)
    return ax - aw < bx + bw and bx - bw < ax + aw and ay - ah < by + bh and by - bh < ay + ah
end

local function footprint_of(F, e)
    local w, h = F.footprint(e.dat or "", e.rot or 0)
    if not w then return 1, 1 end   -- probe: unknown existing footprint = 1x1
    return w, h
end

---------------------------------------------------------------- recipes (site id -> REC -> live Recipe.Name)
local function pp_norm(s)
    s = s:lower()
    if s:sub(1, 5) == "item_" then s = s:sub(6) end
    return (s:gsub("[ _%-\t]", ""))
end

-- "item_a + item_b" -> canonical input set "a+b" (names normalized, sorted, empty parts dropped)
local function item_set(s)
    local v = {}
    for part in (s .. "+"):gmatch("(.-)%+") do
        local t = part:match("^[ \t]*(.-)[ \t]*$")
        if t ~= "" then v[#v + 1] = pp_norm(t) end
    end
    table.sort(v)
    return table.concat(v, "+")
end

-- site "inputs>output" + crafter -> REC id. nil + why when no or several candidates (no guessing).
local function site_rec(site, crafter)
    local gt = site:find(">", 1, true)
    if not gt then return nil, "no '>' in site id" end
    local out = item_set(site:sub(gt + 1))
    local ins = item_set(site:sub(1, gt - 1))
    local c = {}
    for _, r in ipairs(REC_ROWS) do
        if r[1] == crafter and r[2] == out then c[#c + 1] = r end
    end
    if #c > 1 then
        local same = {}
        for _, r in ipairs(c) do if r[3] == ins then same[#same + 1] = r end end
        c = same
    end
    if #c ~= 1 then return nil, #c .. " offline candidates for " .. crafter .. " output " .. out end
    return c[1][4]
end

-- recipe text of a machine -> game Recipe.Name, through live.recipes. Plain text (no '>') = a game name already.
local function resolve_recipe(site, crafter, live_recipes)
    local matches = {}
    if not site:find(">", 1, true) then
        local want = site:lower()
        for _, name in pairs(live_recipes) do
            if name:lower() == want then matches[#matches + 1] = name end
        end
    else
        local rec = site_rec(site, crafter)
        if not rec then return nil end
        local want = rec:lower()
        local bare = want:sub(1, 4) == "rec_" and want:sub(5) or want
        for key, name in pairs(live_recipes) do
            local lk = key:lower()
            if lk == want or lk == bare then matches[#matches + 1] = name end
        end
    end
    if #matches ~= 1 then return nil end   -- none, or ambiguous
    return matches[1]
end

---------------------------------------------------------------- JSON -> records
local function parse_doc(text)
    local root, err = JSON.decode(text)
    if err then bail(err) end
    if type(root) ~= "table" or root[1] ~= nil then bail("bad JSON: top level is not an object") end
    local doc = { name = "", blocks = {}, machines = {} }
    if type(root.DisplayName) == "string" then doc.name = root.DisplayName end
    local bl = root.Blocks
    if type(bl) ~= "table" or not is_array(bl) then bail("bad JSON: Blocks missing or not an array") end
    for _, e in ipairs(bl) do
        local c = type(e) == "table" and e.Class or nil
        if type(c) ~= "string" then bail("bad JSON: block without Class") end
        local x, y, h, rot = grid(e, "block")
        doc.blocks[#doc.blocks + 1] = { class = short(c), gx = x, gy = y, h = h, rot = rot }
    end
    local dm = root.DefaultMachines
    if dm ~= nil and (type(dm) ~= "table" or not is_array(dm)) then bail("bad JSON: DefaultMachines not an array") end
    for _, e in ipairs(dm or {}) do
        local c = type(e) == "table" and e.Class or nil
        if type(c) ~= "string" then bail("bad JSON: machine without Class") end
        local m = { cls = short(c), x = 0, y = 0, h = 0, rot = 0 }
        if type(e.DefaultName) == "string" and e.DefaultName:sub(1, 4) == "DAT_" then m.dat = e.DefaultName end
        local tr = e.Transform
        if type(tr) ~= "table" then bail("bad JSON: machine without Transform: " .. m.cls) end
        m.x, m.y, m.h, m.rot = grid(tr, "machine Transform")
        if m.h % 8 ~= 0 then bail("machine Height not a multiple of 8: " .. m.cls) end
        if m.rot < 0 or m.rot > 3 then bail("machine GridRotation not 0-3: " .. m.cls) end
        if type(e.Recipe) == "string" and e.Recipe ~= "" then m.recipe = e.Recipe end
        if e.Ports ~= nil then
            if type(e.Ports) ~= "table" or not is_array(e.Ports) then bail("bad JSON: Ports not an array: " .. m.cls) end
            m.hasPorts = true
            m.ports = {}
            for _, pe in ipairs(e.Ports) do
                if type(pe) ~= "table" or type(pe.Face) ~= "string" or type(pe.Enabled) ~= "boolean" then
                    bail("bad JSON: Ports entry needs Face and Enabled: " .. m.cls)
                end
                m.ports[#m.ports + 1] = { face = pe.Face, index = int_field(pe.Index, "Ports.Index"), enabled = pe.Enabled }
            end
        end
        if e.ConfigHex ~= nil then
            if type(e.ConfigHex) ~= "string" then bail("bad JSON: ConfigHex not a string: " .. m.cls) end
            local bytes, why = hex_cfg(e.ConfigHex)
            if not bytes then bail("ConfigHex refused for " .. m.cls .. ": " .. why) end
            m.hasHex = true
            m.hexcfg = bytes
        end
        doc.machines[#doc.machines + 1] = m
    end
    return doc
end

-- trace-only: why a JSON block has no live twin. Appends lines to `lines`; never changes matching.
local DIAG_MAX = 5
local function diag_missing(lines, jb, blocks)
    local function dist(b) return math.abs((b.gx or 0) - jb.gx) + math.abs((b.gy or 0) - jb.gy) + math.abs((b.h or 0) - jb.h) end
    local function row(tag, b, extra)
        return "  " .. tag .. " class=" .. tostring(b.class) .. " gx=" .. tostring(b.gx) .. " gy=" .. tostring(b.gy)
            .. " h=" .. tostring(b.h) .. " rot=" .. tostring(b.rot) .. (extra or "")
    end
    local same_cls, same_xyh, same_cxy = {}, {}, {}
    for _, b in ipairs(blocks) do
        if b.class == jb.class then
            same_cls[#same_cls + 1] = b
            if b.gx == jb.gx and b.gy == jb.gy then same_cxy[#same_cxy + 1] = b end   -- same class+grid, h differs (exact match failed)
        elseif b.gx == jb.gx and b.gy == jb.gy and b.h == jb.h then
            same_xyh[#same_xyh + 1] = b
        end
    end
    table.sort(same_cls, function(p, q) return dist(p) < dist(q) end)
    lines[#lines + 1] = "miss " .. jb.class .. "@(" .. jb.gx .. "," .. jb.gy .. ",h" .. jb.h .. "): live same class=" .. #same_cls
        .. ", same grid other class=" .. #same_xyh .. ", same class+grid other h=" .. #same_cxy
    for i = 1, math.min(DIAG_MAX, #same_cls) do lines[#lines + 1] = row("near", same_cls[i], " d=" .. dist(same_cls[i])) end
    for i = 1, math.min(DIAG_MAX, #same_xyh) do lines[#lines + 1] = row("xyh", same_xyh[i]) end
    for i = 1, math.min(DIAG_MAX, #same_cxy) do lines[#lines + 1] = row("cxy", same_cxy[i]) end
end

-- trace-only: why a placed machine failed validation. Appends lines to `lines`; never changes matching.
local function diag_fail(lines, m, existing)
    local function dist(e) return math.abs((e.x or 0) - m.x) + math.abs((e.y or 0) - m.y) + math.abs((e.h or 0) - m.h) end
    local function desc(e) return " id=" .. tostring(e.id) .. " bcls=" .. tostring(e.bcls) .. " x=" .. tostring(e.x) .. " y=" .. tostring(e.y)
        .. " h=" .. tostring(e.h) .. " rot=" .. tostring(e.rot) end
    lines[#lines + 1] = "fail " .. tostring(m.bcls) .. " dat=" .. tostring(m.dat) .. " x=" .. m.x .. " y=" .. m.y .. " h=" .. m.h .. " rot=" .. m.rot
    local same, n_cls, at_xy = {}, 0, {}
    for _, e in ipairs(existing) do
        if e.bcls == m.bcls then n_cls = n_cls + 1; same[#same + 1] = e end
        if e.x == m.x and e.y == m.y then at_xy[#at_xy + 1] = e end
    end
    table.sort(same, function(p, q) return dist(p) < dist(q) end)
    lines[#lines + 1] = "  live same bcls=" .. n_cls
    for i = 1, math.min(8, #same) do lines[#lines + 1] = "  near" .. desc(same[i]) .. " d=" .. dist(same[i]) end
    for _, e in ipairs(at_xy) do lines[#lines + 1] = "  same xy" .. desc(e) end
end

---------------------------------------------------------------- the plan
local function build(text, live, F, opts)
    if type(text) ~= "string" then bail("plan: no blueprint text") end
    if type(live) ~= "table" or type(F) ~= "table" or type(F.tables) ~= "table" then bail("plan: live or factory module missing") end
    local buildables = live.buildables or {}
    -- live machine entries must be tables (bpu_live builds them); any other value is dropped once here, so every loop below sees machines only
    local existing = {}
    for _, e in ipairs(live.existing or {}) do if type(e) == "table" then existing[#existing + 1] = e end end
    local recipes = live.recipes or {}
    local blocks = live.blocks or {}
    local notes, skipped_ug = {}, {}

    local bkeys = sorted_keys(buildables)
    local function dat_for_cls(cls)   -- Buildable of a class: first with a footprint row, else first of that class
        local any
        for _, dat in ipairs(bkeys) do
            local b = buildables[dat]
            if b.bcls == cls or b.cls == cls then
                if F.tables[dat] then return dat end
                any = any or dat
            end
        end
        return any
    end
    local function has_buildable(e)
        return (e.dat ~= nil and buildables[e.dat] ~= nil) or (e.bcls ~= nil and dat_for_cls(e.bcls) ~= nil)
    end

    local doc = parse_doc(text)

    -- hidden Teleporter never places (brief); skipped with a note
    local machines = {}
    for _, m in ipairs(doc.machines) do
        if m.cls:find("Teleporter", 1, true) or (m.dat and m.dat:find("Teleporter", 1, true)) then
            notes[#notes + 1] = "skipped (Teleporter is never placed): " .. m.cls .. "@(" .. m.x .. "," .. m.y .. ")"
        else
            machines[#machines + 1] = m
        end
    end

    -- Blocks must be on the live station Blueprint
    local blockset = {}
    for _, b in ipairs(blocks) do blockset[b.class .. "|" .. b.gx .. "|" .. b.gy .. "|" .. b.h] = true end
    local missing, missing_jb = {}, {}
    for _, jb in ipairs(doc.blocks) do
        if not blockset[jb.class .. "|" .. jb.gx .. "|" .. jb.gy .. "|" .. jb.h] then
            missing[#missing + 1] = jb.class .. "@(" .. jb.gx .. "," .. jb.gy .. ",h" .. jb.h .. ")"
            missing_jb[#missing_jb + 1] = jb
        end
    end
    if #missing > 0 then
        if opts and type(opts.trace) == "function" then
            local lines = {}
            for _, jb in ipairs(missing_jb) do diag_missing(lines, jb, blocks) end
            opts.trace(table.concat(lines, "\n"))
        end
        local msg = "Blocks are not on the grid:"
        for i = 1, math.min(#missing, 5) do msg = msg .. " " .. missing[i] .. ";" end
        bail(msg)
    end

    -- resolve DAT (by class when absent), footprint, bcls; machines with no Buildable are skipped (block-built)
    local resolved = {}
    for i, m in ipairs(machines) do
        if type(m) ~= "table" then error(("plan: machine %d is a %s (%s)"):format(i, type(m), tostring(m))) end
        if not m.dat then m.dat = dat_for_cls(m.cls) end
        if not m.dat then
            notes[#notes + 1] = "skipped (block-built, no Buildable): " .. m.cls
        else
            resolved[#resolved + 1] = m
            if not F.tables[m.dat] then bail("unknown buildable (no footprint row): " .. m.dat) end
            local b = buildables[m.dat]
            if not b then bail("buildable not in this game: " .. m.dat) end
            m.bdat = m.dat
            m.bcls = b.bcls or b.cls or m.cls
            m.w, m.hh = F.footprint(m.dat, m.rot)
        end
    end
    machines = resolved

    -- recipes (site id -> REC -> live name); ConfigHex machines skip the lookup
    for _, m in ipairs(machines) do
        local rt = RECIPE_MACH[m.dat]
        if rt and m.recipe and not m.hasHex then
            local name = resolve_recipe(m.recipe, rt.crafter, recipes)
            if not name then bail("recipe not found: " .. m.recipe) end
            m.recipe = name
        end
    end

    -- config bytes: ConfigHex verbatim (non-underground); recipe machines get the recipe layout; undergrounds paired below
    local port_noted = {}
    for _, m in ipairs(machines) do
        if m.hasHex and not is_ug(m) then
            m.cfg = m.hexcfg
        else
            local rt = RECIPE_MACH[m.dat]
            if rt and m.recipe then
                local ports
                if PT.verified(m.dat) then
                    local perr
                    ports, perr = PT.site_to_game(m.dat, m.rot, m.ports)
                    if not ports then bail(perr .. " at " .. where(m)) end
                else
                    ports = {}
                    for i = 1, rt.ports do ports[i] = true end
                    if m.ports and not port_noted[m.dat] then
                        port_noted[m.dat] = true
                        notes[#notes + 1] = "ports not verified for " .. m.dat .. ": config written with all ports on"
                    end
                end
                m.cfg = F.encode_cfg({ recipe = m.recipe, ports = ports })
            end
        end
        if m.cfg == "" then m.cfg = nil end   -- empty ConfigHex = no config (probe: cfg.empty())
    end

    -- underground pairing: pair = ONE machine at the entrance (Length = cells inclusive), exit cells not placed
    local cells, drop, cell_of = {}, {}, {}   -- cell_of[exit cell] = entrance machine
    for _, t in ipairs(UG_TIERS) do
        for rot = 0, 3 do
            local xaxis = rot % 2 == 0
            local v = {}
            for i, m in ipairs(machines) do
                if m.rot == rot and m.dat == t.dat then v[#v + 1] = i end
            end
            local function line(i) local m = machines[i]; return xaxis and m.y or m.x end
            local function flow(i)
                local m = machines[i]
                local f = xaxis and m.x or m.y
                return rot >= 2 and -f or f
            end
            table.sort(v, function(a, b)   -- stable: index breaks ties
                if line(a) ~= line(b) then return line(a) < line(b) end
                if flow(a) ~= flow(b) then return flow(a) < flow(b) end
                return a < b
            end)
            local used = {}
            for k = 1, #v do
                if not used[k] then
                    for q = k + 1, #v do
                        if line(v[q]) ~= line(v[k]) then break end
                        if not used[q] then
                            local d = flow(v[q]) - flow(v[k])
                            if d < 2 or d % 2 ~= 0 then break end   -- off-grid or same cell: no pair
                            local len = d // 2 + 1
                            local a, b = machines[v[k]], machines[v[q]]
                            local pos_a = "(" .. a.x .. "," .. a.y .. ")"
                            if len > t.max then
                                bail("underground too long: " .. pos_a .. " to (" .. b.x .. "," .. b.y .. ") Length " .. len .. " > " .. t.max .. " (" .. t.dat .. ")")
                            end
                            a.cfg = F.encode_ug(len)
                            if a.hasHex or b.hasHex then notes[#notes + 1] = "ConfigHex ignored for paired underground " .. a.cls .. " at " .. pos_a end
                            cells[#cells + 1] = b
                            cell_of[b] = a
                            drop[v[q]] = true
                            used[k], used[q] = true, true
                            break
                        end
                    end
                    if not used[k] then
                        local u = machines[v[k]]
                        local pos_u = "(" .. u.x .. "," .. u.y .. ")"
                        if not u.hasHex then   -- Length unknown: skip and say so
                            drop[v[k]] = true
                            skipped_ug[#skipped_ug + 1] = pos_u
                            notes[#notes + 1] = "skipped underground without partner/Length at " .. pos_u
                        else
                            -- stand-alone tunnel: ConfigHex must be 01 00 + i32 Length (1..max)
                            local hl = cfg_len(u.hexcfg)
                            if #u.hexcfg ~= 6 or u.hexcfg:byte(1) ~= 1 or u.hexcfg:byte(2) ~= 0 or hl < 1 or hl > t.max then
                                bail("underground without partner at " .. pos_u .. " (ConfigHex must be 01 00 + i32 Length, Length 1-" .. t.max .. ")")
                            end
                            u.cfg = u.hexcfg
                        end
                    end
                end
            end
        end
    end
    local paired = {}
    for i, m in ipairs(machines) do if not drop[i] then paired[#paired + 1] = m end end
    machines = paired

    -- all = machines + exit cells before the keep split (validation/overlap run after it, on placed ones only)
    local all = {}
    for _, m in ipairs(machines) do all[#all + 1] = m end
    for _, m in ipairs(cells) do all[#all + 1] = m end

    -- identity keep (sync): same class+x+y+h+rot as an existing machine; underground also same Length
    local json_ms = machines
    local rest, kept, used = {}, {}, {}
    local trace_on = opts and type(opts.trace) == "function"
    -- trace-only: cfg bytes as "type=... len=... hex=..." (hex bytes space separated)
    local function cfg_desc(b)
        if type(b) ~= "string" then return "type=" .. type(b) end
        local hx = {}
        for i = 1, #b do hx[i] = string.format("%02x", b:byte(i)) end
        return "type=string len=" .. #b .. " hex=" .. (#hx > 0 and table.concat(hx, " ") or "-")
    end
    if trace_on then
        local first
        for _, e in ipairs(existing) do
            if tostring(e.bcls or e.cls or e.dat):lower():find("underground", 1, true) then first = e break end
        end
        if first then
            opts.trace(("live ug first: id=%s bcls=%s x=%s y=%s h=%s rot=%s cfg %s cfg_len=%d"):format(tostring(first.id),
                tostring(first.bcls), tostring(first.x), tostring(first.y), tostring(first.h), tostring(first.rot),
                cfg_desc(first.cfg), cfg_len(first.cfg)))
        else
            opts.trace("live ug first: none in live list")
        end
    end
    for _, m in ipairs(machines) do
        local found
        for k, e in ipairs(existing) do
            if not used[k] and e.bcls == m.bcls and e.x == m.x and e.y == m.y and e.h == m.h and e.rot == m.rot then
                -- live cfg = the station Blueprint snapshot; for undergrounds it is EMPTY in game (trace 2026-11-07), so the Length is unknown:
                -- same class + cell + rotation counts as identical. Compared only when the live cfg really holds a 6-byte Length.
                if not (is_ug(m) and type(e.cfg) == "string" and #e.cfg == 6 and cfg_len(e.cfg) ~= cfg_len(m.cfg or "")) then
                    found = k
                    break
                end
                if trace_on and is_ug(m) then
                    opts.trace(("ug cfg reject: json %s %d,%d,h%d,rot%d | live id=%s live %s live_len=%d | json %s json_len=%d"):format(
                        tostring(m.bcls), m.x, m.y, m.h, m.rot, tostring(e.id), cfg_desc(e.cfg), cfg_len(e.cfg),
                        cfg_desc(m.cfg), cfg_len(m.cfg or "")))
                end
            end
        end
        if found then
            used[found] = true
            local k2 = copy(m)
            k2.id = existing[found].id
            k2.hasLive = existing[found].cfg ~= nil
            k2.live = existing[found].cfg
            kept[#kept + 1] = k2
        else
            rest[#rest + 1] = m
        end
    end
    machines = rest
    if opts and type(opts.trace) == "function" then
        opts.trace(("keep split: json machines %d, kept %d, rest %d, live machines %d"):format(#json_ms, #kept, #rest, #existing))
        local jb, lb = {}, {}
        for i = 1, math.min(5, #json_ms) do jb[i] = tostring(json_ms[i].bcls) end
        for i = 1, math.min(5, #existing) do lb[i] = tostring(existing[i].bcls) end
        opts.trace("json bcls first5: " .. (#jb > 0 and table.concat(jb, ", ") or "-"))
        opts.trace("live bcls first5: " .. (#lb > 0 and table.concat(lb, ", ") or "-"))
        -- identity mismatch diag: for each machine to be placed, the live machines on exactly the same x,y (any class)
        local cl = {}
        for _, m in ipairs(rest) do
            local at = {}
            for _, e in ipairs(existing) do
                if e.x == m.x and e.y == m.y then at[#at + 1] = ("id=%s bcls=%s h=%s rot=%s"):format(tostring(e.id), tostring(e.bcls), tostring(e.h), tostring(e.rot)) end
            end
            cl[#cl + 1] = ("rest %s x=%s y=%s h=%s rot=%s -> live same x,y: [%s]"):format(tostring(m.bcls), tostring(m.x), tostring(m.y), tostring(m.h), tostring(m.rot), table.concat(at, "; "))
        end
        if #cl > 0 then opts.trace(table.concat(cl, "\n")) end
    end

    -- placed = new machines + exit cells of placed pairs. Kept machines (game already has them) are never validated
    local placed = {}
    for _, m in ipairs(rest) do placed[m] = true end
    for _, c in ipairs(cells) do if placed[cell_of[c]] then placed[c] = true end end
    -- floor/parity via F for placed only; overlap pairwise (any layer, as probe), pair skipped when neither side is placed
    local floors = F.floor_rects(blocks, F.block_floor)
    local skip = {}
    for _, m in ipairs(all) do
        if placed[m] then
            local ok, why = F.validate_place(floors, {}, m)
            if not ok and why:find("outside every floor", 1, true) then
                -- floor model has gaps (docks, shipyards): leave the machine out, never half-build it
                skip[cell_of[m] or m] = true
            elseif not ok then
                if opts and type(opts.trace) == "function" then
                    local lines = {}
                    diag_fail(lines, m, existing)
                    opts.trace(table.concat(lines, "\n"))
                end
                bail(why .. " at " .. where(m))
            end
        end
    end
    if next(skip) then
        local cnt, keep_m, keep_all = {}, {}, {}
        for _, m in ipairs(machines) do
            if skip[m] then cnt[m.dat] = (cnt[m.dat] or 0) + 1 else keep_m[#keep_m + 1] = m end
        end
        for _, e in ipairs(all) do
            if skip[e] or skip[cell_of[e]] then placed[e] = nil else keep_all[#keep_all + 1] = e end
        end
        machines, all = keep_m, keep_all
        for _, d in ipairs(sorted_keys(cnt)) do
            notes[#notes + 1] = ("skipped (outside the modeled floors): %d x %s"):format(cnt[d], d)
        end
    end
    -- sweep: sorted by left edge, stop when the next left edge is past this right edge (same pairs as the probe's O(n^2))
    -- ponytail: sweep is enough for ~3000 machines; spatial buckets if a blueprint ever gets much bigger
    local order = {}
    for i, m in ipairs(all) do order[i] = m end
    table.sort(order, function(p, q) return p.x - p.w < q.x - q.w end)
    for i = 1, #order do
        local a = order[i]
        local a_right = a.x + a.w
        for j = i + 1, #order do
            local b = order[j]
            if b.x - b.w >= a_right then break end
            if (placed[a] or placed[b]) and overlap(a.x, a.y, a.w, a.hh, b.x, b.y, b.w, b.hh) then bail("overlap: " .. where(a) .. " and " .. where(b)) end
        end
    end

    -- config changes of kept recipe machines: recipe + port diffs. Port diffs apply only for verified classes at rot 0
    -- (rot ~= 0 only with PT.assume_rot); others logged. chg.ports = { {index=0-based game byte, want=bool}, ... }
    local chg, recN, portN = {}, 0, 0
    for _, m in ipairs(kept) do
        if m.cfg and m.cfg ~= "" and RECIPE_MACH[m.dat] then
            local target, terr = F.decode_cfg(m.cfg)
            local live_c = m.live
            local lv = live_c and live_c ~= "" and F.decode_cfg(live_c) or nil
            if not target then
                notes[#notes + 1] = "CFG " .. m.id .. " " .. m.bcls .. " target not recipe layout (" .. tostring(terr) .. ")"
            elseif not lv then
                notes[#notes + 1] = "CFG " .. m.id .. " " .. m.bcls .. " live unknown, kept as is"
            elseif #lv.ports ~= #target.ports then
                notes[#notes + 1] = "CFG " .. m.id .. " " .. m.bcls .. " live unknown (port count differs), kept as is"
            else
                local pdiffs = {}
                for i = 1, #target.ports do
                    if target.ports[i] ~= lv.ports[i] then pdiffs[#pdiffs + 1] = { index = i - 1, want = target.ports[i] } end
                end
                local applied = {}
                if #pdiffs > 0 then
                    local why
                    if not PT.verified(m.dat) then why = "port mapping unverified for " .. m.dat
                    elseif (m.rot or 0) % 4 ~= 0 and not PT.assume_rot then why = "rot ~= 0 not verified"
                    end
                    if why then
                        notes[#notes + 1] = #pdiffs .. " port difference(s) on id " .. m.id .. " not applied (" .. why .. ")"
                    else
                        applied = pdiffs
                        portN = portN + #pdiffs
                    end
                end
                local recChanged = target.recipe ~= lv.recipe
                if recChanged or #applied > 0 then
                    chg[#chg + 1] = { m = m, recipe = recChanged, oldRec = lv.recipe, newRec = target.recipe, ports = applied }
                    if recChanged then recN = recN + 1 end
                end
            end
        end
    end

    -- removals: conflicts (same layer overlap with new machines, kept ones excluded) + stale (existing the blueprint no longer has)
    local newall = {}
    for _, m in ipairs(machines) do newall[#newall + 1] = m end
    for _, m in ipairs(cells) do newall[#newall + 1] = m end
    local hits = {}
    for k, e in ipairs(existing) do
        local ew, eh = footprint_of(F, e)
        for _, m in ipairs(newall) do
            if m.h == e.h and overlap(m.x, m.y, m.w, m.hh, e.x, e.y, ew, eh) then
                hits[#hits + 1] = k
                break
            end
        end
    end
    local keptset = used
    local stale_set, stale = {}, {}
    for k, e in ipairs(existing) do
        if not keptset[k] and has_buildable(e) then
            local never = false
            for _, w in ipairs(NEVER_REMOVED) do
                if (e.bcls or ""):find(w, 1, true) then never = true end
            end
            if not never then
                stale_set[k] = true
                stale[#stale + 1] = k
            end
        end
    end
    local rmv, in_rmv = {}, {}   -- rmv = conflicts first, then stale (probe pp_plan_removals order)
    for _, k in ipairs(hits) do rmv[#rmv + 1] = k; in_rmv[k] = true end
    for _, k in ipairs(stale) do if not in_rmv[k] then rmv[#rmv + 1] = k; in_rmv[k] = true end end
    if #rmv > 0 then
        local lst = {}
        for i = 1, math.min(#hits, 10) do
            local e = existing[hits[i]]
            lst[#lst + 1] = e.bcls .. "#" .. tostring(e.id) .. "@(" .. e.x .. "," .. e.y .. ")"
        end
        local list = table.concat(lst, ", ")
        for _, k in ipairs(hits) do
            local e = existing[k]
            for _, w in ipairs({ "Dock", "SolarPanel", "Console" }) do
                if e.bcls:find(w, 1, true) then
                    bail("replace refused, would remove " .. e.bcls .. "#" .. tostring(e.id) .. " (Dock/SolarPanel/Console are never removed): " .. list)
                end
            end
        end
        for _, k in ipairs(hits) do
            if not stale_set[k] then
                local e = existing[k]
                bail("sync refused, would remove " .. e.bcls .. "#" .. tostring(e.id) .. " (no player Buildable, never removed): " .. list)
            end
        end
    end
    local removed, stale_ids = {}, {}
    for _, k in ipairs(rmv) do removed[#removed + 1] = existing[k] end
    for _, k in ipairs(stale) do stale_ids[#stale_ids + 1] = existing[k].id end

    -- costs: need = ItemCost of placed machines; refund = ItemCost of removed machines (refund unknown = refused)
    local need, refund = {}, {}
    local function add(into, cost)
        for item, n in pairs(cost) do into[item] = (into[item] or 0) + n end
    end
    for _, m in ipairs(machines) do add(need, buildables[m.dat].cost or {}) end
    for i, e in ipairs(removed) do
        local dat = (e.dat and buildables[e.dat] and e.dat) or dat_for_cls(e.bcls or "")
        if not dat then bail("refund cost unknown for " .. tostring(e.bcls)) end
        local cost = buildables[dat].cost or {}
        add(refund, cost)
        -- copy of the live entry with its own refund (bpu_build sizes removal batches by it)
        local c = {}
        for k, v in pairs(e) do c[k] = v end
        c.refund = cost
        removed[i] = c
    end

    local removes = {}
    for _, e in ipairs(removed) do removes[e.bcls] = (removes[e.bcls] or 0) + 1 end

    return {
        station = live.station,
        name = doc.name,
        place = machines,
        cells = cells,
        kept = kept,
        chg = chg,
        removed = removed,
        stale_ids = stale_ids,
        need = need,
        refund = refund,
        skipped_ug = skipped_ug,
        notes = notes,
        counts = { place = #machines, keep = #kept, remove = #removed, recipe = recN, port = portN },
        removes = removes,
        fp = P.fingerprint(existing),
        valid = true,
    }
end

function P.plan(text, live, F, opts)
    if type(F) ~= "table" or type(F.footprint) ~= "function" then return nil, "plan: factory module missing" end
    local ok, res = pcall(build, text, live, F, opts)
    if ok then return res end
    if type(res) == "table" and res.bpu then return nil, res.bpu end
    error(res, 0)
end

---------------------------------------------------------------- texts and rows
local function strip_item(name)
    if name:sub(1, 5) == "ITEM_" then return name:sub(6) end
    return name
end

function P.summary(plan)
    local c = plan.counts
    local s = "place " .. c.place .. ", keep " .. c.keep .. ", remove " .. c.remove
    if c.remove > 0 then
        local items, shown, more = {}, 0, 0
        for _, name in ipairs(sorted_keys(plan.refund)) do
            if plan.refund[name] > 0 then
                if shown == 5 then
                    more = more + 1
                else
                    shown = shown + 1
                    items[#items + 1] = strip_item(name) .. " x" .. tostring(plan.refund[name])
                end
            end
        end
        local r = table.concat(items, ", ")
        if more > 0 then r = r .. ", +" .. more .. " more" end
        s = s .. " (refund " .. (r == "" and "none" or r) .. ")"
    end
    return s .. ", recipe changes " .. c.recipe
end

-- display name of a removed class: BP_ prefix, _C and Object removed; ConveyorBelt -> belt, Container_2 -> large container
local DISPLAY = {
    ConveyorBelt = "belt", Splitter = "splitter", Container = "container",
    ["ContainerObject_2"] = "large container", ["Container_2"] = "large container",
}
local function display_name(bcls)
    local b = (bcls:gsub("^BP_", ""))
    b = (b:gsub("_C$", ""))
    if DISPLAY[b] then return DISPLAY[b] end
    local o = (b:gsub("Object$", ""))
    if DISPLAY[o] then return DISPLAY[o] end
    return o:lower()
end

function P.removes_text(plan)
    local grouped, names = {}, {}
    for bcls, n in pairs(plan.removes or {}) do
        local d = display_name(bcls)
        if not grouped[d] then grouped[d] = 0; names[#names + 1] = d end
        grouped[d] = grouped[d] + n
    end
    if #names == 0 then return "" end
    table.sort(names, function(a, b)
        if grouped[a] ~= grouped[b] then return grouped[a] > grouped[b] end
        return a < b
    end)
    local parts = {}
    for _, d in ipairs(names) do
        local n = grouped[d]
        parts[#parts + 1] = n .. " " .. d .. (n == 1 and "" or "s")
    end
    return "removes: " .. table.concat(parts, ", ")
end

function P.cost_rows(plan)
    local seen, rows = {}, {}
    for name in pairs(plan.need) do seen[name] = true end
    for name in pairs(plan.refund) do seen[name] = true end
    for _, name in ipairs(sorted_keys(seen)) do
        local nd, rf = plan.need[name] or 0, plan.refund[name] or 0
        if nd > 0 or rf > 0 then
            rows[#rows + 1] = { name = name, need = nd, refund = rf, net = nd - rf }
        end
    end
    return rows
end

-- rolling hash over id,bcls,x,y,h,rot of each existing machine, in order. Arithmetic only (no bitwise ops):
-- hv < 2^32, so hv*31 + byte < 2^38 stays exact in integer and float. Lua 5.4 coerces numeric strings for + and *,
-- not for bitwise ops (the game error "bitwise operation on a string value").
function P.fingerprint(existing)
    local hv = 2166136261
    for _, e in ipairs(existing or {}) do
        local s = string.format("%s|%s|%s|%s|%s|%s;", tostring(e.id), tostring(e.bcls), tostring(e.x), tostring(e.y), tostring(e.h), tostring(e.rot))
        for i = 1, #s do
            hv = (hv * 31 + s:byte(i)) % 4294967296
        end
    end
    return hv
end

return P
