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

function App.new(opts) return setmetatable({ filter = "", home = opts and opts.home }, App) end

function App:go_home() if self.home then self.home() end end

function App:storage()
    if not self._storage then
        local lfs = require("libs/libkoreader-lfs")
        self._storage = Storage.new{ root = Env.ROOT, fs = Storage.lfs_fs(lfs) }
    end
    return self._storage
end

-- Your saved games as a page of boards (about move 40), players' names and the final score
App.GRID_MOVE = 40

function App:open_library(up)
    up = up or function() self:go_home() end
    local storage = self:storage()
    storage:ensure()
    local moved = storage:import_dropped()
    local lib = Library.new{ storage = storage }
    lib:scan()
    local page = lib:page(1, 1000, { sort = "recent", filter = self.filter })
    if #page.items == 0 then
        Env.info(self.filter ~= "" and ("No games match \"" .. self.filter .. "\".")
            or ("No saved games yet.\nCopy .sgf files to:\n" .. storage.dirs.import))
        self.filter, self.delete_mode, self.grid_page = "", false, 1
        return up()
    end
    local GridScreen = require("goreader.ui.gridscreen")
    local items = {}
    for _, e in ipairs(page.items) do
        local who = (Library.latin_only(e.black) ~= "" and Library.latin_only(e.black) or "?") .. " vs "
            .. (Library.latin_only(e.white) ~= "" and Library.latin_only(e.white) or "?")
        if e.black == "" and e.white == "" then who = e.title end
        items[#items + 1] = {
            id = e.path, entry = e, title = who,
            subtitle = (e.result ~= "" and Library.latin_only(e.result) or "unfinished") .. "  ·  " .. e.size .. "x" .. e.size,
            board = function() return self:thumbnail(e) end,
        }
    end
    local delete = self.delete_mode
    local screen
    screen = GridScreen:new{
        title = delete and "Tap a game to DELETE it" or (#items .. " saved games" .. (self.filter ~= "" and ("  ·  \"" .. self.filter .. "\"") or "")
            .. (moved > 0 and ("  ·  " .. moved .. " imported") or "")),
        items = items, cols = 3, rows = 3, compact = true, page = math.max(1, self.grid_page or 1),
        buttons = {
            { id = "search", label = "Search" },
            { id = "delete", label = delete and "Done" or "Delete" },
            { id = "list", label = "List" },
        },
        on_select = function(item)
            self.grid_page = screen.page
            if delete then return self:confirm_delete(item.entry, up) end
            Env.safe("open game", function() self:open_game(item.entry, function() self:open_library(up) end) end)
        end,
        on_button = function(id)
            self.grid_page = screen.page
            if id == "search" then self:ask_filter(up)
            elseif id == "delete" then self.delete_mode = not self.delete_mode; self:open_library(up)
            elseif id == "list" then self:open_list(function() self:open_library(up) end) end
        end,
        on_close = function() self.delete_mode, self.grid_page = false, 1; up() end,
    }
    UIManager:show(screen)
    UIManager:setDirty(nil, "full")
end

-- The board of a saved game at about move 40 (or its last move, if shorter)
function App:thumbnail(entry)
    local text = self:storage():read(entry.path)
    local game = text and SGF.parse(text)
    if not game then return nil end
    local model = ReviewModel.new{ game = game }
    model:last()
    local total = model:state().move_number
    if total > App.GRID_MOVE then model:goto_move(App.GRID_MOVE) end
    local st = model:state()
    return { size = st.size, board = st.board, last = st.last }
end

