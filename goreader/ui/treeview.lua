--[[
    goreader/ui/treeview.lua - the variation tree as a full-screen picture.

    Moves are circles in a grid: the main line along the top row, each
    variation on a row of its own under the fork. Tap a move to go there.
    The buttons at the bottom pan the view; it opens centred on the current move.

        UIManager:show(TreeView:new{ model = ReviewModel, on_close = fn })
--]]

local InputContainer = require("ui/widget/container/inputcontainer")
local GestureRange   = require("ui/gesturerange")
local UIManager      = require("ui/uimanager")
local Geom           = require("ui/geometry")
local Screen         = require("device").screen
local Kit            = require("goreader.ui.kit")
local TreeLayout     = require("goreader.ui.treelayout")

local TreeView = InputContainer:extend{ name = "goreader_treeview", model = nil, on_close = nil }

-- ---------------------------------------------------------------------------
-- Geometry (pure)
-- ---------------------------------------------------------------------------

--[[ Where the grid is drawn and how many cells fit.
     sw, sh screen; header / footer heights in pixels. ]]
function TreeView.geometry(sw, sh, header_h, footer_h, cell)
    local gy = header_h
    local gh = sh - header_h - footer_h
    return { x = 0, y = gy, w = sw, h = gh, cell = cell,
             cols = math.max(1, math.floor(sw / cell)), rows = math.max(1, math.floor(gh / cell)) }
end

--[[ Scroll offset (first visible column, row) that puts grid cell (col,row) in
     the middle of the view, kept inside the tree. ]]
function TreeView.centre_on(geo, layout, col, row)
    local c0 = math.floor(col - geo.cols / 2 + 0.5)
    local r0 = math.floor(row - geo.rows / 2 + 0.5)
    c0 = math.max(0, math.min(math.max(0, layout.cols - geo.cols), c0))
    r0 = math.max(0, math.min(math.max(0, layout.rows - geo.rows), r0))
    return c0, r0
end

function TreeView.clamp(geo, layout, c0, r0)
    return math.max(0, math.min(math.max(0, layout.cols - geo.cols), c0)),
           math.max(0, math.min(math.max(0, layout.rows - geo.rows), r0))
end

-- ---------------------------------------------------------------------------
-- Widget
-- ---------------------------------------------------------------------------

function TreeView:init()
    self.sw, self.sh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.sw, h = self.sh }
    self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.dimen } } }
    self.key_events = { Close = { { "Back" } } }
    self.layout = TreeLayout.build(self.model.game)
    self.links = TreeLayout.links(self.layout)
    self.geo = TreeView.geometry(self.sw, self.sh, Kit.dp(48), Kit.dp(56), Kit.dp(78))
    local cur = self.layout.index[self.model.game.current] or 1
    local n = self.layout.nodes[cur]
    self.c0, self.r0 = TreeView.centre_on(self.geo, self.layout, n.col, n.row)
end

function TreeView:getSize() return self.dimen end

local function cell_xy(self, col, row)
    local g = self.geo
    return g.x + (col - self.c0 + 0.5) * g.cell, g.y + (row - self.r0 + 0.5) * g.cell
end

