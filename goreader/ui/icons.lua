--[[
    goreader/ui/icons.lua - small black-and-white pictures drawn from rectangles and
    discs, for the tiles of the home screens (no image files to install or load).

        Icons.draw(bb, "gear", x, y, size, bg)      -- (x, y) top-left of a size x size box
        Icons.NAMES                                  -- the pictures there are

    `bg` is the colour behind the picture (for the parts drawn by "erasing").
--]]

local Kit = require("goreader.ui.kit")

local Icons = {}

-- a thick line as a run of small squares
local function line(bb, x1, y1, x2, y2, w, c)
    local dx, dy = x2 - x1, y2 - y1
    local steps = math.max(math.abs(dx), math.abs(dy), 1)
    local half = w / 2
    for i = 0, steps do
        local x, y = x1 + dx * i / steps, y1 + dy * i / steps
        bb:paintRect(math.floor(x - half), math.floor(y - half), math.ceil(w), math.ceil(w), c)
    end
end

local function ring(bb, cx, cy, r, w, c, bg)
    bb:paintCircle(math.floor(cx), math.floor(cy), math.floor(r), c)
    if r - w > 0 then bb:paintCircle(math.floor(cx), math.floor(cy), math.floor(r - w), bg) end
end

local PICTURES = {}

PICTURES.gear = function(d)
    local bb, u, w, bg = d.bb, d.u, d.w, d.bg
    for k = 0, 7 do
        local a = k * math.pi / 4
        bb:paintCircle(math.floor(u(50 + 36 * math.cos(a))), math.floor(u(50 + 36 * math.sin(a), true)), math.floor(u(9, nil, true)), Kit.BLACK)
    end
    bb:paintCircle(math.floor(u(50)), math.floor(u(50, true)), math.floor(u(32, nil, true)), Kit.BLACK)
    bb:paintCircle(math.floor(u(50)), math.floor(u(50, true)), math.floor(u(13, nil, true)), bg)
end

PICTURES.play = function(d)        -- a small board with a black and a white stone
    local bb, u, w, bg = d.bb, d.u, d.w, d.bg
    Kit.border(bb, u(8), u(8, true), u(84, nil, true), u(84, nil, true), w, Kit.BLACK)
    for _, v in ipairs({ 36, 64 }) do
        bb:paintRect(math.floor(u(8)), math.floor(u(v, true)), math.floor(u(84, nil, true)), math.max(1, math.floor(w / 2)), Kit.BLACK)
        bb:paintRect(math.floor(u(v)), math.floor(u(8, true)), math.max(1, math.floor(w / 2)), math.floor(u(84, nil, true)), Kit.BLACK)
    end
    bb:paintCircle(math.floor(u(36)), math.floor(u(36, true)), math.floor(u(15, nil, true)), Kit.BLACK)
    ring(bb, u(64), u(64, true), u(15, nil, true), w, Kit.BLACK, Kit.WHITE)
end

PICTURES.ogs = function(d)         -- a globe
    local bb, u, w, bg = d.bb, d.u, d.w, d.bg
    ring(bb, u(50), u(50, true), u(42, nil, true), w, Kit.BLACK, bg)
    ring(bb, u(50), u(50, true), u(20, nil, true), math.max(2, math.floor(w / 2)), Kit.BLACK, bg)
    bb:paintRect(math.floor(u(8)), math.floor(u(50, true)) - 1, math.floor(u(84, nil, true)), math.max(2, math.floor(w / 2)), Kit.BLACK)
    bb:paintRect(math.floor(u(50)) - 1, math.floor(u(8, true)), math.max(2, math.floor(w / 2)), math.floor(u(84, nil, true)), Kit.BLACK)
end

PICTURES.mail = function(d)        -- an envelope (games by post)
    local bb, u, w = d.bb, d.u, d.w
    Kit.border(bb, u(8), u(22, true), u(84, nil, true), u(58, nil, true), w, Kit.BLACK)
    line(bb, u(8), u(24, true), u(50), u(56, true), w, Kit.BLACK)
    line(bb, u(92), u(24, true), u(50), u(56, true), w, Kit.BLACK)
