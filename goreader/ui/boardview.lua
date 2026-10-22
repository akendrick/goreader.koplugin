--[[
    goreader/ui/boardview.lua - draws a Go position. No state of its own.

        local lay = BoardView.layout(width, size, {coords = true})
        BoardView.paint(bb, x, y, lay, state, opts)
        local col, row = BoardView.point_at(lay, px - x, py - y)

    state = {
      size, board = rows of "B"/"W"/false,            required
      last   = { col, row, color } | { pass = true },   marker on the last move
      marks  = { {kind="TR"|"SQ"|"CR"|"MA"|"LB", col,row,text} },
      focus  = { col,row,color },   fade everything, draw this stone at full strength
      candidates = { {col,row,label,winrate,played} }, engine suggestions (A, B, ...)
      variations = { {col,row,label} },                 next-move choices (A, B, ...)
      dead   = { ["c,r"] = true },                      stones marked dead (scoring)
      territory = { ["c,r"] = "B"|"W" },                scoring overlay
      numbers = { ["c,r"] = n },                        move numbers on stones
    }
--]]

local Kit = require("goreader.ui.kit")

local BoardView = {}

local STARS = {
    [9]  = { { 3, 3 }, { 7, 3 }, { 5, 5 }, { 3, 7 }, { 7, 7 } },
    [13] = { { 4, 4 }, { 10, 4 }, { 7, 7 }, { 4, 10 }, { 10, 10 } },
    [19] = { { 4, 4 }, { 10, 4 }, { 16, 4 }, { 4, 10 }, { 10, 10 }, { 16, 10 }, { 4, 16 }, { 10, 16 }, { 16, 16 } },
}
local LETTERS = "ABCDEFGHJKLMNOPQRST"

-- ---------------------------------------------------------------------------
-- Geometry
-- ---------------------------------------------------------------------------

function BoardView.layout(width, size, opts)
    opts = opts or {}
    local label = (opts.coords ~= false) and math.floor(width * 0.045) or 0
    local cell = (width - label) / size
    return {
        width = width, size = size, label = label, cell = cell,
        ox = label + cell / 2, oy = label + cell / 2,        -- first intersection
        r = math.floor(cell * 0.47),
        height = math.floor(label + cell * size),
        coords = label > 0,
    }
end

function BoardView.px(lay, col, row)
    return math.floor(lay.ox + (col - 1) * lay.cell + 0.5), math.floor(lay.oy + (row - 1) * lay.cell + 0.5)
end

-- (col,row) for a point relative to the board's top-left, or nil
function BoardView.point_at(lay, rx, ry)
    local col = math.floor((rx - lay.ox) / lay.cell + 0.5) + 1
    local row = math.floor((ry - lay.oy) / lay.cell + 0.5) + 1
    if col < 1 or col > lay.size or row < 1 or row > lay.size then return nil end
    return col, row
end

-- ---------------------------------------------------------------------------
-- Painting
-- ---------------------------------------------------------------------------

local function disc(bb, cx, cy, r, color) if r > 0 then bb:paintCircle(cx, cy, r, color) end end

local function stone(bb, cx, cy, r, colour, ink, thick)
    if colour == "B" then
        disc(bb, cx, cy, r, ink)
    else
        disc(bb, cx, cy, r, ink)
        disc(bb, cx, cy, r - (thick or math.max(2, math.floor(r * 0.12))), Kit.WHITE)
    end
end

local function mark(bb, cx, cy, r, kind, on_black, color)
    local m = math.floor(r * 0.55)
    local c = color or (on_black and Kit.WHITE or Kit.BLACK)
    local t = math.max(2, math.floor(r * 0.12))
    if kind == "SQ" then
        Kit.border(bb, cx - m, cy - m, m * 2, m * 2, t, c)
    elseif kind == "CR" then
        disc(bb, cx, cy, m, c); disc(bb, cx, cy, m - t, on_black and Kit.BLACK or Kit.WHITE)
    elseif kind == "TR" then
        for i = 0, m * 2 do                               -- an outlined triangle, drawn as three edges
            local y = cy - m + i
            local half = math.floor(i / 2)
            bb:paintRect(cx - half, y, t, t, c); bb:paintRect(cx + half - t + 1, y, t, t, c)
        end
        bb:paintRect(cx - m, cy + m, m * 2, t, c)
    elseif kind == "MA" then
        for i = -m, m do
            bb:paintRect(cx + i, cy + i, t, t, c); bb:paintRect(cx + i, cy - i, t, t, c)
        end
    end
end

