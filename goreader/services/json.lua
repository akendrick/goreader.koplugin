--[[
    goreader/services/json.lua - a small, dependency-free JSON codec.

    Used for KataGo analysis output and the knotwork.ca broker. Pure Lua
    (5.1 / LuaJIT compatible). decode() returns value or nil, message.
    JSON null decodes to json.null (a unique table) so arrays keep their length.
--]]

local json = {}
json.null = setmetatable({}, { __tostring = function() return "null" end })

--[[ An empty Lua table could be an empty list or an empty object; the encoder
     picks "[]". Wrap a table with json.object() to force "{}" (servers that
     expect an object reject a list). ]]
function json.object(t)
    return setmetatable(t or {}, { __json_object = true })
end

-- ---------------------------------------------------------------------------
-- Decode
-- ---------------------------------------------------------------------------

local ESCAPES = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f",
                  n = "\n", r = "\r", t = "\t" }

local function utf8_char(cp)
    if cp < 0x80 then return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
    elseif cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 0x1000),
            0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    else
        return string.char(0xF0 + math.floor(cp / 0x40000),
            0x80 + math.floor(cp / 0x1000) % 0x40,
            0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    end
end

local function fail(s, i, msg)
    error({ json_error = msg .. " at position " .. i }, 0)
end

local function skip(s, i)
    return s:find("[^ \t\r\n]", i) or #s + 1
end

local parse_value

local function parse_string(s, i)
    local out, j = {}, i + 1
    while true do
        local c = s:sub(j, j)
        if c == "" then fail(s, i, "unterminated string") end
        if c == '"' then return table.concat(out), j + 1 end
        if c == "\\" then
            local e = s:sub(j + 1, j + 1)
            if e == "u" then
                local hex = s:match("^%x%x%x%x", j + 2)
                if not hex then fail(s, j, "bad \\u escape") end
                local cp = tonumber(hex, 16)
                j = j + 6
                if cp >= 0xD800 and cp < 0xDC00 then          -- surrogate pair
                    local lo = s:match("^\\u(%x%x%x%x)", j)
                    if lo then
                        cp = 0x10000 + (cp - 0xD800) * 0x400 + (tonumber(lo, 16) - 0xDC00)
                        j = j + 6
                    end
                end
                out[#out + 1] = utf8_char(cp)
            elseif ESCAPES[e] then
                out[#out + 1] = ESCAPES[e]; j = j + 2
            else
                fail(s, j, "bad escape")
            end
        else
            local run = s:match('^[^"\\]+', j)
            out[#out + 1] = run; j = j + #run
        end
    end
end

local DROP_NULL = false

function parse_value(s, i)
    i = skip(s, i)
    local c = s:sub(i, i)
    if c == "{" then
        local obj = {}
        i = skip(s, i + 1)
        if s:sub(i, i) == "}" then return obj, i + 1 end
        while true do
            i = skip(s, i)
            if s:sub(i, i) ~= '"' then fail(s, i, "expected a string key") end
            local key; key, i = parse_string(s, i)
            i = skip(s, i)
            if s:sub(i, i) ~= ":" then fail(s, i, "expected ':'") end
            local val; val, i = parse_value(s, i + 1)
            if val ~= json.null or not DROP_NULL then obj[key] = val end
            i = skip(s, i)
            local d = s:sub(i, i)
            if d == "}" then return obj, i + 1 end
            if d ~= "," then fail(s, i, "expected ',' or '}'") end
            i = i + 1
        end
    elseif c == "[" then
        local arr, n = {}, 0
        i = skip(s, i + 1)
        if s:sub(i, i) == "]" then return arr, i + 1 end
        while true do
            local val; val, i = parse_value(s, i)
            n = n + 1; arr[n] = val
            i = skip(s, i)
            local d = s:sub(i, i)
            if d == "]" then return arr, i + 1 end
            if d ~= "," then fail(s, i, "expected ',' or ']'") end
            i = i + 1
        end
    elseif c == '"' then
        return parse_string(s, i)
    elseif s:sub(i, i + 3) == "true" then return true, i + 4
    elseif s:sub(i, i + 4) == "false" then return false, i + 5
    elseif s:sub(i, i + 3) == "null" then return json.null, i + 4
    else
        local num = s:match("^-?%d+%.?%d*[eE]?[+-]?%d*", i)
        if not num or num == "" or num == "-" then fail(s, i, "unexpected character") end
        local v = tonumber(num)
        if not v then fail(s, i, "bad number") end
        return v, i + #num
    end
end

--[[ opts.drop_null: leave out object members whose value is null, so code can
     test `if x then` without meeting json.null (a table, hence truthy). Array
     elements stay json.null so positions are kept. ]]
function json.decode(s, opts)
    if type(s) ~= "string" then return nil, "not a string" end
    DROP_NULL = opts and opts.drop_null or false
    local ok, v, i = pcall(parse_value, s, 1)
    DROP_NULL = false
    if not ok then
        if type(v) == "table" and v.json_error then return nil, v.json_error end
        return nil, tostring(v)
    end
    i = skip(s, i)
    if i <= #s then return nil, "trailing characters at position " .. i end
    return v
end

-- ---------------------------------------------------------------------------
-- Encode
-- ---------------------------------------------------------------------------

local function esc(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        local map = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r",
                      ["\t"] = "\\t", ["\b"] = "\\b", ["\f"] = "\\f" }
        return map[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
end

local function is_array(t)
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then return false end
        n = n + 1
    end
    return n == #t
end

local function enc(v, out)
    local t = type(v)
    if v == json.null or v == nil then out[#out + 1] = "null"
    elseif t == "boolean" then out[#out + 1] = tostring(v)
    elseif t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then error("cannot encode " .. tostring(v)) end
        out[#out + 1] = (v == math.floor(v) and math.abs(v) < 1e15) and string.format("%d", v)
                        or string.format("%.14g", v)
    elseif t == "string" then out[#out + 1] = esc(v)
    elseif t == "table" then
        local mt = getmetatable(v)
        if is_array(v) and not (mt and mt.__json_object) then
            out[#out + 1] = "["
            for i = 1, #v do
                if i > 1 then out[#out + 1] = "," end
                enc(v[i], out)
            end
            out[#out + 1] = "]"
        else
            out[#out + 1] = "{"
            local keys = {}
            for k in pairs(v) do keys[#keys + 1] = tostring(k) end
            table.sort(keys)
            for i, k in ipairs(keys) do
                if i > 1 then out[#out + 1] = "," end
                out[#out + 1] = esc(k) .. ":"
                enc(v[k], out)
            end
            out[#out + 1] = "}"
        end
    else
        error("cannot encode " .. t)
    end
end

function json.encode(v)
    local out = {}
    local ok, err = pcall(enc, v, out)
    if not ok then return nil, tostring(err) end
    return table.concat(out)
end

return json
