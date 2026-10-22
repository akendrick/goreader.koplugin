--[[
    goreader/ui/kit.lua - drawing helpers shared by every GOReader screen.

    * One sans-serif font everywhere (Noto Sans, falling back).
    * Sizes are given in PIXELS. KOReader multiplies the size passed to
      Font:getFace() by the screen density, so they are converted here.
    * Buttons with clear states (normal, primary, danger, disabled, pressed).
--]]

local Font       = require("ui/font")
local RenderText = require("ui/rendertext")
local Blitbuffer = require("ffi/blitbuffer")
local Screen     = require("device").screen

local Kit = {}

Kit.WHITE = Blitbuffer.COLOR_WHITE
Kit.BLACK = Blitbuffer.COLOR_BLACK
Kit.GRAY  = Blitbuffer.Color8(0x80)
Kit.DARK  = Blitbuffer.Color8(0x44)
Kit.MID   = Blitbuffer.Color8(0xAA)
Kit.LIGHT = Blitbuffer.Color8(0xDD)
Kit.PALE  = Blitbuffer.Color8(0xF0)
Kit.FADE  = Blitbuffer.Color8(0xCC)

-- ---------------------------------------------------------------------------
-- Fonts
-- ---------------------------------------------------------------------------

local REGULAR = { "NotoSans-Regular.ttf", "DejaVuSans.ttf", "cfont" }
local BOLD    = { "NotoSans-Bold.ttf", "DejaVuSans-Bold.ttf", "tfont" }
local cache = {}

local function density() return Screen:scaleBySize(100) / 100 end
Kit.density = density

function Kit.face(px, bold)
    local pt = math.max(6, math.floor(px / density() + 0.5))
    local key = (bold and "b" or "r") .. pt
    if cache[key] then return cache[key] end
    for _, name in ipairs(bold and BOLD or REGULAR) do
        local ok, face = pcall(Font.getFace, Font, name, pt)
        if ok and face then cache[key] = face; return face end
    end
end

-- Screen pixels for a size designed for a ~160 dpi screen
function Kit.dp(n) return Screen:scaleBySize(n) end

-- ---------------------------------------------------------------------------
-- Text
-- ---------------------------------------------------------------------------

