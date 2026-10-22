--[[
    goreader/ui/playout_controller.lua - the PLAY OUT board.

    A temporary game started from the position you were looking at: play out
    variations on either side, step back and forward, make notes, view the
    variation tree and save the result as a NEW sgf file. Nothing here touches
    the real game; leaving asks before throwing work away.

        local c = PlayOutController.new{
            sgf = text, title = "...", stage = { col, row } | nil,
            edit_note = function(initial, cb) end,
            ask_name  = function(default, cb) end,
            save_new  = function(name, sgf_text) -> true, path | nil, err end,
            show_tree = function(model, on_done) end,
            confirm_leave = function(on_choice) end,       -- "keep" | "discard" | "save"
        }
--]]

local SGF              = require("goreader.core.sgf")
local ReviewModel      = require("goreader.ui.review_model")
local ReviewController = require("goreader.ui.review_controller")

local Controller = setmetatable({}, { __index = ReviewController })
Controller.__index = Controller

local REASONS = {
    occupied = "That point is taken.", suicide = "Not allowed: no liberties.",
    ko = "Not allowed: ko.", superko = "Not allowed: repeats a position.",
}

function Controller.new(opts)
    local game = assert(SGF.parse(opts.sgf), "unreadable game")
    game:go_to_end()
    local self = setmetatable({
        model = ReviewModel.new{ game = game }, title = opts.title,
        edit_note = opts.edit_note or function() end, ask_name = opts.ask_name or function() end,
        save_new = opts.save_new, show_tree = opts.show_tree or function() end,
        confirm_leave = opts.confirm_leave or function(cb) cb("discard") end,
        show_numbers = false, number_span = 10, message = nil,
        created = {}, saved_created = 0, on_change = function() end,
        close = function() end,                       -- set by the screen
    }, Controller)
    if opts.stage then
        if opts.stage.pass then self:_pass() else self:_play(opts.stage.col, opts.stage.row) end
    end
    return self
end

function Controller:_track(node, created)
    if created then self.created[node] = true end
end

function Controller:_count()
    local n = 0
    for _ in pairs(self.created) do n = n + 1 end
    return n
end

function Controller:_play(col, row)
    local node, created = self.model:play_move(col, row)
    if not node then self.message = REASONS[created] or ("Cannot play there (" .. tostring(created) .. ")"); return false end
    self:_track(node, created)
    return true
end

function Controller:_pass()
    local node, created = self.model:play_pass()
    self:_track(node, created)
end

-- Anything created since the last save?
function Controller:unsaved()
    return self:_count() > self.saved_created
        or (self.model.dirty and self:_count() == 0 and self.saved_created == 0 and self.notes_changed)
end

function Controller:state()
    local st = ReviewController.state(self)
    local m = self.model
    local s = m:state()
    st.title = (self.title or "Play out")
    local to = s.to_move == "B" and "Black" or "White"
    if not self.message then
        st.status = "Play out (not sent)  ·  " .. to .. " to play"
    end
    local can_undo = self.created[m.game.current] == true
    st.bottom = { kind = "buttons", rows = { {
        { id = "prev", label = "<", enabled = s.can_prev }, { id = "next", label = ">", enabled = s.can_next },
        { id = "ahead10", label = "+10", enabled = s.can_next },
        { id = "pass", label = "Pass" },
        { id = "undo", label = "Undo", enabled = can_undo },
        { id = "tree", label = "Tree" },
        { id = "note", label = "Note" },
        { id = "save", label = "Save", style = self:unsaved() and "primary" or nil },
    } } }
    return st
end

function Controller:board_tap(col, row)
    self.message = nil
    self:_play(col, row)
end

function Controller:button(id)
    local m = self.model
    self.message = nil
    if id == "prev" then m:prev()
    elseif id == "next" then m:next()
    elseif id == "ahead10" then m:next(10)
    elseif id == "pass" then self:_pass()
    elseif id == "undo" then
        if self.created[m.game.current] then
            local node = m.game.current
            -- forget the node and everything under it
            local function forget(n) self.created[n] = nil; for _, c in ipairs(n.children) do forget(c) end end
            forget(node)
            m:delete_current()
        else
            self.message = "Only moves you played here can be undone."
        end
    elseif id == "tree" then
        self.show_tree(m, function() self.on_change() end)
    elseif id == "note" then
        self.edit_note(m.game.current:get("C", ""), function(text)
            if text ~= nil then m:set_comment(text); self.notes_changed = true; self.on_change() end
        end)
    elseif id == "save" then
        self:save()
    end
end

function Controller:show_comment() self:button("note") end

--[[ Ask for a name and save as a new sgf. cb(ok, path_or_error) afterwards. ]]
function Controller:save(cb)
    local default = (self.title or "Play out"):gsub("%s*·.*$", "") .. " variation"
    self.ask_name(default, function(name)
        if not name or name:match("^%s*$") then if cb then cb(false, "cancelled") end return end
        if not self.save_new then self.message = "Saving is not available."; self.on_change(); return end
        local ok, path = self.save_new(name, self.model:to_sgf())
        if ok then
            self.saved_created = self:_count(); self.notes_changed = false
            self.message = "Saved as: " .. name
        else
            self.message = "Could not save: " .. tostring(path)
        end
        self.on_change()
        if cb then cb(ok, path) end
    end)
end

--[[ Back button: leave straight away when nothing would be lost, otherwise ask. ]]
function Controller:back()
    if not self:unsaved() then return true end
    self.confirm_leave(function(choice)
        if choice == "discard" then self.close()
        elseif choice == "save" then self:save(function(ok) if ok then self.close() end end)
        else self.on_change() end                       -- keep playing
    end)
    return false
end

return Controller
