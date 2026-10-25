--[[
    goreader/app/vs_app.lua - "Play the computer": GNU Go on the reader.

    Set-up screen (board size, colour, handicap, level) -> the game. Every exit
    goes up one level: game -> set-up -> the home window. The game is saved after
    every move into the games folder.
--]]

local UIManager  = require("ui/uimanager")
local Env        = require("goreader.app.env")
local Storage    = require("goreader.services.storage")
local Game       = require("goreader.core.game")
local Session    = require("goreader.core.session")
local Engines    = require("goreader.engine.engines")
local GameScreen = require("goreader.ui.gamescreen")
local Setup      = require("goreader.ui.vs_setup_controller")
local VsController = require("goreader.ui.vs_controller")

local App = {}
App.__index = App

App.GNUGO = Env.ROOT .. "/bin/gnugo"

function App.new(opts) return setmetatable({ home = opts and opts.home }, App) end

function App:go_home() if self.home then self.home() end end

function App:storage()
    if not self._storage then
        local lfs = require("libs/libkoreader-lfs")
        self._storage = Storage.new{ root = Env.ROOT, fs = Storage.lfs_fs(lfs) }
    end
    return self._storage
end

function App:saver()
    return function(name, sgf, path)
        local p, err = self:storage():save_game(sgf, name, path)
        if p then return true, p end
        return nil, err
    end
end

function App:deleter() return function(path) return self:storage():delete_game(path) end end

-- Is the engine installed? Returns true or false + where it should be.
function App.engine_present(path)
    local lfs = require("libs/libkoreader-lfs")
    local a = lfs.attributes(path or App.GNUGO)
    return a ~= nil and a.mode == "file"
end

function App:open(up)
    up = up or function() self:go_home() end
    local s = Env.settings()
    local switching, screen = false, nil
    local ctl = Setup.new{
        initial = { size = s:get("play.size"), color = s:get("play.human_color") == "W" and "W" or "B",
                    level = s:get("play.level"), handicap = s:get("play.handicap") },
        on_start = function(choice)
            s:set("play.size", choice.size); s:set("play.human_color", choice.color)
            s:set("play.level", choice.level); s:set("play.handicap", choice.handicap); s:save()
            if not App.engine_present() then
                Env.info("GNU Go is not installed on this reader.\nIt should be at:\n" .. App.GNUGO)
                return
            end
            switching = true
            screen:close()
            Env.safe("play the computer", function() self:start(choice, function() self:open(up) end) end)
        end,
    }
    ctl.on_change = function() if screen then screen:update() end end
    screen = GameScreen:new{ controller = ctl, on_close = function() if not switching then up() end end }
    UIManager:show(screen)
    UIManager:setDirty(nil, "full")
end

-- choice = { size, color = "B"|"W" (yours), level, handicap }
function App:start(choice, back)
    local s = Env.settings()
    local rules = s:get("play.rules")
    local label = string.format("GNU Go (level %d)", choice.level)
    local human = choice.color
    local komi
    if choice.handicap < 2 then komi = (rules == "Japanese") and 6.5 or 7.5; if choice.size == 9 then komi = 5.5 end end
    local game, err = Game.new{
        size = choice.size, handicap = choice.handicap, komi = komi, rules = rules,
        black = human == "B" and "You" or label, white = human == "W" and "You" or label,
        name = label,
    }
    if not game then Env.info("Cannot start this game: " .. tostring(err)); return back() end
    local engine = Engines.gnugo{ path = App.GNUGO, level = choice.level, rules = rules:lower() }
    local screen
    local session = Session.new{
        game = game, engine = engine, human = human,
        scheduler = function(fn)
            -- let the "thinking" status reach the screen before the engine blocks the device
            UIManager:scheduleIn(0.4, function()
                UIManager:forceRePaint()
                Env.safe("engine", fn)
                if screen and not screen.closed then screen:update() end
            end)
        end,
    }
    local ctl = VsController.new{
        session = session, game = game, human = human, label = label,
        save = self:saver(), delete = self:deleter(), choose = Env.choice_dialog,
        close = function() if screen then screen:close() end end,
    }
    screen = GameScreen:new{ controller = ctl, on_close = function() back() end }
    ctl.on_change = function() if screen and not screen.closed then screen:update() end end
    UIManager:show(screen)
    UIManager:setDirty(nil, "full")
    ctl:start()
end

return App