end

PICTURES.document = function(d)    -- a saved game
    local bb, u, w = d.bb, d.u, d.w
    Kit.border(bb, u(22), u(8, true), u(56, nil, true), u(84, nil, true), w, Kit.BLACK)
    for i = 0, 3 do
        bb:paintRect(math.floor(u(32)), math.floor(u(48 + i * 11, true)), math.floor(u(36, nil, true)), math.max(2, math.floor(w / 2)), Kit.BLACK)
    end
    bb:paintCircle(math.floor(u(50)), math.floor(u(27, true)), math.floor(u(10, nil, true)), Kit.BLACK)
end

PICTURES.book = function(d)
    local bb, u, w = d.bb, d.u, d.w
    Kit.border(bb, u(8), u(18, true), u(42, nil, true), u(64, nil, true), w, Kit.BLACK)
    Kit.border(bb, u(50), u(18, true), u(42, nil, true), u(64, nil, true), w, Kit.BLACK)
    for i = 0, 2 do
        bb:paintRect(math.floor(u(16)), math.floor(u(34 + i * 12, true)), math.floor(u(26, nil, true)), math.max(2, math.floor(w / 2)), Kit.BLACK)
        bb:paintRect(math.floor(u(58)), math.floor(u(34 + i * 12, true)), math.floor(u(26, nil, true)), math.max(2, math.floor(w / 2)), Kit.BLACK)
    end
end

PICTURES.corner = function(d)      -- the corner of a board with a joseki
    local bb, u, w = d.bb, d.u, d.w
    for _, v in ipairs({ 14, 38, 62 }) do
        bb:paintRect(math.floor(u(14)), math.floor(u(v, true)), math.floor(u(78, nil, true)), math.max(2, math.floor(w / 2)), Kit.BLACK)
        bb:paintRect(math.floor(u(v + 14)), math.floor(u(14, true)), math.max(2, math.floor(w / 2)), math.floor(u(78, nil, true)), Kit.BLACK)
    end
    bb:paintRect(math.floor(u(14)), math.floor(u(14, true)), math.floor(u(78, nil, true)), w, Kit.BLACK)
    bb:paintRect(math.floor(u(14)), math.floor(u(14, true)), w, math.floor(u(78, nil, true)), Kit.BLACK)
    bb:paintCircle(math.floor(u(52)), math.floor(u(38, true)), math.floor(u(13, nil, true)), Kit.BLACK)
    ring(bb, u(76), u(62, true), u(13, nil, true), w, Kit.BLACK, Kit.WHITE)
end

PICTURES.puzzle = function(d)      -- a stone with a question mark
    local bb, u = d.bb, d.u
    bb:paintCircle(math.floor(u(50)), math.floor(u(50, true)), math.floor(u(44, nil, true)), Kit.BLACK)
    Kit.text_centered(bb, u(50), u(50, true), "?", math.floor(u(64, nil, true)), Kit.WHITE, true)
end

PICTURES.wifi = function(d)
    local bb, u, w = d.bb, d.u, d.w
    local cx, cy = u(50), u(84, true)
    for _, r in ipairs({ 46, 31, 16 }) do                   -- three arcs above the dot
        local prev
        for deg = -145, -35, 5 do
            local a = math.rad(deg)
            local x, y = cx + u(r, nil, true) * math.cos(a), cy + u(r, nil, true) * math.sin(a)
            if prev then line(bb, prev[1], prev[2], x, y, math.max(3, w), Kit.BLACK) end
            prev = { x, y }
        end
    end
    bb:paintCircle(math.floor(cx), math.floor(cy), math.floor(u(7, nil, true)), Kit.BLACK)
end

PICTURES.check = function(d)       -- a tick in a circle (connection test)
    local bb, u, w, bg = d.bb, d.u, d.w, d.bg
    ring(bb, u(50), u(50, true), u(42, nil, true), w, Kit.BLACK, bg)
    line(bb, u(28), u(52, true), u(44), u(68, true), w + 2, Kit.BLACK)
    line(bb, u(44), u(68, true), u(74), u(33, true), w + 2, Kit.BLACK)
