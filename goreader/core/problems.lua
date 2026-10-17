--[[
    goreader/core/problems.lua - Go problems (tsumego) from SGF.

    Loads problems from SGF files or collections and checks a student's moves
    against the solution tree. No UI, no KOReader dependencies.

    How an SGF encodes a problem
        root       setup stones (AB / AW), PL = side to play, C = description
        children   the solution tree: the student's move, then replies

    How we decide right and wrong (tried in this order)
        1. TE (tesuji) or a comment starting "correct" / "right" / "solved"
           marks a line as solved; BM (bad move) or a comment starting
           "wrong" / "incorrect" / "fail" marks it as failed.
        2. Where a line carries no mark, the nearest marked ancestor decides.
        3. A tree with no marks at all: the main line (first child at every
           branch) is the solution, anything else is wrong.

    Usage
        local list = Problems.load_collection(text)
        local attempt = list[1]:start()
        local r = attempt:play(col, row)   -- r.status "correct"|"wrong"|"continue"
--]]

local SGF   = require("goreader.core.sgf")
local Rules = require("goreader.core.rules")

local Problems = {}

local Problem = {}
Problem.__index = Problem
local Attempt = {}
Attempt.__index = Attempt

-- ---------------------------------------------------------------------------
-- Marks
-- ---------------------------------------------------------------------------

local GOOD_WORDS = { "correct", "right", "solved", "success", "good", "yes" }
local BAD_WORDS  = { "wrong", "incorrect", "fail", "bad", "no" }

