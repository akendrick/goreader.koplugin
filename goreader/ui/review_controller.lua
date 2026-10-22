--[[
    goreader/ui/review_controller.lua - drives a GameScreen to review an SGF
    game: step through moves and variations, see comments, engine annotations
    (winrate, suggested moves, mistakes) and add your own notes.

        local c = ReviewController.new{
            model = ReviewModel, title = "...",
            edit_note = function(initial, cb) end,   -- opens a text box; cb(text)
            save = function(sgf_text) -> true | nil, err,
        }
--]]

local Last = require("goreader.ui.lastmove")

local Controller = {}
Controller.__index = Controller

local KIND_TEXT = { inaccuracy = "Inaccuracy", mistake = "Mistake", blunder = "Blunder" }

function Controller.new(opts)
    return setmetatable({
        model = assert(opts.model), title = opts.title,
        edit_note = opts.edit_note or function() end, save = opts.save,
        show_numbers = false, number_span = 10, message = nil,
        on_change = function() end,
    }, Controller)
end

-- Move numbers for the last few moves on the line to this position
function Controller:_numbers(size)
    local out = {}
    local g = self.model.game
    local path, n = {}, g.current
    while n do table.insert(path, 1, n); n = n.parent end
    local SGF = require("goreader.core.sgf")
    local count = 0
    for _, node in ipairs(path) do
        local color, coord = node:move()
        if color then
            count = count + 1
            local c = coord and SGF.sgf_to_coord(coord, size)
            if c then out[c.col .. "," .. c.row] = count end
        end
    end
    -- keep only the newest `number_span`
    local keep = {}
    for key, nn in pairs(out) do if nn > count - self.number_span then keep[key] = nn end end
    return keep
end

function Controller:state()
    local m = self.model
    local s = m:state()
    local rows = {}
    for r = 1, s.size do
        rows[r] = {}
        for c = 1, s.size do rows[r][c] = s.board[r][c] or false end
    end
    local board = { size = s.size, board = rows, last = s.last, marks = s.marks,
                    candidates = s.candidates, variations = s.variations }
    if self.show_numbers then board.numbers = self:_numbers(s.size) end

    -- status line: what the engine thought, and how the move just played rated
    local status = s.analysis and s.analysis.text or ""
    local pr = s.played_rating
    if pr and pr.kind then
        local loss = string.format("%d%%", math.floor(pr.loss_wr * 100 + 0.5))
        status = (KIND_TEXT[pr.kind] or pr.kind) .. " (-" .. loss .. ")" .. (status ~= "" and ("  ·  " .. status) or "")
    end
    if self.message then status = self.message
    elseif status == "" then
        status = s.main_line and "" or ("Variation " .. s.sibling .. "/" .. s.siblings)
        if status == "" and s.result ~= "" then status = "Result: " .. s.result end
    end

    local text = s.comment
    if s.analysis_note then text = (text ~= "" and (text .. "\n\n") or "") .. s.analysis_note end
    if s.node_name ~= "" then text = s.node_name .. (text ~= "" and ("\n" .. text) or "") end

    -- one small row: navigation, then the tools
    local has_analysis = m:has_analysis()
    local row = {
        { id = "first", label = "|<", enabled = s.can_prev }, { id = "prev", label = "<", enabled = s.can_prev },
        { id = "next", label = ">", enabled = s.can_next }, { id = "last", label = ">|", enabled = s.can_next },
        { id = "mistake", label = "Mistake", enabled = has_analysis },
        { id = "cands", label = "Hints", enabled = has_analysis,
          style = (has_analysis and m.show_candidates) and "toggle_on" or nil },
        s.main_line and { id = "numbers", label = "Nums", style = self.show_numbers and "toggle_on" or nil }
                     or { id = "mainline", label = "Main" },
        { id = "note", label = "Note" },
    }
    if status == "" or status == nil then
        local lm = Last.text(s.last, s.size, s.move_number)
        status = lm and ("Last move: " .. lm) or ""
    end

    return {
        title = self.title or (s.black.name .. " vs " .. s.white.name),
        counter = s.move_number .. " / " .. s.total,
        black = { name = s.black.name, rank = s.black.rank, captures = s.captures.B },
        white = { name = s.white.name, rank = s.white.rank, captures = s.captures.W },
        to_move = s.to_move, board = board, show_numbers = self.show_numbers,
        status = status, comment = text,
        bottom = { kind = "buttons", rows = { row } },
    }
end

-- ---------------------------------------------------------------------------
-- Input
-- ---------------------------------------------------------------------------

function Controller:board_tap(col, row)
    self.message = nil
    local s = self.model:state()
    for _, v in ipairs(s.variations) do                      -- tap a lettered point to follow that variation
        if v.col == col and v.row == row then self.model:enter_variation(v.index); return end
    end
end

function Controller:button(id)
    local m = self.model
    self.message = nil
    if id == "first" then m:first()
    elseif id == "prev" then m:prev()
    elseif id == "next" then m:next()
    elseif id == "last" then m:last()
    elseif id == "mistake" then
        if not m:next_mistake() then
            if not m:prev_mistake() or true then self.message = "No more mistakes after this point." end
        end
    elseif id == "cands" then m.show_candidates = not m.show_candidates
    elseif id == "numbers" then self.show_numbers = not self.show_numbers
    elseif id == "mainline" then m:to_main_line()
    elseif id == "note" then
        self.edit_note(m.game.current:get("C", ""), function(text)
            if text ~= nil then m:set_comment(text); self.on_change() end
        end)
    end
end

function Controller:show_comment() self:button("note") end

-- Back: save notes first if the reader changed anything
function Controller:back()
    if self.model.dirty and self.save then
        local ok, err = self.save(self.model:to_sgf())
        if ok then self.model.dirty = false
        else
            self.message = "Could not save: " .. tostring(err)
            return false
        end
    end
    return true
end

return Controller
