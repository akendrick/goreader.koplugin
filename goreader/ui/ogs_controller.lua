--[[
    goreader/ui/ogs_controller.lua - drives a GameScreen for one OGS game you
    are watching (playing comes next). It keeps the connection alive from
    tick(), turns the game model into what the screen draws, and shows the
    latest chat lines under the board.

        local c = OGSController.new{ session = Session, game_id = 123,
                                     show_text = function(title, text) end,
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
        now = opts.now or os.time, dirty = true, chat_dirty = false, last_draw = nil, last_chat_draw = nil, last_reconnect = nil,
        on_change = function() end, closed = false,
    }, Controller)
    self.play = Play.new{
        ogs = self.session.ogs, me = self.session.me and self.session.me.id,
        on_event = function(name) self:_event(name) end,
    }
    return self
end

function Controller:_event(name)
    if name == "loaded" or name == "move" or name == "phase" or name == "clock"
       or name == "error" or name == "resync" or name == "removed_stones" then
        self.dirty = true                                  -- a move (and its clocks) changes the board now
    elseif name == "chat" then
        self.chat_dirty = true                             -- the chat strip can wait a little
    end
    if name == "error" then self.error_seen = true end
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

    if self.session.state ~= "open" then st.status = "Connection lost. Reconnecting…"
    elseif g.phase == "finished" then st.status = "Finished" .. (g:result() and (": " .. g:result()) or "")
    elseif g.phase == "stone removal" then st.status = "Counting: stones are being removed"
    elseif g.desynced then st.status = "Out of step with the server, reloading…"
    else
        local tc = g.time_control or {}
        st.status = "Watching live" .. (tc.system and ("  ·  " .. tc.system) or "")
    end

    local lm = Last.text(st.board.last, size, g:move_count())
    if lm and g.phase == "play" then st.status = st.status .. "  ·  last: " .. lm end
    local lines = play.chat:recent(3)
    st.comment = chat_text(lines)
    local unread = play.chat.unread
    st.bottom.rows = { {
        { id = "chat", label = unread > 0 and ("Chat (" .. unread .. ")") or "Chat" },
        { id = "reload", label = "Reload" },
    } }
    return st
end

-- ---------------------------------------------------------------------------
-- Input
-- ---------------------------------------------------------------------------

function Controller:board_tap() end                          -- spectators cannot move

function Controller:button(id)
    if id == "chat" then
        local lines = self.play.chat:visible()
        self.play.chat:mark_read()
        self.show_text("Game chat", #lines > 0 and chat_text(lines) or "No chat yet.")
        self.dirty = true
    elseif id == "reload" then
        self.play:open(self.game_id)
        self.dirty = true
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
