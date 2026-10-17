--[[
    goreader/services/ogs.lua - the OGS (online-go.com) realtime protocol.

    Mirrors the official client's GobanSocket: every frame is a JSON array.
        client -> server   [command, data]  or  [command, data, id]
        server -> client   [event, data]    or  [id, data, error]

    This layer knows nothing about sockets. The owner feeds it text frames
    and gives it a function that sends text:

        local ogs = OGS.new{ send = function(text) return conn:send_text(text) end,
                             now = function() return ms end }
        ogs:connected()                          -- socket opened
        ogs:authenticate(jwt, function(me, err) end)
        ogs:watch(game_id, function(event, data) end, { chat = true })
        ...
        for _, text in ipairs(conn:poll()) do ogs:receive(text) end
        ogs:tick()                               -- timeouts and pings

    Wire details that are UNVERIFIED against the live server are marked
    below; see OGS_RESEARCH.md.
--]]

local json = require("goreader.services.json")

local OGS = {}
OGS.__index = OGS

OGS.PING_INTERVAL = 10000          -- ms (the official client's default)
OGS.REQUEST_TIMEOUT = 20000        -- ms
OGS.PASS_MOVE = ".."               -- UNVERIFIED: how a pass is written in game/move

-- ---------------------------------------------------------------------------
-- Moves: two letters, "aa" = top left, columns then rows
-- ---------------------------------------------------------------------------

function OGS.encode_move(col, row)
    if col == nil then return OGS.PASS_MOVE end
    assert(col >= 1 and col <= 26 and row >= 1 and row <= 26, "coordinate out of range")
    return string.char(96 + col, 96 + row)
end

-- "dd" -> 4,4    pass/resign markers -> "pass"    garbage -> nil
function OGS.decode_move(s)
    if type(s) ~= "string" then return nil end
    if s == OGS.PASS_MOVE or s == "" or s == "pass" or s == "``" then return "pass" end
    local a, b = s:match("^([a-z])([a-z])$")
    if not a then return nil end
    return a:byte() - 96, b:byte() - 96
end

-- ---------------------------------------------------------------------------
-- Client
-- ---------------------------------------------------------------------------

--[[ opts:
       send      function(text) -> true | nil, err        (required)
       now       function() -> milliseconds              default os.time()*1000
       on_event  function(name, data)                    global events
       client, client_version                            sent with authenticate
       log       function(level, message)
--]]
function OGS.new(opts)
    assert(opts and opts.send, "send is required")
    return setmetatable({
        send_fn = opts.send,
        now = opts.now or function() return os.time() * 1000 end,
        on_event = opts.on_event or function() end,
        log = opts.log or function() end,
        client = opts.client or "GOReader",
        client_version = opts.client_version or "0",
        is_connected = false, authed = false, me = nil,
        last_id = 0, pending = {},
        games = {},                       -- game_id -> { handler, chat }
        handlers = {},                    -- event name -> list of functions
        last_ping = nil, latency = 0, drift = 0,
        jwt = nil, parse_errors = 0,
    }, OGS)
end

function OGS:on(name, fn)
    self.handlers[name] = self.handlers[name] or {}
    table.insert(self.handlers[name], fn)
end

function OGS:server_now() return self.now() - self.drift end

function OGS:_raw_send(command, data, cb, timeout)
    local frame, id
    if cb then
        self.last_id = self.last_id + 1
        id = self.last_id
        frame = json.encode({ command, data == nil and json.null or data, id })
    elseif data ~= nil then
        frame = json.encode({ command, data })
    else
        frame = json.encode({ command })
    end
    local ok, err = self.send_fn(frame)
    if not ok then return nil, err or "send_failed" end
    if cb then self.pending[id] = { cb = cb, deadline = self.now() + (timeout or OGS.REQUEST_TIMEOUT), command = command } end
    return true
end

--[[ Send a command. Refused (nil, reason) rather than queued when not
     connected or not signed in: a move must never be sent late, after the
     player has stopped looking at the position. ]]
function OGS:send(command, data, cb, timeout)
    if not self.is_connected then return nil, "not_connected" end
    if not self.authed and command ~= "authenticate" and command ~= "net/ping" then
        return nil, "not_authenticated"
    end
    return self:_raw_send(command, data, cb, timeout)
end

-- ---------------------------------------------------------------------------
-- Connection life cycle
-- ---------------------------------------------------------------------------

local function fail_pending(self, code)
    local p = self.pending
    self.pending = {}
    for _, req in pairs(p) do req.cb(nil, { code = code, message = code }) end
end

--[[ The socket has opened (first time or after a reconnect). Signs in again
     with the stored token and re-joins every game being watched. ]]
function OGS:connected()
    self.is_connected = true
    self.authed = false
    self.last_ping = nil
    if self.jwt then self:authenticate(self.jwt) end
end

function OGS:disconnected()
    self.is_connected, self.authed = false, false
    fail_pending(self, "disconnected")
    self:_emit("disconnect", {})
end

function OGS:authenticate(jwt, cb)
    self.jwt = jwt
    return self:send("authenticate", {
        jwt = jwt, client = self.client, client_version = self.client_version,
    }, function(data, err)
        if data and data.id then
            self.authed, self.me = true, data
            -- after a reconnect, rejoin what we were watching
            for id, g in pairs(self.games) do self:_join(id, g.chat) end
            self:_emit("authenticated", data)
        else
            self.authed = false
            self:_emit("auth_failed", err or { code = "no_user" })
        end
        if cb then cb(data, err) end
    end)
end

-- ---------------------------------------------------------------------------
-- Receiving
-- ---------------------------------------------------------------------------

function OGS:_emit(name, data)
    for _, fn in ipairs(self.handlers[name] or {}) do fn(data) end
    self.on_event(name, data)
end

-- Frames we never use; the server sends some of them large (active-bots is
-- about 100 KB right after sign-in), so they are skipped before parsing.
OGS.SKIP = { "active-bots", "game/%d+/latency", "score-estimator-enabled-state", "incident-report" }

local function skippable(text)
    local name = text:match('^%["([^"]+)"')
    if not name then return false end
    for _, pat in ipairs(OGS.SKIP) do
        if name:match("^" .. pat) then return true end
    end
    return false
end

function OGS:receive(text)
    if skippable(text) then return end
    local msg = json.decode(text)
    if type(msg) ~= "table" or msg[1] == nil then
        self.parse_errors = self.parse_errors + 1
        self.log("warn", "OGS: unparseable frame")
        self:_emit("parse_error", { text = tostring(text):sub(1, 80) })
        return
    end
    local first, data, extra = msg[1], msg[2], msg[3]
    if data == json.null then data = nil end
    if extra == json.null then extra = nil end          -- replies are [id, data, null]
    if type(first) == "number" then
        local req = self.pending[first]
        if req then
            self.pending[first] = nil
            if type(extra) == "table" then req.cb(nil, extra) else req.cb(data, nil) end
        end
        return
    end
    if first == "net/pong" and type(data) == "table" then
        local now = self.now()
        self.latency = now - (data.client or now)
        self.drift = now - self.latency / 2 - (data.server or now)
        self:_emit("latency", { latency = self.latency, drift = self.drift })
        return
    end
    local id, suffix = tostring(first):match("^game/(%d+)/(.+)$")
    if id then
        local g = self.games[tonumber(id)]
        if g and g.handler then g.handler(suffix, data) end
        self:_emit(first, data)
        return
    end
    self:_emit(first, data)
end

-- ---------------------------------------------------------------------------
-- Time: pings and request timeouts
-- ---------------------------------------------------------------------------

function OGS:tick()
    local now = self.now()
    for id, req in pairs(self.pending) do
        if now >= req.deadline then
            self.pending[id] = nil
            req.cb(nil, { code = "timeout", message = req.command .. " timed out" })
        end
    end
    if self.is_connected and (not self.last_ping or now - self.last_ping >= OGS.PING_INTERVAL) then
        self.last_ping = now
        self:_raw_send("net/ping", { client = now, drift = self.drift, latency = self.latency })
    end
end

-- ---------------------------------------------------------------------------
-- Games
-- ---------------------------------------------------------------------------

function OGS:_join(game_id, chat)
    return self:send("game/connect", { game_id = game_id, chat = chat and true or false })
end

--[[ Start receiving a game. `handler(event, data)` gets "gamedata", "move",
     "clock", "phase", "chat", ... (the part after game/<id>/). Works for games
     you play and for games you only watch. ]]
function OGS:watch(game_id, handler, opts)
    local chat = opts and opts.chat
    self.games[game_id] = { handler = handler, chat = chat }
    if self.authed then return self:_join(game_id, chat) end
    return true                                       -- joined after authentication
end

function OGS:unwatch(game_id)
    self.games[game_id] = nil
    if self.authed then return self:send("game/disconnect", { game_id = game_id }) end
    return true
end

function OGS:watching(game_id) return self.games[game_id] ~= nil end

--[[ Play a move (col,row from the top left) or a pass (col=nil). ]]
function OGS:move(game_id, col, row)
    return self:send("game/move", { game_id = game_id, move = OGS.encode_move(col, row) })
end

function OGS:resign(game_id) return self:send("game/resign", { game_id = game_id }) end
function OGS:pause(game_id) return self:send("game/pause", { game_id = game_id }) end
function OGS:resume(game_id) return self:send("game/resume", { game_id = game_id }) end

function OGS:request_undo(game_id, move_number)
    return self:send("game/undo/request", { game_id = game_id, move_number = move_number })
end
function OGS:accept_undo(game_id, move_number)
    return self:send("game/undo/accept", { game_id = game_id, move_number = move_number })
end

--[[ Stone removal: `stones` is a list of {col,row}; removed = true marks them
     dead, false puts them back. ]]
function OGS.pack_stones(list)
    local parts = {}
    for _, p in ipairs(list or {}) do parts[#parts + 1] = OGS.encode_move(p[1], p[2]) end
    return table.concat(parts)
end

function OGS.unpack_stones(text)
    local out = {}
    for a, b in (text or ""):gmatch("([a-z])([a-z])") do out[#out + 1] = { a:byte() - 96, b:byte() - 96 } end
    return out
end

function OGS:set_removed(game_id, stones, removed)
    return self:send("game/removed_stones/set", {
        game_id = game_id, removed = removed and true or false, stones = OGS.pack_stones(stones) })
end

function OGS:accept_removed(game_id, stones_text, strict_seki)
    return self:send("game/removed_stones/accept", {
        game_id = game_id, stones = stones_text or "", strict_seki_mode = strict_seki and true or false })
end

-- ---------------------------------------------------------------------------
-- Game lists
-- ---------------------------------------------------------------------------

--[[ list = "live" | "corr"; where = filters (see OGS_RESEARCH.md); cb(results, err) ]]
function OGS:list_games(list, where, from, limit, cb)
    limit = math.max(1, math.min(limit or 20, 300))
    return self:send("gamelist/query", {
        list = list or "live", sort_by = "rank", where = where or {},
        from = from or 0, limit = limit,
    }, function(data, err)
        if not data then return cb(nil, err) end
        cb(data.results or {}, nil, data)
    end)
end

-- ---------------------------------------------------------------------------
-- Chat
-- ---------------------------------------------------------------------------

--[[ Say something in a game's chat. Players use "main"; a spectator must use
     the spectators-only channel so players are not coached ("malkovich").
     The channel names are UNVERIFIED. ]]
function OGS:chat(game_id, move_number, body, as_spectator)
    if type(body) ~= "string" or body:match("^%s*$") then return nil, "empty" end
    return self:send("game/chat", {
        game_id = game_id, type = as_spectator and "malkovich" or "main",
        move_number = move_number or 0, body = body })
end

return OGS
