--[[
    goreader/ui/gamescreen.lua - the full-screen game view used by Dragon Go
    Server, OGS, review and play. It draws what a controller describes and
    passes taps back; it knows nothing about any server.

    controller:state() returns
      { title, counter ("36 / 230"),
        black = { name, rank, captures, clock }, white = { ... }, to_move = "B"|"W",
        board = BoardView state, show_numbers = bool,
        status = "Your move (Black)", comment = "...",
        bottom = { kind = "buttons", rows = { { {id,label,style}, ... }, ... } }
              or { kind = "confirm", prompt, ok = "CONFIRM MOVE", cancel = "Cancel" },
        busy = bool }
    controller:board_tap(col, row)      controller:button(id)
    controller:back() -> true to close  controller:menu()  (optional)
    controller:tick(now) (optional, called about once a second while shown)

    The confirmation dialog sits directly below the board, which fades to 20%
    gray with the move being confirmed in full black (BoardView focus).
--]]

local InputContainer = require("ui/widget/container/inputcontainer")
local GestureRange   = require("ui/gesturerange")
local UIManager      = require("ui/uimanager")
local Geom           = require("ui/geometry")
local Screen         = require("device").screen
local Kit            = require("goreader.ui.kit")
local BoardView      = require("goreader.ui.boardview")

local GameScreen = InputContainer:extend{
    name = "goreader_gamescreen",
    controller = nil,
    on_close = nil,
    tick_seconds = 1,
}

-- ---------------------------------------------------------------------------
-- Layout (pure)
-- ---------------------------------------------------------------------------

--[[ sw, sh: screen; st: the controller's state (to know what is at the bottom);
     dp: function converting design pixels. Returns rectangles. ]]
function GameScreen.layout(sw, sh, st, dp)
    dp = dp or function(n) return n end
    local pad = dp(8)
    local r = { pad = pad, sw = sw, sh = sh }
    local y = 0
    r.header = { x = 0, y = y, w = sw, h = dp(48) }; y = y + r.header.h
    r.players = { x = 0, y = y, w = sw, h = dp(48) }; y = y + r.players.h
    local board_w = sw - 2 * pad
    local lay = BoardView.layout(board_w, (st.board and st.board.size) or 19, { coords = true })
    r.board = { x = pad, y = y + dp(4), w = board_w, h = lay.height, lay = lay }
    y = r.board.y + r.board.h + dp(4)

    local bottom = st.bottom or { kind = "buttons", rows = {} }
    if bottom.kind == "confirm" then
        r.confirm = { x = pad, y = y, w = sw - 2 * pad, h = dp(150) }
        r.confirm.prompt = { x = r.confirm.x, y = y, w = r.confirm.w, h = dp(56) }
        r.confirm.buttons = { x = r.confirm.x, y = y + dp(60), w = r.confirm.w, h = dp(82) }
        y = y + r.confirm.h
    else
        r.status = { x = pad, y = y, w = sw - 2 * pad, h = dp(40) }
        y = y + r.status.h
    end
    -- button rows hug the bottom edge
    local rows = (bottom.kind == "buttons") and bottom.rows or {}
    local row_h, gap = dp(64), dp(8)
    local bottom_h = (#rows > 0) and (#rows * row_h + (#rows + 1) * gap) or 0
    r.rows = { x = pad, y = sh - bottom_h + gap, w = sw - 2 * pad, h = row_h, count = #rows, gap = gap, band_y = sh - bottom_h }
    local comment_h = (bottom.kind == "confirm") and 0 or math.max(0, (sh - bottom_h) - y)
    r.comment = { x = pad, y = y, w = sw - 2 * pad, h = comment_h }
    return r
end

-- ---------------------------------------------------------------------------
-- Widget
-- ---------------------------------------------------------------------------

function GameScreen:init()
    self.sw, self.sh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.sw, h = self.sh }
    self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.dimen } } }
    self.key_events = {
        Back = { { "Back" } },
        Next = { { { "RPgFwd", "LPgFwd", "Right" } }, event = "NavKey", args = "next" },
        Prev = { { { "RPgBack", "LPgBack", "Left" } }, event = "NavKey", args = "prev" },
    }
    self._rects = {}
    self:update(true)
    self:_schedule_tick()
end

function GameScreen:update(no_refresh, mode)
    self.st = self.controller:state()
    self.lay = GameScreen.layout(self.sw, self.sh, self.st, Kit.dp)
    if not no_refresh then
        UIManager:setDirty(self, mode or "ui")
    end
end

