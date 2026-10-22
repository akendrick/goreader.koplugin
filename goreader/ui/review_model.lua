--[[
    goreader/ui/review_model.lua - everything the review screen needs to know,
    with no drawing in it (so it is tested here, not on the device).

    A Model wraps an SGF.Game. It answers "what do I show at this position?"
    (state()) and handles navigation, variations, engine annotations
    (winrates, candidate moves, mistakes) and the reader's own notes.

        local m = ReviewModel.new{ game = SGF.parse(text) }
        m:next(); m:next_mistake(); m:enter_variation(2)
        local s = m:state()      -- board, last move, comment, marks, candidates...

    Coordinates: col 1..N left to right, row 1..N top to bottom.
--]]

local SGF      = require("goreader.core.sgf")
local Analysis = require("goreader.core.analysis")
local GTP      = require("goreader.engine.gtp")
local Rules    = require("goreader.core.rules")

local Model = {}
Model.__index = Model

Model.MAX_CANDIDATES = 5
local KIND_RANK = { inaccuracy = 1, mistake = 2, blunder = 3 }
local MARK_KINDS = { TR = true, SQ = true, CR = true, MA = true }

--[[ opts: game (SGF.Game, required), thresholds (see Analysis.THRESHOLDS) ]]
function Model.new(opts)
    assert(opts and opts.game, "a game is required")
    local self = setmetatable({
        game = opts.game, thresholds = opts.thresholds,
        show_candidates = true, show_variations = true, show_marks = true,
        dirty = false,           -- the reader changed notes or marks
        _reviews = nil, _by_node = nil,
    }, Model)
    return self
end

-- ---------------------------------------------------------------------------
-- Engine review data (computed once, on demand)
-- ---------------------------------------------------------------------------

function Model:reviews()
    if not self._reviews then
        self._reviews = Analysis.review(self.game, { thresholds = self.thresholds })
        self._by_node = {}
        for _, r in ipairs(self._reviews) do self._by_node[r.node] = r end
    end
    return self._reviews
end

-- Forget cached analysis (after annotations are added or changed)
function Model:refresh_analysis() self._reviews, self._by_node = nil, nil end

function Model:review_of(node)
    self:reviews()
    return self._by_node[node]
end

function Model:has_analysis()
    local n = self.game.root
    while n do
        if Analysis.has(n) then return true end
        n = n.children[1]
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Lines and positions
-- ---------------------------------------------------------------------------

local function on_main_line(node)
    local n = node
    while n.parent do
        if n.parent.children[1] ~= n then return false end
        n = n.parent
    end
    return true
end

function Model:on_main_line() return on_main_line(self.game.current) end

