--[[
    goreader/ui/vs_setup_controller.lua - the first screen of "Play the computer":
    a clean board and a few choices under it.

        [ 9x9 ] [ 13x13 ] [ 19x19 ]
        [ You: Black ] [ You: White ]
        [ Even ] [ 2 ] [ 3 ] [ 4 ] [ 5 ]          handicap stones (Black gets them)
        [ Easier ] [ Level 3 ] [ Harder ]
        [            START            ]

    The choices are remembered: `initial` holds the last ones and on_start
    receives the new ones.
--]]

local Controller = {}
Controller.__index = Controller

Controller.HANDICAPS = { 0, 2, 3, 4, 5 }

function Controller.new(opts)
    local init = opts.initial or {}
    return setmetatable({
        on_start = assert(opts.on_start),
        size = init.size or 9, color = init.color or "B", level = init.level or 3, handicap = init.handicap or 0,
        engine_name = opts.engine_name or "GNU Go", on_change = function() end,
    }, Controller)
end

function Controller:state()
    local rows = {}
    for r = 1, self.size do rows[r] = {} end
    local function toggle(id, label, on) return { id = id, label = label, style = on and "toggle_on" or nil } end
    local hrow = {}
    for _, h in ipairs(Controller.HANDICAPS) do
        hrow[#hrow + 1] = toggle("h" .. h, h == 0 and "Even" or tostring(h), self.handicap == h)
    end
    return {
        title = "Play the computer", counter = "",
        black = { name = self.color == "B" and "You" or self.engine_name },
        white = { name = self.color == "W" and "You" or self.engine_name },
        board = { size = self.size, board = rows },
        status = string.format("%s, level %d (1 easiest, 10 strongest)%s", self.engine_name, self.level,
            self.handicap >= 2 and (", " .. self.handicap .. " handicap stones") or ""),
        comment = "",
        bottom = { kind = "buttons", rows = {
            { toggle("size_9", "9x9", self.size == 9), toggle("size_13", "13x13", self.size == 13), toggle("size_19", "19x19", self.size == 19) },
            { toggle("color_B", "You: Black", self.color == "B"), toggle("color_W", "You: White", self.color == "W") },
            hrow,
            { { id = "easier", label = "Easier", enabled = self.level > 1 }, { id = "level", label = "Level " .. self.level, style = "disabled" },
              { id = "harder", label = "Harder", enabled = self.level < 10 } },
            { { id = "start", label = "START", style = "primary" } },
        } },
    }
end

function Controller:board_tap() end

function Controller:button(id)
    local size = id:match("^size_(%d+)$")
    local color = id:match("^color_([BW])$")
    local h = id:match("^h(%d)$")
    if size then self.size = tonumber(size)
    elseif color then self.color = color
    elseif h then self.handicap = tonumber(h)
    elseif id == "easier" then self.level = math.max(1, self.level - 1)
    elseif id == "harder" then self.level = math.min(10, self.level + 1)
    elseif id == "start" then
        self.on_start{ size = self.size, color = self.color, level = self.level, handicap = self.handicap }
    end
end

function Controller:back() return true end

return Controller
