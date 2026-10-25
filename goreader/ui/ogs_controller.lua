--[[
    goreader/ui/ogs_controller.lua - drives a GameScreen for one OGS game: one
    you watch, or one you play. It keeps the connection alive from tick(),
    turns the game model into what the screen draws, and shows the latest chat
    lines under the board.

    Playing (signed in as one of the two players): tap a point, check it in the
    CONFIRM MOVE box under the board, confirm. Pass and Resign are on the
    button row; when both pass the stones are counted by tapping dead groups
    and pressing Accept. Chat has one-tap quick replies and a typing box.

        local c = OGSController.new{ session = Session, game_id = 123,
                                     show_text = function(title, text) end,
                                     choose = function(title, choices, cb) end,   -- {id,label} list
                                     ask_text = function(title, initial, ok_label, cb) end,
                                     now = os.time }
        c:open()                    -- joins the game
        GameScreen:new{ controller = c }
--]]

local Play    = require("goreader.core.ogsplay")
local OGSGame = require("goreader.core.ogsgame")
local Chat    = require("goreader.core.chat")
local Last    = require("goreader.ui.lastmove")

local Controller = {}
Controller.__index = Controller

-- One-tap chat replies (a person types slowly on e-ink)
Controller.QUICK_REPLIES = {
    { "hi", "Hello, have fun!" }, { "gl", "Good luck!" }, { "thx", "Thanks!" },
    { "gg", "gg, thank you for the game" }, { "wait", "One moment please" },
    { "ok", "OK" }, { "slow", "Sorry, my e-ink screen is slow" },
}

local REASONS = {
    occupied = "That point is taken.", suicide = "Not allowed: no liberties.",
    ko = "Not allowed: ko.", superko = "Not allowed: repeats a position.",
    not_your_turn = "It is not your move.", spectating = "You are watching this game.",
    submitting = "Sending your move…",
}

-- E-ink: the screen is redrawn when something HAPPENS (a move, the phase of the
-- game, the clocks that come with a move), never on a timer. Chat only
-- refreshes the strip, and at most this often.
Controller.CHAT_REDRAW_SECONDS = 15
Controller.RECONNECT_SECONDS = 8

--[[ opts: session, game_id, title (optional), show_text(title, text), now() ]]
function Controller.new(opts)
    local self = setmetatable({
        session = assert(opts.session), game_id = assert(opts.game_id),
        title = opts.title, show_text = opts.show_text or function() end,
        choose = opts.choose or function() end, ask_text = opts.ask_text or function() end,
        message = nil, sending = false, asked_undo = false,
        now = opts.now or os.time, live_clocks = false, region_refresh = true, refresh_every = opts.refresh_every or 10, moves_since_full = 0, want_full = false, dirty = true, chat_dirty = false, last_draw = nil, last_chat_draw = nil, last_reconnect = nil,
        on_change = function() end, closed = false,
    }, Controller)
    self.play = Play.new{
        ogs = self.session.ogs, me = self.session.me and self.session.me.id,
        on_event = function(name, data) self:_event(name, data) end,
    }
    return self
end

function Controller:_event(name, data)
    if name == "loaded" or name == "move" or name == "phase" or name == "clock"
       or name == "error" or name == "resync" or name == "removed_stones" or name == "undo_requested" then
        self.dirty = true                                  -- a move (and its clocks) changes the board now
        -- a new game or a change of phase starts clean; moves refresh only what changed, with a full refresh
        -- every `refresh_every` moves to clear the ghosting (1 = every move, 0 = never for moves)
        if name == "loaded" or name == "phase" or name == "removed_stones" then self.want_full = true end
        if name == "move" then
            self.moves_since_full = self.moves_since_full + 1
            if self.refresh_every >= 1 and self.moves_since_full >= self.refresh_every then self.want_full = true end
        end
    elseif name == "chat" then
        self.chat_dirty = true                             -- the chat strip can wait a little
    end
    if name == "move" or name == "loaded" or name == "phase" then self.sending = false end
    if name == "move" or name == "phase" then self.message = nil end
    if name == "error" then
        self.error_seen = true
        self.sending = false
        self.message = data and data.message or "Something went wrong."
    end
