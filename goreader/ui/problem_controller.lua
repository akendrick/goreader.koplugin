--[[
    goreader/ui/problem_controller.lua - solving one problem of a set on a GameScreen.

    You tap the point. A right move that needs an answer gets the opponent's reply
    on the board and you carry on; a wrong move says so (Undo takes it back); the
    last right move says "Correct" and the problem is marked solved — unless you
    looked at the answer first. Hint shows one good point; Answer shows the whole
    line, numbered.

        ProblemController.new{
            problems = list from core/problems, index = 1, set = "file.sgf", title = "Starter: ...",
            progress = core/problem_progress, save_progress = function(),
        }
--]]

local Problems = require("goreader.core.problems")
local SGF      = require("goreader.core.sgf")

local Controller = {}
Controller.__index = Controller

local REASONS = {
    occupied = "That point is taken.", suicide = "Not allowed: no liberties.",
    ko = "Not allowed: ko.", superko = "Not allowed: repeats a position.",
}

function Controller.new(opts)
    local self = setmetatable({
        problems = assert(opts.problems), index = opts.index or 1, set = opts.set or "set",
        title = opts.title or "Problems", progress = assert(opts.progress),
        save_progress = opts.save_progress or function() end,
        on_change = function() end,
    }, Controller)
    self:load(self.index)
    return self
end

function Controller:problem() return self.problems[self.index] end

function Controller:load(index)
    self.index = ((index - 1) % #self.problems) + 1
    self.attempt = self:problem():start()
    self.result, self.message, self.last = nil, nil, nil
    self.hint, self.answer, self.peeked = nil, nil, false
end

local function rows_of(rules, size)
    local rows = {}
    for r = 1, size do
        rows[r] = {}
        for c = 1, size do rows[r][c] = rules:get(c, r) or false end
    end
    return rows
end

function Controller:marks()
    local p, out = self:problem(), {}
    local rules = self.attempt:board()
    for _, coord in ipairs(p.root:get_all("MA")) do
        local c = SGF.sgf_to_coord(coord, p.size)
        if c and rules:get(c.col, c.row) then out[#out + 1] = { kind = "MA", col = c.col, row = c.row } end
    end
    return out
end

function Controller:state()
    local p = self:problem()
    local rules = self.attempt:board()
    local board = { size = p.size, board = rows_of(rules, p.size), last = self.last, marks = self:marks() }
    if self.answer then
        board.variations = {}
        for i, m in ipairs(self.answer) do
            if not rules:get(m.col, m.row) then board.variations[#board.variations + 1] = { col = m.col, row = m.row, label = tostring(i) } end
        end
    elseif self.hint then
        board.variations = { { col = self.hint[1], row = self.hint[2], label = "?" } }
    end
    local color_name = p.to_play == "B" and "Black" or "White"
    local solved = self.progress:is_solved(self.set, self.index)
    local status
    if self.message then status = self.message
    elseif self.result == "correct" then status = "Correct!" .. (self.peeked and " (you looked at the answer, so it is not counted)" or "")
    elseif self.result == "wrong" then status = "That does not work. Undo it and try again, or look at the answer."
    elseif self.answer then
        local names = {}
        for i, m in ipairs(self.answer) do names[#names + 1] = i .. " " .. (m.color == "B" and "Black" or "White") end
        status = "Answer: " .. table.concat(names, ", ")
    else
        status = color_name .. " to play"
        local t = p.text or ""
        if t ~= "" then status = t end
    end
    local row
    if self.result == "correct" then
        row = { { id = "prev", label = "‹ Prev" }, { id = "again", label = "Again" }, { id = "next", label = "Next ›", style = "primary" } }
    else
        row = {
            { id = "prev", label = "‹ Prev" },
            { id = "hint", label = "Hint", enabled = self.result == nil },
            { id = "undo", label = "Undo", enabled = #self.attempt.history > 0 },
            { id = "answer", label = "Answer" },
            { id = "next", label = "Next ›" },
        }
    end
    return {
        title = (p.title ~= "" and p.title or self.title) .. (solved and "  ✓" or ""),
        counter = self.index .. "/" .. #self.problems,
        black = { name = "Black" }, white = { name = "White" },
        to_move = p.to_play, turn_fill = false,
        board = board, status = status, comment = "",
        bottom = { kind = "buttons", rows = { row } },
        full_board = true, compact = true, no_confirm = true,
    }
end

function Controller:board_tap(col, row)
    if self.result == "correct" then return end
    if self.result == "wrong" then self.message = "Undo that move first."; return end
    self.message, self.hint, self.answer = nil, nil, nil
    local a = self.attempt
    local r = a:play(col, row)
    if r.status == "illegal" then self.message = REASONS[r.reason] or "Not allowed."; return end
    if r.status == "error" then self.message = "This problem has a mistake in it: " .. tostring(r.reason); return end
    self.last = { col = col, row = row, color = self:problem().to_play }
    if r.reply and r.reply.col then self.last = { col = r.reply.col, row = r.reply.row, color = r.reply.color } end
    self.result = (r.status == "correct" or r.status == "wrong") and r.status or nil
    if r.status == "correct" then
        if not self.peeked then
            self.progress:mark_solved(self.set, self.index)
            self.progress:add_try(self.set, self.index)
            self.save_progress()
        end
    elseif r.status == "wrong" then
        self.progress:add_try(self.set, self.index)
        self.save_progress()
    end
end

function Controller:button(id)
    local a = self.attempt
    self.message = nil
    if id == "hint" then
        self.answer = nil
        self.hint = a:hint()
        if not self.hint then self.message = "No hint here." end
    elseif id == "undo" then
        a:undo(); self.result, self.last, self.hint, self.answer = nil, nil, nil, nil
    elseif id == "answer" then
        self.peeked = true
        self.hint = nil
        local line = a:solution_line()
        self.answer = line
        if #line == 0 then self.message = "No answer is stored for this problem." ; self.answer = nil end
    elseif id == "again" then
        a:reset(); self.result, self.last, self.hint, self.answer, self.peeked = nil, nil, nil, nil, false
    elseif id == "next" then
        self:load(self.index + 1)
    elseif id == "prev" then
        self:load(self.index - 1)
    end
end

function Controller:back() return true end

return Controller
