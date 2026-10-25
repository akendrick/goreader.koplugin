--[[
    goreader/ui/joseki_controller.lua - the joseki dictionary on a GameScreen.

    Shows Kogo's Joseki Dictionary (core/joseki.lua) on the whole board. The
    book's continuations appear as lettered points: tap one to follow it. Tap
    any other point to try your own move: that leaves the book (free play, the
    dictionary itself is never changed) and "Return" brings you back.

        JosekiController.new{ dict = Joseki dict, corner = "ne", show_text = fn(title, text) }
--]]

local Joseki = require("goreader.core.joseki")

local Controller = {}
Controller.__index = Controller

local CORNER_NAMES = { ne = "top right", nw = "top left", se = "bottom right", sw = "bottom left" }
Controller.CORNER_NAMES = CORNER_NAMES

function Controller.new(opts)
    local self = setmetatable({
        dict = assert(opts.dict), view = opts.dict:view(opts.corner or "ne"),
        show_text = opts.show_text or function() end, message = nil, on_change = function() end,
    }, Controller)
    return self
end

local function empty_rows(size)
    local rows = {}
    for r = 1, size do rows[r] = {} ; for c = 1, size do rows[r][c] = false end end
    return rows
end

function Controller:state()
    local v = self.view
    local size = 19
    local rows = empty_rows(size)
    for _, s in ipairs(v:stones()) do rows[s.row][s.col] = s.color end
    local choices = {}
    for _, c in ipairs(v:choices()) do choices[#choices + 1] = { col = c.col, row = c.row, label = c.label } end
    local title, desc = v:comment()
    local to_move = v:to_move()
    local status
    if self.message then status = self.message
    elseif v.sandbox then status = "Off the book: free play. Return goes back to the dictionary."
    elseif #choices > 0 then status = "Tap a lettered point to follow the book, or any point to try your own."
    else status = "End of this line in the book." end
    local comment = title ~= "" and (title .. (desc ~= "" and ("\n" .. desc) or "")) or desc
    local sandbox = v.sandbox
    return {
        title = "Joseki dictionary  ·  " .. CORNER_NAMES[v.corner], counter = tostring(v:move_number()),
        black = { name = "Black" }, white = { name = "White" },
        to_move = to_move, turn_fill = false,
        board = { size = size, board = rows, last = v:last_move(), variations = choices },
        status = status, comment = comment, comment_bottom = false,
        bottom = { kind = "buttons", rows = { {
            { id = "reset", label = "Start" }, { id = "back", label = "Back", enabled = v.current.parent ~= nil },
            { id = "next", label = "Next", enabled = (not sandbox and v.current.children[1] ~= nil) or (sandbox and v.current.children[1] ~= nil) },
            { id = "corner", label = "Corner" },
            sandbox and { id = "return", label = "Return", style = "primary" } or { id = "full", label = "Read" },
        } } },
        full_board = true, compact = true, no_confirm = true,
    }
end

function Controller:board_tap(col, row)
    local v = self.view
    self.message = nil
    -- a lettered point follows the book
    for _, c in ipairs(v:choices()) do
        if c.col == col and c.row == row then v:play_label(c.label); return end
    end
    local result, why = v:play(col, row)
    if not result then
        self.message = (why == "occupied") and "That point is taken." or "Cannot play there."
    elseif result == "sandbox" then
        self.message = "Off the book. Return goes back to the dictionary."
    end
end

function Controller:button(id)
    local v = self.view
    self.message = nil
    if id == "reset" then v:reset()
    elseif id == "back" then v:back()
    elseif id == "next" then v:forward()
    elseif id == "return" then v:return_from_sandbox()
    elseif id == "corner" then
        local order = Joseki.CORNERS
        for i, c in ipairs(order) do
            if c == v.corner then v:set_corner(order[i % #order + 1]); break end
        end
    elseif id == "full" then self:show_comment() end
end

function Controller:show_comment()
    local title, desc = self.view:comment()
    self.show_text(title ~= "" and title or "Joseki", desc ~= "" and desc or "No notes for this position.")
end

function Controller:back() return true end

return Controller