end

--[[ How the screen should refresh for what just happened: "full" (a flashing, clean refresh)
     for a new game, a change of phase, and every `refresh_every` moves; otherwise nothing special
     (the screen then refreshes only the part that changed). ]]
function Controller:take_refresh_mode()
    local want = self.want_full
    self.want_full = false
    if want then self.moves_since_full = 0 end
    return want and "full" or nil
end

function Controller:playing()
    local p = self.play
    return p:role() == "player" and p.game.phase ~= "finished"
end

function Controller:open() return self.play:open(self.game_id) end

-- ---------------------------------------------------------------------------
-- What the screen shows
-- ---------------------------------------------------------------------------

local function rows_of(rules, size)
    local rows = {}
    for r = 1, size do
        rows[r] = {}
        for c = 1, size do rows[r][c] = rules:get(c, r) or false end
    end
    return rows
end

local function chat_text(lines)
    local out = {}
    for _, l in ipairs(lines) do out[#out + 1] = Chat.line_text(l, OGSGame.rank_text(l.rank)) end
    return table.concat(out, "\n")
end

local function removed_set(g)
    local set = {}
    for _, p in ipairs(g.removed or {}) do set[p[1] .. "," .. p[2]] = true end
    return set
end

local function color_name(c) return c == "B" and "Black" or "White" end

function Controller:state()
    local play = self.play
    local g = play.game
    local st = { title = self.title or ("Game " .. self.game_id), busy = false,
                 comment = "", bottom = { kind = "buttons", rows = {} } }
    if not g.loaded then
        st.board = { size = 19, board = rows_of({ get = function() return nil end }, 19) }
        st.counter = ""
        st.status = (self.session:is_open() and "Loading game…") or "Connecting…"
        st.bottom.rows = { { { id = "reload", label = "Try again" } } }
        return st
    end

    local size = g.size
    local rules = g.game.rules
    local caps = rules:captures()
    local moves = g.game:position().moves
    local lastm = moves[#moves]
    st.board = { size = size, board = rows_of(rules, size) }
    if lastm then
        st.board.last = lastm.col and { col = lastm.col, row = lastm.row, color = lastm.color }
                        or { pass = true, color = lastm.color }
    end
    local now_ms = self.session.ogs:server_now()
    local function side(color)
        local p = g.players[color]
        local c = g:player_clock(color, now_ms)
        return { name = p.name or "?", rank = OGSGame.rank_text(p.rank), captures = caps[color], clock = c.text }
    end
    st.black, st.white = side("B"), side("W")
    st.to_move = (g.phase == "play") and g:to_move() or nil
    st.title = self.title or ((st.black.name or "?") .. " vs " .. (st.white.name or "?"))
    st.counter = tostring(g:move_count())

    local mine = play:my_color()
    local player = play:role() == "player"
    local opp = mine and g.players[mine == "B" and "W" or "B"].name or "your opponent"
    local lm = Last.text(st.board.last, size, g:move_count())
    local staged = play.staged

    if self.session.state ~= "open" then st.status = "Connection lost. Reconnecting…"
    elseif g.desynced then st.status = "Out of step with the server, reloading…"
    elseif g.phase == "finished" then st.status = "Finished" .. (g:result() and (": " .. g:result()) or "")
    elseif g.phase == "stone removal" then
        local dead = removed_set(g)
        local list = {}
        for key in pairs(dead) do local c, r = key:match("^(%d+),(%d+)$"); list[#list + 1] = { tonumber(c), tonumber(r) } end
        local sc = rules:score(list)
        st.board.dead = dead
        st.board.territory = {}
        for i = 1, size * size do
            local who = sc.owner and sc.owner[i]
            local c, r = (i - 1) % size + 1, math.floor((i - 1) / size) + 1
            if who and not rules:get(c, r) then st.board.territory[c .. "," .. r] = who end
        end
        st.status = player and ("Counting: tap dead stones, then Accept  ·  " .. sc.text)
                           or "Counting: stones are being removed"
    elseif player then
        if self.sending then st.status = "Sending your move…"
        elseif self.message then st.status = self.message
        elseif play:can_move() then st.status = "Your move (" .. color_name(mine) .. ")"
        else st.status = "Waiting for " .. opp end
        if lm and not staged and not self.message and not self.sending then st.status = st.status .. "  ·  last: " .. lm end
    else
        local tc = g.time_control or {}
        st.status = "Watching live" .. (tc.system and ("  ·  " .. tc.system) or "")
        if lm and g.phase == "play" then st.status = st.status .. "  ·  last: " .. lm end
    end

    local lines = play.chat:recent(3)
    st.comment = chat_text(lines)
    st.comment_bottom = true
    local unread = play.chat.unread
    local chat_button = { id = "chat", label = unread > 0 and ("Chat (" .. unread .. ")") or "Chat" }

    if player and g.phase == "play" and staged then
        -- the board fades, the chosen point stays black and ringed; the confirmation sits under the board
        if staged.col then
            st.board.board[staged.row][staged.col] = staged.color
            st.board.focus = { col = staged.col, row = staged.row, color = staged.color }
            st.board.last = nil
        end
        local what = staged.pass and "Pass" or ("Play " .. Last.name(staged.col, staged.row, size))
        st.bottom = { kind = "confirm", prompt = what .. " in this game?",
                      buttons = { { id = "cancel", label = "Cancel" }, { id = "confirm", label = "CONFIRM MOVE", style = "primary" } } }
        return st
    end

    local row
    if player and g.phase == "play" then
        row = { { id = "pass", label = "Pass", enabled = play:can_move() }, chat_button,
                { id = "undo", label = "Undo", enabled = g:move_count() > 0 },
                { id = "resign", label = "Resign" }, { id = "reload", label = "Reload" } }
    elseif player and g.phase == "stone removal" then
        row = { { id = "accept", label = "Accept", style = "primary" }, chat_button, { id = "resign", label = "Resign" },
                { id = "reload", label = "Reload" } }
    elseif player then
        row = { chat_button, { id = "reload", label = "Reload" } }
    else
        row = { chat_button, { id = "reload", label = "Reload" } }
    end
    st.bottom.rows = { row }
    return st
end

-- ---------------------------------------------------------------------------
-- Input
-- ---------------------------------------------------------------------------

function Controller:board_tap(col, row)
    local play = self.play
    local g = play.game
    if not g.loaded or play:role() ~= "player" then return end        -- spectators cannot move
    self.message = nil
    if g.phase == "play" then
        local ok, why = play:stage(col, row)
        if not ok then self.message = REASONS[why] or ("Cannot play there (" .. tostring(why) .. ")") end
    elseif g.phase == "stone removal" then
        local group = g.game.rules:group_at(col, row)
        if not group then return end
        local dead = removed_set(g)
        local is_dead = dead[group[1][1] .. "," .. group[1][2]] == true
        play.ogs:set_removed(self.game_id, group, not is_dead)
        self.message = nil
    end
end

local function say_result(self, ok, why, wait)
    if ok then return end
    if why == "too_fast" or why == "wait" then self.message = "Wait a moment before the next message."
    elseif why == "empty" then self.message = "Nothing to send."
    else self.message = "Could not send: " .. tostring(why) end
end

function Controller:say(text)
    local ok, why, wait = self.play:say(text)
    say_result(self, ok, why, wait)
    self.dirty = true
end

function Controller:chat_menu()
    if not self.session.signed_in then               -- a guest can only read
        local lines = self.play.chat:visible()
        self.play.chat:mark_read()
        self.show_text("Game chat", #lines > 0 and chat_text(lines) or "No chat yet.")
        self.dirty = true
        return
    end
    local choices = { { "read", "Read the chat" } }
    if self.play.me and self.session.signed_in then
        for _, q in ipairs(Controller.QUICK_REPLIES) do choices[#choices + 1] = q end
        choices[#choices + 1] = { "type", "Type a message…" }
    end
    choices[#choices + 1] = { "close", "Close" }
    self.choose("Chat", choices, function(id)
        if id == "read" then
            local lines = self.play.chat:visible()
            self.play.chat:mark_read()
            self.show_text("Game chat", #lines > 0 and chat_text(lines) or "No chat yet.")
        elseif id == "type" then
            self.ask_text("Say something", "", "Send", function(text)
                if text and text ~= "" then self:say(text) end
                self.on_change()
            end)
            return
        elseif id ~= "close" then
            for _, q in ipairs(Controller.QUICK_REPLIES) do if q[1] == id then self:say(q[2]) end end
        end
        self.dirty = true
        self.on_change()
    end)
end

function Controller:button(id)
    local play = self.play
    self.message = nil
    if id == "chat" then
        self:chat_menu()
    elseif id == "reload" then
        play:open(self.game_id)
        self.dirty = true
    elseif id == "cancel" then
        play:cancel_stage()
    elseif id == "confirm" then
        local ok, err = play:confirm()
        if ok then self.sending = true
        else self.message = REASONS[err] or ("Could not send the move (" .. tostring(err) .. ")") end
    elseif id == "pass" then
        local ok, why = play:stage_pass()
        if not ok then self.message = REASONS[why] or tostring(why) end
    elseif id == "resign" then
        self.choose("Resign this game?", { { "yes", "Yes, resign" }, { "no", "No, keep playing" } }, function(c)
            if c == "yes" then play:resign() end
            self.dirty = true
            self.on_change()
        end)
    elseif id == "undo" then
        self.choose("Ask " .. ((play.game.players[play:my_color() == "B" and "W" or "B"] or {}).name or "your opponent")
            .. " to let you take back your last move?", { { "yes", "Ask for an undo" }, { "no", "Never mind" } }, function(c)
            if c == "yes" then
                local ok, why = play:request_undo()
                self.message = ok and "Undo requested." or ("Could not ask: " .. tostring(why))
            end
            self.dirty = true
            self.on_change()
        end)
    elseif id == "accept" then
        local ok, why = play.ogs:accept_removed(self.game_id, play.game:removed_text())
        self.message = ok and "Accepted. Waiting for your opponent." or ("Could not accept: " .. tostring(why))
    end
end

function Controller:show_comment() self:button("chat") end

function Controller:back()
    self.closed = true
    self.play:close()
    return true
end

-- ---------------------------------------------------------------------------
-- Keeping alive (called about once a second by the screen)
-- ---------------------------------------------------------------------------

-- Questions from the opponent that need an answer (asked once each)
function Controller:_prompts()
    local play = self.play
    local req = play.undo_request
    if req and not self.asked_undo then
        self.asked_undo = true
        local name = (play.game.players[play:my_color() == "B" and "W" or "B"] or {}).name or "Your opponent"
        self.choose(name .. " asks to take back a move.", { { "yes", "Accept" }, { "no", "Decline" } }, function(c)
            if c == "yes" then play:accept_undo() end
            play.undo_request = nil
            self.asked_undo = false
            self.dirty = true
            self.on_change()
        end)
    end
end

--[[ Returns true when the screen should redraw: a move, clocks or phase change
     arrived, a reconnect happened, or new chat is due to be shown. There is no
     clock-driven redraw. ]]
function Controller:tick(now)
    if self.closed then return false end
    now = now or self.now()
    local s = self.session
    if s.state == "dropped" then
        if not self.last_reconnect or now - self.last_reconnect >= Controller.RECONNECT_SECONDS then
            self.last_reconnect = now
            s:reconnect()
            self.dirty = true
        end
    else
        s:pump()
    end
    self:_prompts()
    local chat_due = self.chat_dirty and (not self.last_chat_draw or now - self.last_chat_draw >= Controller.CHAT_REDRAW_SECONDS)
    if self.dirty or chat_due then
        if self.chat_dirty then self.last_chat_draw = now end      -- the strip is redrawn along with the board
        self.dirty, self.chat_dirty = false, false
        self.last_draw = now
        return true
    end
    return false
end

return Controller
