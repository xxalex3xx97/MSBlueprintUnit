-- test_ports.lua: port flags (bpu_ports) and port handling in bpu_plan. Run: lua test_ports.lua (from any dir).
-- Exit code 1 when a check fails. Probe facts: refinery game byte 1 (0-based) = South port; assembler byte 3 = (-2,5) = South, site S index 4.
local dir = (arg and arg[0] or ""):match("^(.*[/\\])") or "./"
package.path = dir .. "../Scripts/?.lua;" .. package.path
local P = require("bpu_plan")
local PT = require("bpu_ports")
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
local function same(a, b)
    if a == nil or b == nil or #a ~= #b then return false end
    for i = 1, #a do if a[i] ~= b[i] then return false end end
    return true
end
local function site_on(list, face, index)   -- enabled flag of one site port
    for _, e in ipairs(list or {}) do if e.face == face and e.index == index then return e.enabled end end
    return nil
end
local function all_site_on_except(list, face, index)   -- every site port on, except the one given (must be off)
    for _, e in ipairs(list) do
        local want = not (e.face == face and e.index == index)
        if e.enabled ~= want then return false end
    end
    return true
end

local REF, ASM, ENR = "DAT_Refinery", "DAT_Assembler", "DAT_EnrichmentChamber"
local REF_HEX = "0100 00000000 04000000 01000101"        -- refinery, empty recipe, byte 1 (South) off
local ASM_HEX = "0100 00000000 08000000 0101010001010101" -- assembler, byte 3 (South-left, site S index 4) off

-- 1. probe sample configs: decode, site mapping, exact re-encode
local rf = F.decode_cfg(F.cfg_hex(REF_HEX))
check("refinery sample decodes to {T,F,T,T}", rf and same(rf.ports, { true, false, true, true }))
local rs = rf and PT.game_to_site(REF, 0, rf.ports)
check("refinery: only site S index 2 off", rs and all_site_on_except(rs, "S", 2))
check("refinery: site_to_game of S off = sample flags", same(PT.site_to_game(REF, 0, { { face = "S", index = 2, enabled = false } }), rf.ports))
check("refinery: encode reproduces sample bytes", F.encode_cfg({ recipe = "", ports = PT.site_to_game(REF, 0, { { face = "S", index = 2, enabled = false } }) }) == F.cfg_hex(REF_HEX))

