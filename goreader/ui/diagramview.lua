--[[
    goreader/ui/diagramview.lua - an interactive Go book diagram.

    Opens over the page where a diagram was tapped. A replay diagram shows
    the slider and the < > ▶ buttons like the original book; a quiz diagram
    lets you tap your answer on the board and the book's own replies follow.
    Only the board and the buttons are redrawn on a change (partial refresh).

        UIManager:show(DiagramView:new{ spec = spec, top = y_of_diagram })
--]]

local InputContainer = require("ui/widget/container/inputcontainer")
local GestureRange   = require("ui/gesturerange")
local UIManager      = require("ui/uimanager")
local Geom           = require("ui/geometry")
local Font           = require("ui/font")
local RenderText     = require("ui/rendertext")
local Blitbuffer     = require("ffi/blitbuffer")
local Screen         = require("device").screen
local Gobooks        = require("goreader.book.gobooks")
local safe           = require("goreader.ui.safe")

local DiagramView = InputContainer:extend{
    name = "goreader_diagramview",
    spec = nil,
    top = nil,                    -- screen y where the diagram was (optional)
    on_close = nil,               -- function() called after closing
    reply_delay = 0.4,            -- seconds, as in the book
    autoplay_delay = 1.0,
}

local WHITE, BLACK = Blitbuffer.COLOR_WHITE, Blitbuffer.COLOR_BLACK
local C_GRAY  = Blitbuffer.Color8(0x80)
local C_DARK  = Blitbuffer.Color8(0x44)
local C_LIGHT = Blitbuffer.Color8(0xDD)

-- Book colour names -> e-ink greys
local COLOURS = {
    black = BLACK, white = WHITE, gray = C_GRAY, grey = C_GRAY,
    green = Blitbuffer.Color8(0x30), red = Blitbuffer.Color8(0x50),
}
local function colour(name, default)
    if not name or name == "none" then return default end
    return COLOURS[name:lower()] or default
end

-- ---------------------------------------------------------------------------
-- Layout (pure arithmetic, also used by tests)
-- ---------------------------------------------------------------------------

--[[ Where everything goes, relative to the widget's top-left.
     input: sw, sh (screen), spec, top (preferred y), pad, button_h ]]
function DiagramView.layout(sw, sh, spec, top, pad, button_h)
    pad = pad or 16
    button_h = button_h or 72
    local caption_h = (spec.caption and spec.caption ~= "") and 44 or 0
    local slider_h = (spec.kind == "replay") and 48 or 0
    local width = sw
    local board_w = width - 2 * pad
    local scale = board_w / spec.width
    local board_h = math.floor(spec.height * scale)
    -- keep the board within about 62% of the screen height
    local max_h = math.floor(sh * 0.62)
    if board_h > max_h then
        scale = max_h / spec.height
        board_h = max_h
        board_w = math.floor(spec.width * scale)
    end
    local height = pad + caption_h + board_h + pad + slider_h + button_h + pad * 6   -- the extra covers the page's own caption
    local y = top and math.max(0, math.min(top, sh - height)) or math.floor((sh - height) / 2)
    local bx = math.floor((width - board_w) / 2)
    local r = {
        x = 0, y = y, w = width, h = height, scale = scale,
        caption = { x = pad, y = pad, w = width - 2 * pad, h = caption_h },
        board = { x = bx, y = pad + caption_h, w = board_w, h = board_h },
    }
    local cy = pad + caption_h + board_h + pad
    if slider_h > 0 then r.slider = { x = pad, y = cy, w = width - 2 * pad, h = slider_h }; cy = cy + slider_h end
    r.buttons_y, r.button_h = cy, button_h
    return r
end

-- Button rows: list of { id, label } for the diagram kind
function DiagramView.buttons_for(kind)
    if kind == "replay" then
        return { { "start", "|<" }, { "prev", "<" }, { "next", ">" }, { "play", "▶" }, { "close", "✕" } }
    end
    return { { "reset", "Reset" }, { "close", "✕" } }
end

-- Frame number for a tap at x on the slider
function DiagramView.slider_frame(x, slider, max)
    local f = (x - slider.x) / slider.w
    f = math.max(0, math.min(1, f))
    return math.floor(f * max + 0.5)
end

-- ---------------------------------------------------------------------------
-- Widget
-- ---------------------------------------------------------------------------

function DiagramView:init()
    local spec = assert(self.spec, "a diagram spec is required")
    self.diagram = Gobooks.Diagram.new(spec)
    if spec.kind == "replay" then self.diagram:to_start() end    -- the book's tap starts from move 0
    self.sw, self.sh = Screen:getWidth(), Screen:getHeight()
    self.lay = DiagramView.layout(self.sw, self.sh, spec, self.top, Screen:scaleBySize(8), Screen:scaleBySize(36))
    self.dimen = Geom:new{ x = 0, y = self.lay.y, w = self.lay.w, h = self.lay.h }
    self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.dimen } } }
    self.key_events = {
        Close = { { "Back" } },
        Next = { { { "RPgFwd", "LPgFwd", "Right" } }, event = "NavKey", args = "next" },
        Prev = { { { "RPgBack", "LPgBack", "Left" } }, event = "NavKey", args = "prev" },
    }
    self.playing = false
    self._buttons = DiagramView.buttons_for(spec.kind)
