--[[
    goreader/core/room.lua - one OGS chat room (global-english, global-help,
    group-<id>, ...), read mostly, with throttled redraws.

    Shapes follow a real recording (see OGS_RESEARCH.md 7b): on joining, the
    server sends chat-join with the user list, then the recent history as a
    burst of chat-message events (50 lines), then live messages, chat-part for
    leavers and chat-topic.

        local room = Room.new{ ogs = client, channel = "global-english", me = "name" }
        room:join()
        ... feed server frames to the client ...
        if room:due(now) then redraw(room:lines(12)) end
        room:say("hello")      -- needs a signed-in (non-guest) account
        room:leave()
--]]

local Chat = require("goreader.core.chat")

local Room = {}
Room.__index = Room

Room.REFRESH_SECONDS = 12      -- redraw no more often than this (e-ink, battery)

--[[ opts: ogs (client), channel, me (own username, to mark own lines),
            guest (true when signed in as a guest: reading only),
            now (function -> seconds), chat_opts ]]
function Room.new(opts)
    assert(opts and opts.ogs and opts.channel, "ogs and channel are required")
    local self = setmetatable({
        ogs = opts.ogs, channel = opts.channel, me = opts.me, guest = opts.guest or false,
        now = opts.now or os.time, chat = Chat.new(opts.chat_opts),
        joined = false, roster_loaded = false, topic = nil, user_count = 0, users = {},
        dirty = false, last_draw = nil, new_since_draw = 0,
    }, Room)
    local function mine(ev) return type(ev) == "table" and ev.channel == opts.channel end
    opts.ogs:on("chat-join", function(ev)
        if not mine(ev) then return end
        self.joined = true
        local list = type(ev.users) == "table" and ev.users or (type(ev.user) == "table" and { ev.user }) or {}
        -- The first chat-join after we join is the whole room; later ones (seen
        -- in a real recording) carry one newcomer each in the same "users" list.
        if not self.roster_loaded then self.users, self.roster_loaded = {}, true end
        for _, u in ipairs(list) do if u.id then self.users[u.id] = true end end
        self:_recount(); self.dirty = true
    end)
    opts.ogs:on("chat-part", function(ev)
        if not mine(ev) then return end
        if type(ev.user) == "table" and ev.user.id then self.users[ev.user.id] = nil end
        self:_recount()
    end)
    opts.ogs:on("chat-message", function(ev)
        if not mine(ev) then return end
        local line = self.chat:add_room(ev, self.me)
        if line then self.dirty = true; self.new_since_draw = self.new_since_draw + 1 end
    end)
    opts.ogs:on("chat-topic", function(ev)
        if not mine(ev) or type(ev.topic) ~= "string" then return end
        self.topic = Chat.clean(ev.topic, 200); self.dirty = true
    end)
    opts.ogs:on("chat-message-removed", function(ev)
        if not mine(ev) then return end
        self.chat:remove_ids({ ev.uuid }); self.dirty = true
    end)
    return self
end

function Room:_recount()
    local n = 0
    for _ in pairs(self.users) do n = n + 1 end
    self.user_count = n
end

function Room:join()
    self.chat = Chat.new()                       -- the server replays history on join
    self.users, self.user_count, self.joined, self.topic, self.roster_loaded = {}, 0, false, nil, false
    return self.ogs:join_room(self.channel)
end

function Room:leave()
    self.joined, self.roster_loaded = false, false
    return self.ogs:leave_room(self.channel)
end

--[[ Is it time to redraw? True when something changed and at least
     REFRESH_SECONDS have passed since the last draw (or never drawn). ]]
function Room:due(now)
    now = now or self.now()
    if not self.dirty then return false end
    return self.last_draw == nil or now - self.last_draw >= Room.REFRESH_SECONDS
end

-- Visible lines (mutes applied), newest last; marks the room as drawn
function Room:lines(n, now)
    self.dirty, self.last_draw, self.new_since_draw = false, now or self.now(), 0
    local all = self.chat:room(self.channel)
    local out = {}
    for i = math.max(1, #all - (n or 12) + 1), #all do out[#out + 1] = all[i] end
    return out
end

function Room:can_write() return not self.guest and self.joined end

function Room:say(text)
    if self.guest then return nil, "guests_cannot_write" end
    if not self.joined then return nil, "not_joined" end
    local clean, why, wait = self.chat:outgoing(text)
    if not clean then return nil, why, wait end
    local uuid, err = self.ogs:say_room(self.channel, clean)
    if not uuid then return nil, err end
    self.chat:sent()
    return uuid
end

return Room
