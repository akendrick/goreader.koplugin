--[[
    goreader/ui/gridscreen.lua - a page of game thumbnails (2 x 3 on the Forma).
    Each cell shows the board as it stands now, the opponent and whose move it
    is. Tap a cell to open that game.

        GridScreen:new{
            title = "Dragon Go Server", items = {
                { id, title, subtitle, mine = bool, board = {size, board, last} } },
            on_select = fn(item), on_close = fn(),
            buttons = { {id="list", label="List"}, {id="reload", label="Reload"} },   -- after Prev / page / Next
            on_button = fn(id),                 (on_list / on_reload still work for those two)
            cols = 2, rows = 3, compact = false, -- compact: smaller caption text
        }
    An item's board may be a function returning the board: it is only called when the item is
    first drawn, so a long list costs nothing until its page is shown.
--]]

local InputContainer = require("ui/widget/container/inputcontainer")
local GestureRange   = require("ui/gesturerange")
local UIManager      = require("ui/uimanager")
local Geom           = require("ui/geometry")
local Screen         = require("device").screen
local Kit            = require("goreader.ui.kit")
local BoardView      = require("goreader.ui.boardview")

local Grid = InputContainer:extend{
    name = "goreader_grid", title = "", items = {}, cols = 2, rows = 3,
    page = 1, on_select = nil, on_list = nil, on_reload = nil, on_close = nil,
    buttons = nil, on_button = nil, compact = false,
}

--[[ Pure layout. Returns { header, footer, cells = { {x,y,w,h, board = {x,y,w}, caption = {x,y,w,h}} ... }, per_page } ]]
function Grid.layout(sw, sh, cols, rows, dp)
    dp = dp or function(n) return n end
    local pad = dp(10)
    local header_h, footer_h = dp(64), dp(84)
    local caption_h = dp(70)
    local top = header_h + pad
    local cell_w = math.floor((sw - (cols + 1) * pad) / cols)
    local cell_h = math.floor((sh - header_h - footer_h - (rows + 1) * pad) / rows)
    local cells = {}
    for r = 0, rows - 1 do
        for c = 0, cols - 1 do
            local x = pad + c * (cell_w + pad)
            local y = top + r * (cell_h + pad)
            local bw = math.min(cell_w - dp(12), cell_h - caption_h - dp(8))
            cells[#cells + 1] = {
                x = x, y = y, w = cell_w, h = cell_h,
                board = { x = x + math.floor((cell_w - bw) / 2), y = y + dp(6), w = bw },
                caption = { x = x + dp(8), y = y + dp(6) + bw + dp(2), w = cell_w - dp(16), h = caption_h },
            }
        end
    end
    return { sw = sw, sh = sh, pad = pad,
             header = { x = 0, y = 0, w = sw, h = header_h },
             footer = { x = 0, y = sh - footer_h, w = sw, h = footer_h },
             cells = cells, per_page = cols * rows }
end

function Grid:init()
    self.sw, self.sh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.sw, h = self.sh }
    self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.dimen } } }
    self.key_events = {
        Back = { { "Back" } },
        Next = { { { "RPgFwd", "LPgFwd" } }, event = "NavKey", args = "next" },
        Prev = { { { "RPgBack", "LPgBack" } }, event = "NavKey", args = "prev" },
    }
    self.lay = Grid.layout(self.sw, self.sh, self.cols, self.rows, Kit.dp)
    self._rects = { cells = {}, buttons = {} }
    self.buttons = self.buttons or { { id = "list", label = "List" }, { id = "reload", label = "Reload" } }
end

