--[[
    goreader/ui/find_controller.lua - "Finding a game…": the waiting screen
    while OGS looks for an opponent (quick match). An empty board, one line of
    status, one button. Nothing redraws on a timer; the screen changes when a
    game is found, the search is cancelled, or the connection drops.

        FindController.new{ session = Session, prefs = <automatch prefs>, label = "19x19 rapid",
                            correspondence = false, on_found = fn(game_id), leave = fn() }
--]]

local Controller = {}
Controller.__index = Controller

-- A correspondence search can take a long time: after this the search is left
-- running on the server and you may leave.
Controller.PATIENCE_SECONDS = 45

function Controller.new(opts)
    local self = setmetatable({
        session = assert(opts.session), prefs = assert(opts.prefs), label = opts.label or "",
        correspondence = opts.correspondence == true, on_found = opts.on_found or function() end,
        leave = opts.leave or function() end, on_change = function() end,
        started = nil, found = nil, cancelled = false, dirty = false, patient_shown = false, closed = false,
        error = nil,
    }, Controller)
    self.session.ogs:on("automatch/start", function(d)
        if type(d) == "table" and d.uuid == self.prefs.uuid and d.game_id and not self.found and not self.closed then
            self.found = d.game_id
            self.dirty = true
        end
    end)
    self.session.ogs:on("automatch/cancel", function(d)
        if type(d) == "table" and d.uuid == self.prefs.uuid then self.cancelled = true; self.dirty = true end
    end)
    return self
end

function Controller:begin(now)
    self.started = now or os.time()
    local ok, err = self.session.ogs:find_match(self.prefs)
    if not ok then self.error = "Could not start the search (" .. tostring(err) .. ")."; self.dirty = true end
    return ok
end

function Controller:state()
    local rows = {}
    for r = 1, 9 do rows[r] = {} end
    local status
    if self.error then status = self.error
    elseif self.cancelled then status = "The search was cancelled."
    elseif self.found then status = "Opponent found. Opening the game…"
    elseif self.session.state ~= "open" then status = "Connection lost. Reconnecting…"
    elseif self.patient_shown then
        status = "Still searching for " .. self.label .. ". You can leave: the game appears under My games when someone accepts."
    else status = "Looking for an opponent: " .. self.label .. "…" end
    local row
    if self.patient_shown and not self.found then
        row = { { id = "cancel", label = "Cancel search" }, { id = "leave", label = "Leave it running", style = "primary" } }
    elseif self.found or self.cancelled or self.error then
        row = { { id = "leave", label = "Back" } }
    else
        row = { { id = "cancel", label = "Cancel search" } }
    end
    return {
        title = "Find a game", counter = "", black = { name = "You" }, white = { name = "Opponent" },
        board = { size = 9, board = rows }, status = status, comment = "",
        bottom = { kind = "buttons", rows = { row } },
    }
end

function Controller:board_tap() end

function Controller:button(id)
    if id == "cancel" then
        self.session.ogs:cancel_match(self.prefs.uuid)
        self.cancelled = true
        self.dirty = true
    elseif id == "leave" then
        self.closed = true
        self.leave()
    end
end

function Controller:back()
    if not self.found and not self.cancelled and not (self.correspondence and self.patient_shown) then
        self.session.ogs:cancel_match(self.prefs.uuid)           -- leaving an unfinished live search cancels it
    end
    self.closed = true
    return true
end

-- Called about once a second; true when the screen should redraw
function Controller:tick(now)
    if self.closed then return false end
    now = now or os.time()
    self.session:pump()
    if self.found then
        self.closed = true
        self.on_found(self.found)
        return false
    end
    if self.correspondence and not self.patient_shown and self.started and now - self.started >= Controller.PATIENCE_SECONDS then
        self.patient_shown = true
        self.dirty = true
    end
    if self.dirty then self.dirty = false; return true end
    return false
end

return Controller
