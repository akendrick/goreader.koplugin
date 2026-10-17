--[[
    goreader/services/dgs.lua - Dragon Go Server client (quick API).

    Ported from GoBook with the HTTP layer injected so everything but the
    transport can be tested without a network:

        local dgs = DGS.new{ transport = DGS.koreader_transport() }
        local ok, err = dgs:login(user, pass)
        local games = dgs:running_games()
        local sgf   = dgs:download_sgf(games[1].id)
        dgs:submit_move(gid, move_id, col, row, size)

    transport(req) -> { code = 200, headers = { ["set-cookie"] = "..." }, body = "..." }
                      or nil, err
        req = { url = string, method = "GET", headers = { Cookie = ... } }

    Passwords: the quick API only accepts them in the query string, so they
    are percent-encoded, sent over HTTPS, and removed from every log line and
    error message (redact()). Nothing here stores them.

    Errors are short codes the UI can map to text: missing_credentials,
    bad_credentials, no_session_cookie, not_logged_in, http_<code>, bad_json,
    not_sgf, missing_args, bad_move, or DGS's own message.
--]]

local GTP  = require("goreader.engine.gtp")
local json = require("goreader.services.json")

local DGS = {}
DGS.__index = DGS

DGS.BASE_URL = "https://www.dragongoserver.net"

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