--[[ opts: show_numbers (bool). Returns nothing. (x, y) is the top-left of the board area. ]]
function BoardView.paint(bb, x, y, lay, state, opts)
    opts = opts or {}
    local size, cell, r = lay.size, lay.cell, lay.r
    local focus = state.focus
    local ink = focus and Kit.FADE or Kit.BLACK              -- the "20% gray" look while confirming
    local board_bg = focus and Kit.WHITE or Kit.FADE

    Kit.fill(bb, x, y, lay.width, lay.height, Kit.WHITE)
    -- board surface
    Kit.fill(bb, x + lay.label, y + lay.label, lay.width - lay.label, lay.height - lay.label, board_bg)

    -- grid
    local x0, y0 = BoardView.px(lay, 1, 1)
    local x1, y1 = BoardView.px(lay, size, size)
    local gw = math.max(1, math.floor(cell / 22))
    for i = 1, size do
        local px = BoardView.px(lay, i, 1)
        local _, py = BoardView.px(lay, 1, i)
        local w = (i == 1 or i == size) and gw + 1 or gw
        Kit.fill(bb, x + px - math.floor(w / 2), y + y0, w, y1 - y0 + 1, ink)
        Kit.fill(bb, x + x0, y + py - math.floor(w / 2), x1 - x0 + 1, w, ink)
    end
    for _, s in ipairs(STARS[size] or {}) do
        local sx, sy = BoardView.px(lay, s[1], s[2])
        disc(bb, x + sx, y + sy, math.max(2, math.floor(cell * 0.11)), ink)
    end

    -- coordinates along the top and left edges
    if lay.coords then
        local px = math.max(10, math.floor(lay.label * 0.62))
        for i = 1, size do
            local cx, cy = BoardView.px(lay, i, i)
            Kit.text_centered(bb, x + cx, y + lay.label * 0.5, LETTERS:sub(i, i), px, focus and Kit.FADE or Kit.GRAY)
            Kit.text_centered(bb, x + lay.label * 0.5, y + cy, tostring(size - i + 1), px, focus and Kit.FADE or Kit.GRAY)
        end
    end

    -- territory (scoring)
    for key, owner in pairs(state.territory or {}) do
        local c, rw = key:match("^(%d+),(%d+)$")
        local sx, sy = BoardView.px(lay, tonumber(c), tonumber(rw))
        local m = math.floor(cell * 0.18)
        Kit.fill(bb, x + sx - m, y + sy - m, m * 2, m * 2, owner == "B" and Kit.BLACK or Kit.WHITE)
        if owner == "W" then Kit.border(bb, x + sx - m, y + sy - m, m * 2, m * 2, 2, Kit.BLACK) end
    end

    -- stones
    local thick = math.max(2, math.floor(r * 0.12))
    for row = 1, size do
        local line = state.board[row]
        for col = 1, size do
            local c = line and line[col]
            if c then
                local sx, sy = BoardView.px(lay, col, row)
                local dead = state.dead and state.dead[col .. "," .. row]
                stone(bb, x + sx, y + sy, r, c, dead and Kit.MID or ink, thick)
                if dead then                                    -- X over a dead stone
                    mark(bb, x + sx, y + sy, r, "MA", c == "B", Kit.BLACK)
                end
                local n = opts.show_numbers and state.numbers and state.numbers[col .. "," .. row]
                if n then
                    Kit.text_centered(bb, x + sx, y + sy, tostring(n), math.floor(r * (n > 99 and 0.8 or 1.0)),
                        c == "B" and Kit.WHITE or Kit.BLACK)
                end
            end
        end
    end

    -- the pending move at full strength
    if focus then
        local sx, sy = BoardView.px(lay, focus.col, focus.row)
        stone(bb, x + sx, y + sy, r, focus.color, Kit.BLACK, math.max(4, math.floor(r * 0.24)))
        return
    end

    -- last move: a clear ring on the stone (white ring on black, black ring on white)
    local last = state.last
    if last and last.col then
        local sx, sy = BoardView.px(lay, last.col, last.row)
        local ring_r = math.max(5, math.floor(r * 0.58))
        local ring_w = math.max(4, math.floor(r * 0.16))
        local fill = last.color == "B" and Kit.BLACK or Kit.WHITE
        local line = last.color == "B" and Kit.WHITE or Kit.BLACK
        disc(bb, x + sx, y + sy, ring_r, line)
        disc(bb, x + sx, y + sy, ring_r - ring_w, fill)
    end

    -- SGF marks
    for _, m in ipairs(state.marks or {}) do
        local sx, sy = BoardView.px(lay, m.col, m.row)
        local on = state.board[m.row] and state.board[m.row][m.col]
        if m.kind == "LB" then
            if not on then Kit.fill(bb, x + sx - r, y + sy - r, r * 2, r * 2, Kit.FADE) end
            Kit.text_centered(bb, x + sx, y + sy, m.text or "", math.floor(r * 1.1), on == "B" and Kit.WHITE or Kit.BLACK, true)
        else
            mark(bb, x + sx, y + sy, r, m.kind, on == "B")
        end
    end

    -- engine candidates and variation choices: a lettered disc
    local function letter(c, played)
        local sx, sy = BoardView.px(lay, c.col, c.row)
        disc(bb, x + sx, y + sy, r, Kit.BLACK)
        disc(bb, x + sx, y + sy, r - 3, played and Kit.LIGHT or Kit.WHITE)
        Kit.text_centered(bb, x + sx, y + sy, c.label or "?", math.floor(r * 1.15), Kit.BLACK, true)
    end
    for _, c in ipairs(state.variations or {}) do if c.col then letter(c) end end
    for _, c in ipairs(state.candidates or {}) do if c.col then letter(c, c.played) end end
end

return BoardView
