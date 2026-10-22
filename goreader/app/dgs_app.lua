--[[
    goreader/app/dgs_app.lua - Dragon Go Server in KOReader: sign in, your
    games (yours to move first), review a game, play your move behind a
    CONFIRM MOVE dialog.
--]]

local UIManager  = require("ui/uimanager")
local Env        = require("goreader.app.env")
local DGS        = require("goreader.services.dgs")
local DGSGame    = require("goreader.core.dgsgame")
local Controller = require("goreader.ui.dgs_controller")
local GameScreen = require("goreader.ui.gamescreen")
local SGF        = require("goreader.core.sgf")
local ReviewModel = require("goreader.ui.review_model")
local ReviewController = require("goreader.ui.review_controller")
local Storage    = require("goreader.services.storage")

local App = {}
App.__index = App

function App.new() return setmetatable({ client = nil }, App) end

-- ---------------------------------------------------------------------------
-- Sign-in
-- ---------------------------------------------------------------------------

function App:saved_login()
    local s = Env.settings()
    local user = s:get("dgs.user")
    local pass = s:get_secret("dgs_password")
    if user ~= "" and pass and pass ~= "" then return user, pass end
end

function App:prompt_login(cb)
    local InputDialog = require("ui/widget/inputdialog")
    local s = Env.settings()
    local user_dlg, pass_dlg
    user_dlg = InputDialog:new{
        title = "Dragon Go Server: username", input = s:get("dgs.user"), input_type = "text",
        buttons = {{
            { text = "Cancel", callback = function() UIManager:close(user_dlg); cb(nil) end },
            { text = "Next", is_enter_default = true, callback = function()
                local user = (user_dlg:getInputText() or ""):match("^%s*(.-)%s*$")
                UIManager:close(user_dlg)
                pass_dlg = InputDialog:new{
                    title = "Dragon Go Server: password", input = "", input_type = "text", text_type = "password",
                    buttons = {{
                        { text = "Cancel", callback = function() UIManager:close(pass_dlg); cb(nil) end },
                        { text = "Sign in", is_enter_default = true, callback = function()
                            local pass = pass_dlg:getInputText() or ""
                            UIManager:close(pass_dlg)
                            s:set("dgs.user", user); s:save()
                            s:set_secret("dgs_password", pass)
                            cb(user, pass)
                        end },
                    }},
                }
                UIManager:show(pass_dlg)
                pass_dlg:onShowKeyboard()
            end },
        }},
    }
    UIManager:show(user_dlg)
    user_dlg:onShowKeyboard()
end

function App:forget_login()
    local s = Env.settings()
    s:set("dgs.user", ""); s:save(); s:set_secret("dgs_password", nil)
    self.client = nil
    Env.info("Dragon Go Server sign-in forgotten.", 2)
end

-- A signed-in client; cb(client) or cb(nil, reason)
function App:with_client(cb)
    local function go(user, pass)
        if not user then return cb(nil, "cancelled") end
        Env.when_online(function()
            Env.with_progress("Signing in to Dragon Go Server…", function()
                local client = DGS.new{ transport = DGS.koreader_transport(), log = Env.log }
                local ok, err = client:login(user, pass)
                if not ok then
                    if err == "bad_credentials" then
                        Env.info("Sign-in failed: check your username and password.")
                        return self:prompt_login(go)
                    end
                    return cb(nil, err)
                end
                client.password = pass
                self.client = client
                cb(client)
            end)
        end)
    end
    if self.client and self.client:is_logged_in() then return cb(self.client) end
    local user, pass = self:saved_login()
    if user then go(user, pass) else self:prompt_login(go) end
end

-- Call fn(client); if the session expired, sign in once more and retry
local function retrying(client, fn)
    local a, b = fn()
    if a == nil and b == "not_logged_in" then
        local user = Env.settings():get("dgs.user")
        local ok = client:login(user, client.password or "")
        if ok then return fn() end
    end
    return a, b
end

-- ---------------------------------------------------------------------------
-- Your games
-- ---------------------------------------------------------------------------

local function side_of(client, g)
    local me = (client.userid or ""):lower()
    local b = type(g.black) == "table" and (g.black.handle or ""):lower() or ""
    local w = type(g.white) == "table" and (g.white.handle or ""):lower() or ""
    if b == me then return "B", g.white end
    if w == me then return "W", g.black end
    return nil, g.white
end

function App:open()
    self:with_client(function(client, why)
        if not client then
            if why ~= "cancelled" then Env.info("Could not sign in to Dragon Go Server (" .. tostring(why) .. ").") end
            return
        end
        Env.with_progress("Loading your games…", function()
            local games, err = retrying(client, function() return client:running_games() end)
            if not games then Env.info("Could not load your games (" .. tostring(err) .. ")."); return end
            if #games == 0 then Env.info("You have no running games on Dragon Go Server."); return end
            self:show_list(client, games)
        end)
    end)
end