function Grid:page_count() return math.max(1, math.ceil(#self.items / self.lay.per_page)) end
function Grid:getSize() return self.dimen end

function Grid:set_items(items)
    self.items = items
    if self.page > self:page_count() then self.page = self:page_count() end
    UIManager:setDirty(self, "ui")
end

function Grid:goto_page(p)
    p = math.max(1, math.min(self:page_count(), p))
    if p == self.page then return end
    self.page = p
    UIManager:setDirty(self, "ui")
end

function Grid:onNavKey(dir)
    self:goto_page(self.page + (dir == "next" and 1 or -1))
    return true
end

function Grid:_paint_cell(bb, x, y, cell, item)
    local thick = item.mine and 5 or 2
    Kit.border(bb, x + cell.x, y + cell.y, cell.w, cell.h, thick, Kit.BLACK)
    local b = item.board
    if type(b) == "function" then
        local ok, made = pcall(b)
        b = ok and made or false
        item.board = b
    end
    if b then
        local lay = BoardView.layout(cell.board.w, b.size, { coords = false })
        BoardView.paint(bb, x + cell.board.x, y + cell.board.y, lay, b, {})
    end
    local c = cell.caption
    local px = math.floor(c.h * (self.compact and 0.28 or 0.36))
    Kit.text_left(bb, x + c.x, y + c.y + c.h * 0.28, item.title or "", px, Kit.BLACK, not self.compact, c.w)
    Kit.text_left(bb, x + c.x, y + c.y + c.h * 0.74, item.subtitle or "", math.floor(px * (self.compact and 1.0 or 0.88)), item.mine and Kit.BLACK or Kit.DARK, item.mine or self.compact, c.w)
end

function Grid:paintTo(bb, x, y)
    local L = self.lay
    Kit.fill(bb, x, y, self.sw, self.sh, Kit.WHITE)
    self._rects = { cells = {}, buttons = {} }

    -- header
    local hpx = math.floor(L.header.h * 0.44)
    self._rects.back = { x = x, y = y, w = L.header.h * 1.8, h = L.header.h }
    Kit.text_left(bb, x + Kit.dp(12), y + L.header.h / 2, "‹ Back", hpx, Kit.BLACK, true)
    Kit.text_centered(bb, x + self.sw / 2, y + L.header.h / 2, Kit.fit(bb, self.title, hpx, self.sw - 2 * L.header.h * 1.8, true), hpx, Kit.BLACK, true)
    Kit.fill(bb, x, y + L.header.h - 2, self.sw, 2, Kit.BLACK)

    -- cells for this page
    local first = (self.page - 1) * L.per_page
    for i = 1, L.per_page do
        local item, cell = self.items[first + i], L.cells[i]
        if item then
            self:_paint_cell(bb, x, y, cell, item)
            self._rects.cells[#self._rects.cells + 1] = { x = x + cell.x, y = y + cell.y, w = cell.w, h = cell.h, item = item }
        end
    end

    -- footer
    local f = L.footer
    local more = self:page_count() > 1
    local items = {
        { "prev", "‹ Prev", (more and self.page > 1) and "normal" or "disabled" },
        { "page", self.page .. " / " .. self:page_count(), "disabled" },
        { "next", "Next ›", (more and self.page < self:page_count()) and "normal" or "disabled" },
    }
    for _, b in ipairs(self.buttons) do items[#items + 1] = { b.id, b.label, b.style or "normal" } end
    self._rects.buttons = Kit.button_row(bb, x + L.pad, y + f.y + Kit.dp(8), self.sw - 2 * L.pad, f.h - Kit.dp(16), items, Kit.dp(8))
end

function Grid:onTap(_, ges)
    local p = ges.pos
    if self._rects.back and Kit.hit({ self._rects.back }, p.x, p.y) then self:close(); return true end
    local b = Kit.hit(self._rects.buttons, p.x, p.y)
    if b then
        if b.enabled == false or b.id == "page" then return true end
        if b.id == "prev" then self:goto_page(self.page - 1)
        elseif b.id == "next" then self:goto_page(self.page + 1)
        else
            local fn = (self.on_button and function() self.on_button(b.id) end)
                or (b.id == "list" and self.on_list) or (b.id == "reload" and self.on_reload)
            if fn then self:_leave(fn) end
        end
        return true
    end
    local cell = Kit.hit(self._rects.cells, p.x, p.y)
    if cell and self.on_select then self:_leave(function() self.on_select(cell.item) end) end
    return true
end

-- Close this page, then do what was asked (the caller shows the next screen)
function Grid:_leave(fn)
    if self.closed then return end
    self.closed = true
    UIManager:close(self)
    UIManager:setDirty("all", "full")
    Kit.safe(fn)
end

function Grid:onBack() self:close(); return true end

function Grid:close()
    if self.closed then return end
    self.closed = true
    UIManager:close(self)
    UIManager:setDirty("all", "full")
    if self.on_close then Kit.safe(self.on_close) end
end

return Grid
