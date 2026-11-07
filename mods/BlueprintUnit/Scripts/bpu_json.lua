-- bpu_json.lua: JSON decoder for the Blueprint Unit (website Factory Blueprint export). Pure Lua 5.4, no game globals.
-- M.decode(text) -> value | nil, err. Objects -> tables (string keys), arrays -> sequences, null -> absent (nil).
-- Accepts a UTF-8 BOM. Strings: escapes incl. \uXXXX and surrogate pairs. Tokens are found with string.find patterns.
-- Port of the probe parser (mb_bpprobe.hpp PJParser), same accept/refuse rules (trailing commas refused, depth 64).

local M = {}

local find, sub, byte, tonumber, concat = string.find, string.sub, string.byte, tonumber, table.concat
local utf8char = utf8.char

local NULL = {}   -- internal null marker; containers drop it
local MAX_DEPTH = 64
local ESC = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }

local function perr(msg, pos)
    error(msg .. " at byte " .. pos, 0)
end

local function skip_ws(s, pos)
    local _, e = find(s, "^[ \t\r\n]*", pos)
    return e + 1
end

local function hex4(s, at)
    local h = sub(s, at, at + 3)
    if find(h, "^%x%x%x%x$") then return tonumber(h, 16) end
    return nil
end

-- pos = opening quote. Fast path: no escapes -> one sub. Slow path: pieces joined with table.concat.
local function parse_string(s, pos)
    local i = pos + 1
    local q = find(s, '["\\]', i)
    if not q then perr("unterminated string", pos) end
    if byte(s, q) == 34 then return sub(s, i, q - 1), q + 1 end
    local out, n, j = {}, 0, i
    while true do
        q = find(s, '["\\]', j)
        if not q then perr("unterminated string", pos) end
        if q > j then n = n + 1; out[n] = sub(s, j, q - 1) end
        if byte(s, q) == 34 then return concat(out), q + 1 end
        local e = sub(s, q + 1, q + 1)
        if e == "u" then
            local cp = hex4(s, q + 2)
            if not cp then perr("bad \\u escape", q) end
            j = q + 6
            if cp >= 0xD800 and cp <= 0xDBFF and sub(s, j, j + 1) == "\\u" then
                local lo = hex4(s, j + 2)
                if not lo or lo < 0xDC00 or lo > 0xDFFF then perr("bad surrogate pair", j) end
                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
                j = j + 6
            end
            n = n + 1; out[n] = utf8char(cp)
        else
            local r = ESC[e]
            if not r then perr("bad escape", q) end
            n = n + 1; out[n] = r
            j = q + 2
        end
    end
end

local function parse_number(s, pos)
    local a, b = find(s, "^[%-%+%.%deE]+", pos)
    if not a then perr("unexpected character", pos) end
    local v = tonumber(sub(s, a, b))
    if not v then perr("bad number", pos) end
    return v, b + 1
end

local parse_value   -- forward (mutual recursion with containers)

local function parse_array(s, pos, depth)
    if depth > MAX_DEPTH then perr("nesting too deep", pos) end
    local t, n = {}, 0
    pos = skip_ws(s, pos + 1)
    if byte(s, pos) == 93 then return t, pos + 1 end
    while true do
        local v
        v, pos = parse_value(s, skip_ws(s, pos), depth + 1)
        if v ~= NULL then n = n + 1; t[n] = v end
        pos = skip_ws(s, pos)
        local c = byte(s, pos)
        if c == 93 then return t, pos + 1 end
        if c ~= 44 then perr("expected , or ]", pos) end
        pos = pos + 1
    end
end

local function parse_object(s, pos, depth)
    if depth > MAX_DEPTH then perr("nesting too deep", pos) end
    local t = {}
    pos = skip_ws(s, pos + 1)
    if byte(s, pos) == 125 then return t, pos + 1 end
    while true do
        if byte(s, pos) ~= 34 then perr("expected key", pos) end
        local k
        k, pos = parse_string(s, pos)
        pos = skip_ws(s, pos)
        if byte(s, pos) ~= 58 then perr("expected :", pos) end
        local v
        v, pos = parse_value(s, skip_ws(s, pos + 1), depth + 1)
        if v ~= NULL then t[k] = v end
        pos = skip_ws(s, pos)
        local c = byte(s, pos)
        if c == 125 then return t, pos + 1 end
        if c ~= 44 then perr("expected , or }", pos) end
        pos = skip_ws(s, pos + 1)
    end
end

function parse_value(s, pos, depth)
    local c = byte(s, pos)
    if c == nil then perr("unexpected end", pos) end
    if c == 123 then return parse_object(s, pos, depth) end
    if c == 91 then return parse_array(s, pos, depth) end
    if c == 34 then return parse_string(s, pos) end
    if c == 116 and sub(s, pos, pos + 3) == "true" then return true, pos + 4 end
    if c == 102 and sub(s, pos, pos + 4) == "false" then return false, pos + 5 end
    if c == 110 and sub(s, pos, pos + 3) == "null" then return NULL, pos + 4 end
    return parse_number(s, pos)
end

function M.decode(text)
    if type(text) ~= "string" then return nil, "bad JSON: text is not a string" end
    local start = 1
    if sub(text, 1, 3) == "\239\187\191" then start = 4 end   -- UTF-8 BOM
    local ok, v = pcall(function()
        local val, p = parse_value(text, skip_ws(text, start), 0)
        p = skip_ws(text, p)
        if p <= #text then perr("trailing data", p) end
        return val
    end)
    if not ok then return nil, "bad JSON: " .. tostring(v) end
    if v == NULL then v = nil end
    return v
end

return M
