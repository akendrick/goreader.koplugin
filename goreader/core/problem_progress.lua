--[[
    goreader/core/problem_progress.lua - which problems of a set you have solved.

    Plain data, saved by the app as JSON:
        { ["starter-captures.sgf"] = { solved = { [3] = true, ... }, tries = { [3] = 2 } } }
    A problem counts as solved the first time it is solved without looking at the answer.
--]]

local Progress = {}
Progress.__index = Progress

function Progress.new(data)
    local self = setmetatable({ data = type(data) == "table" and data or {} }, Progress)
    return self
end

local function entry(self, set)
    local e = self.data[set]
    if type(e) ~= "table" then e = {}; self.data[set] = e end
    e.solved = type(e.solved) == "table" and e.solved or {}
    e.tries = type(e.tries) == "table" and e.tries or {}
    return e
end

-- JSON turns number keys into strings: look up both
local function get(t, i) return t[i] or t[tostring(i)] end

function Progress:is_solved(set, index)
    local e = self.data[set]
    return e ~= nil and type(e.solved) == "table" and get(e.solved, index) == true
end

function Progress:mark_solved(set, index)
    local e = entry(self, set)
    e.solved[tostring(index)] = true
    e.solved[index] = nil
end

function Progress:add_try(set, index)
    local e = entry(self, set)
    local k = tostring(index)
    e.tries[k] = (get(e.tries, index) or 0) + 1
    e.tries[index] = nil
end

function Progress:tries(set, index)
    local e = self.data[set]
    return e and type(e.tries) == "table" and get(e.tries, index) or 0
end

function Progress:solved_count(set, total)
    local n = 0
    for i = 1, total do if self:is_solved(set, i) then n = n + 1 end end
    return n
end

-- The first problem not yet solved at or after `from`, wrapping round; nil when all are solved
function Progress:next_unsolved(set, total, from)
    for step = 0, total - 1 do
        local i = ((from or 1) - 1 + step) % total + 1
        if not self:is_solved(set, i) then return i end
    end
    return nil
end

function Progress:set_total(set, n) entry(self, set).total = n end
function Progress:total(set) local e = self.data[set]; return e and tonumber(e.total) or nil end

function Progress:reset(set) self.data[set] = nil end

return Progress