end

function DiagramView:getSize() return self.dimen end

-- -- drawing helpers -------------------------------------------------------

local function line(bb, x1, y1, x2, y2, w, c)
    w = math.max(1, math.floor(w + 0.5))
    if x1 == x2 then
        bb:paintRect(math.floor(x1 - w / 2 + 0.5), math.floor(math.min(y1, y2) + 0.5), w, math.floor(math.abs(y2 - y1) + 0.5) + 1, c)
    elseif y1 == y2 then
        bb:paintRect(math.floor(math.min(x1, x2) + 0.5), math.floor(y1 - w / 2 + 0.5), math.floor(math.abs(x2 - x1) + 0.5) + 1, w, c)
    else                                                       -- diagonal: step along the longer axis
        local dx, dy = x2 - x1, y2 - y1
        local n = math.max(math.abs(dx), math.abs(dy))
        for i = 0, n do
            local t = n == 0 and 0 or i / n
            bb:paintRect(math.floor(x1 + dx * t - w / 2 + 0.5), math.floor(y1 + dy * t - w / 2 + 0.5), w, w, c)
        end
    end
end

-- Font:getFace() multiplies the size it is given by the screen density, so a
-- size in pixels has to be divided by that factor first.
local SANS = { "NotoSans-Regular.ttf", "DejaVuSans.ttf", "cfont" }
local face_cache = {}
local function sans_face(px)
    local factor = Screen:scaleBySize(100) / 100
    local pt = math.max(6, math.floor(px / factor + 0.5))
    if face_cache[pt] then return face_cache[pt] end
    for _, name in ipairs(SANS) do
        local ok, face = pcall(Font.getFace, Font, name, pt)
        if ok and face then face_cache[pt] = face; return face end
    end
end
DiagramView.sans_face = sans_face

