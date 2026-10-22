--[[
    goreader/ui/record_controller.lua - RECORD GAME: one person writes down a
    game that is being played on a real board. Everything is on the bottom row;
    the side to move is shown as a solid block in the player bar. Every move is
    saved at once, so a dead battery loses nothing.

        RecordController.new{
            live = LiveGame,
            edit_info = function(info, cb),         -- ask for names and details; cb(fields) | cb(nil)
            choose = function(title, choices, cb),  -- choices = { {id, label}, ... }
            save = function(name, sgf, path) -> true, path | nil, err,
        }
--]]

local Last = require("goreader.ui.lastmove")

local Controller = {}
Controller.__index = Controller

local REASONS = {
    occupied = "That point is taken.", suicide = "Not allowed: no liberties.",
    ko = "Not allowed: ko.", superko = "Not allowed: repeats a position.",
}

function Controller.new(opts)
    return setmetatable({
        live = assert(opts.live), edit_info = opts.edit_info or function() end,
        choose = opts.choose or function() end, save = opts.save,
        path = nil, message = nil, saved_moves = -1, on_change = function() end,
    }, Controller)
end

-- Save now; the file keeps its name for the rest of the game
function Controller:autosave()
    if not self.save then return end
    local ok, path = self.save(self.live:suggested_name(), self.live:to_sgf(), self.path)
    if ok then self.path = path; self.saved_moves = self.live:move_count(); self.save_error = nil
    else self.save_error = tostring(path) end
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
    local lg = self.live
    local rules = lg:board()
    local caps = rules:captures()
    local moves = lg.game:position().moves
    local lastm = moves[#moves]
    local board = { size = lg.size, board = rows_of(rules, lg.size) }
    if lastm and lg.state == "playing" then
        board.last = lastm.col and { col = lastm.col, row = lastm.row, color = lastm.color } or { pass = true, color = lastm.color }
    end

    local status
    if self.message then status = self.message
    elseif self.save_error then status = "Could not save: " .. self.save_error
    elseif lg.state == "scoring" then
        local s = lg:score()
        status = "Count: " .. s.text .. "  (tap dead groups)"
        board.dead = lg.dead
        board.territory = {}
        for i = 1, lg.size * lg.size do
            local who = s.owner[i]
            local c, r = (i - 1) % lg.size + 1, math.floor((i - 1) / lg.size) + 1
            if who and not rules:get(c, r) then board.territory[c .. "," .. r] = who end
        end
    elseif lg.state == "over" then status = "Finished: " .. tostring(lg.result)
    else
        local lm = Last.text(board.last, lg.size, lg:move_count())
        status = (lg:to_move() == "B" and "Black" or "White") .. " to play" .. (lm and ("  ·  last: " .. lm) or "")
    end

    local row
    if lg.state == "scoring" then
        row = { { id = "resume", label = "Keep playing" }, { id = "count_done", label = "Done", style = "primary" }, { id = "info", label = "Info" } }
    elseif lg.state == "over" then
        row = { { id = "info", label = "Info" }, { id = "export", label = "Saved" } }
    else
        row = {
            { id = "undo", label = "Undo", enabled = lg:move_count() > 0 }, { id = "pass", label = "Pass" },
            { id = "resign", label = "Resign" }, { id = "info", label = "Info" }, { id = "finish", label = "Finish" },
        }
    end
    return {
        title = lg.info.name or "Recording", counter = tostring(lg:move_count()),
        black = { name = lg.info.black, rank = lg.info.black_rank, captures = caps.B },
        white = { name = lg.info.white, rank = lg.info.white_rank, captures = caps.W },
        to_move = (lg.state == "playing") and lg:to_move() or nil, turn_fill = true,
        board = board, status = status, comment = "",
        bottom = { kind = "buttons", rows = { row } },
    }
end

function Controller:board_tap(col, row)
    local lg = self.live
    self.message = nil
    if lg.state == "scoring" then lg:toggle_dead(col, row); return end
    if lg.state ~= "playing" then return end
    local ok, why = lg:play(col, row)
    if not ok then self.message = REASONS[why] or ("Cannot play there (" .. tostring(why) .. ")"); return end
    self:autosave()
end

function Controller:button(id)
    local lg = self.live
    self.message = nil
    if id == "undo" then lg:undo(); self:autosave()
    elseif id == "pass" then lg:pass(); self:autosave()
    elseif id == "resume" then lg:resume(); self:autosave()
    elseif id == "count_done" then lg:confirm_score(); self:autosave()
    elseif id == "resign" then
        self.choose("Who resigned?", { { "W", "White resigned" }, { "B", "Black resigned" }, { "no", "Cancel" } }, function(c)
            if c == "W" or c == "B" then lg:resign(c); self:autosave() end
            self.on_change()
        end)
    elseif id == "finish" then
        self.choose("Finish the game", { { "count", "Count the score" }, { "W", "White resigned" }, { "B", "Black resigned" },
            { "draw", "Draw / no result" }, { "no", "Keep recording" } }, function(c)
            if c == "count" then lg.state = "scoring"; lg.dead = {}
            elseif c == "W" or c == "B" then lg:resign(c)
            elseif c == "draw" then lg:set_result("0") end
            self:autosave(); self.on_change()
        end)
    elseif id == "info" then
        self.edit_info(lg.info, function(fields)
            if fields then lg:set_info(fields); self:autosave() end
            self.on_change()
        end)
    end
end

-- Leaving: the game is already saved; save once more in case of a late change
function Controller:back()
    if self.live:move_count() > 0 and self.saved_moves ~= self.live:move_count() then self:autosave() end
    return true
end

return Controller