function App:show_list(client, games)
    local Menu = require("ui/widget/menu")
    local rows, turn_count = {}, 0
    for _, g in ipairs(games) do
        local mine, opp = side_of(client, g)
        local my_turn = mine ~= nil and g.move_color == mine
        if my_turn then turn_count = turn_count + 1 end
        local name = type(opp) == "table" and (opp.handle or opp.name) or "?"
        rows[#rows + 1] = { game = g, my_color = mine, my_turn = my_turn, opponent = name,
                            text = (my_turn and "● " or "   ") .. name,
                            mandatory = my_turn and "your move" or "waiting" }
    end
    table.sort(rows, function(a, b)
        if a.my_turn ~= b.my_turn then return a.my_turn end
        return a.opponent:lower() < b.opponent:lower()
    end)
    local menu
    menu = Menu:new{
        title = string.format("Dragon Go Server  ·  %d to move", turn_count), item_table = rows,
        covers_fullscreen = true, is_borderless = true, is_popout = false, title_multilines = true,
        onMenuSelect = function(_, item)
            UIManager:close(menu)
            Env.safe("open game", function() self:open_game(client, item) end)
        end,
        close_callback = function() UIManager:close(menu) end,
    }
    UIManager:show(menu)
end

-- ---------------------------------------------------------------------------
-- One game
-- ---------------------------------------------------------------------------

function App:open_game(client, row)
    local gid = row.game.id
    Env.with_progress("Loading the game…", function()
        local sgf, err = retrying(client, function() return client:download_sgf(gid) end)
        if not sgf then Env.info("Could not load the game (" .. tostring(err) .. ")."); self:open(); return end
        -- Nothing for you to do here: open it as a replay of the game
        if not row.my_turn then return self:open_replay(row, sgf) end
        local game, gerr = DGSGame.new{ sgf = sgf, my_color = row.my_color, gid = gid,
                                        move_id = row.game.move_id, opponent = row.opponent }
        if not game then Env.info("Cannot show this game: " .. tostring(gerr)); return end

        local ctl = Controller.new{
            game = game,
            submit = function(p)
                return retrying(client, function()
                    return client:submit_move(p.gid, p.move_id, p.col, p.row, p.size)
                end)
            end,
            refresh = function()
                local new_sgf = retrying(client, function() return client:download_sgf(gid) end)
                if not new_sgf then return nil, "download failed" end
                local move_id
                local list = retrying(client, function() return client:running_games() end)
                for _, g in ipairs(list or {}) do if g.id == gid then move_id = g.move_id end end
                return { sgf = new_sgf, move_id = move_id, my_color = row.my_color }
            end,
            schedule = function(fn) UIManager:scheduleIn(0.15, function() Env.safe("dragon go server", fn) end) end,
        }
        local screen
        ctl.on_change = function() if screen then screen:update() end end
        screen = GameScreen:new{ controller = ctl, on_close = function() self:open() end }
        UIManager:show(screen)
        UIManager:setDirty(nil, "full")
    end)
end

-- A game that is not waiting on you: replay it from the first move
function App:open_replay(row, sgf)
    local game = SGF.parse(sgf)
    if not game then Env.info("This game could not be read."); return self:open() end
    game:go_to_root()
    local model = ReviewModel.new{ game = game }
    local lfs = require("libs/libkoreader-lfs")
    local storage = Storage.new{ root = Env.ROOT, fs = Storage.lfs_fs(lfs) }
    local ctl = ReviewController.new{
        model = model, title = row.opponent .. "  ·  replay",
        edit_note = function(initial, cb)
            local InputDialog = require("ui/widget/inputdialog")
            local dlg
            dlg = InputDialog:new{
                title = "Note for move " .. model:state().move_number, input = initial or "",
                input_type = "text", allow_newline = true,
                buttons = {{
                    { text = "Cancel", callback = function() UIManager:close(dlg); cb(nil) end },
                    { text = "Save note", callback = function() local t = dlg:getInputText() or ""; UIManager:close(dlg); cb(t) end },
                }},
            }
            UIManager:show(dlg); dlg:onShowKeyboard()
        end,
        -- notes added to a replayed DGS game are kept in the saved-games library
        save = function(text)
            storage:ensure()
            local name = "dgs-" .. Storage.sanitize(row.opponent, "opponent") .. "-" .. tostring(row.game.id)
            return storage:save_game(text, name, storage.dirs.games .. "/" .. name .. ".sgf")
        end,
    }
    local screen
    ctl.on_change = function() if screen then screen:update() end end
    screen = GameScreen:new{ controller = ctl, on_close = function() self:open() end }
    UIManager:show(screen)
    UIManager:setDirty(nil, "full")
end

function App:menu_items()
    return {
        text = "Dragon Go Server",
        sub_item_table = {
            { text = "Your games", callback = function() Env.safe("dragon go server", function() self:open() end) end },
            { text = "Forget sign-in", callback = function() Env.safe("forget sign-in", function() self:forget_login() end) end },
        },
    }
end

return App