-- Centre `text` on (cx, cy); `px` is the font size in pixels
local function text_centered(bb, cx, cy, text, px, c)
    local face = sans_face(px)
    if not face then return end
    local tw = RenderText:sizeUtf8Text(0, bb:getWidth(), face, text, false, false)
    local width = tw and tw.x or (#text * px * 0.55)
    RenderText:renderUtf8Text(bb, math.floor(cx - width / 2), math.floor(cy + px * 0.36), face, text, false, false, c)
end

-- Draw the diagram's current frame into rect (bx, by) at `scale`
function DiagramView:_paint_diagram(bb, bx, by)
    local s = self.lay.scale
    for _, o in ipairs(self.diagram:ops()) do
        if o.op == "line" then
            line(bb, bx + o.x1 * s, by + o.y1 * s, bx + o.x2 * s, by + o.y2 * s, (o.sw or 1) * s, colour(o.color, BLACK))
        elseif o.op == "circle" then
            local cx, cy, r = bx + o.cx * s, by + o.cy * s, o.r * s
            local stroke, fill = colour(o.stroke), colour(o.fill)
            if stroke then bb:paintCircle(math.floor(cx + 0.5), math.floor(cy + 0.5), math.floor(r + 0.5), stroke) end
            if fill then
                local inner = r - ((stroke and o.sw or 0) * s)
                if inner > 0.5 then bb:paintCircle(math.floor(cx + 0.5), math.floor(cy + 0.5), math.floor(inner + 0.5), fill) end
            end
        elseif o.op == "rect" then
            local stroke = colour(o.stroke)
            if stroke then bb:paintBorder(math.floor(bx + o.x * s), math.floor(by + o.y * s),
                math.floor(o.w * s), math.floor(o.h * s), math.max(1, math.floor((o.sw or 1) * s)), stroke) end
        elseif o.op == "text" then
            text_centered(bb, bx + o.x * s, by + o.y * s, o.text, (o.size or 16) * Gobooks.LABEL_SCALE * s, colour(o.color, BLACK))
        end
    end
end

function DiagramView:_paint_controls(bb, x, y)
    local lay, spec = self.lay, self.spec
    local cy = y + lay.buttons_y
    if lay.slider then
        local sl = lay.slider
        local ty = y + sl.y + math.floor(sl.h / 2)
        bb:paintRect(x + sl.x, ty - 2, sl.w, 4, C_LIGHT)
        local max = self.diagram:max()
        local fx = x + sl.x + (max > 0 and math.floor(sl.w * self.diagram.frame / max) or 0)
        bb:paintRect(x + sl.x, ty - 2, fx - (x + sl.x), 4, C_DARK)
        bb:paintCircle(fx, ty, math.floor(sl.h / 3), BLACK)
        bb:paintCircle(fx, ty, math.floor(sl.h / 3) - 3, WHITE)
        text_centered(bb, x + sl.x + sl.w - 40, ty - sl.h / 2 + 6, self.diagram.frame .. "/" .. max, 22, C_GRAY)
    end
    local n = #self._buttons
    local gap = Screen:scaleBySize(6)
    local bw = math.floor((lay.w - 2 * Screen:scaleBySize(8) - (n - 1) * gap) / n)
    self._button_rects = {}
    for i, b in ipairs(self._buttons) do
        local bx = x + Screen:scaleBySize(8) + (i - 1) * (bw + gap)
        local label = b[2]
        if b[1] == "play" and self.playing then label = "⏸" end
        bb:paintRect(bx, cy, bw, lay.button_h, C_LIGHT)
        bb:paintBorder(bx, cy, bw, lay.button_h, 1, C_GRAY)
        text_centered(bb, bx + bw / 2, cy + lay.button_h / 2, label, lay.button_h * 0.45, BLACK)
        self._button_rects[#self._button_rects + 1] = { id = b[1], x = bx, y = cy, w = bw, h = lay.button_h }
    end
end

function DiagramView:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, self.lay.y
    local lay = self.lay
    local oy = self.lay.y
    bb:paintRect(x, oy, lay.w, lay.h, WHITE)
    bb:paintBorder(x, oy, lay.w, lay.h, 2, BLACK)
    if lay.caption.h > 0 then
        text_centered(bb, x + lay.w / 2, oy + lay.caption.y + lay.caption.h / 2, self.spec.caption, 32, C_DARK)
    end
    self:_paint_diagram(bb, x + lay.board.x, oy + lay.board.y)
    self:_paint_controls(bb, x, oy)
end

-- -- actions ---------------------------------------------------------------

function DiagramView:refresh(region)
    UIManager:setDirty(self, "ui", region or self.dimen)
end

function DiagramView:_board_region()
    return Geom:new{ x = self.lay.board.x, y = self.lay.y + self.lay.board.y, w = self.lay.board.w, h = self.lay.board.h }
end

function DiagramView:_controls_region()
    return Geom:new{ x = 0, y = self.lay.y + self.lay.buttons_y - (self.lay.slider and self.lay.slider.h or 0),
                     w = self.lay.w, h = self.lay.button_h + (self.lay.slider and self.lay.slider.h or 0) }
end

function DiagramView:stop_autoplay()
    if self.playing then
        self.playing = false
        UIManager:unschedule(self._autoplay_step)
    end
end

function DiagramView:_schedule_autoplay()
    self._autoplay_step = self._autoplay_step or function()
        if not self.playing then return end
        if self.diagram.frame >= self.diagram:max() then
            self.playing = false
            self:refresh(self:_controls_region())
            return
        end
        self.diagram:set(self.diagram.frame + 1)
        self:refresh()
        UIManager:scheduleIn(self.autoplay_delay, self._autoplay_step)
    end
    UIManager:scheduleIn(self.autoplay_delay, self._autoplay_step)
end

function DiagramView:do_button(id)
    local d = self.diagram
    if id == "close" then return self:close() end
    if id == "play" then
        if self.playing then self:stop_autoplay()
        else
            if d.frame >= d:max() then d:to_start() end
            self.playing = true
            self:_schedule_autoplay()
        end
        self:refresh()
        return true
    end
    self:stop_autoplay()
    if id == "next" then d:next() elseif id == "prev" then d:prev()
    elseif id == "start" or id == "reset" then d:to_start() end
    self:refresh()
    return true
end

function DiagramView:do_board_tap(px, py)
    local lay = self.lay
    local vx, vy = (px - lay.board.x) / lay.scale, (py - (lay.y + lay.board.y)) / lay.scale
    local r = self.diagram:tap(vx, vy)
    if r.replies then
        local reply = r.replies[math.random(#r.replies)]
        UIManager:scheduleIn(self.reply_delay, function()
            self.diagram:apply(reply)
            self:refresh(self:_board_region())
        end)
    end
    self:refresh(self:_board_region())
end

function DiagramView:onTap(_, ges)
    local p = ges.pos
    local lay = self.lay
    local rel_y = p.y - lay.y
    -- board
    if p.x >= lay.board.x and p.x < lay.board.x + lay.board.w and rel_y >= lay.board.y and rel_y < lay.board.y + lay.board.h then
        if self.spec.kind == "quiz" then self:do_board_tap(p.x, p.y) end
        return true
    end
    -- slider
    if lay.slider and rel_y >= lay.slider.y and rel_y < lay.slider.y + lay.slider.h then
        self:stop_autoplay()
        self.diagram:set(DiagramView.slider_frame(p.x, lay.slider, self.diagram:max()))
        self:refresh()
        return true
    end
    -- buttons
    for _, b in ipairs(self._button_rects or {}) do
        if p.x >= b.x and p.x < b.x + b.w and p.y >= b.y and p.y < b.y + b.h then
            return self:do_button(b.id)
        end
    end
    return true
end

-- The physical page-turn buttons step the diagram like the on-screen ones
function DiagramView:onNavKey(dir)
    if dir == "next" or dir == "prev" then return self:do_button(dir) end
    return true
end

function DiagramView:onClose() return self:close() end

function DiagramView:close()
    self:stop_autoplay()
    UIManager:close(self)
    UIManager:setDirty("all", "ui")             -- repaint the page under us
    if self.on_close then safe(self.on_close) end
    return true
end

return DiagramView
