--[[
    goreader/app/review_app.lua - your saved SGF games: a list (nine to a page,
    searchable) and the review screen with comments, variations, engine
    annotations and your own notes.

    Files live in /mnt/onboard/GOReader/games; drop new ones into
    /mnt/onboard/GOReader/import over USB and they are moved in on opening.
--]]

local UIManager   = require("ui/uimanager")
local Env         = require("goreader.app.env")
local Storage     = require("goreader.services.storage")
local Library     = require("goreader.services.library")
local SGF         = require("goreader.core.sgf")
local ReviewModel = require("goreader.ui.review_model")
local Controller  = require("goreader.ui.review_controller")
local GameScreen  = require("goreader.ui.gamescreen")

local App = {}
App.__index = App

function App.new() return setmetatable({ filter = "" }, App) end

function App:storage()
    if not self._storage then
        local lfs = require("libs/libkoreader-lfs")
        self._storage = Storage.new{ root = Env.ROOT, fs = Storage.lfs_fs(lfs) }
    end
    return self._storage
end

function App:open_library()
    local storage = self:storage()
    storage:ensure()
    local moved = storage:import_dropped()
    local lib = Library.new{ storage = storage }
    lib:scan()
    local page = lib:page(1, 1000, { sort = "recent", filter = self.filter })
    if #page.items == 0 then
        Env.info(self.filter ~= "" and ("No games match \"" .. self.filter .. "\".")
            or ("No saved games yet.\nCopy .sgf files to:\n" .. storage.dirs.import))
        self.filter = ""
        return
    end
    local Menu = require("ui/widget/menu")
    local items = {}
    for _, e in ipairs(page.items) do
        items[#items + 1] = { text = e.title, mandatory = e.size .. "x" .. e.size .. (e.result ~= "" and ("  " .. Library.latin_only(e.result)) or ""),
                              entry = e }
    end
    local per_page = Env.settings():get("view.games_per_page")
    local menu
    menu = Menu:new{
        title = (#page.items) .. " saved games" .. (self.filter ~= "" and ("  ·  \"" .. self.filter .. "\"") or "")
            .. (moved > 0 and ("  ·  " .. moved .. " imported") or ""),
        item_table = items, items_per_page = per_page,
        covers_fullscreen = true, is_borderless = true, is_popout = false, title_multilines = false,
        title_bar_left_icon = "appbar.search",
        onLeftButtonTap = function() UIManager:close(menu); self:ask_filter() end,
        onMenuSelect = function(_, item)
            UIManager:close(menu)
            Env.safe("open game", function() self:open_game(item.entry) end)
        end,
        onMenuHold = function(_, item) self:game_options(menu, item.entry) end,
        close_callback = function() UIManager:close(menu) end,
    }
    UIManager:show(menu)
end

function App:ask_filter()
    local InputDialog = require("ui/widget/inputdialog")
    local dlg
    dlg = InputDialog:new{
        title = "Search saved games (name, player, event)", input = self.filter, input_type = "text",
        buttons = {{
            { text = "Show all", callback = function() UIManager:close(dlg); self.filter = ""; self:open_library() end },
            { text = "Search", is_enter_default = true, callback = function()
                self.filter = dlg:getInputText() or ""; UIManager:close(dlg); self:open_library() end },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

function App:game_options(menu, entry)
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    dialog = ButtonDialog:new{
        title = entry.title,
        buttons = {
            { { text = "Delete this game", callback = function()
                UIManager:close(dialog)
                local ConfirmBox = require("ui/widget/confirmbox")
                UIManager:show(ConfirmBox:new{
                    text = "Delete \"" .. entry.title .. "\"?\nThe file is removed from the Kobo.",
                    ok_text = "Delete",
                    ok_callback = function()
                        local ok, err = self:storage():delete_game(entry.path)
                        UIManager:close(menu)
                        Env.info(ok and "Deleted." or ("Could not delete: " .. tostring(err)), 2)
                        self:open_library()
                    end,
                })
            end } },
            { { text = "Close", callback = function() UIManager:close(dialog) end } },
        },
    }
    UIManager:show(dialog)
end

function App:open_game(entry)
    local text, err = self:storage():read(entry.path)
    if not text then Env.info("Could not read the file: " .. tostring(err)); return self:open_library() end
    local game = SGF.parse(text)
    if not game then Env.info("This file is not a readable SGF game."); return self:open_library() end
    local model = ReviewModel.new{ game = game }
    model:go_to_start_position()                  -- latest move, or move 40 for a finished game
    local ctl = Controller.new{
        model = model, title = entry.title,
        edit_note = function(initial, cb)
            local InputDialog = require("ui/widget/inputdialog")
            local dlg
            dlg = InputDialog:new{
                title = "Note for move " .. model:state().move_number, input = initial or "",
                input_type = "text", allow_newline = true, fullscreen = false,
                buttons = {{
                    { text = "Cancel", callback = function() UIManager:close(dlg); cb(nil) end },
                    { text = "Save note", is_enter_default = false, callback = function()
                        local t = dlg:getInputText() or ""
                        UIManager:close(dlg); cb(t) end },
                }},
            }
            UIManager:show(dlg)
            dlg:onShowKeyboard()
        end,
        save = function(sgf_text) return self:storage():write(entry.path, sgf_text) end,
    }
    local screen
    ctl.on_change = function() if screen then screen:update() end end
    screen = GameScreen:new{ controller = ctl, on_close = function() self:open_library() end }
    UIManager:show(screen)
    UIManager:setDirty(nil, "full")
end

function App:menu_items()
    return { text = "Saved games", callback = function() Env.safe("saved games", function() self:open_library() end) end }
end

return App
