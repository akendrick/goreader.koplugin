--[[
    goreader/ui/tilescreen.lua - a screen of big square tiles, each with a picture and
    a name: the GOReader home screen and the second-level screens under it.

        TileScreen:new{
            title = "GOReader",
            tiles = { { id = "play", label = "Play", icon = "play" }, ... },
            cols = 4, rows = 4,
            on_select = fn(tile),        -- the screen has been closed when this is called
            on_back = fn() | nil,        -- a second-level screen: "‹ Back" calls this
            on_close = fn() | nil,       -- the top screen: "✕" (or the Back key) closes it
        }
--]]

local InputContainer = require("ui/widget/container/inputcontainer")
local GestureRange   = require("ui/gesturerange")
local UIManager      = require("ui/uimanager")
local Geom           = require("ui/geometry")
local Screen         = require("device").screen
local Kit            = require("goreader.ui.kit")
local Icons          = require("goreader.ui.icons")
local safe           = require("goreader.ui.safe")

local Tiles = InputContainer:extend{
    name = "goreader_tiles", title = "", tiles = {}, cols = 4, rows = 4,
    on_select = nil, on_back = nil, on_close = nil,
}

--[[ Pure layout. Returns { header, cells = { {x,y,w,h, icon = {x,y,size}, label = {x,y,w,h}} ... } } ]]
function Tiles.layout(sw, sh, cols, rows, dp)
    dp = dp or function(n) return n end
    local pad = dp(10)
    local header_h = dp(64)
    local top = header_h + pad
    local cell_w = math.floor((sw - (cols + 1) * pad) / cols)
    local cell_h = math.floor((sh - top - (rows + 1) * pad + pad) / rows)
    local cells = {}
    for r = 0, rows - 1 do
        for c = 0, cols - 1 do
            local x = pad + c * (cell_w + pad)
            local y = top + r * (cell_h + pad)
            local icon = math.min(math.floor(cell_w * 0.62), math.floor(cell_h * 0.52))
            cells[#cells + 1] = {
                x = x, y = y, w = cell_w, h = cell_h,
                icon = { x = x + math.floor((cell_w - icon) / 2), y = y + math.floor(cell_h * 0.10), size = icon },
                label = { x = x + dp(6), y = y + math.floor(cell_h * 0.10) + icon + dp(8), w = cell_w - dp(12),
                          h = cell_h - math.floor(cell_h * 0.10) - icon - dp(14) },
            }
        end
    end
    return { sw = sw, sh = sh, pad = pad, header = { x = 0, y = 0, w = sw, h = header_h }, cells = cells }
end

function Tiles:init()
    self.sw, self.sh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.sw, h = self.sh }
    self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.dimen } } }
    self.key_events = { Back = { { "Back" } } }
    self.lay = Tiles.layout(self.sw, self.sh, self.cols, self.rows, Kit.dp)
    self._rects = { tiles = {} }
end

function Tiles:getSize() return self.dimen end

function Tiles:paintTo(bb, x, y)
    local L = self.lay
    Kit.fill(bb, x, y, self.sw, self.sh, Kit.WHITE)
    self._rects = { tiles = {} }

    -- header
    local hpx = math.floor(L.header.h * 0.44)
    if self.on_back then
        self._rects.back = { x = x, y = y, w = L.header.h * 1.8, h = L.header.h }
        Kit.text_left(bb, x + Kit.dp(12), y + L.header.h / 2, "‹ Back", hpx, Kit.BLACK, true)
    else
        self._rects.close = { x = x + self.sw - L.header.h * 1.4, y = y, w = L.header.h * 1.4, h = L.header.h }
        Kit.text_right(bb, x + self.sw - Kit.dp(16), y + L.header.h / 2, "✕", hpx, Kit.BLACK, true)
    end
    Kit.text_centered(bb, x + self.sw / 2, y + L.header.h / 2, self.title, hpx, Kit.BLACK, true)
    Kit.fill(bb, x, y + L.header.h - 2, self.sw, 2, Kit.BLACK)

    -- tiles
    for i, tile in ipairs(self.tiles) do
        local cell = L.cells[i]
        if not cell then break end
        Kit.fill(bb, x + cell.x, y + cell.y, cell.w, cell.h, Kit.PALE)
        Kit.border(bb, x + cell.x, y + cell.y, cell.w, cell.h, 3, Kit.BLACK)
        Icons.draw(bb, tile.icon, x + cell.icon.x, y + cell.icon.y, cell.icon.size, Kit.PALE)
        local px = math.max(14, math.floor(cell.w * 0.105))
        local lines = Kit.wrap(bb, tile.label, px, cell.label.w, true)
        local line_h = math.floor(px * 1.25)
        local first = cell.label.y + math.max(0, math.floor((cell.label.h - #lines * line_h) / 2))
        for li = 1, math.min(#lines, 3) do
            Kit.text_centered(bb, x + cell.x + cell.w / 2, y + first + (li - 0.5) * line_h, lines[li], px, Kit.BLACK, true)
        end
        self._rects.tiles[#self._rects.tiles + 1] = { x = x + cell.x, y = y + cell.y, w = cell.w, h = cell.h, tile = tile }
    end
end

function Tiles:onTap(_, ges)
    local p = ges.pos
    if self._rects.back and Kit.hit({ self._rects.back }, p.x, p.y) then self:_go_back(); return true end
    if self._rects.close and Kit.hit({ self._rects.close }, p.x, p.y) then self:close(); return true end
    local hit = Kit.hit(self._rects.tiles, p.x, p.y)
    if hit and self.on_select then
        if self.closed then return true end
        self.closed = true
        UIManager:close(self)
        UIManager:setDirty("all", "full")
        safe(self.on_select, hit.tile)
    end
    return true
end

function Tiles:_go_back()
    if self.closed then return end
    self.closed = true
    UIManager:close(self)
    UIManager:setDirty("all", "full")
    if self.on_back then safe(self.on_back) end
end

function Tiles:onBack()
    if self.on_back then self:_go_back() else self:close() end
    return true
end

function Tiles:close()
    if self.closed then return end
    self.closed = true
    UIManager:close(self)
    UIManager:setDirty("all", "full")
    if self.on_close then safe(self.on_close) end
end

return Tiles
