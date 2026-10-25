--[[
    goreader/ui/vs_controller.lua - a game against the computer (GNU Go).

    Drives a GameScreen from core/session.lua. The player taps a point to play
    it (Undo takes it back); the computer answers after a short "thinking" status
    that is drawn before the engine blocks the device. The game is saved after
    every move, so leaving or a flat battery loses nothing.

        VsController.new{
            session = Session, game = Game, human = "B"|"W", label = "GNU Go (level 3)",
            save = function(name, sgf, path) -> true, path | nil, err,
            delete = function(path), choose = function(title, choices, cb), close = function(),
        }
--]]

local Last = require("goreader.ui.lastmove")

local Controller = {}
Controller.__index = Controller

local REASONS = {
    occupied = "That point is taken.", suicide = "Not allowed: no liberties.",
    ko = "Not allowed: ko.", superko = "Not allowed: repeats a position.",
    not_your_turn = "Wait for the computer.",
}

function Controller.new(opts)
    local self = setmetatable({
        session = assert(opts.session), game = assert(opts.game), human = opts.human or "B",
        label = opts.label or "Computer", save = opts.save, delete = opts.delete,
        choose = opts.choose or function() end, close = opts.close or function() end,
        path = nil, message = nil, thinking = false, error = nil, deleted = false,
        on_change = function() end,
    }, Controller)
    self.session.on_event = function(name, data) self:_event(name, data or {}) end
    return self
end

function Controller:_event(name, data)
    if name == "thinking" then self.thinking = true; self.error = nil
    elseif name == "engine_move" or name == "engine_pass" then self.thinking = false; self.error = nil; self:autosave()
    elseif name == "error" then self.thinking = false; self.error = data.message
    elseif name == "game_over" then self.thinking = false; self:autosave()
    elseif name == "scoring" then self.thinking = false; self:autosave() end
    self.on_change()
end

function Controller:start() self.session:start() end

function Controller:autosave()
    if not self.save or self.deleted or self.game:move_count() == 0 then return end
    local ok, path = self.save(self:suggested_name(), self.game:to_sgf(), self.path)
    if ok then self.path = path; self.save_error = nil else self.save_error = tostring(path) end
end

function Controller:suggested_name()
    return os.date("%Y-%m-%d") .. " " .. (self.human == "B" and "You vs " .. self.label or self.label .. " vs You")
end

local function rows_of(rules, size)
    local rows = {}
    for r = 1, size do
        rows[r] = {}
        for c = 1, size do rows[r][c] = rules:get(c, r) or false end
    end
    return rows
end

function Controller:state()
    local s, g = self.session, self.game
    local rules = g.rules
    local size = g.size or rules.size
    local caps = rules:captures()
    local moves = g:position().moves
    local lastm = moves[#moves]
    local board = { size = size, board = rows_of(rules, size) }
    if lastm then
        board.last = lastm.col and { col = lastm.col, row = lastm.row, color = lastm.color } or { pass = true, color = lastm.color }
    end
    local human_name, engine_name = "You", self.label
    local black = { name = self.human == "B" and human_name or engine_name, captures = caps.B }
    local white = { name = self.human == "W" and human_name or engine_name, captures = caps.W }
    local lm = Last.text(board.last, size, g:move_count())

    local status, row
    if s.state == "scoring" then
        local sc = s:preview_score()
        status = "Count: " .. sc.text .. "  (tap dead groups)"
        board.dead = s.dead
        board.territory = {}
        for i = 1, size * size do
            local who = sc.owner and sc.owner[i]
            local c, r = (i - 1) % size + 1, math.floor((i - 1) / size) + 1
            if who and not rules:get(c, r) then board.territory[c .. "," .. r] = who end
        end
        row = { { id = "resume", label = "Keep playing" }, { id = "count_done", label = "Done", style = "primary" } }
    elseif s.state == "over" then
        status = "Finished: " .. tostring(g:result() or "")
        row = { { id = "exit", label = "Exit", style = "primary" }, { id = "delete", label = "Delete" } }
    elseif self.error then
        status = "The computer had a problem: " .. self.error
        row = { { id = "retry", label = "Try again", style = "primary" }, { id = "resign", label = "Resign" } }
    elseif s.state == "engine" or self.thinking then
        status = self.label .. " is thinking" .. (size == 19 and " (a 19x19 move can take up to 20 seconds)" or "…")
        row = { { id = "undo", label = "Undo", enabled = false } }
    else
        status = (self.message) or ("Your move (" .. (self.human == "B" and "Black" or "White") .. ")")
        if lm and not self.message then status = status .. "  ·  last: " .. lm end
        local has_move = false
        for _, m in ipairs(moves) do if m.color == self.human then has_move = true end end
        row = { { id = "undo", label = "Undo", enabled = has_move }, { id = "pass", label = "Pass" },
                { id = "resign", label = "Resign" }, { id = "delete", label = "Delete" } }
    end
    if self.save_error then status = "Could not save: " .. self.save_error end
    return {
        title = self.label, counter = tostring(g:move_count()),
        black = black, white = white,
        to_move = (s.state == "human" or s.state == "engine") and g:to_move() or nil, turn_fill = true,
        board = board, status = status, comment = "",
        bottom = { kind = "buttons", rows = { row } },
        full_board = true, compact = true, no_confirm = true,
    }
end

function Controller:board_tap(col, row)
    local s = self.session
    self.message = nil
    if s.state == "scoring" then s:toggle_dead(col, row); return end
    if s.state ~= "human" then
        if s.state == "engine" then self.message = REASONS.not_your_turn end
        return
    end
    local ok, why = s:human_play(col, row)
    if not ok then self.message = REASONS[why] or ("Cannot play there (" .. tostring(why) .. ")") return end
    self:autosave()
end

function Controller:button(id)
    local s = self.session
    self.message = nil
    if id == "undo" then
        s:undo(); self:autosave()
    elseif id == "pass" then
        s:human_pass(); self:autosave()
    elseif id == "resign" then
        self.choose("Resign this game?", { { "yes", "Yes, resign" }, { "no", "No, keep playing" } }, function(c)
            if c == "yes" then
                self.error = nil
                s:human_resign(); self:autosave()
            end
            self.on_change()
        end)
    elseif id == "exit" then
        self:autosave()
        self.close()
    elseif id == "retry" then
        self.error = nil
        s:retry_engine()
    elseif id == "resume" then
        s:continue_playing(); self:autosave()
    elseif id == "count_done" then
        s:confirm_score(); self:autosave()
    elseif id == "delete" then
        self.choose("Delete this game?\nThe saved record is removed too.", { { "yes", "Delete the game" }, { "no", "Keep it" } }, function(c)
            if c == "yes" then
                if self.path and self.delete then self.delete(self.path) end
                self.path, self.deleted = nil, true
                self.session.generation = self.session.generation + 1
                self.close()
            else
                self.on_change()
            end
        end)
    end
end

function Controller:back()
    self.session.generation = self.session.generation + 1       -- a move still being thought about is dropped
    if not self.deleted then self:autosave() end
    return true
end

return Controller