function GameScreen:_schedule_tick()
    if not self.controller.tick then return end
    self._tick = self._tick or function()
        if self.closed then return end
        local changed = self.controller:tick(os.time())
        if changed then self:update() end
        UIManager:scheduleIn(self.tick_seconds, self._tick)
    end
    UIManager:scheduleIn(self.tick_seconds, self._tick)
end

function GameScreen:getSize() return self.dimen end

-- -- painting ----------------------------------------------------------------

local function stone_icon(bb, cx, cy, r, color)
    bb:paintCircle(cx, cy, r, Kit.BLACK)
    if color == "W" then bb:paintCircle(cx, cy, r - 3, Kit.WHITE) end
end

function GameScreen:_paint_header(bb, x, y, st, h)
    local px = math.floor(h * 0.42)
    self._rects.back = { x = x, y = y, w = h * 1.6, h = h }
    Kit.text_left(bb, x + Kit.dp(12), y + h / 2, "‹ Back", px, Kit.BLACK, true)
    local counter = st.counter or ""
    local cw = Kit.text_width(bb, counter, px, true)
    Kit.text_right(bb, x + self.sw - Kit.dp(12), y + h / 2, counter, px, Kit.BLACK, true)
    local left = x + h * 1.6
    local avail = self.sw - h * 1.6 - cw - Kit.dp(28)
    Kit.text_centered(bb, left + avail / 2, y + h / 2, Kit.fit(bb, st.title or "", px, avail, true), px, Kit.BLACK, true)
    Kit.fill(bb, x, y + h - 2, self.sw, 2, Kit.BLACK)
    self._rects.menu = nil
end

function GameScreen:_paint_player(bb, x, y, w, h, p, color, active)
    local px = math.floor(h * 0.38)
    stone_icon(bb, x + h * 0.45, y + h / 2, math.floor(h * 0.26), color)
    local name = (p and p.name or "") .. ((p and p.rank and p.rank ~= "") and (" (" .. p.rank .. ")") or "")
    local clock = p and p.clock and p.clock ~= "" and p.clock or nil
    local right = x + w - Kit.dp(8)
    local extra = ""
    if p and p.captures and p.captures > 0 then extra = "  ×" .. p.captures end
    if clock then
        Kit.text_right(bb, right, y + h / 2, clock, px, Kit.BLACK, active)
        right = right - Kit.text_width(bb, clock, px, active) - Kit.dp(10)
    end
    Kit.text_left(bb, x + h * 0.85, y + h / 2, name .. extra, px, Kit.BLACK, active, right - (x + h * 0.85))
    if active then Kit.fill(bb, x + Kit.dp(4), y + h - 5, w - Kit.dp(8), 4, Kit.BLACK) end
end