function Kit.text_width(bb, text, px, bold)
    local face = Kit.face(px, bold)
    if not face then return #text * px * 0.55 end
    local t = RenderText:sizeUtf8Text(0, bb:getWidth(), face, text, false, bold and true or false)
    return t and t.x or (#text * px * 0.55)
end

-- Cut `text` with an ellipsis so that it fits in max_w pixels
function Kit.fit(bb, text, px, max_w, bold)
    if Kit.text_width(bb, text, px, bold) <= max_w then return text end
    local t = text
    while #t > 1 do
        -- drop one UTF-8 character
        local cut = #t
        while cut > 1 and t:byte(cut) >= 0x80 and t:byte(cut) < 0xC0 do cut = cut - 1 end
        t = t:sub(1, cut - 1)
        if Kit.text_width(bb, t .. "…", px, bold) <= max_w then return t .. "…" end
    end
    return "…"
end

function Kit.text_centered(bb, cx, cy, text, px, color, bold)
    local face = Kit.face(px, bold)
    if not face then return end
    local w = Kit.text_width(bb, text, px, bold)
    RenderText:renderUtf8Text(bb, math.floor(cx - w / 2), math.floor(cy + px * 0.36), face, text,
        false, bold and true or false, color or Kit.BLACK)
end

-- Left-aligned, vertically centred on cy; shortened to max_w when given
function Kit.text_left(bb, x, cy, text, px, color, bold, max_w)
    local face = Kit.face(px, bold)
    if not face then return end
    if max_w then text = Kit.fit(bb, text, px, max_w, bold) end
    RenderText:renderUtf8Text(bb, math.floor(x), math.floor(cy + px * 0.36), face, text,
        false, bold and true or false, color or Kit.BLACK)
end

function Kit.text_right(bb, right, cy, text, px, color, bold, max_w)
    if max_w then text = Kit.fit(bb, text, px, max_w, bold) end
    local w = Kit.text_width(bb, text, px, bold)
    Kit.text_left(bb, right - w, cy, text, px, color, bold)
end

--[[ Word-wrap `text` to max_w pixels. Returns a list of lines (explicit
     newlines are kept). Words longer than a line are broken. ]]
function Kit.wrap(bb, text, px, max_w, bold)
    local lines = {}
    for para in (tostring(text) .. "\n"):gmatch("([^\n]*)\n") do
        if para == "" then lines[#lines + 1] = ""
        else
            local line = ""
            for token in para:gmatch("%S+") do
                local word = token
                local try = line == "" and word or (line .. " " .. word)
                if Kit.text_width(bb, try, px, bold) <= max_w then
                    line = try
                else
                    if line ~= "" then lines[#lines + 1] = line end
                    while Kit.text_width(bb, word, px, bold) > max_w and #word > 1 do
                        local cut = #word
                        while cut > 1 and Kit.text_width(bb, word:sub(1, cut), px, bold) > max_w do cut = cut - 1 end
                        while cut > 1 and word:byte(cut + 1) and word:byte(cut + 1) >= 0x80 and word:byte(cut + 1) < 0xC0 do cut = cut - 1 end
                        lines[#lines + 1] = word:sub(1, cut); word = word:sub(cut + 1)
                    end
                    line = word
                end
            end
            lines[#lines + 1] = line
        end
    end
    return lines
end

-- ---------------------------------------------------------------------------
-- Boxes and buttons
-- ---------------------------------------------------------------------------

function Kit.fill(bb, x, y, w, h, color) bb:paintRect(math.floor(x), math.floor(y), math.floor(w), math.floor(h), color) end
function Kit.border(bb, x, y, w, h, bw, color) bb:paintBorder(math.floor(x), math.floor(y), math.floor(w), math.floor(h), bw or 1, color or Kit.BLACK) end

--[[ style: "normal" | "primary" (black, white bold label) | "danger" (thick
     border) | "disabled" (grey label, no border) | "toggle_on".
     opts.px label size (default h * 0.40), opts.pressed ]]
function Kit.button(bb, x, y, w, h, label, style, opts)
    opts = opts or {}
    style = style or "normal"
    local px = opts.px or math.floor(h * 0.40)
    if style == "primary" then
        Kit.fill(bb, x, y, w, h, Kit.BLACK)
        Kit.text_centered(bb, x + w / 2, y + h / 2, label, px, Kit.WHITE, true)
    elseif style == "disabled" then
        Kit.fill(bb, x, y, w, h, Kit.PALE)
        Kit.border(bb, x, y, w, h, 1, Kit.LIGHT)
        Kit.text_centered(bb, x + w / 2, y + h / 2, label, px, Kit.MID)
    elseif style == "danger" then
        Kit.fill(bb, x, y, w, h, Kit.WHITE)
        Kit.border(bb, x, y, w, h, 4, Kit.BLACK)
        Kit.text_centered(bb, x + w / 2, y + h / 2, label, px, Kit.BLACK, true)
    elseif style == "toggle_on" then
        Kit.fill(bb, x, y, w, h, Kit.DARK)
        Kit.text_centered(bb, x + w / 2, y + h / 2, label, px, Kit.WHITE)
    else
        Kit.fill(bb, x, y, w, h, opts.pressed and Kit.MID or Kit.LIGHT)
        Kit.border(bb, x, y, w, h, 2, Kit.DARK)
        Kit.text_centered(bb, x + w / 2, y + h / 2, label, px, Kit.BLACK)
    end
end

-- Equal-width buttons in a row. items = { {id, label, style}, ... }.
-- Returns the hit rectangles { id, x, y, w, h }.
function Kit.button_row(bb, x, y, w, h, items, gap)
    gap = gap or Kit.dp(8)
    local n = #items
    local bw = math.floor((w - (n - 1) * gap) / n)
    local rects = {}
    for i, it in ipairs(items) do
        local bx = x + (i - 1) * (bw + gap)
        Kit.button(bb, bx, y, bw, h, it[2], it[3])
        rects[#rects + 1] = { id = it[1], x = bx, y = y, w = bw, h = h, enabled = it[3] ~= "disabled" }
    end
    return rects
end

function Kit.hit(rects, px, py)
    for _, r in ipairs(rects or {}) do
        if px >= r.x and px < r.x + r.w and py >= r.y and py < r.y + r.h then return r end
    end
end

return Kit