function DGS.escape(s)
    return (tostring(s):gsub("[^%w%-_%.~]", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

-- Remove credentials from a path before it can reach a log or message
function DGS.redact(s)
    s = tostring(s or "")
    s = s:gsub("([?&]passwd=)[^&%s]*", "%1REDACTED")
    s = s:gsub("([?&]userid=)[^&%s]*", "%1REDACTED")
    return s
end

-- Attribute names that can appear in Set-Cookie but are not cookies, and
-- whose values (expires=Wed, 09-Jun...) contain commas.
local COOKIE_ATTRS = {
    expires = true, path = true, domain = true, ["max-age"] = true,
    secure = true, httponly = true, samesite = true, version = true,
}

local function merge_cookies(jar, header)
    if not header then return end
    if type(header) == "table" then header = table.concat(header, ", ") end
    for name, value in header:gmatch("([%w_%-]+)%s*=%s*([^;,]+)") do
        if not COOKIE_ATTRS[name:lower()] then jar[name] = value end
    end
end

local function cookie_header(jar)
    local parts = {}
    for name, value in pairs(jar) do parts[#parts + 1] = name .. "=" .. value end
    if #parts == 0 then return nil end
    table.sort(parts)
    return table.concat(parts, "; ")
end

--[[ One CSV line -> fields. Handles quoted fields with commas and "" escapes,
     and keeps empty fields (GoBook's %[^,]+ pattern dropped them, shifting
     every later column). ]]
function DGS.split_csv(line)
    local out, i, n = {}, 1, #line
    while i <= n + 1 do
        if line:sub(i, i) == '"' then
            local buf, j = {}, i + 1
            while j <= n do
                local c = line:sub(j, j)
                if c == '"' then
                    if line:sub(j + 1, j + 1) == '"' then buf[#buf + 1] = '"'; j = j + 2
                    else j = j + 1; break end
                else buf[#buf + 1] = c; j = j + 1 end
            end
            out[#out + 1] = table.concat(buf)
            if line:sub(j, j) == "," then i = j + 1 else break end
        else
            local j = line:find(",", i, true)
            if j then out[#out + 1] = line:sub(i, j - 1); i = j + 1
            else out[#out + 1] = line:sub(i); break end
        end
    end
    return out
end

--[[ quick_status.php?version=2 text -> list of games waiting for the user.
     The column names come from the "## G,..." header line. ]]
function DGS.parse_status(body)
    local games, cols = {}, nil
    for line in (body or ""):gmatch("[^\r\n]+") do
        if line:match("^##%s*G,") then
            cols = DGS.split_csv((line:gsub("^##%s*", "")))
        elseif cols and line:match("^G,") then
            local fields = DGS.split_csv(line)
            local raw = {}
            for i, name in ipairs(cols) do raw[name] = fields[i] end
            local id = raw.game_id
            if id and id ~= "" then
                games[#games + 1] = {
                    id = tonumber(id) or id,
                    opponent = raw.opponent_name or raw.opponent,
                    size = tonumber(raw.size), raw = raw,
                }
            end
        end
    end
    return games
end

--[[ Move label the quick API expects: lower-case column letter (no i) and
     the row counted from the BOTTOM, e.g. "q3"; or "pass".
     Not yet checked against the live server on the device. ]]
function DGS.move_label(col, row, size)
    if col == nil then return "pass" end
    if type(col) ~= "number" or type(row) ~= "number" or type(size) ~= "number"
       or col < 1 or col > size or row < 1 or row > size then
        return nil, "bad_move"
    end
    return (GTP.vertex(col, row, size):gsub("^%u", string.lower))
end

-- ---------------------------------------------------------------------------
-- Client
-- ---------------------------------------------------------------------------

--[[ opts: transport (required), base_url, log(level, message) ]]
function DGS.new(opts)
    assert(opts and opts.transport, "a transport is required")
    return setmetatable({
        transport = opts.transport,
        base_url  = opts.base_url or DGS.BASE_URL,
        log       = opts.log or function() end,
        jar       = {},
        userid    = nil,
    }, DGS)
end

function DGS:is_logged_in() return self.userid ~= nil end

function DGS:logout() self.jar, self.userid = {}, nil end

-- GET a path; returns body or nil, err
function DGS:get(path)
    local headers = {}
    local cookie = cookie_header(self.jar)
    if cookie then headers["Cookie"] = cookie end
    local res, err = self.transport{ url = self.base_url .. path, method = "GET", headers = headers }
    if not res then
        self.log("warn", "DGS request failed: " .. DGS.redact(err))
        return nil, "network: " .. DGS.redact(err)
    end
    if res.headers then merge_cookies(self.jar, res.headers["set-cookie"]) end
    if res.code ~= 200 then
        self.log("warn", "DGS HTTP " .. tostring(res.code) .. " for " .. DGS.redact(path))
        return nil, "http_" .. tostring(res.code)
    end
    return res.body or ""
end

-- GET and decode a JSON reply, mapping DGS's error field to an error string
function DGS:get_json(path)
    if not self:is_logged_in() then return nil, "not_logged_in" end
    local body, err = self:get(path)
    if not body then return nil, err end
    local data = json.decode(body)
    if type(data) ~= "table" then
        self.log("warn", "DGS non-JSON reply: " .. body:gsub("%s+", " "):sub(1, 120))
        return nil, "bad_json"
    end
    if data.error and data.error ~= "" and data.error ~= json.null then
        local msg = tostring(data.error_msg or data.error)
        if msg:find("login", 1, true) or msg:find("not_logged", 1, true) then
            self.userid = nil                      -- session expired
            return nil, "not_logged_in"
        end
        return nil, msg
    end
    return data
end

function DGS:login(userid, passwd)
    if not userid or userid == "" or not passwd or passwd == "" then
        return nil, "missing_credentials"
    end
    self.jar, self.userid = {}, nil
    local path = "/login.php?quick_mode=1&userid=" .. DGS.escape(userid)
        .. "&passwd=" .. DGS.escape(passwd)
    local body, err = self:get(path)
    if not body then return nil, err end
    if body:match("wrong_password") or body:match("don't know anyone") then
        self.jar = {}
        return nil, "bad_credentials"
    end
    if not cookie_header(self.jar) then return nil, "no_session_cookie" end
    self.userid = userid
    return true
end

-- Games where it is the user's turn (quick_status). Not all running games.
function DGS:my_turn_games()
    if not self:is_logged_in() then return nil, "not_logged_in" end
    local body, err = self:get("/quick_status.php?version=2&order=0")
    if not body then return nil, err end
    return DGS.parse_status(body)
end

-- Every running game, whoever is to move
function DGS:running_games()
    local data, err = self:get_json(
        "/quick_do.php?obj=game&cmd=list&view=running&with=user_id&lstyle=json&limit=100")
    if not data then return nil, err end
    local games = {}
    for _, item in ipairs(data.list_result or {}) do
        games[#games + 1] = {
            id = item.id, move_id = item.move_id, move_color = item.move_color,
            game_action = item.game_action, status = item.status,
            black = item.black_user, white = item.white_user, raw = item,
        }
    end
    return games
end

function DGS:download_sgf(gid)
    if not self:is_logged_in() then return nil, "not_logged_in" end
    if not gid then return nil, "missing_gid" end
    local body, err = self:get("/sgf.php?gid=" .. DGS.escape(gid))
    if not body then return nil, err end
    -- DGS writes "( ;FF[4]": allow space between ( and ;
    if not body:match("^%s*%(%s*;") then
        self.log("warn", "DGS sgf not SGF: " .. body:gsub("%s+", " "):sub(1, 120))
        return nil, "not_sgf"
    end
    return body
end

--[[ Send a move. `col`/`row` are GOReader coordinates (row from the top);
     pass col=nil for a pass. `move_id` guards against a double submit. ]]
function DGS:submit_move(gid, move_id, col, row, size)
    if not self:is_logged_in() then return nil, "not_logged_in" end
    if not gid or not move_id then return nil, "missing_args" end
    local label, why = DGS.move_label(col, row, size)
    if not label then return nil, why end
    local data, err = self:get_json(string.format(
        "/quick_do.php?obj=game&cmd=move&gid=%s&move_id=%s&move=%s",
        DGS.escape(gid), DGS.escape(move_id), DGS.escape(label)))
    if not data then return nil, err end
    return true
end

function DGS:waiting_room()
    local data, err = self:get_json(
        "/quick_do.php?obj=wroom&cmd=list&with=user_id&filter_suitable=0&lstyle=json&limit=100")
    if not data then return nil, err end
    local offers = {}
    for _, item in ipairs(data.list_result or {}) do
        local user = item.user or {}
        offers[#offers + 1] = {
            id = item.id, handle = user.handle, rating = user.rating,
            size = item.size, rated = item.rated, ruleset = item.ruleset,
            komi = item.komi, handicap = item.handicap,
            time_limit = item.time_limit, comment = item.comment,
            joinable = item.join, raw = item,
        }
    end
    return offers
end

function DGS:join_waiting_room(wrid)
    if not wrid then return nil, "missing_wrid" end
    local data, err = self:get_json("/quick_do.php?obj=wroom&cmd=join&wrid=" .. DGS.escape(wrid))
    if not data then return nil, err end
    return true
end

function DGS:delete_waiting_room(wrid)
    if not wrid then return nil, "missing_wrid" end
    local data, err = self:get_json("/quick_do.php?obj=wroom&cmd=delete&wrid=" .. DGS.escape(wrid))
    if not data then return nil, err end
    return true
end

-- ---------------------------------------------------------------------------
-- KOReader transport (not exercised by the tests; needs the device libraries)
-- ---------------------------------------------------------------------------

function DGS.koreader_transport()
    return function(req)
        local http       = require("socket.http")
        local socket     = require("socket")
        local socketutil = require("socketutil")
        local ltn12      = require("ltn12")
        local sink = {}
        socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
        local code, headers, status = socket.skip(1, http.request{
            url = req.url, method = req.method or "GET", headers = req.headers,
            sink = ltn12.sink.table(sink),
        })
        socketutil:reset_timeout()
        if not code or type(code) ~= "number" then return nil, tostring(code or status or "error") end
        return { code = code, headers = headers, body = table.concat(sink) }
    end
end

return DGS