end

PICTURES.pencil = function(d)      -- the SGF editor
    local bb, u, w, bg = d.bb, d.u, d.w, d.bg
    line(bb, u(26), u(74, true), u(74), u(26, true), w * 2, Kit.BLACK)
    line(bb, u(14), u(88, true), u(24), u(76, true), w, Kit.BLACK)
    bb:paintCircle(math.floor(u(80)), math.floor(u(20, true)), math.floor(u(9, nil, true)), Kit.BLACK)
    bb:paintRect(math.floor(u(10)), math.floor(u(90, true)), math.floor(u(40, nil, true)), math.max(2, math.floor(w / 2)), Kit.BLACK)
end

PICTURES.players = function(d)     -- two people: a black and a white stone facing each other
    local bb, u, w = d.bb, d.u, d.w
    bb:paintCircle(math.floor(u(27)), math.floor(u(50, true)), math.floor(u(22, nil, true)), Kit.BLACK)
    ring(bb, u(73), u(50, true), u(22, nil, true), w, Kit.BLACK, Kit.WHITE)
    bb:paintRect(math.floor(u(44)), math.floor(u(48, true)), math.floor(u(12, nil, true)), math.max(2, w), Kit.BLACK)
end

PICTURES.computer = function(d)
    local bb, u, w = d.bb, d.u, d.w
    Kit.border(bb, u(10), u(14, true), u(80, nil, true), u(54, nil, true), w, Kit.BLACK)
    bb:paintCircle(math.floor(u(50)), math.floor(u(41, true)), math.floor(u(13, nil, true)), Kit.BLACK)
    bb:paintRect(math.floor(u(42)), math.floor(u(68, true)), math.floor(u(16, nil, true)), math.floor(u(10, nil, true)), Kit.BLACK)
    bb:paintRect(math.floor(u(28)), math.floor(u(78, true)), math.floor(u(44, nil, true)), math.max(3, math.floor(w)), Kit.BLACK)
end

PICTURES.eye = function(d)         -- watching
    local bb, u, w, bg = d.bb, d.u, d.w, d.bg
    ring(bb, u(50), u(50, true), u(38, nil, true), w, Kit.BLACK, bg)
    bb:paintCircle(math.floor(u(50)), math.floor(u(50, true)), math.floor(u(17, nil, true)), Kit.BLACK)
    bb:paintCircle(math.floor(u(56)), math.floor(u(44, true)), math.floor(u(5, nil, true)), bg)
end

PICTURES.chat = function(d)
    local bb, u, w = d.bb, d.u, d.w
    Kit.border(bb, u(8), u(14, true), u(84, nil, true), u(52, nil, true), w, Kit.BLACK)
    line(bb, u(26), u(66, true), u(22), u(86, true), w, Kit.BLACK)
    line(bb, u(22), u(86, true), u(46), u(66, true), w, Kit.BLACK)
    for _, x in ipairs({ 30, 50, 70 }) do bb:paintCircle(math.floor(u(x)), math.floor(u(40, true)), math.floor(u(6, nil, true)), Kit.BLACK) end
end

Icons.NAMES = {}
for name in pairs(PICTURES) do Icons.NAMES[#Icons.NAMES + 1] = name end
table.sort(Icons.NAMES)

function Icons.draw(bb, name, x, y, size, bg)
    local picture = PICTURES[name]
    bg = bg or Kit.WHITE
    local d = {
        bb = bb, bg = bg, w = math.max(2, math.floor(size * 0.055)),
        -- unit 0..100 -> pixels; `vertical` shifts to the box's top, `length` is a size, not a position
        u = function(v, vertical, length)
            if length then return v * size / 100 end
            return (vertical and y or x) + v * size / 100
        end,
    }
    if not picture then
        bb:paintCircle(math.floor(x + size / 2), math.floor(y + size / 2), math.floor(size * 0.4), Kit.BLACK)
        return
    end
    picture(d)
end

return Icons
