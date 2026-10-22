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
local Last    = require("goreader.ui.lastmove")

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
        play_out = opts.play_out,          -- function(controller): opens the play-out board
        phase = nil,                       -- nil | "options" (CANCEL / PLAY OUT / SUBMIT) | "confirm"
        busy = false, on_change = function() end,
    }, Controller)
end

local function changed(self) self.on_change() end

-- ---------------------------------------------------------------------------
-- What the screen shows
-- ---------------------------------------------------------------------------

function Controller:state()
    local g = self.game
    if not g:staged() then self.phase = nil end
    local board, s = g:board_state(self.phase == "confirm" and "confirm" or "options")
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
    -- always say where the latest move is: the current move is what you came to see
    local lm = Last.text(s.last, s.size, s.move_number)
    if lm and not g:staged() and not (g.message and g.message ~= "") then
        st.status = st.status .. "  ·  last: " .. lm
    end
    if g:staged() then
        local what = g:describe_staged()
        if self.phase == "confirm" then
            st.bottom = { kind = "confirm", prompt = "Submit " .. what .. " to Dragon Go Server?",
                          buttons = { { id = "cancel", label = "Cancel" }, { id = "confirm", label = "CONFIRM MOVE", style = "primary" } } }
        else
            st.bottom = { kind = "confirm", prompt = what .. ": what next?",
                          buttons = { { id = "cancel", label = "CANCEL" }, { id = "playout", label = "PLAY OUT" },
                                      { id = "submit", label = "SUBMIT", style = "primary" } } }
        end
    else
        -- one small row: navigation, then actions
        local row = {
            { id = "first", label = "|<", enabled = s.can_prev }, { id = "prev", label = "<", enabled = s.can_prev },
            { id = "next", label = ">", enabled = s.can_next }, { id = "last", label = ">|", enabled = s.can_next },
        }
        if g:can_move() then row[#row + 1] = { id = "pass", label = "Pass" } end
        row[#row + 1] = { id = "reload", label = "Refresh" }
        st.bottom = { kind = "buttons", rows = { row } }
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
        if not ok then g.message = REASONS[why] or ("Cannot play there (" .. tostring(why) .. ")")
        else self.phase = "options" end                  -- a new point: back to the three choices
    end
end

function Controller:_do_submit()
    local g = self.game
    local payload = g:confirm_payload()
    local ok, err = self.submit(payload)
    if not ok then
        g:submit_failed(err)
    else
        self.phase = nil
        local fresh = self.refresh and self.refresh()
        g:submitted(fresh and fresh.sgf or nil)
        if fresh and fresh.move_id then g.move_id = fresh.move_id end
        -- Safety net: the server's record must show the move we chose. DGS's move
        -- label format is not yet proven on the device, so say so loudly if it differs.
        if fresh and fresh.sgf then
            local last = g.model:state().last
            if last and not payload.col and not last.pass then
                g.message = "WARNING: you passed but the server shows a stone at the last move. Check the game."
            elseif last and payload.col and (last.col ~= payload.col or last.row ~= payload.row) then
                g.message = "WARNING: the server recorded a different move than the one you chose. Check the game."
            end
        end
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
    elseif id == "cancel" then
        if self.phase == "confirm" then self.phase = "options"      -- one step back: the three choices
        else g:cancel(); self.phase = nil end                        -- CANCEL: back to the last move
    elseif id == "submit" then
        if g:staged() then self.phase = "confirm" end
    elseif id == "playout" then
        if g:staged() and self.play_out then self.play_out(self) end
    elseif id == "pass" then
        local ok, why = g:stage_pass()
        if not ok then g.message = REASONS[why] or "Cannot pass now." else self.phase = "options" end
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

-- Back button: step back out of the move choices first; leave only when nothing is pending
function Controller:back()
    if self.game:staged() then
        if self.phase == "confirm" then self.phase = "options"
        else self.game:cancel(); self.phase = nil end
        return false
    end
    return true
end

function Controller:show_comment() end

return Controller
