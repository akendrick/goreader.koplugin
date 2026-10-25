--[[
    goreader/app/joseki_app.lua - Kogo's Joseki Dictionary.

    The dictionary is one large SGF (about 1.5 MB, 60,000 positions). It is read
    once per session: opening it the first time takes a while on the reader, so a
    message says so. Put it at /mnt/onboard/GOReader/joseki/kjd.sgf.
--]]

local UIManager  = require("ui/uimanager")
local Env        = require("goreader.app.env")
local Joseki     = require("goreader.core.joseki")
local GameScreen = require("goreader.ui.gamescreen")
local Controller = require("goreader.ui.joseki_controller")

local App = {}
App.__index = App

App.PATH = Env.ROOT .. "/joseki/kjd.sgf"

function App.new(opts) return setmetatable({ home = opts and opts.home, dict = nil, corner = "ne" }, App) end

function App:go_home() if self.home then self.home() end end

-- The parsed dictionary (kept for the session); returns dict or nil + reason
function App:load_dictionary()
    if self.dict then return self.dict end
    local f = io.open(App.PATH, "rb")
    if not f then return nil, "missing" end
    local text = f:read("*a")
    f:close()
    local dict, err = Joseki.load(text)
    if not dict then return nil, err or "unreadable" end
    self.dict = dict
    return dict
end

function App:open(up)
    up = up or function() self:go_home() end
    if self.dict then return self:show(up) end
    Env.with_progress("Opening the joseki dictionary…\nThe first time takes a little while.", function()
        local dict, why = self:load_dictionary()
        if not dict then
            if why == "missing" then
                Env.info("The joseki dictionary is not on this reader.\nCopy kjd.sgf to:\n" .. App.PATH)
            else
                Env.info("Could not read the joseki dictionary (" .. tostring(why) .. ").")
            end
            return up()
        end
        self:show(up)
    end)
end

function App:show(up)
    local ctl = Controller.new{ dict = self.dict, corner = self.corner, show_text = Env.show_text }
    local screen
    ctl.on_change = function() screen:update() end
    -- remember the corner you last used
    local orig_button = ctl.button
    ctl.button = function(c, id) orig_button(c, id); self.corner = c.view.corner end
    screen = GameScreen:new{ controller = ctl, on_close = up }
    UIManager:show(screen)
    UIManager:setDirty(nil, "full")
end

return App
