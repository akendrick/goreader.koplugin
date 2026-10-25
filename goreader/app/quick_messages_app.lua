--[[
    goreader/app/quick_messages_app.lua - Settings > Quick messages: the one-tap chat messages
    used in OGS games. Create new ones, edit or delete the ones you have, or go back to the
    standard set. Saved at once in the settings file.
--]]

local UIManager = require("ui/uimanager")
local Env       = require("goreader.app.env")
local QM        = require("goreader.core.quick_messages")

local App = {}
App.__index = App

function App.new(opts) return setmetatable({ home = opts and opts.home }, App) end

function App:list() return Env.settings():get("ogs.quick_replies") end

function App:save(list)
    local s = Env.settings()
    local ok, why = s:set("ogs.quick_replies", list)
    if not ok then Env.info("Could not save: " .. tostring(why)); return false end
    s:save()
    return true
end

local function complain(why) Env.info(QM.REASONS[why] or tostring(why)) end

function App:open(up)
    up = up or function() end
    local Menu = require("ui/widget/menu")
    local list = self:list()
    local items = { { text = "＋  New message", kind = "new" } }
    for i, text in ipairs(list) do items[#items + 1] = { text = text, kind = "message", index = i } end
    items[#items + 1] = { text = "Back to the standard messages", kind = "reset" }
    local menu
    local function again() self:open(up) end
    menu = Menu:new{
        title = "Quick messages  (" .. #list .. ")", item_table = items, items_per_page = 12,
        covers_fullscreen = true, is_borderless = true, is_popout = false, title_multilines = false,
        onMenuSelect = function(_, item)
            UIManager:close(menu)
            Env.safe("quick messages", function()
                if item.kind == "new" then self:new_message(again)
                elseif item.kind == "reset" then self:ask_reset(again)
                else self:message_options(item.index, again) end
            end)
        end,
        close_callback = function() UIManager:close(menu); up() end,
    }
    UIManager:show(menu)
end

function App:new_message(back)
    Env.text_dialog("New quick message", "", "Add", function(text)
        if text ~= nil then
            local list, why = QM.add(self:list(), text)
            if not list then complain(why) else self:save(list) end
        end
        back()
    end)
end

function App:message_options(i, back)
    local list = self:list()
    local text = list[i]
    if not text then return back() end
    Env.choice_dialog(text, { { "edit", "Edit" }, { "delete", "Delete" }, { "cancel", "Cancel" } }, function(choice)
        if choice == "edit" then
            Env.text_dialog("Edit the message", text, "Save", function(new_text)
                if new_text ~= nil then
                    local out, why = QM.edit(self:list(), i, new_text)
                    if not out then complain(why) else self:save(out) end
                end
                back()
            end)
        elseif choice == "delete" then
            Env.choice_dialog("Delete \"" .. text .. "\"?", { { "yes", "Delete it" }, { "no", "Keep it" } }, function(c)
                if c == "yes" then
                    local out = QM.delete(self:list(), i)
                    if out then self:save(out) end
                end
                back()
            end)
        else
            back()
        end
    end)
end

function App:ask_reset(back)
    Env.choice_dialog("Go back to the standard messages?\nYour own messages are removed.", { { "yes", "Go back to the standard ones" }, { "no", "Keep mine" } }, function(c)
        if c == "yes" then self:save(QM.reset()) end
        back()
    end)
end

return App
