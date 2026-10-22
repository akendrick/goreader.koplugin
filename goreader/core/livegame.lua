--[[
    goreader/core/livegame.lua - a game played or recorded by people at the
    board (no engine, no server).

        local g = LiveGame.new{ size = 19, mode = "record" | "play", komi = 6.5 }
        g:play(col, row)       the side to move plays (alternating); true | false, why
        g:pass()               two passes in a row start scoring
        g:resign(color)        ends the game, result "W+R" / "B+R"
        g:toggle_dead(c, r)    while scoring: mark / unmark a group
        g:score()              preview { text, black, white, territory ... }
        g:confirm_score()      ends the game with the counted result
        g:set_info{ black=, white=, black_rank=, white_rank=, komi=, event=, place=, date=, name= }
        g:to_sgf()             the record so far

    States: "playing" -> "scoring" (after two passes) -> "over".
--]]

local Game = require("goreader.core.game")
local SGF  = require("goreader.core.sgf")

local LiveGame = {}
LiveGame.__index = LiveGame

function LiveGame.new(opts)
    opts = opts or {}
    local size = opts.size or 19
    local game = Game.new{
        size = size, komi = opts.komi or 6.5, black = opts.black or "Black", white = opts.white or "White",
        black_rank = opts.black_rank, white_rank = opts.white_rank, rules = opts.rules or "Japanese",
        name = opts.name, date = opts.date,
    }
    return setmetatable({
        game = game, size = size, mode = opts.mode or "record", state = "playing",
        dead = {}, info = { black = opts.black or "Black", white = opts.white or "White" },
        result = nil,
    }, LiveGame)
end

function LiveGame:to_move() return self.game:to_move() end
function LiveGame:move_count() return self.game:move_count() end
function LiveGame:board() return self.game.rules end

-- ---------------------------------------------------------------------------
-- Playing
-- ---------------------------------------------------------------------------

function LiveGame:play(col, row)
    if self.state ~= "playing" then return false, "not_playing" end
    return self.game:play(col, row)
end

function LiveGame:pass()
    if self.state ~= "playing" then return false, "not_playing" end
    self.game:pass()
    if self.game.rules:consecutive_passes() >= 2 then
        self.state, self.dead = "scoring", {}
    end
    return true
end

function LiveGame:undo()
    if self.state == "over" then return 0 end
    local was_scoring = self.state == "scoring"
    local n = self.game:undo(1)
    if was_scoring or self.state == "scoring" then self.state, self.dead = "playing", {} end
    return n
end

function LiveGame:resign(color)
    if self.state == "over" then return false, "over" end
    color = color or self.game:to_move()
    self.game:resign(color)
    self.state, self.result = "over", self.game:result()
    return true
end

-- Leave scoring and carry on playing (the two passes are taken back)
function LiveGame:resume()
    if self.state ~= "scoring" then return false end
    self.game:undo(self.game.rules:consecutive_passes())
    self.state, self.dead = "playing", {}
    return true
end

-- ---------------------------------------------------------------------------
-- Scoring
-- ---------------------------------------------------------------------------

function LiveGame:toggle_dead(col, row)
    if self.state ~= "scoring" then return false, "not_scoring" end
    local group = self.game.rules:group_at(col, row)
    if not group then return false, "empty" end
    local mark = not self.dead[group[1][1] .. "," .. group[1][2]]
    for _, p in ipairs(group) do
        local key = p[1] .. "," .. p[2]
        if mark then self.dead[key] = true else self.dead[key] = nil end
    end
    return true, mark
end

function LiveGame:dead_list()
    local out = {}
    for key in pairs(self.dead) do
        local c, r = key:match("^(%d+),(%d+)$")
        out[#out + 1] = { tonumber(c), tonumber(r) }
    end
    return out
end

function LiveGame:score() return self.game.rules:score(self:dead_list()) end

function LiveGame:confirm_score()
    if self.state ~= "scoring" then return nil, "not_scoring" end
    local s = self.game:finish(self:dead_list())
    self.state, self.result = "over", s.text
    return s
end

-- A result decided without counting (e.g. agreed, or time)
function LiveGame:set_result(text)
    self.game.sgf:set_result(text)
    self.game.result_text = text
    self.state, self.result = "over", text
end

-- ---------------------------------------------------------------------------
-- The record
-- ---------------------------------------------------------------------------

local function put(root, key, value)
    if value == nil or value == "" then root.props[key] = nil else root.props[key] = { tostring(value) } end
end

function LiveGame:set_info(t)
    local root = self.game.sgf.root
    for k, v in pairs(t) do self.info[k] = v end
    put(root, "PB", self.info.black); put(root, "PW", self.info.white)
    put(root, "BR", self.info.black_rank); put(root, "WR", self.info.white_rank)
    put(root, "EV", self.info.event); put(root, "PC", self.info.place)
    put(root, "DT", self.info.date); put(root, "GN", self.info.name)
    if t.komi ~= nil then
        local komi = tonumber(t.komi)
        if komi then
            self.game.komi = komi; self.game.rules.komi = komi
            root.props["KM"] = { tostring(komi) }
        end
    end
end

function LiveGame:to_sgf() return self.game:to_sgf() end

-- A file name that says what the game is: "2026-10-22 Ann vs Bob"
function LiveGame:suggested_name()
    local i = self.info
    local date = (i.date and i.date ~= "") and i.date or os.date("%Y-%m-%d")
    return date .. " " .. (i.black or "Black") .. " vs " .. (i.white or "White")
end

return LiveGame