function GameScreen:paintTo(bb, x, y)
    local st, lay = self.st, self.lay
    self._rects = { buttons = {}, confirm_buttons = {} }
    Kit.fill(bb, x, y, self.sw, self.sh, Kit.WHITE)

    self:_paint_header(bb, x, y + lay.header.y, st, lay.header.h)

    local half = math.floor(self.sw / 2)
    self:_paint_player(bb, x, y + lay.players.y, half, lay.players.h, st.black, "B", st.to_move == "B")
    self:_paint_player(bb, x + half, y + lay.players.y, half, lay.players.h, st.white, "W", st.to_move == "W")
    Kit.fill(bb, x, y + lay.players.y + lay.players.h - 1, self.sw, 1, Kit.LIGHT)

    BoardView.paint(bb, x + lay.board.x, y + lay.board.y, lay.board.lay, st.board, { show_numbers = st.show_numbers })

    if lay.confirm then
        local c = lay.confirm
        Kit.fill(bb, x + c.x, y + c.y, c.w, c.h, Kit.WHITE)
        Kit.border(bb, x + c.x, y + c.y, c.w, c.h, 4, Kit.BLACK)
        local bt = st.bottom
        Kit.text_centered(bb, x + c.prompt.x + c.prompt.w / 2, y + c.prompt.y + c.prompt.h / 2 + Kit.dp(4),
            Kit.fit(bb, bt.prompt or "", math.floor(c.prompt.h * 0.46), c.w - Kit.dp(24), true),
            math.floor(c.prompt.h * 0.46), Kit.BLACK, true)
        local rects = Kit.button_row(bb, x + c.buttons.x + Kit.dp(8), y + c.buttons.y, c.buttons.w - Kit.dp(16), c.buttons.h - Kit.dp(8), {
            { "cancel", bt.cancel or "Cancel", "normal" },
            { "confirm", bt.ok or "CONFIRM MOVE", st.busy and "disabled" or "primary" },
        }, Kit.dp(12))
        self._rects.confirm_buttons = rects
    else
        local s = lay.status
        if st.status and st.status ~= "" then
            Kit.text_left(bb, x + s.x, y + s.y + s.h / 2, st.status, math.floor(s.h * 0.55), Kit.BLACK, true, s.w)
        end
    end

    -- comment text
    local cm = lay.comment
    if cm.h > Kit.dp(30) and st.comment and st.comment ~= "" then
        local px = math.floor(Kit.dp(18))
        local lines = Kit.wrap(bb, st.comment, px, cm.w)
        local line_h = math.floor(px * 1.3)
        local max_lines = math.floor(cm.h / line_h)
        for i = 1, math.min(#lines, max_lines) do
            local text = lines[i]
            if i == max_lines and #lines > max_lines then text = Kit.fit(bb, text .. " …", px, cm.w) end
            Kit.text_left(bb, x + cm.x, y + cm.y + (i - 0.5) * line_h, text, px, Kit.DARK)
        end
        self._rects.comment = { x = x + cm.x, y = y + cm.y, w = cm.w, h = cm.h }
    end

    -- bottom button rows
    local bt = st.bottom
    if bt and bt.kind == "buttons" then
        local rl = lay.rows
        for i, row in ipairs(bt.rows) do
            local items = {}
            for _, b in ipairs(row) do items[#items + 1] = { b.id, b.label, b.style or (b.enabled == false and "disabled") or "normal" } end
            local rects = Kit.button_row(bb, x + rl.x, y + rl.band_y + rl.gap + (i - 1) * (rl.h + rl.gap), rl.w, rl.h, items, Kit.dp(8))
            for _, r in ipairs(rects) do self._rects.buttons[#self._rects.buttons + 1] = r end
        end
    end

    if st.busy then
        Kit.text_right(bb, x + self.sw - Kit.dp(12), y + lay.players.y + lay.players.h + Kit.dp(14), "working…", Kit.dp(16), Kit.GRAY)
    end
end

-- -- input -------------------------------------------------------------------

function GameScreen:_mode_for(before, after)
    local b = before and before.bottom and before.bottom.kind
    local a = after and after.bottom and after.bottom.kind
    if a ~= b then return "partial" end              -- confirm shown/hidden: board fades or returns
    return "ui"
end

function GameScreen:_act(fn)
    local before = self.st
    fn()
    if self.closed then return end
    self.st = nil
    local after = self.controller:state()
    self.st, self.lay = after, GameScreen.layout(self.sw, self.sh, after, Kit.dp)
    UIManager:setDirty(self, self:_mode_for(before, after))
end

function GameScreen:onTap(_, ges)
    local p = ges.pos
    local st, lay = self.st, self.lay
    if st.busy then return true end

    local r = self._rects
    if r.back and p.y < r.back.y + r.back.h and p.x < r.back.x + r.back.w then
        return self:do_back()
    end
    if st.bottom and st.bottom.kind == "confirm" then
        local hit = Kit.hit(r.confirm_buttons, p.x, p.y)
        if hit then
            if hit.enabled ~= false then self:_act(function() self.controller:button(hit.id) end) end
            return true
        end
        -- while confirming only the board answers (to choose another point)
        if p.y >= lay.board.y and p.y < lay.board.y + lay.board.h then return self:_board_tap(p) end
        return true
    end
    local b = Kit.hit(r.buttons, p.x, p.y)
    if b then
        if b.enabled then self:_act(function() self.controller:button(b.id) end) end
        return true
    end
    if p.y >= lay.board.y and p.y < lay.board.y + lay.board.h then return self:_board_tap(p) end
    if r.comment and p.y >= r.comment.y and p.y < r.comment.y + r.comment.h and self.controller.show_comment then
        self.controller:show_comment()
        return true
    end
    return true
end

function GameScreen:_board_tap(p)
    local lay = self.lay
    local col, row = BoardView.point_at(lay.board.lay, p.x - lay.board.x, p.y - lay.board.y)
    if col then self:_act(function() self.controller:board_tap(col, row) end) end
    return true
end

function GameScreen:do_back()
    local close = true
    if self.controller.back then close = self.controller:back() end
    if close ~= false then self:close() else self:update() end
    return true
end

function GameScreen:onBack() return self:do_back() end

function GameScreen:onNavKey(dir)
    if self.st and self.st.bottom and self.st.bottom.kind == "confirm" then return true end
    self:_act(function() self.controller:button(dir) end)
    return true
end

function GameScreen:close()
    if self.closed then return end
    self.closed = true
    UIManager:close(self)
    UIManager:setDirty("all", "full")
    if self.on_close then self.on_close() end
end

return GameScreen
