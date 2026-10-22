--[[
    goreader/services/ogs_auth.lua - signing in to online-go.com with your own
    account, to get the token the realtime socket needs (and to list your games).

        local auth, err = Auth.sign_in{ transport = T, username = "...", password = "..." }
        auth.jwt, auth.user          the socket token and the signed-in user ({id, username, ranking})
        auth:overview()              -> your running games (see Auth.parse_overview)

    The website signs a browser in with a form post and a session cookie, then
    hands that session a personal token in /api/v1/ui/config. Same here:
        1. GET  /api/v1/ui/config      cookies (csrftoken, sessionid)
        2. POST /api/v0/login          {username, password}, JSON, with the csrf token
        3. GET  /api/v1/ui/config      user.anonymous == false, user_jwt = your token

    Nothing is stored here and the password is only ever in the request body
    (never a URL or a log line).

    transport(req) -> { code, headers, body } | nil, err
        req = { url, method, headers, body }
    Errors are short codes: missing_credentials, bad_credentials, unreachable,
    http_<code>, bad_json, not_signed_in.
--]]

local json = require("goreader.services.json")

local Auth = {}
Auth.__index = Auth

Auth.BASE = "https://online-go.com"

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
    for k, v in pairs(jar) do parts[#parts + 1] = k .. "=" .. v end
    table.sort(parts)
    return table.concat(parts, "; ")
end

function Auth:request(method, path, body)
    local headers = {
        ["User-Agent"] = "GOReader/0.1", ["Accept"] = "application/json",
        ["Cookie"] = cookie_header(self.jar), ["Referer"] = Auth.BASE .. "/",
    }
    if self.jar.csrftoken then headers["X-CSRFToken"] = self.jar.csrftoken end
    local payload
    if body ~= nil then
        payload = json.encode(body)
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = tostring(#payload)
    end
    local res, err = self.transport{ url = Auth.BASE .. path, method = method, headers = headers, body = payload }
    if not res then return nil, "unreachable", tostring(err) end
    merge_cookies(self.jar, res.headers and (res.headers["set-cookie"] or res.headers["Set-Cookie"]))
    return res
end

local function parse(res)
    local ok, data = pcall(json.decode, res.body or "")
    if ok and type(data) == "table" then return data end
    return nil
end

--[[ A signed-in page config: returns token, user or nil, code ]]
local function token_from(cfg)
    local user = type(cfg) == "table" and cfg.user
    if type(user) ~= "table" or user.anonymous or type(cfg.user_jwt) ~= "string" or #cfg.user_jwt < 20 then
        return nil, "not_signed_in"
    end
    return cfg.user_jwt, { id = user.id, username = user.username, ranking = user.ranking }
end

function Auth.sign_in(opts)
    local username = opts and opts.username and opts.username:match("^%s*(.-)%s*$") or ""
    local password = opts and opts.password or ""
    if username == "" or password == "" then return nil, "missing_credentials" end
    local self = setmetatable({ transport = assert(opts.transport), jar = {} }, Auth)

    local res, code, detail = self:request("GET", "/api/v1/ui/config")
    if not res then return nil, code, detail end
    if res.code ~= 200 then return nil, "http_" .. tostring(res.code) end

    res, code, detail = self:request("POST", "/api/v0/login", { username = username, password = password })
    if not res then return nil, code, detail end
    if res.code == 400 or res.code == 401 or res.code == 403 then return nil, "bad_credentials" end
    if res.code ~= 200 and res.code ~= 201 and res.code ~= 302 then return nil, "http_" .. tostring(res.code) end

    res, code, detail = self:request("GET", "/api/v1/ui/config")
    if not res then return nil, code, detail end
    if res.code ~= 200 then return nil, "http_" .. tostring(res.code) end
    local cfg = parse(res)
    if not cfg then return nil, "bad_json" end
    local jwt, user = token_from(cfg)
    if not jwt then return nil, "bad_credentials" end            -- the site did not accept the sign-in
    self.jwt, self.user = jwt, user
    return self
end

--[[ Your running games, newest information first.
     Returns a list of { id, black, white, width, height, my_turn, move_count, speed, name } ]]
function Auth.parse_overview(data, my_id)
    local out = {}
    for _, g in ipairs(type(data) == "table" and data.active_games or {}) do
        if type(g) == "table" and g.id then
            local j = type(g.json) == "table" and g.json or {}
            local clock = type(j.clock) == "table" and j.clock or {}
            local black = type(g.black) == "table" and g.black or {}
            local white = type(g.white) == "table" and g.white or {}
            local mine
            if clock.current_player ~= nil and my_id ~= nil then mine = (clock.current_player == my_id) end
            out[#out + 1] = {
                id = g.id, width = g.width or j.width, height = g.height or j.height,
                black = { id = black.id, username = black.username, rank = black.ranking },
                white = { id = white.id, username = white.username, rank = white.ranking },
                my_turn = mine == true, move_count = type(j.moves) == "table" and #j.moves or nil,
                speed = (type(j.time_control) == "table" and j.time_control.speed) or g.speed,
                name = g.name or j.game_name,
            }
        end
    end
    -- games waiting for you first
    table.sort(out, function(a, b)
        if a.my_turn ~= b.my_turn then return a.my_turn end
        return (a.id or 0) > (b.id or 0)
    end)
    return out
end

function Auth:overview()
    local res, code, detail = self:request("GET", "/api/v1/ui/overview")
    if not res then return nil, code, detail end
    if res.code == 401 or res.code == 403 then return nil, "not_signed_in" end
    if res.code ~= 200 then return nil, "http_" .. tostring(res.code) end
    local data = parse(res)
    if not data then return nil, "bad_json" end
    return Auth.parse_overview(data, self.user and self.user.id)
end

-- The real thing, for KOReader (LuaSocket + LuaSec): supports a request body
function Auth.koreader_transport()
    return function(req)
        local http       = require("socket.http")
        local socket     = require("socket")
        local socketutil = require("socketutil")
        local ltn12      = require("ltn12")
        local sink = {}
        socketutil:set_timeout(15, 30)
        local r = { url = req.url, method = req.method or "GET", headers = req.headers, sink = ltn12.sink.table(sink) }
        if req.body then r.source = ltn12.source.string(req.body) end
        local code, headers, status = socket.skip(1, http.request(r))
        socketutil:reset_timeout()
        if type(code) ~= "number" then return nil, tostring(code or status or "error") end
        return { code = code, headers = headers, body = table.concat(sink) }
    end
end

return Auth