local function starts_with_word(text, words)
    local t = (text or ""):lower():gsub("^%s+", "")
    for _, w in ipairs(words) do
        if t:sub(1, #w) == w then
            local nxt = t:sub(#w + 1, #w + 1)
            if nxt == "" or not nxt:match("%a") then return true end
        end
    end
    return false
end

-- "good", "bad" or nil
local function mark_of(node)
    if node.props["TE"] then return "good" end
    if node.props["BM"] then return "bad" end
    local c = node:get("C", "")
    if c ~= "" then
        if starts_with_word(c, GOOD_WORDS) then return "good" end
        if starts_with_word(c, BAD_WORDS) then return "bad" end
    end
    return nil
end

local function tree_has_marks(node)
    if node.parent and mark_of(node) then return true end
    for _, child in ipairs(node.children) do
        if tree_has_marks(child) then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Problem
-- ---------------------------------------------------------------------------

--[[ Build a problem from an SGF.Game. Returns problem, or nil + reason. ]]
function Problems.from_game(game, index)
    local root = game.root
    local size = game.board_size or 19
    local setup = game:setup_stones()
    if #setup.B + #setup.W == 0 then return nil, "no setup stones" end
    if #root.children == 0 then return nil, "no solution tree" end

    local to_play = root:get("PL")
    if to_play ~= "B" and to_play ~= "W" then
        local first = root.children[1]:move()
        to_play = first or "B"
    end

    local title = root:get("GN", "")
    if title == "" then title = root:get("N", "") end
    return setmetatable({
        game      = game,
        size      = size,
        setup     = setup,
        to_play   = to_play,
        root      = root,
        has_marks = tree_has_marks(root),
        title     = title,
        text      = root:get("C", ""),
        index     = index,
    }, Problem)
end

--[[ Load every problem in an SGF string (one game or a collection).
     Returns a list of problems and a list of "problem N: reason" strings for
     entries that could not be used.
--]]
function Problems.load_collection(text)
    local first, all = SGF.parse(text)
    local list, errors = {}, {}
    if not first then return list, { "could not parse SGF" } end
    for i, game in ipairs(all) do
        local p, why = Problems.from_game(game, i)
        if p then list[#list + 1] = p
        else errors[#errors + 1] = "problem " .. i .. ": " .. tostring(why) end
    end
    return list, errors
end

-- A fresh board with the setup stones in place
function Problem:initial_rules()
    local r = Rules.new(self.size, { komi = 0, superko = true })
    for _, p in ipairs(self.setup.B) do r:setup_stone("B", p[1], p[2]) end
    for _, p in ipairs(self.setup.W) do r:setup_stone("W", p[1], p[2]) end
    r:set_turn(self.to_play)
    return r
end

function Problem:start()
    return setmetatable({
        problem  = self,
        node     = self.root,
        rules    = self:initial_rules(),
        history  = {},          -- stack of { node, plies_added }
        finished = false,
        result   = nil,         -- "correct" | "wrong"
        wrong_tries = 0,
    }, Attempt)
end

-- ---------------------------------------------------------------------------
-- Judging a node
-- ---------------------------------------------------------------------------

-- Walk up from `node` for the nearest mark; returns "good" / "bad" / nil.
local function inherited_mark(node)
    local n = node
    while n do
        local m = mark_of(n)
        if m then return m end
        n = n.parent
    end
    return nil
end

local function is_main_line(node)
    local n = node
    while n and n.parent do
        if n.parent.children[1] ~= n then return false end
        n = n.parent
    end
    return true
end

-- "correct" / "wrong" / nil (not decided yet) for the position at `node`.
function Problem:judge(node)
    local own = mark_of(node)
    if own == "good" then return "correct" end
    if own == "bad"  then return "wrong" end
    if #node.children > 0 then return nil end                -- line continues
    -- end of a line with no mark of its own
    if self.has_marks then
        local m = inherited_mark(node)
        if m == "good" then return "correct" end
        return "wrong"
    end
    return is_main_line(node) and "correct" or "wrong"
end

-- ---------------------------------------------------------------------------
-- Attempt
-- ---------------------------------------------------------------------------

local function child_for_move(node, color, col, row)
    local sgf = SGF.coord_to_sgf(col, row)
    for _, child in ipairs(node.children) do
        local c, coord = child:move()
        if c == color and coord == sgf then return child end
    end
    return nil
end

local function coords_of(node, size)
    local color, coord = node:move()
    if not color then return nil end
    local c = SGF.sgf_to_coord(coord, size)
    if not c then return { color = color, pass = true } end
    return { color = color, col = c.col, row = c.row }
end

-- Does this line end in a solved position?
local function leads_to_correct(problem, node)
    local v = problem:judge(node)
    if v == "correct" then return true end
    if v == "wrong" then return false end
    for _, child in ipairs(node.children) do
        if leads_to_correct(problem, child) then return true end
    end
    return false
end

-- The preferred reply / solution move among the children of `node`:
-- an explicitly marked move, else the first line that ends solved, else the
-- first child.
local function best_child(problem, node)
    for _, child in ipairs(node.children) do
        if mark_of(child) == "good" then return child end
    end
    for _, child in ipairs(node.children) do
        if leads_to_correct(problem, child) then return child end
    end
    return node.children[1]
end

function Attempt:board() return self.rules end
function Attempt:to_play() return self.problem.to_play end
function Attempt:is_finished() return self.finished end

--[[ The student plays at (col,row). Returns
       { status   = "correct" | "wrong" | "continue" | "illegal" | "error",
         reply    = { color, col, row } | nil     (the opponent's answer)
         finished = bool,
         comment  = text of the node reached, if any,
         reason   = for "illegal": rules reason }
--]]
function Attempt:play(col, row)
    if self.finished then return { status = self.result, finished = true } end
    local p = self.problem
    local color = p.to_play

    local ok, why = self.rules:play(color, col, row)
    if not ok then return { status = "illegal", reason = why, finished = false } end
    local entry = { node = self.node, plies = 1 }

    local child = child_for_move(self.node, color, col, row)
    if not child then
        -- not in the solution tree: wrong, but stop there (the move stays on
        -- the board so the student can see it; undo takes it back)
        self.history[#self.history + 1] = entry
        self.finished, self.result = true, "wrong"
        self.wrong_tries = self.wrong_tries + 1
        return { status = "wrong", finished = true,
                 comment = "That move is not in the solution." }
    end

    self.node = child
    local verdict = p:judge(child)
    local comment = child:get("C", "")
    if verdict then
        self.history[#self.history + 1] = entry
        self.finished, self.result = true, verdict
        if verdict == "wrong" then self.wrong_tries = self.wrong_tries + 1 end
        return { status = verdict, finished = true, comment = comment }
    end

    -- the line continues: the opponent answers
    local reply_node = best_child(p, child)
    local reply = coords_of(reply_node, p.size)
    if reply and reply.col then
        local rok = self.rules:play(reply.color, reply.col, reply.row)
        if not rok then
            -- the problem's own tree contains an illegal reply
            self.history[#self.history + 1] = entry
            return { status = "error", finished = false,
                     reason = "the problem's solution contains an illegal move" }
        end
        entry.plies = 2
    elseif reply and reply.pass then
        self.rules:pass(reply.color); entry.plies = 2
    end
    self.history[#self.history + 1] = entry
    self.node = reply_node

    local rverdict = p:judge(reply_node)
    local rcomment = reply_node:get("C", "")
    if rverdict then
        self.finished, self.result = true, rverdict
        if rverdict == "wrong" then self.wrong_tries = self.wrong_tries + 1 end
        return { status = rverdict, reply = reply, finished = true,
                 comment = rcomment ~= "" and rcomment or comment }
    end
    return { status = "continue", reply = reply, finished = false,
             comment = rcomment ~= "" and rcomment or comment }
end

-- Where to play next. Returns { col, row } or nil.
function Attempt:hint()
    if self.finished then return nil end
    local child = best_child(self.problem, self.node)
    if not child then return nil end
    local m = coords_of(child, self.problem.size)
    if m and m.col then return { m.col, m.row } end
    return nil
end

-- The solution from the current position: list of { color, col, row }
function Attempt:solution_line()
    local out, n = {}, self.node
    if self.finished and self.result == "wrong" then
        -- show the solution from where the student went off
        n = self.problem.root
        for _, h in ipairs(self.history) do n = h.node end
    end
    while n and #n.children > 0 do
        n = best_child(self.problem, n)
        local m = coords_of(n, self.problem.size)
        if m and m.col then out[#out + 1] = m end
        if self.problem:judge(n) then break end
    end
    return out
end

-- Take back the last attempt move (and the reply). Returns true if undone.
function Attempt:undo()
    local entry = table.remove(self.history)
    if not entry then return false end
    for _ = 1, entry.plies do self.rules:undo() end
    self.node = entry.node
    self.finished, self.result = false, nil
    return true
end

function Attempt:reset()
    self.rules = self.problem:initial_rules()
    self.node, self.history = self.problem.root, {}
    self.finished, self.result = false, nil
end

return Problems