-- The nodes of the line through the current position: root ... current ... end
-- (continuing down first children). Index 1 is the root.
function Model:line()
    local path = {}
    local n = self.game.current
    while n do table.insert(path, 1, n); n = n.parent end
    n = self.game.current.children[1]
    while n do path[#path + 1] = n; n = n.children[1] end
    return path
end

local function counts_as_move(node) return node.props["B"] ~= nil or node.props["W"] ~= nil end

-- Number of moves in the current line (to its end)
function Model:total()
    local t = 0
    for _, n in ipairs(self:line()) do if counts_as_move(n) then t = t + 1 end end
    return t
end

function Model:move_number() return self.game:move_number() end

-- ---------------------------------------------------------------------------
-- Navigation (each returns true if the position changed)
-- ---------------------------------------------------------------------------

function Model:first() local moved = self.game.current ~= self.game.root; self.game:go_to_root(); return moved end

function Model:last()
    local before = self.game.current
    self.game:go_to_end()
    return self.game.current ~= before
end

function Model:prev(n)
    local moved = false
    for _ = 1, n or 1 do
        if not self.game:go_prev() then break end
        moved = true
    end
    return moved
end

function Model:next(n)
    local moved = false
    for _ = 1, n or 1 do
        if not self.game:go_next(1) then break end
        moved = true
    end
    return moved
end

--[[ Where a game should open. A game still in progress opens on its latest
     move; a finished game (it has a result) opens on an early-middle position,
     move `opening` (default 40), so the board is full enough to be worth reading
     without giving the ending away. Returns the move number shown. ]]
Model.OPENING_MOVE = 40
function Model:go_to_start_position(opening)
    if self.game:result() ~= "" then
        self:goto_move(math.min(opening or Model.OPENING_MOVE, self:total()))
    else
        self:last()
    end
    return self.game.current:move_number()
end

-- Jump to move number n along the current line (0 = before the first move)
function Model:goto_move(n)
    n = math.max(0, math.floor(n))
    local count = 0
    local target = self.game.root
    for _, node in ipairs(self:line()) do
        if counts_as_move(node) then count = count + 1 end
        if count > n then break end
        target = node
    end
    if target == self.game.current then return false end
    self.game.current = target
    return true
end

-- Step into the i-th continuation of the current position
function Model:enter_variation(i)
    return self.game:go_next(i)
end

-- Replace the current move by its previous/next sibling (a different move
-- from the same position). delta = -1 or +1; wraps around.
function Model:switch_sibling(delta)
    local node = self.game.current
    local parent = node.parent
    if not parent or #parent.children < 2 then return false end
    local idx
    for i, c in ipairs(parent.children) do if c == node then idx = i end end
    local nxt = ((idx - 1 + delta) % #parent.children) + 1
    self.game.current = parent.children[nxt]
    return true
end

-- Go back to the main line (to the nearest ancestor on it)
function Model:to_main_line()
    local n = self.game.current
    while not on_main_line(n) do n = n.parent end
    if n == self.game.current then return false end
    self.game.current = n
    return true
end

-- Index of the current node among its siblings, and how many there are
function Model:sibling_position()
    local node = self.game.current
    local parent = node.parent
    if not parent then return 1, 1 end
    for i, c in ipairs(parent.children) do if c == node then return i, #parent.children end end
    return 1, 1
end

-- ---------------------------------------------------------------------------
-- Mistakes (main line only; needs engine analysis in the file)
-- ---------------------------------------------------------------------------

-- Reviews at or above `min_kind` (default "mistake"), in move order
function Model:mistakes(min_kind)
    local min = KIND_RANK[min_kind or "mistake"] or 2
    local out = {}
    for _, r in ipairs(self:reviews()) do
        if r.kind and KIND_RANK[r.kind] >= min then out[#out + 1] = r end
    end
    return out
end

-- Main-line move number of the current position (the ancestor's, in a variation)
function Model:main_line_move()
    local n = self.game.current
    while not on_main_line(n) do n = n.parent end
    return n:move_number()
end

local function goto_review(self, r)
    self.game.current = r.node
    return true
end

function Model:next_mistake(min_kind)
    local here = self:main_line_move()
    for _, r in ipairs(self:mistakes(min_kind)) do
        if r.move > here then return goto_review(self, r) end
    end
    return false
end

function Model:prev_mistake(min_kind)
    local here = self:main_line_move()
    local list = self:mistakes(min_kind)
    for i = #list, 1, -1 do
        if list[i].move < here then return goto_review(self, list[i]) end
    end
    return false
end

-- Winrate graph data for the main line: list of { move, winrate, score, color }
function Model:graph() return Analysis.series(self.game) end

-- ---------------------------------------------------------------------------
-- What to show
-- ---------------------------------------------------------------------------

local function mark_list(node, size)
    local out = {}
    for kind in pairs(MARK_KINDS) do
        for _, coord in ipairs(node:get_all(kind)) do
            -- compressed rectangles "aa:cc" are not expanded; single points only
            local c = SGF.sgf_to_coord(coord, size)
            if c then out[#out + 1] = { kind = kind, col = c.col, row = c.row } end
        end
    end
    for _, lb in ipairs(node:get_all("LB")) do
        local coord, text = lb:match("^(..):(.*)$")
        local c = coord and SGF.sgf_to_coord(coord, size)
        if c and text then out[#out + 1] = { kind = "LB", col = c.col, row = c.row, text = text } end
    end
    table.sort(out, function(a, b)
        if a.row ~= b.row then return a.row < b.row end
        if a.col ~= b.col then return a.col < b.col end
        return a.kind < b.kind
    end)
    return out
end

local LETTERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"

--[[ The continuations from the current position (variations), each with the
     move it plays: { index, label, col, row, color, pass, main, comment }.
     Only when there is more than one, or the user asked to see the single one. ]]
function Model:variations()
    local size = self.game.board_size
    local out = {}
    for i, child in ipairs(self.game.current.children) do
        local color, coord = child:move()
        local c = coord and SGF.sgf_to_coord(coord, size)
        out[#out + 1] = {
            index = i, label = LETTERS:sub(i, i), color = color,
            col = c and c.col, row = c and c.row, pass = (color ~= nil and c == nil),
            main = (i == 1), name = child:get("N", ""),
        }
    end
    return out
end

-- Candidate moves the engine liked from here, for the side to move next.
-- { rank, label, col, row, winrate (for the mover), score, visits, played }
function Model:candidates()
    local node = self.game.current
    local info = Analysis.get(node, self.game.board_size)
    if not info or #info.candidates == 0 then return {} end
    local mover = self.game:current_color()
    local next_move = node.children[1] and select(2, node.children[1]:move())
    local played = next_move and SGF.sgf_to_coord(next_move, self.game.board_size)
    local out = {}
    for i, c in ipairs(info.candidates) do
        if c.col then
            local wr = (mover == "B") and c.winrate or (1 - c.winrate)
            out[#out + 1] = {
                rank = i, label = LETTERS:sub(i, i), col = c.col, row = c.row,
                winrate = wr, score = c.score, visits = c.visits, pv = c.pv,
                played = played ~= nil and played.col == c.col and played.row == c.row,
            }
            if #out >= Model.MAX_CANDIDATES then break end
        end
    end
    return out
end

local function player(game, color)
    local name = color == "B" and game:black_player() or game:white_player()
    local rank = color == "B" and game:black_rank() or game:white_rank()
    return { name = name, rank = rank, color = color }
end

--[[ Snapshot for the screen. Cheap enough to call after every navigation. ]]
function Model:state()
    local g = self.game
    local node = g.current
    local board, cap_b, cap_w, size = SGF.build_board(node, g.board_size)
    local color, coord = node:move()
    local last
    if color then
        local c = coord and SGF.sgf_to_coord(coord, size)
        last = c and { col = c.col, row = c.row, color = color } or { pass = true, color = color }
    end

    local info = Analysis.get(node, size)
    local review = self:review_of(node)
    local note
    if review and review.kind then
        local existing = node:get("C", "")
        note = Analysis.comment_for(review, size)
        if existing:find(review.kind:sub(1, 1):upper() .. review.kind:sub(2), 1, true) then note = nil end
    end

    local sib, sibs = self:sibling_position()
    return {
        size = size, board = board, captures = { B = cap_b, W = cap_w },
        move_number = node:move_number(), total = self:total(),
        main_line = self:on_main_line(),
        to_move = g:current_color(), last = last,
        black = player(g, "B"), white = player(g, "W"),
        komi = g:komi(), result = g:result(), date = g:date(), name = g:name(),
        comment = node:get("C", ""), analysis_note = note, node_name = node:get("N", ""),
        marks = self.show_marks and mark_list(node, size) or {},
        variations = (self.show_variations and #node.children > 1) and self:variations() or {},
        sibling = sib, siblings = sibs,
        analysis = info and { winrate = info.winrate, score = info.score, visits = info.visits,
                              text = Analysis.describe(info) } or nil,
        candidates = self.show_candidates and self:candidates() or {},
        played_rating = review and { kind = review.kind, loss_wr = review.loss_wr,
                                     loss_score = review.loss_score, best = review.best } or nil,
        can_prev = node.parent ~= nil, can_next = node.children[1] ~= nil,
        dirty = self.dirty,
    }
end

-- ---------------------------------------------------------------------------
-- Playing moves into the game (the play-out board)
-- ---------------------------------------------------------------------------

-- The rules engine set to the current position (setup stones, then the moves
-- on the path from the start), for checking whether a move is legal.
function Model:rules_here()
    local g = self.game
    local rules = Rules.new(g.board_size, { komi = g:komi(), superko = true })
    local setup = g:setup_stones()
    for _, key in ipairs({ "B", "W" }) do
        for _, p in ipairs(setup[key]) do rules:setup_stone(key, p[1], p[2]) end
    end
    for _, m in ipairs(g:path_moves()) do
        if m.col then rules:play(m.color, m.col, m.row) else rules:pass(m.color) end
    end
    return rules
end

--[[ Play a stone for the side to move. If that move already exists here the
     game just goes to it. Returns node, created (true when a new node was
     added), or nil + the rules' reason ("occupied", "suicide", "ko", ...). ]]
function Model:play_move(col, row)
    local g = self.game
    local color = g:current_color()
    local ok, why = self:rules_here():play(color, col, row)
    if not ok then return nil, why end
    local before = #g.current.children
    local node = g:add_move(color, col, row)
    local created = #node.parent.children > before
    if created then self.dirty = true; self:refresh_analysis() end
    return node, created
end

function Model:play_pass()
    local g = self.game
    local node = g:add_pass(g:current_color())
    self.dirty = true; self:refresh_analysis()
    return node, true
end

-- Take back the current move (it and anything after it) and step to its parent
function Model:delete_current()
    local ok = self.game:delete_current()
    if ok then self.dirty = true; self:refresh_analysis() end
    return ok
end

-- ---------------------------------------------------------------------------
-- The reader's own notes (written back into the SGF)
-- ---------------------------------------------------------------------------

function Model:set_comment(text)
    local node = self.game.current
    text = tostring(text or "")
    if text == "" then node.props["C"] = nil else node.props["C"] = { text } end
    self.dirty = true
    self:refresh_analysis()
end

-- Add the mark if absent, remove it if present. kind = TR | SQ | CR | MA.
function Model:toggle_mark(kind, col, row)
    if not MARK_KINDS[kind] then return nil, "bad_mark" end
    local node = self.game.current
    local coord = SGF.coord_to_sgf(col, row)
    local list = node.props[kind] or {}
    local found
    for i, c in ipairs(list) do if c == coord then found = i end end
    if found then table.remove(list, found) else list[#list + 1] = coord end
    node.props[kind] = (#list > 0) and list or nil
    self.dirty = true
    return not found                         -- true = added, false = removed
end

function Model:to_sgf() return SGF.write(self.game) end

return Model
