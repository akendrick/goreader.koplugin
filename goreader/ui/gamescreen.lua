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
              or { kind = "confirm", prompt = "...", buttons = { {id,label,style}, ... } },
              (the older form ok = "CONFIRM MOVE", cancel = "Cancel" still works)
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
    clock_seconds = 5,          -- how often the player bar's clocks are refreshed (only that strip)
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
    r.header = { x = 0, y = y, w = sw, h = dp(44) }; y = y + r.header.h
    r.players = { x = 0, y = y, w = sw, h = dp(44) }; y = y + r.players.h

    local bottom = st.bottom or { kind = "buttons", rows = {} }
    local confirm_h = dp(150)
    local row_h, gap = (st.compact and dp(36) or dp(44)), dp(6)
    local rows = (bottom.kind == "buttons") and bottom.rows or {}
    local rows_h = (#rows > 0) and (#rows * (row_h + gap) + gap) or 0

    -- The board is as wide as the screen allows but never so tall that the
    -- confirmation dialog (or the status line and button row) would not fit
    -- below it. It keeps the same size in both modes so it never jumps.
    local status_h = dp(34)
    local reserve = (st.no_confirm and (rows_h + status_h) or math.max(confirm_h, rows_h + status_h)) + dp(8)
    local avail = sh - y - reserve
    local bpad = st.full_board and 0 or pad                 -- a full-width board has no margins and no A-T / 1-19 labels
    local board_w = math.min(sw - 2 * bpad, avail)
    local lay = BoardView.layout(board_w, (st.board and st.board.size) or 19, { coords = not st.full_board })
    r.board = { x = math.floor((sw - board_w) / 2), y = y + dp(4), w = board_w, h = lay.height, lay = lay }
    y = r.board.y + r.board.h + dp(4)

    if bottom.kind == "confirm" then
        r.confirm = { x = pad, y = y, w = sw - 2 * pad, h = confirm_h }
        r.confirm.prompt = { x = r.confirm.x, y = y, w = r.confirm.w, h = dp(56) }
        r.confirm.buttons = { x = r.confirm.x, y = y + dp(60), w = r.confirm.w, h = dp(82) }
        y = y + r.confirm.h
    else
        r.status = { x = pad, y = y, w = sw - 2 * pad, h = status_h }
        y = y + r.status.h
    end
    -- button rows hug the bottom edge
    r.rows = { x = pad, y = sh - rows_h + gap, w = sw - 2 * pad, h = row_h, count = #rows, gap = gap, band_y = sh - rows_h }
    local comment_h = (bottom.kind == "confirm") and 0 or math.max(0, (sh - rows_h) - y)
    r.comment = { x = pad, y = y, w = sw - 2 * pad, h = comment_h }
    return r
end

-- ---------------------------------------------------------------------------
-- Widget
-- ---------------------------------------------------------------------------

-- How long things take is logged (only the slow ones), so a sluggish screen can be diagnosed from the log
local function note_slow(what, started, limit)
    local ms = (os.clock() - started) * 1000
    if ms >= (limit or 150) then
        local ok, logger = pcall(require, "logger")
        if ok and logger then logger.info(string.format("GOReader: %s took %d ms", what, ms)) end
    end
    return ms
end

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

-- A stable text form of a value, to see whether something changed between two states
local function ser(v)
    local t = type(v)
    if t ~= "table" then return tostring(v) end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local out = {}
    for _, k in ipairs(keys) do out[#out + 1] = tostring(k) .. "=" .. ser(v[k]) end
    return "{" .. table.concat(out, ",") .. "}"
end

--[[ What part of the screen differs between two drawn states: a list of { x, y, w, h }
     (empty when nothing visible changed), or nil when the layout changed and the whole
     screen should be refreshed. Used for moves: only the points that changed on the
     board (the new stone, captures, the move marker), the bars and the text that
     changed are refreshed, not the whole screen. ]]
function GameScreen.changed_regions(prev, st, old_lay, lay)
    if not (prev and st and old_lay and lay and prev.board and st.board) then return nil end
    local a, b, ob, nb = prev.board, st.board, old_lay.board, lay.board
    if a.size ~= b.size or ob.x ~= nb.x or ob.y ~= nb.y or ob.w ~= nb.w or ob.h ~= nb.h then return nil end
    if (prev.bottom or {}).kind ~= (st.bottom or {}).kind or #((prev.bottom or {}).rows or {}) ~= #((st.bottom or {}).rows or {}) then return nil end
    local out = {}
    local function add(x, y, w, h) out[#out + 1] = { x = math.floor(x), y = math.floor(y), w = math.ceil(w), h = math.ceil(h) } end

    -- the board
    local size = b.size
    local minc, minr, maxc, maxr
    local function touch(c, r)
        if not c then return end
        minc = minc and math.min(minc, c) or c; maxc = maxc and math.max(maxc, c) or c
        minr = minr and math.min(minr, r) or r; maxr = maxr and math.max(maxr, r) or r
    end
    for r = 1, size do
        local ra, rb = a.board[r] or {}, b.board[r] or {}
        for c = 1, size do
            if (ra[c] or false) ~= (rb[c] or false) then touch(c, r) end
        end
    end
    if ser(a.last) ~= ser(b.last) then
        if a.last and a.last.col then touch(a.last.col, a.last.row) end
        if b.last and b.last.col then touch(b.last.col, b.last.row) end
    end
    local overlays = function(x) return ser({ x.marks, x.variations, x.candidates, x.dead, x.territory, x.focus, x.pending }) end
    if overlays(a) ~= overlays(b) then
        add(nb.x, nb.y, nb.w, nb.h)                                   -- letters, counting marks: the whole board
    elseif minc then
        local cell = nb.lay.cell
        local x1, y1 = BoardView.px(nb.lay, minc, minr)
        local x2, y2 = BoardView.px(nb.lay, maxc, maxr)
        local m = math.ceil(cell * 0.75)
        local left, top = math.max(nb.x, nb.x + x1 - m), math.max(nb.y, nb.y + y1 - m)
        local right, bottom = math.min(nb.x + nb.w, nb.x + x2 + m), math.min(nb.y + nb.h, nb.y + y2 + m)
        add(left, top, right - left, bottom - top)
    end

    -- the bars and the text
    if prev.title ~= st.title or prev.counter ~= st.counter then add(lay.header.x, lay.header.y, lay.header.w, lay.header.h) end
    if ser({ prev.black, prev.white, prev.to_move }) ~= ser({ st.black, st.white, st.to_move }) then
        add(lay.players.x, lay.players.y, lay.players.w, lay.players.h)
    end
    if prev.status ~= st.status or prev.busy ~= st.busy then
        local r = lay.status or (lay.confirm and lay.confirm.prompt)
        if r then add(r.x, r.y, r.w, r.h) end
    end
    if prev.comment ~= st.comment then add(lay.comment.x, lay.comment.y, lay.comment.w, lay.comment.h) end
    if ser(prev.bottom) ~= ser(st.bottom) then
        if lay.confirm then add(lay.confirm.x, lay.confirm.y, lay.confirm.w, lay.confirm.h) end
        add(0, lay.rows.band_y, lay.sw, lay.sh - lay.rows.band_y)
    end
    return out
end

function GameScreen:update(no_refresh, mode)
    local t0 = os.clock()
    local prev_st, prev_lay = self.st, self.lay
    self.st = self.controller:state()
    self.lay = GameScreen.layout(self.sw, self.sh, self.st, Kit.dp)
    note_slow("preparing the screen (state)", t0, 100)
    if not no_refresh then
        -- a controller may ask for a full (flashing, clean) refresh for what just happened
        local wanted = self.controller.take_refresh_mode and self.controller:take_refresh_mode()
        local ok, logger = pcall(require, "logger")
        if mode or wanted == "full" or not self.controller.region_refresh then
            local use = mode or wanted or "ui"
            if ok and logger and use == "full" then logger.info("GOReader: full refresh requested") end
            UIManager:setDirty(self, use)
        else
            -- partial refresh of just what changed
            local regions = GameScreen.changed_regions(prev_st, self.st, prev_lay, self.lay)
            if regions == nil then
                UIManager:setDirty(self, "ui")
            else
                for _, r in ipairs(regions) do UIManager:setDirty(self, "ui", Geom:new{ x = r.x, y = r.y, w = r.w, h = r.h }) end
            end
        end
    end
end

function GameScreen:_schedule_tick()
    if not self.controller.tick then return end
    self._tick = self._tick or function()
        if self.closed then return end
        local now = os.time()
        local t0 = os.clock()
        local changed = self.controller:tick(now)
        note_slow("connection pump and tick", t0, 300)
        if changed then self:update(); self._clock_at = now
        else self:_refresh_clocks(now) end
        UIManager:scheduleIn(self.tick_seconds, self._tick)
    end
    UIManager:scheduleIn(self.tick_seconds, self._tick)
end

-- Live clocks: redraw just the player bar, and only when a clock reading changed
function GameScreen:_refresh_clocks(now)
    if not self.controller.live_clocks then return end
    if self._clock_at and now - self._clock_at < self.clock_seconds then return end
    self._clock_at = now
    local st = self.controller:state()
    local function sig(s) return ((s.black or {}).clock or "") .. "|" .. ((s.white or {}).clock or "") end
    if sig(st) == sig(self.st) then return end
    self.st = st
    local p = self.lay.players
    UIManager:setDirty(self, "ui", Geom:new{ x = p.x, y = p.y, w = p.w, h = p.h })
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

function GameScreen:_paint_player(bb, x, y, w, h, p, color, active, fill)
    local px = math.floor(h * 0.38)
    local ink = Kit.BLACK
    if fill and active then                      -- the side to move is shown as a solid block
        Kit.fill(bb, x, y, w, h, Kit.BLACK)
        ink = Kit.WHITE
        bb:paintCircle(math.floor(x + h * 0.45), math.floor(y + h / 2), math.floor(h * 0.26), Kit.WHITE)
        if color == "B" then bb:paintCircle(math.floor(x + h * 0.45), math.floor(y + h / 2), math.floor(h * 0.26) - 3, Kit.BLACK) end
    else
        stone_icon(bb, x + h * 0.45, y + h / 2, math.floor(h * 0.26), color)
    end
    local name = (p and p.name or "") .. ((p and p.rank and p.rank ~= "") and (" (" .. p.rank .. ")") or "")
    local clock = p and p.clock and p.clock ~= "" and p.clock or nil
    local right = x + w - Kit.dp(8)
    local extra = ""
    if p and p.captures and p.captures > 0 then extra = "  ×" .. p.captures end
    if clock then
        Kit.text_right(bb, right, y + h / 2, clock, px, ink, active)
        right = right - Kit.text_width(bb, clock, px, active) - Kit.dp(10)
    end
    Kit.text_left(bb, x + h * 0.85, y + h / 2, name .. extra, px, ink, active, right - (x + h * 0.85))
    if active and not fill then Kit.fill(bb, x + Kit.dp(4), y + h - 5, w - Kit.dp(8), 4, Kit.BLACK) end
end

function GameScreen:paintTo(bb, x, y)
    local t0 = os.clock()
    self:_paint(bb, x, y)
    note_slow("paint of " .. tostring(self.controller.title or "screen"), t0)
end

function GameScreen:_paint(bb, x, y)
    local st, lay = self.st, self.lay
    self._rects = { buttons = {}, confirm_buttons = {} }
    Kit.fill(bb, x, y, self.sw, self.sh, Kit.WHITE)

    self:_paint_header(bb, x, y + lay.header.y, st, lay.header.h)

    local half = math.floor(self.sw / 2)
    self:_paint_player(bb, x, y + lay.players.y, half, lay.players.h, st.black, "B", st.to_move == "B", st.turn_fill)
    self:_paint_player(bb, x + half, y + lay.players.y, half, lay.players.h, st.white, "W", st.to_move == "W", st.turn_fill)
    Kit.fill(bb, x, y + lay.players.y + lay.players.h - 1, self.sw, 1, Kit.LIGHT)

    BoardView.paint(bb, x + lay.board.x, y + lay.board.y, lay.board.lay, st.board, { show_numbers = st.show_numbers, sprites = true })

    if lay.confirm then
        local c = lay.confirm
        Kit.fill(bb, x + c.x, y + c.y, c.w, c.h, Kit.WHITE)
        Kit.border(bb, x + c.x, y + c.y, c.w, c.h, 4, Kit.BLACK)
        local bt = st.bottom
        Kit.text_centered(bb, x + c.prompt.x + c.prompt.w / 2, y + c.prompt.y + c.prompt.h / 2 + Kit.dp(4),
            Kit.fit(bb, bt.prompt or "", math.floor(c.prompt.h * 0.46), c.w - Kit.dp(24), true),
            math.floor(c.prompt.h * 0.46), Kit.BLACK, true)
        local buttons = bt.buttons
        if not buttons then
            buttons = { { "cancel", bt.cancel or "Cancel", "normal" },
                        { "confirm", bt.ok or "CONFIRM MOVE", st.busy and "disabled" or "primary" } }
        else
            local b2 = {}
            for _, b in ipairs(buttons) do b2[#b2 + 1] = { b.id, b.label, st.busy and "disabled" or b.style or "normal" } end
            buttons = b2
        end
        local rects = Kit.button_row(bb, x + c.buttons.x + Kit.dp(8), y + c.buttons.y, c.buttons.w - Kit.dp(16), c.buttons.h - Kit.dp(8), buttons, Kit.dp(12))
        self._rects.confirm_buttons = rects
    else
        local s = lay.status
        if st.status and st.status ~= "" then
            Kit.text_left(bb, x + s.x, y + s.y + s.h / 2, st.status, math.floor(s.h * 0.6), Kit.BLACK, true, s.w)
        end
    end

    -- comment text
    local cm = lay.comment
    if cm.h > Kit.dp(30) and st.comment and st.comment ~= "" then
        local px = math.floor(Kit.dp(18))
        local lines = Kit.wrap(bb, st.comment, px, cm.w)
        local line_h = math.floor(px * 1.3)
        local max_lines = math.floor(cm.h / line_h)
        if st.comment_bottom then
            -- newest line last, sitting directly above the buttons
            local first = math.max(1, #lines - max_lines + 1)
            local shown = #lines - first + 1
            local top = cm.y + cm.h - shown * line_h
            for i = first, #lines do
                local text = lines[i]
                if i == first and first > 1 then text = Kit.fit(bb, "… " .. text, px, cm.w) end
                Kit.text_left(bb, x + cm.x, y + top + (i - first + 0.5) * line_h, text, px, Kit.DARK)
            end
        else
            for i = 1, math.min(#lines, max_lines) do
                local text = lines[i]
                if i == max_lines and #lines > max_lines then text = Kit.fit(bb, text .. " …", px, cm.w) end
                Kit.text_left(bb, x + cm.x, y + cm.y + (i - 0.5) * line_h, text, px, Kit.DARK)
            end
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
            local rects = Kit.button_row(bb, x + rl.x, y + rl.band_y + rl.gap + (i - 1) * (rl.h + rl.gap), rl.w, rl.h, items, Kit.dp(4))
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
    if self.on_close then Kit.safe(self.on_close) end
end

return GameScreen
