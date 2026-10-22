--[[
    goreader/ui/sgf_setup_controller.lua - the first screen of "SGF Game": a
    clean board and a short choice under it.

        [ Record Game ] [ Play Game ]        record a game being played, or play one here
        [ 9x9 ] [ 13x13 ] [ 19x19 ]
        [            START            ]
--]]

local Controller = {}
Controller.__index = Controller

function Controller.new(opts)
    return setmetatable({
        on_start = assert(opts.on_start), mode = opts.mode or "record", size = opts.size or 19,
        on_change = function() end,
    }, Controller)
end

function Controller:state()
    local rows = {}
    for r = 1, self.size do rows[r] = {} end
    local function toggle(id, label, on) return { id = id, label = label, style = on and "toggle_on" or nil } end
    return {
        title = "SGF Game", counter = "",
        black = { name = "Black" }, white = { name = "White" },
        board = { size = self.size, board = rows },
        status = self.mode == "record" and "Record a game that is being played"
                                        or "Play a game here, face to face",
        comment = "",
        bottom = { kind = "buttons", rows = {
            { toggle("mode_record", "Record Game", self.mode == "record"), toggle("mode_play", "Play Game", self.mode == "play") },
            { toggle("size_9", "9x9", self.size == 9), toggle("size_13", "13x13", self.size == 13), toggle("size_19", "19x19", self.size == 19) },
            { { id = "start", label = "START", style = "primary" } },
        } },
    }
end

function Controller:board_tap() end

function Controller:button(id)
    if id == "mode_record" then self.mode = "record"
    elseif id == "mode_play" then self.mode = "play"
    elseif id == "size_9" then self.size = 9
    elseif id == "size_13" then self.size = 13
    elseif id == "size_19" then self.size = 19
    elseif id == "start" then self.on_start(self.mode, self.size) end
end

function Controller:back() return true end

return Controller
