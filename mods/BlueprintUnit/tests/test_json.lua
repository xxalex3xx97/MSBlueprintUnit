-- test_json.lua: bpu_json decoder checks. Run: lua test_json.lua (from any dir). Exit code 1 when a check fails.
local dir = (arg and arg[0] or ""):match("^(.*[/\\])") or "./"
package.path = dir .. "../Scripts/?.lua;" .. package.path
local J = require("bpu_json")

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

-- types
check("null -> nil", J.decode("null") == nil)
check("true", J.decode("true") == true)
check("false", J.decode("false") == false)
check("integer", J.decode("  -42 ") == -42)
check("float", J.decode("1.5e2") == 150.0)
check("string", J.decode('"abc"') == "abc")
local t = J.decode('{"a":[1,2,{"b":null,"c":false}],"d":{"e":"f"}}')
check("nested object/array", t and t.a[3].c == false and t.a[2] == 2 and t.d.e == "f")
check("null member is absent", t and t.a[3].b == nil)
check("empty object and array", type(J.decode("{}")) == "table" and #J.decode("[]") == 0)

-- escapes and unicode
check("simple escapes", J.decode('"a\\"b\\\\c\\/d\\n\\t"') == 'a"b\\c/d\n\t')
check("\\u escape to UTF-8", J.decode('"\\u00e9"') == "\195\169")
check("surrogate pair", J.decode('"\\ud83d\\ude00"') == "\240\159\152\128")
check("long string with escape", J.decode('"' .. string.rep("x", 1000) .. '\\n"') == string.rep("x", 1000) .. "\n")

-- BOM
check("UTF-8 BOM accepted", type(J.decode("\239\187\191{\"a\":1}")) == "table")

-- errors (nil, err)
local function refused(text) local v, err = J.decode(text); return v == nil and type(err) == "string" end
check("trailing comma object refused", refused('{"a":1,}'))
check("trailing comma array refused", refused("[1,]"))
check("unterminated string refused", refused('"abc'))
check("bad escape refused", refused('"\\q"'))
check("bad \\u refused", refused('"\\u12G4"'))
check("bad surrogate refused", refused('"\\ud83d\\u0041"'))
check("trailing data refused", refused("{} x"))
check("bad literal refused", refused("tru"))
check("missing colon refused", refused('{"a" 1}'))
check("bad number refused", refused("1-2"))
check("not a string refused", select(2, J.decode(42)) ~= nil)

-- fixture
local b = J.decode(read("belts2.json"))
check("fixture belts2 decodes", b and b.DisplayName == "Belts2" and #b.DefaultMachines == 2 and b.DefaultMachines[2].Transform.GridLocation.X == 3)

-- speed: 3000 machines, about 500 KB
local parts = {}
for i = 0, 2999 do
    parts[#parts + 1] = string.format('{"Class":"BP_ConveyorBeltObject","DefaultName":"DAT_ConveyorBelt","Transform":{"GridLocation":{"X":%d,"Y":%d},"Height":0,"GridRotation":0},"MachineID":%d}',
        (i % 200) * 2 + 1, (i // 200) * 2 + 1, i + 1)
end
local big = '{"Version":2,"Blocks":[],"DefaultMachines":[' .. table.concat(parts, ",") .. "]}"
local t0 = os.clock()
local bv, berr = J.decode(big)
local dt = os.clock() - t0
print(string.format("info: %d KB decoded in %.3f s", #big // 1024, dt))
check("3000 machines parse, count matches", bv and #bv.DefaultMachines == 3000 and berr == nil)
check("500 KB decode under 1 s (target 150 ms)", dt < 1.0)

print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