local af = F.decode_cfg(F.cfg_hex(ASM_HEX))
check("assembler sample decodes 8 ports, byte 3 off", af and #af.ports == 8 and af.ports[4] == false and af.ports[1] == true)
local as = af and PT.game_to_site(ASM, 0, af.ports)
check("assembler: only site S index 4 off", as and all_site_on_except(as, "S", 4))
check("assembler: game byte 3 is (-2,5)", same(PT.game_cells(ASM, 0)[4], { -2, 5 }))
local a_flags = PT.site_to_game(ASM, 0, { { face = "S", index = 4, enabled = false } })
check("assembler: encode one port off reproduces sample bytes", a_flags and F.encode_cfg({ recipe = "", ports = a_flags }) == F.cfg_hex(ASM_HEX))
check("index: refinery S2 -> byte 1, assembler S4 -> byte 3", PT.index(REF, { face = "S", index = 2 }, 0) == 1 and PT.index(ASM, { face = "S", index = 4 }, 0) == 3)

-- 2. rotation: clockwise quarter turn (x,y)->(-y,x). Rot 1 refinery: byte i = rotate(rot-0 cell i) (UNVERIFIED assumption)
check("rot1 refinery cells: byte 0 (0,3), byte 1 (-3,0)", same(PT.game_cells(REF, 1)[1], { 0, 3 }) and same(PT.game_cells(REF, 1)[2], { -3, 0 }))
check("rot1 refinery: site S2 (now at (-3,0)) -> byte 1", PT.index(REF, { face = "S", index = 2 }, 1) == 1)
local r1 = PT.site_to_game(REF, 1, { { face = "S", index = 2, enabled = false } })
check("rot1 refinery: flags {T,F,T,T}", same(r1, { true, false, true, true }))

-- 3. round trips for verified classes, all rotations, several patterns; cells distinct
local function patterns(n)
    local out = {}
    out[1] = {}; for k = 1, n do out[1][k] = true end
    out[2] = {}; for k = 1, n do out[2][k] = (k % 2 == 0) end
    out[3] = {}; for k = 1, n do out[3][k] = (k * k) % 5 ~= 0 end
    out[4] = {}; for k = 1, n do out[4][k] = false end
    return out
end
local rt_ok, distinct_ok = true, true
for _, cls in ipairs({ REF, ASM }) do
    check(cls .. " verified", PT.verified(cls))
    for rot = 0, 3 do
        local cells = PT.game_cells(cls, rot)
        local seen = {}
        for _, c in ipairs(cells) do
            local key = c[1] .. "," .. c[2]
            if seen[key] then distinct_ok = false end
            seen[key] = true
        end
        for _, flags in ipairs(patterns(#cells)) do
            local site = PT.game_to_site(cls, rot, flags)
            local back = site and PT.site_to_game(cls, rot, site)
            if not same(back, flags) then rt_ok = false end
            local site2 = back and PT.game_to_site(cls, rot, back)
            if not site2 or #site2 ~= #site then rt_ok = false end
            for k = 1, (site2 and #site2 or 0) do if site2[k].enabled ~= site[k].enabled then rt_ok = false end end
        end
    end
end
check("round trip site<->game, verified classes, rot 0-3", rt_ok)
check("game cells distinct per rotation", distinct_ok)

-- 4. unverified classes: no mapping, plan keeps all-on config and notes it
check("enrichment unverified", not PT.verified(ENR))
check("unverified: site_to_game refused", PT.site_to_game(ENR, 0, {}) == nil)

local BUILD = {}
for k, v in pairs({
    DAT_Refinery = { bcls = "BP_RefineryObject", cost = { ITEM_A = 5 } },
    DAT_EnrichmentChamber = { bcls = "BP_EnrichmentChamberObject", cost = { ITEM_A = 7 } },
}) do BUILD[k] = v end
local function live(over)
    local l = {
        station = 42,
        blocks = { { class = "BPO_Station_01", gx = 0, gy = 0, h = 0, rot = 0 } },
        existing = {},
        recipes = { REC_TitaniumPlates = "TitaniumPlates", REC_ChromaticAlloy = "ChromaticAlloy" },
        buildables = BUILD,
    }
    for k, v in pairs(over or {}) do l[k] = v end
    return l
end
local function ex(id, bcls, dat, x, y, cfg, rot)
    return { id = id, cls = bcls, bcls = bcls, dat = dat, x = x, y = y, h = 0, rot = rot or 0, cfg = cfg }
end
local function plan_of(file, over)
    return P.plan(read(file), live(over), F)
end

-- 5. plan: verified refinery writes real flags (recipe name stored by plan, flags from site S2 off)
local p = plan_of("ports_refinery.json")
local pc = p and p.place[1] and p.place[1].cfg and F.decode_cfg(p.place[1].cfg)
check("plan refinery: flags {T,F,T,T}", pc and same(pc.ports, { true, false, true, true }) and pc.recipe == "TitaniumPlates")

-- 6. plan: unverified enrichment keeps all ports on and notes it
p = plan_of("ports_enrich.json")
local ec = p and p.place[1] and p.place[1].cfg and F.decode_cfg(p.place[1].cfg)
check("plan enrichment: 12 ports, all on", ec and #ec.ports == 12 and same(ec.ports, (function() local t = {} for k = 1, 12 do t[k] = true end return t end)()))
local noted = false
for _, n in ipairs(p and p.notes or {}) do if n == "ports not verified for DAT_EnrichmentChamber: config written with all ports on" then noted = true end end
check("plan enrichment: notes 'ports not verified'", noted)

-- 7. plan: kept refinery, live all on, blueprint S2 off -> one port diff applied (byte 1 -> false), recipe same
local live_on = F.encode_cfg({ recipe = "TitaniumPlates", ports = { true, true, true, true } })
p = plan_of("ports_refinery.json", { existing = { ex(30, "BP_RefineryObject", REF, 1, 1, live_on) } })
check("kept port diff: one chg with ports {index=1,want=false}", p and #p.chg == 1 and #p.chg[1].ports == 1
    and p.chg[1].ports[1].index == 1 and p.chg[1].ports[1].want == false)
check("kept port diff: counts.port 1, recipe 0", p and p.counts.port == 1 and p.counts.recipe == 0 and p.chg[1].recipe == false)

-- 8. plan: kept refinery already matching -> nothing
local live_off = F.encode_cfg({ recipe = "TitaniumPlates", ports = { true, false, true, true } })
p = plan_of("ports_refinery.json", { existing = { ex(30, "BP_RefineryObject", REF, 1, 1, live_off) } })
check("kept port match: no chg, counts.port 0", p and #p.chg == 0 and p.counts.port == 0)

-- 9. plan: rot 1 kept refinery: port diff logged only, unless Pm.assume_rot
p = plan_of("ports_refinery_rot1.json", { existing = { ex(30, "BP_RefineryObject", REF, 1, 1, live_on, 1) } })
local logged = false
for _, n in ipairs(p and p.notes or {}) do if n:find("not applied (rot ~= 0 not verified)", 1, true) then logged = true end end
check("rot1 kept: logged, counts.port 0", p and logged and p.counts.port == 0 and #p.chg == 0)
PT.assume_rot = true
p = plan_of("ports_refinery_rot1.json", { existing = { ex(30, "BP_RefineryObject", REF, 1, 1, live_on, 1) } })
PT.assume_rot = false
check("rot1 kept with assume_rot: applied", p and p.counts.port == 1 and #p.chg == 1)

-- 10. plan: unverified class kept port diff logged, not applied
local enr_live = F.encode_cfg({ recipe = "ChromaticAlloy", ports = (function() local t = {} for k = 1, 12 do t[k] = true end t[1] = false return t end)() })
p = plan_of("ports_enrich.json", { existing = { ex(31, "BP_EnrichmentChamberObject", ENR, 1, 1, enr_live) } })
local nlog = false
for _, n in ipairs(p and p.notes or {}) do if n:find("not applied (port mapping unverified", 1, true) then nlog = true end end
check("unverified kept: logged, not applied, counts.port 0", p and nlog and p.counts.port == 0 and #p.chg == 0)

print(string.format("RESULT %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
