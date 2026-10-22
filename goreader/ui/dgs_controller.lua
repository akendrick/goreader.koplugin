--[[
    goreader/ui/dgs_controller.lua - drives a GameScreen for one DGS game.

        local c = DGSController.new{
            game = DGSGame,
            submit = function(payload) -> true | nil, err,       -- sends the move
            refresh = function() -> { sgf, move_id, my_color } | nil, err,
            schedule = function(fn),      -- run fn after the screen showed "working"
            notify = function(text),      -- a pop-up message (optional)
        }
        GameScreen:new{ controller = c }       -- c.on_change is set by the screen

    Moves are always staged first and sent only from the CONFIRM MOVE button.
--]]

local DGSGame = require("goreader.core.dgsgame")

local Controller = {}
Controller.__index = Controller

local REASONS = {
    occupied = "That point is already taken.",
    suicide = "Not allowed: that move has no liberties.",
    ko = "Not allowed: ko. Play elsewhere first.",
    superko = "Not allowed: that repeats an earlier position.",
    not_your_turn = "It is not your turn.",
    not_latest = "Go to the last move first.",
    submitting = "Still sending the last move.",
}

function Controller.new(opts)
    return setmetatable({
        game = assert(opts.game), submit = opts.submit, refresh = opts.refresh,
        schedule = opts.schedule or function(fn) fn() end, notify = opts.notify or function() end,
        busy = false, on_change = function() end,
    }, Controller)
end

local function changed(self) self.on_change() end

-- ---------------------------------------------------------------------------
-- What the screen shows
-- ---------------------------------------------------------------------------

function Controller:state()
    local g = self.game
    local board, s = g:board_state()
    local st = {
        title = (g.opponent and (g.opponent .. "  ·  ") or "") .. s.size .. "x" .. s.size,
        counter = s.move_number .. " / " .. s.total,
        black = { name = s.black.name, rank = s.black.rank, captures = s.captures.B },
        white = { name = s.white.name, rank = s.white.rank, captures = s.captures.W },
        to_move = (not g:finished()) and g:next_color() or nil,
        board = board, status = g:status_line(),
        comment = (g:staged() and "") or ((s.comment ~= "" and s.comment) or s.analysis_note or ""),
        busy = self.busy,
    }
    if g:staged() then
        st.bottom = { kind = "confirm", prompt = "Submit " .. g:describe_staged() .. " to Dragon Go Server?",
                      ok = "CONFIRM MOVE", cancel = "Cancel" }
    else
        local nav = {
            { id = "first", label = "|<", enabled = s.can_prev }, { id = "prev", label = "<", enabled = s.can_prev },
            { id = "next", label = ">", enabled = s.can_next }, { id = "last", label = ">|", enabled = s.can_next },
        }
        local acts = {}
        if g:can_move() then acts[#acts + 1] = { id = "pass", label = "Pass" } end
        acts[#acts + 1] = { id = "reload", label = "Refresh" }
        st.bottom = { kind = "buttons", rows = { nav, acts } }
    end
    return st
end

-- ---------------------------------------------------------------------------
-- Input
-- ---------------------------------------------------------------------------

function Controller:board_tap(col, row)
    if self.busy then return end
    local g = self.game
    g.message = nil
    if g:my_turn() then
        local ok, why = g:stage(col, row)
        if not ok then g.message = REASONS[why] or ("Cannot play there (" .. tostring(why) .. ")") end
    end
end

function Controller:_do_submit()
    local g = self.game
    local payload = g:confirm_payload()
    local ok, err = self.submit(payload)
    if not ok then
        g:submit_failed(err)
    else
        local fresh = self.refresh and self.refresh()
        g:submitted(fresh and fresh.sgf or nil)
        if fresh and fresh.move_id then g.move_id = fresh.move_id end
    end
    self.busy = false
    changed(self)
end

function Controller:_do_refresh()
    local g = self.game
    local fresh, err = self.refresh and self.refresh()
    if fresh and fresh.sgf then
        local ng = DGSGame.new{ sgf = fresh.sgf, my_color = fresh.my_color or g.my_color, gid = g.gid,
                                move_id = fresh.move_id or g.move_id, opponent = g.opponent }
        if ng then
            self.game = ng
            ng.message = "Updated."
        else
            g.message = "Could not read the updated game."
        end
    else
        g.message = "Could not refresh (" .. tostring(err or "no connection") .. ")"
    end
    self.busy = false
    changed(self)
end

function Controller:button(id)
    local g = self.game
    if self.busy then return end
    local m = g.model
    if id == "first" then m:first(); g.message = nil
    elseif id == "prev" then m:prev(); g.message = nil
    elseif id == "next" then m:next(); g.message = nil
    elseif id == "last" then m:last(); g.message = nil
    elseif id == "cancel" then g:cancel()
    elseif id == "pass" then
        local ok, why = g:stage_pass()
        if not ok then g.message = REASONS[why] or "Cannot pass now." end
    elseif id == "confirm" then
        if not g:begin_submit() then return end
        self.busy = true
        self.schedule(function() self:_do_submit() end)
    elseif id == "reload" then
        self.busy = true
        g.message = "Refreshing…"
        self.schedule(function() self:_do_refresh() end)
    end
end

-- Back button: cancel a pending move first; leave only when nothing is pending
function Controller:back()
    if self.game:staged() then self.game:cancel(); return false end
    return true
end

function Controller:show_comment() end

return Controller
