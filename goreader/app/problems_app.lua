--[[
    goreader/app/problems_app.lua - Go problems (tsumego).

    Problem sets are SGF files in /mnt/onboard/GOReader/problems: copy any
    collection there over USB (one game per problem: set-up stones, who plays, and
    the solution as a tree). A starter set of capture problems comes with GOReader.
    Which problems you have solved is remembered in problem-progress.json.

    Every exit goes up one level: problem -> the set -> the list of sets -> home.
--]]

local UIManager  = require("ui/uimanager")
local Env        = require("goreader.app.env")
local json       = require("goreader.services.json")
local Problems   = require("goreader.core.problems")
local Progress   = require("goreader.core.problem_progress")
local GameScreen = require("goreader.ui.gamescreen")
local Controller = require("goreader.ui.problem_controller")

local App = {}
App.__index = App

App.DIR = Env.ROOT .. "/problems"
App.PROGRESS_FILE = Env.ROOT .. "/problem-progress.json"

function App.new(opts) return setmetatable({ home = opts and opts.home }, App) end

function App:go_home() if self.home then self.home() end end

function App:progress()
    if self._progress then return self._progress end
    local data
    local f = io.open(App.PROGRESS_FILE, "rb")
    if f then
        local text = f:read("*a"); f:close()
        local ok, t = pcall(json.decode, text)
        if ok and type(t) == "table" then data = t end
    end
    self._progress = Progress.new(data)
    return self._progress
end

function App:save_progress()
    local f = io.open(App.PROGRESS_FILE, "wb")
    if f then f:write(json.encode(self:progress().data)); f:close() end
end

-- "starter-captures.sgf" -> "starter captures"
function App.set_title(file)
    return (file:gsub("%.[sS][gG][fF]$", ""):gsub("[_%-]+", " "))
end

-- The problem files: list of { file, path, size }
function App:sets()
    local lfs = require("libs/libkoreader-lfs")
    local out = {}
    local ok, iter, state = pcall(lfs.dir, App.DIR)
    if not ok then return out end
    for name in iter, state do
        if name:lower():match("%.sgf$") and not name:match("^%.") then
            local a = lfs.attributes(App.DIR .. "/" .. name)
            if a and a.mode == "file" then out[#out + 1] = { file = name, path = App.DIR .. "/" .. name, size = a.size } end
        end
    end
    table.sort(out, function(a, b) return a.file:lower() < b.file:lower() end)
    return out
end

function App:open(up)
    up = up or function() self:go_home() end
    local sets = self:sets()
    if #sets == 0 then
        Env.info("No problem sets yet.\nCopy .sgf problem collections to:\n" .. App.DIR)
        return up()
    end
    local Menu = require("ui/widget/menu")
    local progress = self:progress()
    local items = {}
    for _, s in ipairs(sets) do
        local total = progress:total(s.file)
        items[#items + 1] = {
            text = App.set_title(s.file),
            mandatory = total and (progress:solved_count(s.file, total) .. "/" .. total .. " solved")
                or (math.max(1, math.floor(s.size / 1024)) .. " KB"),
            set = s,
        }
    end
    local menu
    menu = Menu:new{
        title = "Problems", item_table = items, items_per_page = 12,
        covers_fullscreen = true, is_borderless = true, is_popout = false, title_multilines = false,
        onMenuSelect = function(_, item)
            UIManager:close(menu)
            Env.with_progress("Opening the problems…", function()
                self:open_set(item.set, function() self:open(up) end)
            end)
        end,
        close_callback = function() UIManager:close(menu); up() end,
    }
    UIManager:show(menu)
end

function App:open_set(set, up)
    local f = io.open(set.path, "rb")
    if not f then Env.info("Could not read " .. set.file); return up() end
    local text = f:read("*a"); f:close()
    local list, errors = Problems.load_collection(text)
    if #list == 0 then
        Env.info("No usable problems in " .. set.file .. ".\n" .. tostring(errors[1] or ""))
        return up()
    end
    local progress = self:progress()
    progress:set_total(set.file, #list)
    local ctl = Controller.new{
        problems = list, set = set.file, title = App.set_title(set.file), progress = progress,
        index = progress:next_unsolved(set.file, #list, 1) or 1,
        save_progress = function() self:save_progress() end,
    }
    local screen
    ctl.on_change = function() screen:update() end
    screen = GameScreen:new{ controller = ctl, on_close = function() self:save_progress(); up() end }
    UIManager:show(screen)
    UIManager:setDirty(nil, "full")
end

return App
