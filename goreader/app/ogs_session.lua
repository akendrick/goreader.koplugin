--[[
    goreader/app/ogs_session.lua - one connection to OGS: sign-in, the socket,
    and the pump that moves frames between the socket and the protocol client.

    Everything that touches the device (HTTP, TLS socket, sleeping, the clock)
    is injected, so this runs under plain Lua with scripted frames.

        local s = Session.new{
            http_get = function(url) -> body | nil, err,
            connect  = function(host, port) -> socket | nil, err,    -- see services/websocket.lua
            sleep    = function(seconds),
            now_ms   = function() -> milliseconds,
            log      = function(level, text),
        }
        local ok, err = s:open()          -- fetch token, connect, sign in (blocking, a few seconds)
        s:pump()                          -- call about once a second; returns number of frames handled
        s.ogs                             -- the OGS client (watch games, list games, chat)

    Signs in as a GUEST (the anonymous token the website gives every visitor)
    unless env.sign_in is given: then it is your own account, and you can play.
--]]

local json = require("goreader.services.json")
local WS   = require("goreader.services.websocket")
local OGS  = require("goreader.services.ogs")

local Session = {}
Session.__index = Session

Session.CONFIG_URL = "https://online-go.com/api/v1/ui/config"
Session.WS_HOST = "wss.online-go.com"
Session.WS_PORT = 443

function Session.new(env)
    assert(env and env.http_get and env.connect, "http_get and connect are required")
    local self = setmetatable({
        env = env, log = env.log or function() end,
        sleep = env.sleep or function() end, now_ms = env.now_ms or function() return os.time() * 1000 end,
        state = "closed", steps = {}, reconnects = 0, last_error = nil,
    }, Session)
    return self
end

-- One timed step for the connection report
function Session:_step(name, fn)
    local t0 = self.now_ms()
    local ok, a, b = fn()
    local ms = self.now_ms() - t0
    self.steps[#self.steps + 1] = { name = name, ok = ok and true or false, ms = ms, info = ok and a or b }
    self.log("info", string.format("OGS %s: %s (%d ms)%s", name, ok and "ok" or "FAILED", ms,
        (not ok and b) and (" - " .. tostring(b)) or ""))
    return ok, a, b
end

-- Find the sign-in token in the website config; returns token, key name
local function find_token(cfg)
    if type(cfg) ~= "table" then return nil end
    if type(cfg.user_jwt) == "string" and #cfg.user_jwt > 20 then return cfg.user_jwt, "user_jwt" end
    for k, v in pairs(cfg) do
        if type(v) == "string" and tostring(k):lower():find("jwt") and #v > 20 then return v, k end
    end
end

--[[ Connect and sign in. Returns true, or nil + a short reason. The steps
     (with timings) stay in self.steps for the connection report. ]]
function Session:open()
    self.steps, self.last_error = {}, nil
    self.state = "connecting"

    local token, user
    local ok, why
    if self.env.sign_in then
        -- your own account: env.sign_in() -> { jwt, user } | nil, reason
        ok, why = self:_step("sign in to your OGS account", function()
            local a, err = self.env.sign_in()
            if not a then return false, tostring(err) end
            token, user = a.jwt, a.user
            return true, "signed in as " .. tostring(a.user and a.user.username)
        end)
    else
        ok, why = self:_step("fetch sign-in token", function()
            local body, err = self.env.http_get(Session.CONFIG_URL)
            if not body then return false, "cannot reach online-go.com: " .. tostring(err) end
            local cfg = json.decode(body)
            if not cfg then return false, "the website sent something unreadable" end
            local t, key = find_token(cfg)
            if not t then return false, "no sign-in token in the website config" end
            token = t
            return true, "found under " .. key
        end)
    end
    if not ok then self.state, self.last_error = "closed", why; return nil, why end

    local sock
    ok, why = self:_step("open secure connection", function()
        local s, err = self.env.connect(Session.WS_HOST, Session.WS_PORT)
        if not s then return false, tostring(err) end
        sock = s
        return true, Session.WS_HOST
    end)
    if not ok then self.state, self.last_error = "closed", why; return nil, why end

    self.conn = WS.new{ socket = sock, host = Session.WS_HOST, path = "/", origin = "https://online-go.com",
        sleep = self.sleep, rand = self.env.rand }
    ok, why = self:_step("websocket handshake", function()
        local good, err = self.conn:open(100)
        if not good then return false, tostring(err) end
        return true
    end)
    if not ok then self.state, self.last_error = "closed", why; return nil, why end

    self.ogs = self.ogs or OGS.new{
        send = function(text) return self.conn:send_text(text) end,
        now = self.now_ms, log = self.log, client = "GOReader", client_version = "0.1",
    }
    self.ogs.send_fn = function(text) return self.conn:send_text(text) end
    self.ogs:connected()

    local me
    ok, why = self:_step(user and "connect as you" or "sign in as guest", function()
        local done, result, errv
        self.ogs:authenticate(token, function(d, e) done, result, errv = true, d, e end)
        for _ = 1, 100 do
            self:pump()
            if done then break end
            self.sleep(0.1)
        end
        if not done then return false, "no answer from the server" end
        if not result then return false, (errv and (errv.message or errv.code)) or "refused" end
        me = result
        if user and result.id ~= user.id then return false, "the server signed in a different account" end
        return true, (user and "id " or "guest id ") .. tostring(result.id)
    end)
    if not ok then self:close(); self.last_error = why; return nil, why end

    self.me = me
    self.user = user
    self.signed_in = user ~= nil
    self.token = token
    self.state = "open"
    return true
end

--[[ Move frames from the socket into the client and let it do its timing.
     Returns the number of frames handled. Notices a dropped connection. ]]
function Session:pump()
    if not self.conn then return 0 end
    local msgs, closed = self.conn:poll()
    for _, m in ipairs(msgs) do self.ogs:receive(m) end
    self.ogs:tick()
    if closed and self.state == "open" then
        self.state = "dropped"
        self.ogs:disconnected()
        self.log("warn", "OGS connection dropped")
    end
    return #msgs
end

--[[ After a drop: open a new socket and sign in again with the same token;
     the client rejoins the watched games by itself. Returns true or nil, why. ]]
function Session:reconnect()
    if self.state == "open" then return true end
    self.reconnects = self.reconnects + 1
    local sock, err = self.env.connect(Session.WS_HOST, Session.WS_PORT)
    if not sock then return nil, tostring(err) end
    self.conn = WS.new{ socket = sock, host = Session.WS_HOST, path = "/", origin = "https://online-go.com",
        sleep = self.sleep, rand = self.env.rand }
    local ok, herr = self.conn:open(100)
    if not ok then return nil, tostring(herr) end
    self.ogs.send_fn = function(text) return self.conn:send_text(text) end
    self.ogs:connected()                              -- signs in again and rejoins
    self.state = "open"
    return true
end

function Session:close()
    if self.conn then pcall(function() self.conn:close() end) end
    self.conn = nil
    if self.ogs then self.ogs.is_connected, self.ogs.authed = false, false end
    self.state = "closed"
end

function Session:is_open() return self.state == "open" end

-- Plain-text report of the last open(): for the connection test screen
function Session:report()
    local lines = {}
    for i, s in ipairs(self.steps) do
        lines[#lines + 1] = string.format("%d. %s  %s  (%d ms)", i, s.ok and "OK     " or "FAILED", s.name, s.ms)
        if s.info and s.info ~= "" then lines[#lines + 1] = "      " .. tostring(s.info) end
    end
    if #lines == 0 then lines[1] = "(nothing has been tried yet)" end
    return table.concat(lines, "\n")
end

return Session
