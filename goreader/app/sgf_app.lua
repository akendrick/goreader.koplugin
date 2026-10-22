--[[
    goreader/app/sgf_app.lua - "SGF Game": a clean board to RECORD a game that
    is being played on a real board, or to PLAY one face to face on the reader.

    Every exit goes up one level: game -> this setup screen -> the home window.
    Games are saved after every move into the games folder.
--]]

local UIManager  = require("ui/uimanager")
local Env        = require("goreader.app.env")
local Storage    = require("goreader.services.storage")
local LiveGame   = require("goreader.core.livegame")
local GameScreen = require("goreader.ui.gamescreen")
local Setup      = require("goreader.ui.sgf_setup_controller")
local Record     = require("goreader.ui.record_controller")
local Faceoff    = require("goreader.ui.faceoff_controller")

local App = {}
App.__index = App

function App.new(opts) return setmetatable({ home = opts and opts.home, mode = "record", size = 19 }, App) end

function App:go_home() if self.home then self.home() end end

function App:storage()
    if not self._storage then
        local lfs = require("libs/libkoreader-lfs")
        self._storage = Storage.new{ root = Env.ROOT, fs = Storage.lfs_fs(lfs) }
    end
    return self._storage
end

-- save(name, sgf, path) -> true, path | nil, err
function App:saver()
    return function(name, sgf, path)
        local p, err = self:storage():save_game(sgf, name, path)
        if p then return true, p end
        return nil, err
    end
end

-- The set-up screen. `up` is where leaving it goes (the home window)
function App:open(up)
    up = up or function() self:go_home() end
    local switching, screen = false, nil
    local ctl = Setup.new{ mode = self.mode, size = self.size, on_start = function(mode, size)
        self.mode, self.size = mode, size
        switching = true
        screen:close()
        Env.safe("sgf game", function() self:start(mode, size, function() self:open(up) end) end)
    end }
    ctl.on_change = function() if screen then screen:update() end end
    screen = GameScreen:new{ controller = ctl, on_close = function() if not switching then up() end end }
    UIManager:show(screen)
    UIManager:setDirty(nil, "full")
end

-- Names and details, asked one after another; cb(fields) or cb(nil) on cancel
function App:edit_info(info, cb)
    local steps = {
        { "Black player", "black" }, { "White player", "white" },
        { "Black rank (optional)", "black_rank" }, { "White rank (optional)", "white_rank" },
        { "Komi", "komi" }, { "Event (optional)", "event" }, { "Place (optional)", "place" },
    }
    local out = {}
    local function ask(i)
        local s = steps[i]
        if not s then return cb(out) end
        local initial = out[s[2]]
        if initial == nil then initial = info[s[2]] end
        Env.text_dialog(s[1] .. "  (" .. i .. "/" .. #steps .. ")", initial ~= nil and tostring(initial) or "",
            i == #steps and "Done" or "Next", function(text)
                if text == nil then return cb(nil) end
                out[s[2]] = text
                ask(i + 1)
            end)
    end
    ask(1)
end

function App:start(mode, size, back)
    local live = LiveGame.new{ size = size, mode = mode, komi = size == 9 and 5.5 or 6.5 }
    local screen
    if mode == "play" then
        local FaceoffScreen = require("goreader.ui.faceoff_screen")
        local ctl = Faceoff.new{ live = live, save = self:saver(), choose = Env.choice_dialog,
                                 leave = function() if screen then screen:close() end end }
        screen = FaceoffScreen:new{ controller = ctl, on_close = function() back() end }
        ctl.on_change = function() screen:update() end
        UIManager:show(screen)
    else
        local ctl = Record.new{ live = live, save = self:saver(), choose = Env.choice_dialog,
                                edit_info = function(info, cb) self:edit_info(info, cb) end }
        screen = GameScreen:new{ controller = ctl, on_close = function() back() end }
        ctl.on_change = function() screen:update() end
        UIManager:show(screen)
    end
    UIManager:setDirty(nil, "full")
end

return App
