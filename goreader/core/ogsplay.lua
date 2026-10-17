--[[
    goreader/core/ogsplay.lua - playing or watching one OGS game (no UI).

    Ties the protocol client (services/ogs), the game model (core/ogsgame)
    and the chat store (core/chat) together. The screen calls the methods and
    listens for events; the controller deals with staging a move behind the
    CONFIRM MOVE dialogue, reloading when moves are missed, and the fair-play
    rule that no engine help is offered while you are playing a live game.

    Events (on_event(name, data)):
        "loaded"      the game was (re)loaded
        "move"        { color, col, row | pass }   a move was applied
        "clock"       the clocks changed
        "phase"       { phase }
        "chat"        { line }
        "staged"      { col, row, color } | {}    a move awaiting confirmation
        "submitted"   { col, row }                 the server has the move
        "error"       { message }
        "resync"      reloading from the server
        "undo_requested" / "undo_accepted"
--]]

local OGSGame = require("goreader.core.ogsgame")
local Chat    = require("goreader.core.chat")

local Play = {}
Play.__index = Play

local MAX_RESYNCS = 3

--[[ opts: ogs (OGS client), me (user id, or nil when not signed in),
            chat (join the chat, default true), on_event, chat_opts ]]
function Play.new(opts)
    assert(opts and opts.ogs, "an OGS client is required")
    return setmetatable({
        ogs = opts.ogs, me = opts.me,
        want_chat = opts.chat ~= false,
        on_event = opts.on_event or function() end,
        game = OGSGame.new(), chat = Chat.new(opts.chat_opts),
        game_id = nil, staged = nil, submitting = nil, resyncs = 0,
        undo_request = nil,
    }, Play)
end

function Play:emit(name, data) self.on_event(name, data or {}) end

-- ---------------------------------------------------------------------------
-- Opening and closing
-- ---------------------------------------------------------------------------

function Play:open(game_id)
    if self.game_id then self:close() end
    self.game_id = game_id
    self.game = OGSGame.new()
    self.staged, self.submitting, self.resyncs = nil, nil, 0
    return self.ogs:watch(game_id, function(event, data) self:_handle(event, data) end,
                          { chat = self.want_chat })
end

function Play:close()
    if self.game_id then self.ogs:unwatch(self.game_id) end
    self.game_id, self.staged, self.submitting = nil, nil, nil
end

-- "player" when signed in as one of the two players, else "spectator"
function Play:role()
    if self.me and self.game.loaded and self.game:color_of(self.me) then return "player" end
    return "spectator"
end

function Play:my_color() return self.me and self.game:color_of(self.me) end

-- ---------------------------------------------------------------------------
-- Fair play
-- ---------------------------------------------------------------------------

--[[ Engine analysis, hints and the like are allowed when watching someone
     else's game and once your own game is finished - never while you are a
     player in a game that is still going. ]]
function Play:can_analyse()
    if not self.game.loaded then return false end
    if self:role() == "player" and self.game.phase ~= "finished" then return false end
    return true
end

-- ---------------------------------------------------------------------------
-- Server events
-- ---------------------------------------------------------------------------

function Play:_resync(why)
    self.resyncs = self.resyncs + 1
    if self.resyncs > MAX_RESYNCS then
        self:emit("error", { message = "Lost track of the game (" .. tostring(why) .. "). Reopen it." })
        return
    end
    self:emit("resync", { reason = why })
    self.game.loaded = false
    self.ogs:send("game/connect", { game_id = self.game_id, chat = self.want_chat })
end

