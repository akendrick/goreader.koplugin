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
local PlayOut    = require("goreader.ui.playout_controller")

local App = {}
App.__index = App

function App.new(opts) return setmetatable({ client = nil, home = opts and opts.home }, App) end

-- Leaving anything returns to the GOReader home window
function App:go_home() if self.home then self.home() end end

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

function App:open(up)
    up = up or function() up() end
    self:with_client(function(client, why)
        if not client then
            if why ~= "cancelled" then Env.info("Could not sign in to Dragon Go Server (" .. tostring(why) .. ").") end
            up()
            return
        end
        Env.with_progress("Loading your games…", function()
            local games, err = retrying(client, function() return client:running_games() end)
            if not games then Env.info("Could not load your games (" .. tostring(err) .. ")."); up(); return end
            if #games == 0 then Env.info("You have no running games on Dragon Go Server."); up(); return end
            local ok, err = pcall(function() self:show_grid(client, games, up) end)
            if not ok then
                Env.log("warn", "game grid failed: " .. tostring(err))
                self:show_list(client, games, up)
            end
        end)
    end)
end

-- Your games as rows: the game, your colour, whether it is your move, the opponent's name
function App:build_rows(client, games)
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
    return rows, turn_count
end

-- The board of a downloaded game as it stands now: { size, board, last }, move number
local function thumbnail(sgf)
    local game = SGF.parse(sgf)
    if not game then return nil end
    local model = ReviewModel.new{ game = game }
    model:last()
    local st = model:state()
    return { size = st.size, board = st.board, last = st.last }, st.move_number
end
App.thumbnail = thumbnail

--[[ Download every running game (only those that changed since last time) and
     show their boards, as they stand now, as a page of thumbnails. ]]
function App:show_grid(client, games, up)
    up = up or function() self:go_home() end
    local GridScreen = require("goreader.ui.gridscreen")
    local rows, turn_count = self:build_rows(client, games)
    self.sgf_cache = self.sgf_cache or {}
    local function build()
        local items = {}
        for _, row in ipairs(rows) do
            local key = tostring(row.game.id) .. ":" .. tostring(row.game.move_id)
            local sgf = self.sgf_cache[key]
            if not sgf then
                sgf = retrying(client, function() return client:download_sgf(row.game.id) end)
                if sgf then self.sgf_cache[key] = sgf end
            end
            local board, number
            if sgf then board, number = thumbnail(sgf) end
            items[#items + 1] = {
                id = row.game.id, row = row, mine = row.my_turn, board = board,
                title = row.opponent,
                subtitle = (row.my_turn and "Your move" or "Waiting") .. (number and ("  ·  move " .. number) or "  ·  could not load"),
            }
        end
        return items
    end
    Env.with_progress(string.format("Downloading your %d games…", #rows), function()
        local items = build()
        local screen
        screen = GridScreen:new{
            title = string.format("Dragon Go Server  ·  %d to move", turn_count), items = items,
            on_select = function(item)
                Env.safe("open game", function() self:open_game(client, item.row, function() self:open(up) end) end)
            end,
            on_list = function() self:show_list(client, games, up) end,
            on_reload = function() self.sgf_cache = {}; self:open(up) end,
            on_close = up,
        }
        UIManager:show(screen)
        UIManager:setDirty(nil, "full")
    end)
end

function App:show_list(client, games, up)
    up = up or function() self:go_home() end
    local Menu = require("ui/widget/menu")
    local rows, turn_count = self:build_rows(client, games)
    local menu
    menu = Menu:new{
        title = string.format("Dragon Go Server  ·  %d to move", turn_count), item_table = rows,
        covers_fullscreen = true, is_borderless = true, is_popout = false, title_multilines = true,
        onMenuSelect = function(_, item)
            UIManager:close(menu)
            Env.safe("open game", function() self:open_game(client, item, function() self:open(up) end) end)
        end,
        close_callback = function() UIManager:close(menu); up() end,
    }
    UIManager:show(menu)
end

-- ---------------------------------------------------------------------------
-- One game
-- ---------------------------------------------------------------------------

function App:open_game(client, row, back)
    back = back or function() back() end
    local gid = row.game.id
    Env.with_progress("Loading the game…", function()
        local sgf, err = retrying(client, function() return client:download_sgf(gid) end)
        if not sgf then Env.info("Could not load the game (" .. tostring(err) .. ")."); back(); return end
        -- Nothing for you to do here: open it as a replay of the game
        if not row.my_turn then return self:open_replay(row, sgf, back) end
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
            play_out = function(c) Env.safe("play out", function() self:play_out(c, row) end) end,
        }
        local screen
        ctl.on_change = function() if screen then screen:update() end end
        screen = GameScreen:new{ controller = ctl, on_close = function() back() end }
        UIManager:show(screen)
        UIManager:setDirty(nil, "full")
    end)
end

--[[ PLAY OUT: a temporary board started from this position (with the move you
     chose already played) for trying variations, notes and saving a new SGF.
     Nothing is sent to Dragon Go Server. Closing it returns to the choices. ]]
function App:play_out(dgs_ctl, row)
    local game = dgs_ctl.game
    local staged = game:staged()
    local lfs = require("libs/libkoreader-lfs")
    local storage = Storage.new{ root = Env.ROOT, fs = Storage.lfs_fs(lfs) }
    local TreeView = require("goreader.ui.treeview")
    local po
    po = PlayOut.new{
        sgf = SGF.write(game.model.game),
        title = (row.opponent or "game") .. "  ·  play out",
        stage = staged and (staged.pass and { pass = true } or { col = staged.col, row = staged.row }) or nil,
        edit_note = function(initial, cb)
            Env.text_dialog("Note for move " .. po.model:state().move_number, initial, "Save note", cb, true)
        end,
        ask_name = function(default, cb) Env.text_dialog("Save as a new SGF: name", default, "Save", cb, false) end,
        save_new = function(name, text)
            storage:ensure()
            return storage:save_game(text, name)                  -- always a new file, never an overwrite
        end,
        show_tree = function(model, done) UIManager:show(TreeView:new{ model = model, on_close = done }) end,
        confirm_leave = function(cb)
            Env.choice_dialog("Leave the play-out?\nYour variations are not saved.", {
                { "keep", "Keep playing" }, { "save", "Save as a new SGF…" }, { "discard", "Discard and go back" } }, cb)
        end,
    }
    local screen
    screen = GameScreen:new{ controller = po, on_close = function() dgs_ctl.on_change() end }
    po.on_change = function() screen:update() end
    po.close = function() screen:close() end
    UIManager:show(screen)
    UIManager:setDirty(nil, "full")
end

-- A game that is not waiting on you: replay it (opens on the latest move, or move 40 if it is finished)
function App:open_replay(row, sgf, back)
    back = back or function() back() end
    local game = SGF.parse(sgf)
    if not game then Env.info("This game could not be read."); return back() end
    local model = ReviewModel.new{ game = game }
    model:go_to_start_position()                  -- latest move, or move 40 for a finished game
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
    screen = GameScreen:new{ controller = ctl, on_close = function() back() end }
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
