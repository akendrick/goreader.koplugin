--[[
    goreader/ui/faceoff_controller.lua - PLAY GAME: two people play a game on
    the reader laid flat between them. Black sits at the top of the screen (that
    side has the thick black line, its controls read upside-down to them),
    White at the bottom. Pass and Resign appear on both sides; either player
    taps the board for their own move.

        FaceoffController.new{ live = LiveGame, save = fn(name, sgf, path) -> true, path | nil, err,
                               choose = fn(title, choices, cb), leave = fn() }
--]]

local Last = require("goreader.ui.lastmove")

local Controller = {}
Controller.__index = Controller

local REASONS = {
    occupied = "Taken", suicide = "No liberties", ko = "Ko", superko = "Repeats a position",
}

function Controller.new(opts)
    return setmetatable({
        live = assert(opts.live), save = opts.save, choose = opts.choose or function() end,
        leave = opts.leave or function() end, delete = opts.delete,
        resigning = nil, message = nil, path = nil, on_change = function() end,
    }, Controller)
end

function Controller:autosave()
    if not self.save or self.live:move_count() == 0 then return end
    local ok, path = self.save(self.live:suggested_name(), self.live:to_sgf(), self.path)
    if ok then self.path = path; self.save_error = nil else self.save_error = tostring(path) end
end

local function rows_of(rules, size)
    local rows = {}
    for r = 1, size do
        rows[r] = {}
        for c = 1, size do rows[r][c] = rules:get(c, r) or false end
    end
    return rows
end

local function name_of(side) return side == "B" and "Black" or "White" end

--[[ What one side's strip shows: { text, buttons = { {id,label,style,enabled} }, active } ]]
function Controller:strip(side)
    local lg = self.live
    if lg.state == "scoring" then
        local s = lg:score()
        return { text = "Count: " .. s.text .. "   (tap dead groups)", active = false,
                 buttons = { { id = "resume", label = "Keep playing" }, { id = "done", label = "Done", style = "primary" } } }
    elseif lg.state == "over" then
        return { text = "Finished: " .. tostring(lg.result), active = false,
                 buttons = { { id = "exit", label = "Exit", style = "primary" } } }
    end
    if self.resigning == side then
        return { text = "Resign the game?", active = true,
                 buttons = { { id = "yes", label = "Yes, resign", style = "danger" }, { id = "no", label = "No" } } }
    end
    local mine = lg:to_move() == side
    local text
    if self.message and mine then text = self.message
    elseif mine then text = "Your move"
    else text = name_of(lg:to_move()) .. " is thinking" end
    local buttons = {
        { id = "pass", label = "Pass", enabled = mine },
        { id = "undo", label = "Undo", enabled = lg:move_count() > 0 },
        { id = "resign", label = "Resign" },
    }
    if side == "W" then buttons[#buttons + 1] = { id = "menu", label = "Menu" } end   -- one shared menu, on White's side
    return { text = text, active = mine, buttons = buttons }
end

function Controller:state()
    local lg = self.live
    local rules = lg:board()
    local caps = rules:captures()
    local moves = lg.game:position().moves
    local lastm = moves[#moves]
    local board = { size = lg.size, board = rows_of(rules, lg.size) }
    if lastm and lg.state == "playing" then
        board.last = lastm.col and { col = lastm.col, row = lastm.row, color = lastm.color } or { pass = true, color = lastm.color }
    end
    if lg.state == "scoring" then
        local s = lg:score()
        board.dead = lg.dead
        board.territory = {}
        for i = 1, lg.size * lg.size do
            local who = s.owner[i]
            local c, r = (i - 1) % lg.size + 1, math.floor((i - 1) / lg.size) + 1
            if who and not rules:get(c, r) then board.territory[c .. "," .. r] = who end
        end
    end
    return {
        board = board, to_move = (lg.state == "playing") and lg:to_move() or nil, phase = lg.state,
        captures = caps, move_count = lg:move_count(),
        strips = { B = self:strip("B"), W = self:strip("W") },
        last_text = Last.text(board.last, lg.size, lg:move_count()),
        save_error = self.save_error,
    }
end

function Controller:board_tap(col, row)
    local lg = self.live
    self.message, self.resigning = nil, nil
    if lg.state == "scoring" then lg:toggle_dead(col, row); return end
    if lg.state ~= "playing" then return end
    local ok, why = lg:play(col, row)
    if not ok then self.message = REASONS[why] or "Not allowed"; return end
    self:autosave()
end

function Controller:button(side, id)
    local lg = self.live
    self.message = nil
    if id == "pass" then
        if lg:to_move() == side then lg:pass(); self.resigning = nil; self:autosave() end
    elseif id == "undo" then lg:undo(); self.resigning = nil; self:autosave()
    elseif id == "resign" then self.resigning = side
    elseif id == "no" then self.resigning = nil
    elseif id == "yes" then lg:resign(side); self.resigning = nil; self:autosave()
    elseif id == "resume" then lg:resume(); self:autosave()
    elseif id == "done" then lg:confirm_score(); self:autosave()
    elseif id == "exit" then self.leave()
    elseif id == "menu" then
        self.choose("Game menu", { { "undo", "Undo the last move" }, { "save", "Save now" },
            { "delete", "Delete this game" }, { "exit", "Leave the game" }, { "no", "Back to the game" } }, function(c)
            if c == "undo" then lg:undo(); self:autosave()
            elseif c == "save" then self:autosave()
            elseif c == "delete" then self:ask_delete(); return
            elseif c == "exit" then self:back_ask() end
            self.on_change()
        end)
    end
end

-- Delete this game and its saved file, after a confirmation
function Controller:ask_delete()
    self.choose("Delete this game?\nThe saved record is removed too.", { { "yes", "Delete the game" }, { "no", "Keep it" } }, function(c)
        if c == "yes" then
            if self.path and self.delete then self.delete(self.path) end
            self.path = nil
            self.save = nil
            self.leave()
        else
            self.on_change()
        end
    end)
end

-- Leaving the game: it is already saved after every move
function Controller:back_ask()
    if self.live.state == "over" or self.live:move_count() == 0 then self.leave(); return end
    self.choose("Leave the game?\nIt is saved after every move.", { { "leave", "Leave" }, { "stay", "Keep playing" } }, function(c)
        if c == "leave" then self:autosave(); self.leave() end
        self.on_change()
    end)
end

function Controller:back()
    self:back_ask()
    return false
end

return Controller