function TreeView:paintTo(bb, x, y)
    local g, L = self.geo, self.layout
    Kit.fill(bb, x, y, self.sw, self.sh, Kit.WHITE)
    -- header
    local h = Kit.dp(48)
    Kit.text_left(bb, x + Kit.dp(12), y + h / 2, "‹ Back", math.floor(h * 0.42), Kit.BLACK, true)
    Kit.text_centered(bb, x + self.sw / 2, y + h / 2, "Variation tree", math.floor(h * 0.42), Kit.BLACK, true)
    Kit.fill(bb, x, y + h - 2, self.sw, 2, Kit.BLACK)
    self._back_rect = { x = x, y = y, w = h * 1.6, h = h }

    local cur = L.index[self.model.game.current]
    -- links first, so the circles sit on top
    local lw = math.max(2, Kit.dp(2))
    for _, l in ipairs(self.links) do
        local x1, y1 = cell_xy(self, l[1], l[2])
        local x2, y2 = cell_xy(self, l[3], l[4])
        if x1 == x2 then
            Kit.fill(bb, x + math.min(x1, x2) - lw / 2, y + math.min(y1, y2), lw, math.abs(y2 - y1) + 1, Kit.GRAY)
        else
            Kit.fill(bb, x + math.min(x1, x2), y + math.min(y1, y2) - lw / 2, math.abs(x2 - x1) + 1, lw, Kit.GRAY)
        end
    end
    local r = math.floor(g.cell * 0.36)
    for i, n in ipairs(L.nodes) do
        if n.col >= self.c0 - 1 and n.col <= self.c0 + g.cols and n.row >= self.r0 - 1 and n.row <= self.r0 + g.rows then
            local cx, cy = cell_xy(self, n.col, n.row)
            cx, cy = x + cx, y + cy
            if cy > y + g.y - r and cy < y + g.y + g.h + r then
                if i == cur then bb:paintCircle(math.floor(cx), math.floor(cy), r + Kit.dp(5), Kit.BLACK)
                                 bb:paintCircle(math.floor(cx), math.floor(cy), r + Kit.dp(2), Kit.WHITE) end
                if n.color == "B" then
                    bb:paintCircle(math.floor(cx), math.floor(cy), r, Kit.BLACK)
                elseif n.color == "W" then
                    bb:paintCircle(math.floor(cx), math.floor(cy), r, Kit.BLACK)
                    bb:paintCircle(math.floor(cx), math.floor(cy), r - 3, Kit.WHITE)
                else
                    Kit.border(bb, cx - r * 0.7, cy - r * 0.7, r * 1.4, r * 1.4, 2, Kit.BLACK)
                end
                local label = n.color and tostring(n.number) or "S"
                Kit.text_centered(bb, cx, cy, label, math.floor(r * (#label > 2 and 0.85 or 1.05)),
                    n.color == "B" and Kit.WHITE or Kit.BLACK, true)
            end
        end
    end
    -- footer
    local fy = y + self.sh - Kit.dp(56)
    self._buttons = Kit.button_row(bb, x + Kit.dp(8), fy + Kit.dp(6), self.sw - Kit.dp(16), Kit.dp(44), {
        { "left", "◂" }, { "right", "▸" }, { "up", "▴" }, { "down", "▾" }, { "close", "Close", "primary" },
    }, Kit.dp(6))
end

function TreeView:refresh() UIManager:setDirty(self, "ui") end

function TreeView:pan(dc, dr)
    self.c0, self.r0 = TreeView.clamp(self.geo, self.layout, self.c0 + dc, self.r0 + dr)
    self:refresh()
end

function TreeView:node_at_screen(px, py)
    local g = self.geo
    if py < g.y or py >= g.y + g.h then return nil end
    local col = (px - g.x) / g.cell + self.c0 - 0.5
    local row = (py - g.y) / g.cell + self.r0 - 0.5
    return TreeLayout.node_at(self.layout, col, row, 0.5)
end

function TreeView:onTap(_, ges)
    local p = ges.pos
    if self._back_rect and p.y < self._back_rect.h and p.x < self._back_rect.w then return self:close() end
    local b = Kit.hit(self._buttons, p.x, p.y)
    if b then
        local step_c, step_r = math.max(1, math.floor(self.geo.cols / 2)), math.max(1, math.floor(self.geo.rows / 2))
        if b.id == "left" then self:pan(-step_c, 0)
        elseif b.id == "right" then self:pan(step_c, 0)
        elseif b.id == "up" then self:pan(0, -step_r)
        elseif b.id == "down" then self:pan(0, step_r)
        else self:close() end
        return true
    end
    local i = self:node_at_screen(p.x, p.y)
    if i then
        self.model.game:go_to_node(self.layout.nodes[i].node)      -- go there, then back to the board
        return self:close()
    end
    return true
end

function TreeView:onClose() return self:close() end

function TreeView:close()
    UIManager:close(self)
    UIManager:setDirty("all", "full")
    if self.on_close then self.on_close() end
    return true
end

return TreeView