function App:open_list(up)
    up = up or function() self:go_home() end
    local storage = self:storage()
    storage:ensure()
    local moved = storage:import_dropped()
    local lib = Library.new{ storage = storage }
    lib:scan()
    local page = lib:page(1, 1000, { sort = "recent", filter = self.filter })
    if #page.items == 0 then
        Env.info(self.filter ~= "" and ("No games match \"" .. self.filter .. "\".")
            or ("No saved games yet.\nCopy .sgf files to:\n" .. storage.dirs.import))
        self.filter, self.delete_mode = "", false
        return up()
    end
    local Menu = require("ui/widget/menu")
    local items = {}
    for _, e in ipairs(page.items) do
        items[#items + 1] = { text = e.title, mandatory = e.size .. "x" .. e.size .. (e.result ~= "" and ("  " .. Library.latin_only(e.result)) or ""),
                              entry = e }
    end
    -- a visible way to delete: the first row switches the list to "tap a game to delete it"
    if self.delete_mode then
        table.insert(items, 1, { text = "Done deleting", mandatory = "", action = "done" })
    else
        table.insert(items, 1, { text = "Delete games…", mandatory = "", action = "delete" })
    end
    local per_page = Env.settings():get("view.games_per_page")
    local menu
    menu = Menu:new{
        title = (self.delete_mode and "Tap a game to DELETE it" or ((#page.items) .. " saved games")) .. (self.filter ~= "" and ("  ·  \"" .. self.filter .. "\"") or "")
            .. (moved > 0 and ("  ·  " .. moved .. " imported") or ""),
        item_table = items, items_per_page = per_page,
        covers_fullscreen = true, is_borderless = true, is_popout = false, title_multilines = false,
        title_bar_left_icon = "appbar.search",
        onLeftButtonTap = function() UIManager:close(menu); self:ask_filter(up) end,
        onMenuSelect = function(_, item)
            UIManager:close(menu)
            if item.action then
                self.delete_mode = (item.action == "delete")
                return self:open_list(up)
            end
            if self.delete_mode then return self:confirm_delete(item.entry, up) end
            Env.safe("open game", function() self:open_game(item.entry, function() self:open_list(up) end) end)
        end,
        onMenuHold = function(_, item) self:game_options(menu, item.entry, up) end,
        close_callback = function() UIManager:close(menu); self.delete_mode = false; up() end,
    }
    UIManager:show(menu)
end

function App:confirm_delete(entry, up)
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = "Delete \"" .. entry.title .. "\"?\nThe file is removed from the Kobo.",
        ok_text = "Delete",
        cancel_callback = function() self:open_library(up) end,
        ok_callback = function()
            local ok, err = self:storage():delete_game(entry.path)
            Env.info(ok and "Deleted." or ("Could not delete: " .. tostring(err)), 2)
            self:open_library(up)
        end,
    })
end

function App:ask_filter(up)
    up = up or function() self:go_home() end
    local InputDialog = require("ui/widget/inputdialog")
    local dlg
    dlg = InputDialog:new{
        title = "Search saved games (name, player, event)", input = self.filter, input_type = "text",
        buttons = {{
            { text = "Show all", callback = function() UIManager:close(dlg); self.filter = ""; self:open_library(up) end },
            { text = "Search", is_enter_default = true, callback = function()
                self.filter = dlg:getInputText() or ""; UIManager:close(dlg); self:open_library(up) end },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

function App:game_options(menu, entry, up)
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
                        self:open_library(up)
                    end,
                })
            end } },
            { { text = "Close", callback = function() UIManager:close(dialog) end } },
        },
    }
    UIManager:show(dialog)
end

function App:open_game(entry, back)
    back = back or function() self:go_home() end
    local text, err = self:storage():read(entry.path)
    if not text then Env.info("Could not read the file: " .. tostring(err)); return back() end
    local game = SGF.parse(text)
    if not game then Env.info("This file is not a readable SGF game."); return back() end
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
    screen = GameScreen:new{ controller = ctl, on_close = function() back() end }
    UIManager:show(screen)
    UIManager:setDirty(nil, "full")
end

function App:menu_items()
    return { text = "Saved games", callback = function() Env.safe("saved games", function() self:open_library() end) end }
end

return App
