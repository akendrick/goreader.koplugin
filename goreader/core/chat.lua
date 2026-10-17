--[[
    goreader/core/chat.lua - game chat storage and cleaning.

    Chat text comes from strangers, so everything is treated as untrusted:
    control characters are stripped, length is capped, nothing is interpreted.
    Non-Latin text is kept as is (GoBook's title filter would have hidden real
    conversation); the screen decides how to draw characters its font lacks.

        local chat = Chat.new{ max_lines = 200, mute = {"troll"} }
        chat:add_ogs(event_data)           -- game/<id>/chat payload
        chat:recent(5)                     -- last lines, mutes applied
        chat:for_move(12)                  -- lines made at move 12
        chat:outgoing("hello")             -- cleaned text, or nil,why
--]]

local Chat = {}
Chat.__index = Chat

Chat.MAX_BODY = 500          -- characters kept from an incoming line
Chat.MAX_OUTGOING = 200
Chat.MIN_SEND_GAP = 2        -- seconds between lines we send

-- One-tap phrases for the e-ink keyboard-free case
Chat.PHRASES = {
    "Good luck, have fun!", "Thank you", "Good game", "Sorry, misclick",
    "One moment please", "Are you still there?", "Nice move", "Thanks for the game",
}

-- ---------------------------------------------------------------------------
-- Cleaning
-- ---------------------------------------------------------------------------

--[[ Strip control characters (keeps tab/newline as a space), collapse
     whitespace, cut to `max` characters without splitting a UTF-8 sequence. ]]
function Chat.clean(text, max)
    if type(text) ~= "string" then return "" end
    text = text:gsub("[%z\1-\8\11\12\14-\31\127]", "")
    text = text:gsub("[\t\n\r]", " "):gsub(" +", " ")
    text = text:match("^%s*(.-)%s*$")
    max = max or Chat.MAX_BODY
    if #text > max then
        local cut = max
        -- back up over continuation bytes (10xxxxxx) so a character is not split
        while cut > 0 do
            local b = text:byte(cut + 1)
            if b and b >= 0x80 and b < 0xC0 then cut = cut - 1 else break end
        end
        text = text:sub(1, cut) .. "..."
    end
    return text
end

-- ---------------------------------------------------------------------------
-- Store
-- ---------------------------------------------------------------------------

--[[ opts: max_lines (default 200), mute = list of usernames, now = function() ]]
function Chat.new(opts)
    opts = opts or {}
    local mute = {}
    for _, n in ipairs(opts.mute or {}) do mute[n:lower()] = true end
    return setmetatable({
        lines = {}, ids = {}, max_lines = opts.max_lines or 200, mute = mute,
        now = opts.now or os.time, last_sent = nil, unread = 0,
    }, Chat)
end

function Chat:is_muted(name) return name ~= nil and self.mute[tostring(name):lower()] == true end
function Chat:set_muted(name, on) self.mute[name:lower()] = on and true or nil end

function Chat:muted_list()
    local out = {}
    for n in pairs(self.mute) do out[#out + 1] = n end
    table.sort(out)
    return out
end

--[[ Add a line. `line` = { id, from, name, body, move, time, channel, rank }.
     Returns the stored line, or nil if it was a duplicate or empty. ]]
function Chat:add(line)
    local body = Chat.clean(line.body)
    if body == "" then return nil end
    if line.id and self.ids[line.id] then return nil end
    local l = {
        id = line.id, from = line.from, name = Chat.clean(line.name or "", 40),
        body = body, move = line.move or 0, time = line.time,
        channel = line.channel or "main", rank = line.rank, mine = line.mine or false,
    }
    self.lines[#self.lines + 1] = l
    if l.id then self.ids[l.id] = true end
    if #self.lines > self.max_lines then
        local old = table.remove(self.lines, 1)
        if old.id then self.ids[old.id] = nil end
    end
    if not l.mine then self.unread = self.unread + 1 end
    return l
end

--[[ A game/<id>/chat event: { channel, line = { chat_id, body, date,
     move_number, player_id, username, ranking } }. Structured bodies (analysis,
     review, translated) are reduced to text. Returns the stored line or nil. ]]
function Chat:add_ogs(ev, my_id)
    if type(ev) ~= "table" then return nil end
    local l = ev.line or ev
    if type(l) ~= "table" then return nil end
    local body = l.body
    if type(body) == "table" then
        if body.type == "translated" then body = body.en
        elseif body.type == "analysis" then body = "[analysis" .. (body.name and (": " .. body.name) or "") .. "]"
        elseif body.type == "review" then body = "[review]"
        else body = nil end
    end
    if type(body) ~= "string" then return nil end
    return self:add{
        id = l.chat_id, from = l.player_id, name = l.username, body = body,
        move = l.move_number, time = l.date, channel = ev.channel or l.channel,
        rank = l.ranking, mine = my_id ~= nil and l.player_id == my_id,
    }
end

-- Remove lines the server deleted (game/<id>/chat/remove { chat_ids })
function Chat:remove_ids(ids)
    local gone = {}
    for _, id in ipairs(ids or {}) do gone[id] = true end
    local kept = {}
    for _, l in ipairs(self.lines) do
        if l.id and gone[l.id] then self.ids[l.id] = nil else kept[#kept + 1] = l end
    end
    self.lines = kept
end

-- Lines that are visible: muted people and hidden/moderator channels excluded
local HIDDEN = { shadowban = true, hidden = true, moderator = true }

function Chat:visible()
    local out = {}
    for _, l in ipairs(self.lines) do
        if not self:is_muted(l.name) and not HIDDEN[l.channel] then out[#out + 1] = l end
    end
    return out
end

function Chat:recent(n)
    local v = self:visible()
    local out = {}
    for i = math.max(1, #v - n + 1), #v do out[#out + 1] = v[i] end
    return out
end

function Chat:for_move(move)
    local out = {}
    for _, l in ipairs(self:visible()) do if l.move == move then out[#out + 1] = l end end
    return out
end

function Chat:mark_read() self.unread = 0 end

-- "ann (3k): hello" for the strip under the board
function Chat.line_text(l, rank_text)
    local who = l.name ~= "" and l.name or "?"
    if rank_text and rank_text ~= "" then who = who .. " (" .. rank_text .. ")" end
    return who .. ": " .. l.body
end

-- ---------------------------------------------------------------------------
-- Sending
-- ---------------------------------------------------------------------------

--[[ Prepare text to send. Returns cleaned text, or nil + "empty" | "too_long"
     | "too_fast" (wait `wait` seconds, second result). ]]
function Chat:outgoing(text)
    local t = Chat.clean(text, Chat.MAX_OUTGOING + 1)
    if t == "" then return nil, "empty" end
    if #t > Chat.MAX_OUTGOING then return nil, "too_long" end
    local now = self.now()
    if self.last_sent and now - self.last_sent < Chat.MIN_SEND_GAP then
        return nil, "too_fast", Chat.MIN_SEND_GAP - (now - self.last_sent)
    end
    return t
end

function Chat:sent() self.last_sent = self.now() end

return Chat
