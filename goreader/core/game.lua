--[[
    goreader/core/game.lua - a game in progress.

    Keeps the rules engine and the SGF record in step, so every legal move is
    both enforced and recorded, and the result can be saved as an SGF file.
    No KOReader dependencies.

    Coordinates and colours follow rules.lua / sgf.lua:
    col 1..N left to right, row 1..N top to bottom, "B" / "W".
--]]

local Rules = require("goreader.core.rules")
local SGF   = require("goreader.core.sgf")

local Game = {}
Game.__index = Game

local function other(color) return color == "B" and "W" or "B" end

local function scoring_for(rules_name)
    local r = (rules_name or ""):lower()
    if r:find("japan") or r:find("korea") then return "territory" end
    return "area"
end

--[[ opts:
       size      9 | 13 | 19 (any 2..25)        default 19
       komi      number   default 7.5, or 0.5 with a handicap
       handicap  0 or 2..9 (fixed placement; White moves first)
       black, white, black_rank, white_rank   player names / ranks
       rules     "Chinese" (default) | "Japanese"
       date      string, default today
       name      game name (GN)
--]]
function Game.new(opts)
    opts = opts or {}
    local size = opts.size or 19
    local handicap = opts.handicap or 0
    local komi = opts.komi
    if komi == nil then komi = (handicap >= 2) and 0.5 or 7.5 end
    local rules_name = opts.rules or "Chinese"

    local rules = Rules.new(size, { komi = komi, scoring = scoring_for(rules_name) })
    local setup = {}
    if handicap >= 2 then
        local ok, pts = rules:place_handicap(handicap)
        if not ok then return nil, pts end
        setup = pts
    end

    local sgf = SGF.new_game{
        board_size  = size, komi = komi, rules = rules_name,
        handicap    = handicap, setup_black = setup,
        black_name  = opts.black or "Black", white_name = opts.white or "White",
        black_rank  = opts.black_rank, white_rank = opts.white_rank,
        date        = opts.date or os.date("%Y-%m-%d"),
        game_name   = opts.name,
    }

    return setmetatable({
        rules = rules, sgf = sgf, size = size, komi = komi,
        handicap = handicap, resigned = nil, result_text = nil,
    }, Game)
end

-- ---------------------------------------------------------------------------
-- Playing
-- ---------------------------------------------------------------------------

function Game:to_move() return self.rules:to_move() end

function Game:is_over()
    return self.resigned ~= nil or self.rules:is_over()
end

-- Returns true, captured_count  or  false, reason
function Game:play(col, row)
    if self:is_over() then return false, "game_over" end
    local color = self.rules:to_move()
    local ok, res = self.rules:play(color, col, row)
    if not ok then return false, res end
    self.sgf:add_move(color, col, row)
    return true, res
end

function Game:pass()
    if self:is_over() then return false, "game_over" end
    local color = self.rules:to_move()
    self.rules:pass(color)
    self.sgf:add_pass(color)
    return true
end

-- `color` resigns (default: the side to move)
function Game:resign(color)
    if self:is_over() then return false, "game_over" end
    color = color or self.rules:to_move()
    self.resigned = color
    self.result_text = other(color) .. "+R"
    self.sgf:set_result(self.result_text)
    return true
end

-- Take back `n` moves (default 1). Returns how many were undone.
function Game:undo(n)
    n = n or 1
    local done = 0
    if self.resigned then
        self.resigned, self.result_text = nil, nil
        self.sgf:set_result(nil)
    end
    for _ = 1, n do
        if not self.rules:undo() then break end
        self.sgf:delete_current()
        done = done + 1
    end
    return done
end

function Game:move_count() return self.rules:move_count() end

-- ---------------------------------------------------------------------------
-- Finishing
-- ---------------------------------------------------------------------------

--[[ Score the position. `dead` is a list of {col,row} dead-stone points.
     Writes the result into the SGF and returns the score table.
--]]
function Game:finish(dead)
    local s = self.rules:score(dead)
    self.result_text = s.text
    self.sgf:set_result(s.text)
    return s
end

function Game:result() return self.result_text end

-- ---------------------------------------------------------------------------
-- Interface for engines
-- ---------------------------------------------------------------------------

--[[ Everything an engine needs to reconstruct the position:
     { size, komi, setup = {B={{c,r}..}, W={..}}, moves = {{color,col,row}..},
       to_move = "B"|"W" }   (a pass has col == nil)
--]]
function Game:position()
    return {
        size    = self.size,
        komi    = self.komi,
        setup   = self.sgf:setup_stones(),
        moves   = self.sgf:path_moves(),
        to_move = self.rules:to_move(),
    }
end

-- ---------------------------------------------------------------------------
-- Saving and loading
-- ---------------------------------------------------------------------------

function Game:to_sgf()
    return SGF.write(self.sgf)
end

-- Build a game from SGF text by replaying the main line through the rules.
-- Returns game, or nil + message ("move N: reason") if a move is illegal.
function Game.from_sgf(text)
    local ok, parsed = pcall(SGF.parse, text)
    if not ok or not parsed then return nil, "could not parse SGF" end
    local sgf = parsed
    local size = sgf.board_size or 19
    local rules_name = sgf.root:get("RU", "Chinese")
    local komi = tonumber(sgf.root:get("KM", "7.5")) or 7.5
    local rules = Rules.new(size, { komi = komi, scoring = scoring_for(rules_name) })

    local setup = sgf:setup_stones()
    for _, p in ipairs(setup.B) do rules:setup_stone("B", p[1], p[2]) end
    for _, p in ipairs(setup.W) do rules:setup_stone("W", p[1], p[2]) end
    rules:set_turn(sgf:current_color())          -- handicap / PL aware at the root

    -- walk the main line
    sgf:go_to_root()
    local n = 0
    while sgf:go_next() do
        local color, coord = sgf.current:move()
        if color then
            n = n + 1
            if coord == "" or coord == "tt" then
                rules:pass(color)
            else
                local c = SGF.sgf_to_coord(coord, size)
                if not c then return nil, "move " .. n .. ": bad coordinate" end
                local ok2, why = rules:play(color, c.col, c.row)
                if not ok2 then return nil, "move " .. n .. ": " .. tostring(why) end
            end
        end
    end

    local g = setmetatable({
        rules = rules, sgf = sgf, size = size, komi = komi,
        handicap = tonumber(sgf.root:get("HA", "0")) or 0,
        resigned = nil, result_text = nil,
    }, Game)
    local re = sgf.root:get("RE", "")
    if re ~= "" then g.result_text = re end
    return g
end

return Game
