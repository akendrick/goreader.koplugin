--[[
    goreader/core/dgsgame.lua - one Dragon Go Server game: review it, and make
    your move behind a confirmation.

    Pure logic (no drawing, no network). The screen asks for state(); the
    network layer is a DGS client (services/dgs.lua) passed in.

        local g = DGSGame.new{ sgf = text, my_color = "B", gid = 123, move_id = 45 }
        g.model:next()                      -- review: navigate like any SGF
        g:stage(16, 3)                      -- pick a point (nothing is sent)
        g:confirm_payload()                 -- what CONFIRM MOVE will send
        g:submitted(new_sgf_text)           -- after the server accepted it

    A move can only be staged when it is your turn AND you are looking at the
    latest position of the main line.
--]]

local SGF         = require("goreader.core.sgf")
local Game        = require("goreader.core.game")
local ReviewModel = require("goreader.ui.review_model")
local GTP         = require("goreader.engine.gtp")

local DGSGame = {}
DGSGame.__index = DGSGame

--[[ opts: sgf (text), my_color ("B"|"W"|nil when only watching), gid, move_id,
            opponent (name), on_pass_ok ]]
function DGSGame.new(opts)
    local sgf = SGF.parse(opts.sgf)
    if not sgf then return nil, "could not read the game" end
    local replay, err = Game.from_sgf(opts.sgf)
    if not replay then return nil, err end
    local self = setmetatable({
        gid = opts.gid, move_id = opts.move_id, my_color = opts.my_color,
        opponent = opts.opponent, size = sgf.board_size or 19,
        model = ReviewModel.new{ game = sgf }, replay = replay,
        staged_move = nil, submitting = false, message = nil,
    }, DGSGame)
    sgf:go_to_end()                                  -- DGS games open at the latest move
    return self
end

-- ---------------------------------------------------------------------------
-- Whose turn, where we are
-- ---------------------------------------------------------------------------

function DGSGame:next_color() return self.replay:to_move() end

function DGSGame:finished()
    return self.model.game:result() ~= "" or self.replay:is_over()
end

-- Looking at the newest position of the main line?
function DGSGame:at_latest()
    local m = self.model
    return m:on_main_line() and m.game.current.children[1] == nil
end

function DGSGame:my_turn()
    return self.my_color ~= nil and not self:finished() and self:next_color() == self.my_color
end

function DGSGame:can_move()
    return self:my_turn() and self:at_latest() and not self.submitting
end

-- ---------------------------------------------------------------------------
-- Staging a move
-- ---------------------------------------------------------------------------

--[[ Pick a point. Returns true, or nil + reason:
     "not_your_turn", "not_latest", "submitting", or the rules' reason
     ("occupied", "suicide", "ko", "superko"). ]]
function DGSGame:stage(col, row)
    if self.submitting then return nil, "submitting" end
    if not self:my_turn() then return nil, "not_your_turn" end
    if not self:at_latest() then return nil, "not_latest" end
    local probe = self.replay.rules:clone()
    local ok, why = probe:play(self.my_color, col, row)
    if not ok then return nil, why end
    self.staged_move = { col = col, row = row, color = self.my_color }
    return true
end

function DGSGame:stage_pass()
    if not self:can_move() then return nil, self:my_turn() and "not_latest" or "not_your_turn" end
    self.staged_move = { pass = true, color = self.my_color }
    return true
end

function DGSGame:cancel() self.staged_move = nil end
function DGSGame:staged() return self.staged_move end

-- "Black R17" / "White pass" for the confirmation prompt
function DGSGame:describe_staged()
    local m = self.staged_move
    if not m then return nil end
    local who = m.color == "B" and "Black" or "White"
    if m.pass then return who .. " passes" end
    return who .. " " .. GTP.vertex(m.col, m.row, self.size)
end

-- What CONFIRM MOVE sends (for DGS:submit_move)
function DGSGame:confirm_payload()
    local m = self.staged_move
    if not m then return nil end
    return { gid = self.gid, move_id = self.move_id, col = (not m.pass) and m.col or nil,
             row = (not m.pass) and m.row or nil, size = self.size }
end

function DGSGame:begin_submit()
    if not self.staged_move then return nil, "nothing_staged" end
    if self.submitting then return nil, "submitting" end
    self.submitting = true
    return true
end

-- The server refused or the network failed: keep the staged move so the user can retry
function DGSGame:submit_failed(reason)
    self.submitting = false
    self.message = "Move not sent: " .. tostring(reason)
end

--[[ The server accepted the move; `new_sgf` is the game as it now stands
     (or nil to just record the move locally). ]]
function DGSGame:submitted(new_sgf)
    local m = self.staged_move
    self.submitting, self.staged_move = false, nil
    if new_sgf then
        local fresh, err = DGSGame.new{ sgf = new_sgf, my_color = self.my_color, gid = self.gid,
                                        move_id = nil, opponent = self.opponent }
        if fresh then
            self.model, self.replay = fresh.model, fresh.replay
            self.message = "Move sent. Waiting for " .. (self.opponent or "your opponent") .. "."
            self.sent = true
            return true
        end
    end
    -- fall back: play it on our copy
    if m then
        if m.pass then self.replay:pass() else self.replay:play(m.col, m.row) end
        self.model.game:go_to_end()
        if m.pass then self.model.game:add_pass(m.color) else self.model.game:add_move(m.color, m.col, m.row) end
    end
    self.message = "Move sent."
    self.sent = true
    return true
end

-- ---------------------------------------------------------------------------
-- What to draw
-- ---------------------------------------------------------------------------

--[[ A BoardView state for the current position, with the staged move shown
     as the focus stone while confirming. ]]
function DGSGame:board_state()
    local s = self.model:state()
    local board = {}
    for r = 1, s.size do
        board[r] = {}
        for c = 1, s.size do board[r][c] = s.board[r][c] end
    end
    local st = {
        size = s.size, board = board, last = s.last, marks = s.marks,
        variations = s.variations, candidates = s.candidates,
    }
    local m = self.staged_move
    if m and not m.pass then
        board[m.row][m.col] = m.color
        st.focus = { col = m.col, row = m.row, color = m.color }
        st.last, st.marks, st.variations, st.candidates = nil, nil, nil, nil
    end
    return st, s
end

function DGSGame:status_line()
    if self.message then return self.message end
    if self:finished() then
        local r = self.model.game:result()
        return r ~= "" and ("Finished: " .. r) or "Finished"
    end
    if not self.my_color then return "Watching" end
    if self:my_turn() then
        if not self:at_latest() then return "Your move: go to the last move to play" end
        return "Your move (" .. (self.my_color == "B" and "Black" or "White") .. ")"
    end
    return "Waiting for " .. (self.opponent or "your opponent")
end

return DGSGame
