--[[
    goreader/core/rules.lua - the rules of Go.

    Pure Lua (5.1 / LuaJIT compatible), no KOReader dependencies.

    Coordinates: col 1..size left to right, row 1..size TOP to bottom
    (the same as SGF). Colours in the public API are "B" and "W".

    Features
      * legal-move checking: occupied, suicide, simple ko, positional superko
      * captures, undo, passes
      * fixed handicap placement (GTP order)
      * scoring: area (Chinese) or territory (Japanese), with dead stones

    Not covered here: deciding which stones are dead. That comes from the
    player marking them or from the engine (GTP final_status_list).
--]]

local Rules = {}
Rules.__index = Rules

local EMPTY, BLACK, WHITE = 0, 1, 2
Rules.EMPTY, Rules.BLACK, Rules.WHITE = EMPTY, BLACK, WHITE

local NAME = { [BLACK] = "B", [WHITE] = "W" }
local function code(color)
    if color == "B" then return BLACK end
    if color == "W" then return WHITE end
    return nil
end
Rules.code = code

-- neighbour tables are the same for every board of a given size
local NEIGHBOURS = {}
local function neighbours(size)
    local t = NEIGHBOURS[size]
    if t then return t end
    t = {}
    for row = 1, size do
        for col = 1, size do
            local list, idx = {}, (row - 1) * size + col
            if row > 1    then list[#list + 1] = idx - size end
            if row < size then list[#list + 1] = idx + size end
            if col > 1    then list[#list + 1] = idx - 1 end
            if col < size then list[#list + 1] = idx + 1 end
            t[idx] = list
        end
    end
    NEIGHBOURS[size] = t
    return t
end

-- ---------------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------------

--[[ opts:
       komi    number   default 7.5
       scoring "area" | "territory"   default "area"
       superko bool     default true (positional superko). false = simple ko only.
--]]
function Rules.new(size, opts)
    size = size or 19
    assert(size >= 2 and size <= 25, "board size out of range")
    opts = opts or {}
    local self = setmetatable({}, Rules)
    self.size    = size
    self.n       = size * size
    self.nbr     = neighbours(size)
    self.cells   = {}
    for i = 1, self.n do self.cells[i] = EMPTY end
    self.komi    = opts.komi or 7.5
    self.scoring = opts.scoring or "area"
    self.superko = (opts.superko ~= false)
    self.turn    = BLACK
    self.prisoners = { [BLACK] = 0, [WHITE] = 0 }   -- stones captured BY colour
    self.passes  = 0                                -- consecutive passes
    self.history = {}                               -- stack of move records
    local key = table.concat(self.cells)
    self.keys    = { key }                          -- position key after each ply
    self.seen    = { [key] = 1 }
    return self
end

function Rules:clone()
    local c = Rules.new(self.size, { komi = self.komi, scoring = self.scoring,
                                     superko = self.superko })
    for i = 1, self.n do c.cells[i] = self.cells[i] end
    c.turn = self.turn
    c.prisoners = { [BLACK] = self.prisoners[BLACK], [WHITE] = self.prisoners[WHITE] }
    c.passes = self.passes
    for i, r in ipairs(self.history) do
        local rc = {}
        for k, v in pairs(r) do rc[k] = v end
        c.history[i] = rc
    end
    c.keys, c.seen = {}, {}
    for i, k in ipairs(self.keys) do c.keys[i] = k end
    for k, v in pairs(self.seen) do c.seen[k] = v end
    return c
end

-- ---------------------------------------------------------------------------
-- Inspection
-- ---------------------------------------------------------------------------

local function index(self, col, row)
    if col < 1 or col > self.size or row < 1 or row > self.size then return nil end
    return (row - 1) * self.size + col
end

function Rules:get(col, row)
    local i = index(self, col, row)
    if not i then return nil end
    return NAME[self.cells[i]]     -- nil when empty
end

function Rules:to_move()
    return NAME[self.turn]
end

function Rules:set_turn(color)
    self.turn = assert(code(color), "bad colour")
end

function Rules:move_count()
    return #self.history
end

function Rules:captures()
    return { B = self.prisoners[BLACK], W = self.prisoners[WHITE] }
end

function Rules:consecutive_passes()
    return self.passes
end

-- Last move played: { color, col, row } or { color, pass = true }, or nil
function Rules:last_move()
    local r = self.history[#self.history]
    if not r then return nil end
    if r.pass then return { color = NAME[r.color], pass = true } end
    local row = math.floor((r.idx - 1) / self.size) + 1
    return { color = NAME[r.color], col = r.idx - (row - 1) * self.size, row = row }
end

-- flood fill: stones of the group at idx and its liberty count
local function group(self, idx)
    local cells, nbr = self.cells, self.nbr
    local color = cells[idx]
    local stones, seen, libs, lib_seen = {}, { [idx] = true }, 0, {}
    local stack, sp = { idx }, 1
    while sp > 0 do
        local i = stack[sp]; sp = sp - 1
        stones[#stones + 1] = i
        local list = nbr[i]
        for k = 1, #list do
            local j = list[k]
            local v = cells[j]
            if v == EMPTY then
                if not lib_seen[j] then lib_seen[j] = true; libs = libs + 1 end
            elseif v == color and not seen[j] then
                seen[j] = true; sp = sp + 1; stack[sp] = j
            end
        end
    end
    return stones, libs
end

-- Group at (col,row): list of {col,row} and the number of liberties.
function Rules:group_at(col, row)
    local i = index(self, col, row)
    if not i or self.cells[i] == EMPTY then return nil end
    local stones, libs = group(self, i)
    local out = {}
    for _, s in ipairs(stones) do
        local r = math.floor((s - 1) / self.size) + 1
        out[#out + 1] = { s - (r - 1) * self.size, r }
    end
    return out, libs
end

-- ---------------------------------------------------------------------------
-- Setup (before the first move): handicap and other set-up stones
-- ---------------------------------------------------------------------------

function Rules:reset_keys()
    local key = table.concat(self.cells)
    self.keys = { key }
    self.seen = { [key] = 1 }
end

-- color: "B", "W" or nil (to clear the point)
function Rules:setup_stone(color, col, row)
    assert(#self.history == 0, "setup stones are only allowed before the first move")
    local i = index(self, col, row)
    if not i then return false, "off_board" end
    self.cells[i] = color and code(color) or EMPTY
    self:reset_keys()
    return true
end

-- Fixed handicap points in GTP order. Returns list of {col,row} or nil, err.
function Rules.handicap_points(size, n)
    if n < 2 then return {} end
    if size < 7 or n > 9 then return nil, "unsupported handicap" end
    local lo = (size >= 13) and 4 or 3
    local hi = size - lo + 1
    local mid = (size % 2 == 1) and ((size + 1) / 2) or nil
    if (n == 5 or n == 7 or n == 9) and not mid then return nil, "needs odd board" end
    if (n >= 6) and not mid then return nil, "needs odd board" end
    local function pt(c, r_bottom)         -- r_bottom: row counted from the bottom
        return { c, size - r_bottom + 1 }
    end
    local list = {
        pt(lo, lo), pt(hi, hi), pt(lo, hi), pt(hi, lo),
    }
    local out = {}
    local function take(count) for i = 1, count do out[#out + 1] = list[i] end end
    if n <= 4 then take(n); return out end
    take(4)
    if n == 5 then out[#out + 1] = pt(mid, mid); return out end
    out[#out + 1] = pt(lo, mid); out[#out + 1] = pt(hi, mid)
    if n == 6 then return out end
    if n == 7 then out[#out + 1] = pt(mid, mid); return out end
    out[#out + 1] = pt(mid, lo); out[#out + 1] = pt(mid, hi)
    if n == 9 then out[#out + 1] = pt(mid, mid) end
    return out
end

-- Place fixed handicap stones for Black and give White the first move.
function Rules:place_handicap(n)
    local pts, err = Rules.handicap_points(self.size, n)
    if not pts then return false, err end
    for _, p in ipairs(pts) do self:setup_stone("B", p[1], p[2]) end
    if #pts > 0 then self.turn = WHITE end
    return true, pts
end

-- ---------------------------------------------------------------------------
-- Playing
-- ---------------------------------------------------------------------------

--[[ Play `color` at (col,row). The side to move is not enforced (SGF allows
     any order); afterwards it is the other colour's turn.
     Returns true, captured_count  or  false, reason
     reason: "off_board" | "occupied" | "suicide" | "ko" | "superko"
--]]
function Rules:play(color, col, row)
    local c = code(color)
    if not c then return false, "bad_colour" end
    local idx = index(self, col, row)
    if not idx then return false, "off_board" end
    local cells = self.cells
    if cells[idx] ~= EMPTY then return false, "occupied" end

    local opp = 3 - c
    cells[idx] = c

    -- captures: opposing neighbour groups left without liberties
    local captured = {}
    local nb = self.nbr[idx]
    for k = 1, #nb do
        local j = nb[k]
        if cells[j] == opp then
            local stones, libs = group(self, j)
            if libs == 0 then
                for _, s in ipairs(stones) do
                    cells[s] = EMPTY
                    captured[#captured + 1] = s
                end
            end
        end
    end

    local function rollback()
        for _, s in ipairs(captured) do cells[s] = opp end
        cells[idx] = EMPTY
    end

    -- suicide
    local _, libs = group(self, idx)
    if libs == 0 then rollback(); return false, "suicide" end

    -- ko: same position as before the opponent's last move; superko: any
    local key = table.concat(cells)
    local before = self.keys[#self.keys - 1]
    if before and key == before and #captured > 0 then
        rollback(); return false, "ko"
    end
    if self.superko and self.seen[key] then
        rollback(); return false, "superko"
    end

    self.history[#self.history + 1] = {
        color = c, idx = idx, captured = captured,
        prev_turn = self.turn, prev_passes = self.passes,
    }
    self.prisoners[c] = self.prisoners[c] + #captured
    self.turn = opp
    self.passes = 0
    self.keys[#self.keys + 1] = key
    self.seen[key] = (self.seen[key] or 0) + 1
    return true, #captured
end

function Rules:pass(color)
    local c = code(color or NAME[self.turn])
    if not c then return false, "bad_colour" end
    self.history[#self.history + 1] = {
        color = c, pass = true, prev_turn = self.turn, prev_passes = self.passes,
    }
    self.turn = 3 - c
    self.passes = self.passes + 1
    local key = self.keys[#self.keys]
    self.keys[#self.keys + 1] = key
    self.seen[key] = (self.seen[key] or 0) + 1
    return true
end

function Rules:undo()
    local r = table.remove(self.history)
    if not r then return false end
    local key = table.remove(self.keys)
    self.seen[key] = self.seen[key] - 1
    if self.seen[key] <= 0 then self.seen[key] = nil end
    if not r.pass then
        self.cells[r.idx] = EMPTY
        local opp = 3 - r.color
        for _, s in ipairs(r.captured) do self.cells[s] = opp end
        self.prisoners[r.color] = self.prisoners[r.color] - #r.captured
    end
    self.turn = r.prev_turn
    self.passes = r.prev_passes
    return true
end

-- Would this move be legal? Returns true or false, reason. No side effects.
function Rules:legal(color, col, row)
    local ok, why = self:play(color, col, row)
    if ok then self:undo(); return true end
    return false, why
end

-- Both players passed in a row
function Rules:is_over()
    return self.passes >= 2
end

-- ---------------------------------------------------------------------------
-- Scoring
-- ---------------------------------------------------------------------------

--[[ dead: optional list of {col,row}; the whole group at each point is
     treated as dead and removed before counting.
     Returns {
       black, white       final scores (komi included in white)
       winner             "B", "W" or nil for a draw
       margin             positive number
       text               "B+3.5", "W+0.5" or "0"
       black_territory, white_territory, neutral
       black_stones, white_stones      (after removing dead stones)
       owner              array idx -> "B" | "W" | nil (territory + live stones)
     }
--]]
function Rules:score(dead)
    local cells = {}
    for i = 1, self.n do cells[i] = self.cells[i] end
    local dead_of = { [BLACK] = 0, [WHITE] = 0 }       -- dead stones by owner
    if dead then
        local tmp = setmetatable({ cells = cells, nbr = self.nbr }, Rules)
        for _, p in ipairs(dead) do
            local i = index(self, p[1], p[2])
            if i and cells[i] ~= EMPTY then
                local color = cells[i]
                local stones = group(tmp, i)
                for _, s in ipairs(stones) do
                    cells[s] = EMPTY
                    dead_of[color] = dead_of[color] + 1
                end
            end
        end
    end

    local stones = { [BLACK] = 0, [WHITE] = 0 }
    for i = 1, self.n do
        if cells[i] ~= EMPTY then stones[cells[i]] = stones[cells[i]] + 1 end
    end

    -- empty regions and who borders them
    local terr = { [BLACK] = 0, [WHITE] = 0 }
    local neutral = 0
    local owner = {}
    local region_of = {}
    for i = 1, self.n do
        if cells[i] ~= EMPTY then owner[i] = NAME[cells[i]] end
    end
    for start = 1, self.n do
        if cells[start] == EMPTY and not region_of[start] then
            local region, stack, sp = {}, { start }, 1
            region_of[start] = true
            local touches = { [BLACK] = false, [WHITE] = false }
            while sp > 0 do
                local i = stack[sp]; sp = sp - 1
                region[#region + 1] = i
                local list = self.nbr[i]
                for k = 1, #list do
                    local j = list[k]
                    local v = cells[j]
                    if v == EMPTY then
                        if not region_of[j] then region_of[j] = true; sp = sp + 1; stack[sp] = j end
                    else
                        touches[v] = true
                    end
                end
            end
            local who
            if touches[BLACK] and not touches[WHITE] then who = BLACK
            elseif touches[WHITE] and not touches[BLACK] then who = WHITE end
            if who then
                terr[who] = terr[who] + #region
                for _, i in ipairs(region) do owner[i] = NAME[who] end
            else
                neutral = neutral + #region
            end
        end
    end

    local black, white
    if self.scoring == "territory" then
        -- territory + prisoners (captured on the board + dead stones removed)
        black = terr[BLACK] + self.prisoners[BLACK] + dead_of[WHITE]
        white = terr[WHITE] + self.prisoners[WHITE] + dead_of[BLACK] + self.komi
    else
        black = stones[BLACK] + terr[BLACK]
        white = stones[WHITE] + terr[WHITE] + self.komi
    end

    local diff = black - white
    local winner, text
    if diff > 0 then winner = "B"; text = "B+" .. tostring(diff)
    elseif diff < 0 then winner = "W"; text = "W+" .. tostring(-diff)
    else text = "0" end
    return {
        black = black, white = white, winner = winner,
        margin = math.abs(diff), text = text,
        black_territory = terr[BLACK], white_territory = terr[WHITE],
        neutral = neutral,
        black_stones = stones[BLACK], white_stones = stones[WHITE],
        owner = owner,
    }
end

-- ---------------------------------------------------------------------------
-- Debug helper
-- ---------------------------------------------------------------------------

function Rules:ascii()
    local rows = {}
    for row = 1, self.size do
        local line = {}
        for col = 1, self.size do
            local v = self.cells[(row - 1) * self.size + col]
            line[#line + 1] = (v == BLACK) and "X" or (v == WHITE) and "O" or "."
        end
        rows[#rows + 1] = table.concat(line, " ")
    end
    return table.concat(rows, "\n")
end

return Rules