function Play:_handle(event, data)
    if event == "gamedata" then
        local ok, why = self.game:load(data)
        if not ok then
            self:emit("error", { message = "Cannot show this game: " .. tostring(why) })
            return
        end
        if not self.game.desynced then self.resyncs = 0 end
        self.staged, self.submitting = nil, nil
        self:emit("loaded")
        if self.game.desynced then self:_resync(self.game.problem) end
    elseif event == "move" then
        local r, why = self.game:apply_move(data or {})
        if r == "applied" then
            local c, row = OGSGame.decode_move((data or {}).move)
            -- our own submitted move coming back clears the staging
            if self.submitting then self:emit("submitted", { col = c, row = row }) end
            self.staged, self.submitting = nil, nil
            self:emit("move", { col = c ~= "pass" and c or nil, row = row, pass = c == "pass" })
        elseif r == "resync" then
            self:_resync(why)
        end
    elseif event == "clock" then
        self.game:apply_clock(data)
        self:emit("clock")
    elseif event == "phase" then
        self.game:set_phase(data)
        self.staged = nil
        self:emit("phase", { phase = data })
    elseif event == "chat" then
        local line = self.chat:add_ogs(data, self.me)
        if line then self:emit("chat", { line = line }) end
    elseif event == "chat/remove" then
        self.chat:remove_ids((data or {}).chat_ids)
    elseif event == "removed_stones" then
        if type(data) == "table" and data.all_removed then self.game:set_removed(data.all_removed) end
        self:emit("removed_stones")
    elseif event == "undo_requested" then
        self.undo_request = type(data) == "table" and data or { move_number = data }
        self:emit("undo_requested", self.undo_request)
    elseif event == "undo_accepted" then
        self.undo_request = nil
        self:emit("undo_accepted", type(data) == "table" and data or {})
        self:_resync("undo")                   -- simplest correct handling: reload
    end
end

-- ---------------------------------------------------------------------------
-- Moving: stage, then confirm
-- ---------------------------------------------------------------------------

function Play:can_move()
    return self.game.loaded and not self.game.desynced and self.game.phase == "play"
       and self.me ~= nil and self.game:is_my_turn(self.me) and not self.submitting
end

--[[ Choose a point. Nothing is sent yet: the screen shows the CONFIRM MOVE
     dialogue. Choosing another point replaces the pending one. ]]
function Play:stage(col, row)
    if not self:can_move() then
        if self.submitting then return nil, "submitting" end
        return nil, self:role() == "spectator" and "spectating" or "not_your_turn"
    end
    local color = self:my_color()
    local probe = self.game.game.rules:clone()
    local ok, why = probe:play(color, col, row)
    if not ok then return nil, why end
    self.staged = { col = col, row = row, color = color }
    self:emit("staged", self.staged)
    return true
end

function Play:stage_pass()
    if not self:can_move() then return nil, "not_your_turn" end
    self.staged = { pass = true, color = self:my_color() }
    self:emit("staged", self.staged)
    return true
end

function Play:cancel_stage()
    self.staged = nil
    self:emit("staged", {})
end

-- The CONFIRM MOVE button. Sends the staged move, once.
function Play:confirm()
    if not self.staged then return nil, "nothing_staged" end
    if not self:can_move() then return nil, "not_your_turn" end
    local m = self.staged
    local ok, err = self.ogs:move(self.game_id, m.col, m.row)
    if not ok then
        self:emit("error", { message = "Could not send the move (" .. tostring(err) .. ")." })
        return nil, err
    end
    self.submitting = m              -- stays staged until the server echoes it
    return true
end

function Play:resign()
    if self:role() ~= "player" then return nil, "spectating" end
    return self.ogs:resign(self.game_id)
end

function Play:request_undo()
    if self:role() ~= "player" then return nil, "spectating" end
    return self.ogs:request_undo(self.game_id, self.game:move_count())
end

function Play:accept_undo()
    if not self.undo_request then return nil, "no_request" end
    return self.ogs:accept_undo(self.game_id, self.undo_request.move_number or self.game:move_count())
end

-- ---------------------------------------------------------------------------
-- Chat
-- ---------------------------------------------------------------------------

--[[ Say something. Spectators are sent on the spectators-only channel. ]]
function Play:say(text)
    local clean, why, wait = self.chat:outgoing(text)
    if not clean then return nil, why, wait end
    local ok, err = self.ogs:chat(self.game_id, self.game:move_count(), clean, self:role() == "spectator")
    if not ok then return nil, err end
    self.chat:sent()
    return true
end

-- ---------------------------------------------------------------------------
-- For the screen
-- ---------------------------------------------------------------------------

function Play:status(now_ms)
    local g = self.game
    return {
        loaded = g.loaded, role = self:role(), my_color = self:my_color(),
        phase = g.phase, to_move = g.loaded and g:to_move() or nil,
        my_turn = self.me ~= nil and g.loaded and g:is_my_turn(self.me) or false,
        move_count = g:move_count(), staged = self.staged, submitting = self.submitting ~= nil,
        desynced = g.desynced, can_analyse = self:can_analyse(),
        black = g.loaded and g.players.B or nil, white = g.loaded and g.players.W or nil,
        clock_b = g:player_clock("B", now_ms), clock_w = g:player_clock("W", now_ms),
        result = g:result(), unread = self.chat.unread,
    }
end

return Play
