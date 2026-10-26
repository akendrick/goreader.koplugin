--[[
    goreader/ui/faceoff_screen.lua - the face-to-face board: Black's strip at
    the top (drawn upside-down, with the thick black line under it), the board in
    the middle, White's strip at the bottom.
--]]

local InputContainer = require("ui/widget/container/inputcontainer")
local GestureRange   = require("ui/gesturerange")
local UIManager      = require("ui/uimanager")
local Geom           = require("ui/geometry")
local Screen         = require("device").screen
local Kit            = require("goreader.ui.kit")
local BoardView      = require("goreader.ui.boardview")

local Faceoff = InputContainer:extend{ name = "goreader_faceoff", controller = nil, on_close = nil }

--[[ Pure layout. Returns { top = strip, line = rect, board = rect(+lay), bottom = strip } ]]
function Faceoff.layout(sw, sh, size, dp)
    dp = dp or function(n) return n end
    local pad = 0
    local strip_h, line_h = math.min(dp(110), math.floor(sh * 0.07)), dp(10)
    local avail = sh - 2 * strip_h - line_h
    local board_w = math.min(sw, avail)                            -- the full width of the screen (labels, when on, are inside it)
    local lay = BoardView.layout(board_w, size, { coords = BoardView.show_coordinates() })
    local board_y = strip_h + line_h + math.floor((avail - lay.height) / 2)
    return {
        sw = sw, sh = sh, pad = pad,
        top = { x = 0, y = 0, w = sw, h = strip_h },
        line = { x = 0, y = strip_h, w = sw, h = line_h },
        board = { x = math.floor((sw - board_w) / 2), y = board_y, w = board_w, h = lay.height, lay = lay },
        bottom = { x = 0, y = sh - strip_h, w = sw, h = strip_h },
    }
end

function Faceoff:init()
    self.sw, self.sh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.sw, h = self.sh }
    self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.dimen } } }
    self.key_events = { Back = { { "Back" } } }
    self._rects = { B = {}, W = {} }
    self:update(true)
end

function Faceoff:update(no_refresh)
    self.st = self.controller:state()
    self.lay = Faceoff.layout(self.sw, self.sh, self.st.board.size, Kit.dp)
    if not no_refresh then UIManager:setDirty(self, "ui") end
end

function Faceoff:getSize() return self.dimen end

-- One strip drawn with its top-left at (ox, oy). Returns the button rects.
local function draw_strip(bb, ox, oy, w, h, side, strip)
    Kit.fill(bb, ox, oy, w, h, strip.active and Kit.LIGHT or Kit.WHITE)
    local tpx = math.floor(h * 0.20)
    local who = side == "B" and "Black" or "White"
    local gap = Kit.dp(14)
    Kit.text_left(bb, ox + gap, oy + h * 0.22, who, tpx, Kit.BLACK, true)
    local room = w - 2 * gap - Kit.text_width(bb, who, tpx, true) - Kit.dp(24)
    Kit.text_right(bb, ox + w - gap, oy + h * 0.22, strip.text, tpx, Kit.BLACK, strip.active, room)
    local items = {}
    for _, b in ipairs(strip.buttons) do
        items[#items + 1] = { b.id, b.label, b.style or ((b.enabled == false) and "disabled") or "normal" }
    end
    return Kit.button_row(bb, ox + Kit.dp(8), oy + math.floor(h * 0.42), w - Kit.dp(16), math.floor(h * 0.48), items, Kit.dp(8))
end

function Faceoff:paintTo(bb, x, y)
    local st, L = self.st, self.lay
    Kit.fill(bb, x, y, self.sw, self.sh, Kit.WHITE)
    self._rects = { B = {}, W = {} }

    -- Black's side: upside-down, so it reads correctly to the player across the table
    Kit.flipped(bb, x + L.top.x, y + L.top.y, L.top.w, L.top.h, function(tmp)
        for _, r in ipairs(draw_strip(tmp, 0, 0, L.top.w, L.top.h, "B", st.strips.B)) do
            local sx, sy, w, h = Kit.mirror_rect(x + L.top.x, y + L.top.y, L.top.w, L.top.h, r.x, r.y, r.w, r.h)
            self._rects.B[#self._rects.B + 1] = { id = r.id, x = sx, y = sy, w = w, h = h, enabled = r.enabled }
        end
    end)
    Kit.fill(bb, x + L.line.x, y + L.line.y, L.line.w, L.line.h, Kit.BLACK)        -- Black's side of the board

    BoardView.paint(bb, x + L.board.x, y + L.board.y, L.board.lay, st.board, {})

    for _, r in ipairs(draw_strip(bb, x + L.bottom.x, y + L.bottom.y, L.bottom.w, L.bottom.h, "W", st.strips.W)) do
        self._rects.W[#self._rects.W + 1] = r
    end
end

function Faceoff:_act(fn)
    fn()
    if self.closed then return end
    self:update()
end

function Faceoff:onTap(_, ges)
    local p = ges.pos
    local L = self.lay
    for _, side in ipairs({ "B", "W" }) do
        local hit = Kit.hit(self._rects[side], p.x, p.y)
        if hit then
            if hit.enabled ~= false then self:_act(function() self.controller:button(side, hit.id) end) end
            return true
        end
    end
    local b = L.board
    if p.x >= b.x and p.x < b.x + b.w and p.y >= b.y and p.y < b.y + b.h then
        local col, row = BoardView.point_at(b.lay, p.x - b.x, p.y - b.y)
        if col then self:_act(function() self.controller:board_tap(col, row) end) end
    end
    return true
end

function Faceoff:onBack()
    local close = self.controller:back()
    if close ~= false then self:close() end
    return true
end

function Faceoff:close()
    if self.closed then return end
    self.closed = true
    UIManager:close(self)
    UIManager:setDirty("all", "full")
    if self.on_close then Kit.safe(self.on_close) end
end

return Faceoff
