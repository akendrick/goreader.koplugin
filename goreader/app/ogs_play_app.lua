--[[
    goreader/app/ogs_play_app.lua - play on OGS (online-go.com) with your own account.

        Play on OGS
            My games       your running games, the ones waiting for you first
            Find a game    quick match: pick a board size and speed, wait for an opponent
            Sign out       forget the saved name and password

    Every exit goes up one level: game -> My games -> this menu -> the home window.
    A move is always checked in the CONFIRM MOVE box before it is sent.
    The password is kept in secrets.json on the reader (like the Dragon Go Server one).
--]]

local UIManager  = require("ui/uimanager")
local Env        = require("goreader.app.env")
local Session    = require("goreader.app.ogs_session")
local Auth       = require("goreader.services.ogs_auth")
local Controller = require("goreader.ui.ogs_controller")
local Find       = require("goreader.ui.find_controller")
local GameScreen = require("goreader.ui.gamescreen")
local OGSGame    = require("goreader.core.ogsgame")

local App = {}
App.__index = App

function App.new(opts) return setmetatable({ home = opts and opts.home, session = nil, auth = nil }, App) end

function App:go_home() if self.home then self.home() end end

-- What "Find a game" offers: { label, size, speed }
App.MATCHES = {
    { label = "19x19, rapid",          size = "19x19", speed = "rapid" },
    { label = "19x19, normal",         size = "19x19", speed = "live" },
    { label = "19x19, correspondence", size = "19x19", speed = "correspondence" },
    { label = "13x13, rapid",          size = "13x13", speed = "rapid" },
    { label = "9x9, rapid",            size = "9x9",   speed = "rapid" },
    { label = "9x9, correspondence",   size = "9x9",   speed = "correspondence" },
}

App.ERRORS = {
    bad_credentials = "OGS did not accept that name and password.",
    missing_credentials = "Enter your OGS name and password.",
    unreachable = "Could not reach online-go.com. Check the Wi-Fi.",
    bad_json = "OGS sent something unreadable.",
    not_signed_in = "OGS says you are not signed in.",
    banned = "OGS says this account is banned.",
    sso = "This OGS account signs in with Google, Facebook or similar. Set a password on the OGS website first, then use it here.",
    refused = "OGS refused the sign-in.",
}

function App.error_text(code)
    code = tostring(code or "")
    if App.ERRORS[code] then return App.ERRORS[code] end
    if code:match("^http_") then return "OGS answered with an error (" .. code:gsub("^http_", "") .. ")." end
    return code
end

-- ---------------------------------------------------------------------------
-- Sign-in
-- ---------------------------------------------------------------------------

function App:saved_login()
    local s = Env.settings()
    local user, pass = s:get("ogs.user"), s:get_secret("ogs_password")
    if user ~= "" and pass and pass ~= "" then return user, pass end
end

function App:prompt_login(cb)
    local InputDialog = require("ui/widget/inputdialog")
    local s = Env.settings()
    local user_dlg, pass_dlg
    user_dlg = InputDialog:new{
        title = "OGS: your username", input = s:get("ogs.user"), input_type = "text",
        buttons = {{
            { text = "Cancel", callback = function() UIManager:close(user_dlg); cb(nil) end },
            { text = "Next", is_enter_default = true, callback = function()
                local user = (user_dlg:getInputText() or ""):match("^%s*(.-)%s*$")
                UIManager:close(user_dlg)
                pass_dlg = InputDialog:new{
                    title = "OGS: your password", input = "", input_type = "text", text_type = "password",
                    buttons = {{
                        { text = "Cancel", callback = function() UIManager:close(pass_dlg); cb(nil) end },
                        { text = "Sign in", is_enter_default = true, callback = function()
                            local pass = pass_dlg:getInputText() or ""
                            UIManager:close(pass_dlg)
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
    s:set("ogs.user", ""); s:save(); s:set_secret("ogs_password", nil)
    self:disconnect()
    Env.info("OGS sign-in forgotten.", 2)
end

function App:disconnect()
    if self.session then self.session:close() end
    self.session, self.auth = nil, nil
end

--[[ A connected, signed-in session; cb(session) or cb(nil, reason).
     Asks for the name and password the first time (or when OGS refuses them). ]]
function App:with_session(cb)
    if self.session and self.session:is_open() and self.auth then return cb(self.session) end
    local function go(user, pass, save)
        if not user then return cb(nil, "cancelled") end
        Env.when_online(function()
            Env.with_progress("Signing in to OGS…", function()
                local env = Env.ogs_env()
                env.sign_in = function()
                    local a, err = Auth.sign_in{ transport = Auth.koreader_transport(), username = user, password = pass }
                    if a then self.auth = a end
                    return a, err
                end
                local s = Session.new(env)
                local ok, why = s:open()
                if not ok then
                    self.session, self.auth = nil, nil
                    if why == "bad_credentials" then
                        Env.info(App.error_text(why))
                        return self:prompt_login(function(u, p) go(u, p, true) end)
                    end
                    return cb(nil, App.error_text(why), s)
                end
                if save then
                    local st = Env.settings()
                    st:set("ogs.user", user); st:save(); st:set_secret("ogs_password", pass)
                end
                self.session = s
                cb(s)
            end)
        end)
    end
    local user, pass = self:saved_login()
    if user then go(user, pass, false) else self:prompt_login(function(u, p) go(u, p, true) end) end
end

-- ---------------------------------------------------------------------------
-- The menu
-- ---------------------------------------------------------------------------

function App:open(up)
    up = up or function() self:go_home() end
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local function back_here() self:open(up) end
    local function pick(fn) return function() UIManager:close(dialog); Env.safe("play on ogs", fn) end end
    dialog = ButtonDialog:new{
        title = "Play on OGS",
        buttons = {
            { { text = "My games", callback = pick(function() self:my_games(back_here) end) } },
            { { text = "Find a game", callback = pick(function() self:choose_match(back_here) end) } },
            { { text = "Sign out", callback = pick(function() self:forget_login(); up() end) } },
            { { text = "Cancel", callback = function() UIManager:close(dialog); self:disconnect(); up() end } },
        },
    }
    UIManager:show(dialog)
end

-- ---------------------------------------------------------------------------
-- My games
-- ---------------------------------------------------------------------------

local function name_of(p)
    if type(p) ~= "table" then return "?" end
    local rank = p.rank and OGSGame.rank_text(p.rank) or ""
    return (p.username or "?") .. (rank ~= "" and (" (" .. rank .. ")") or "")
end

function App:my_games(up)
    up = up or function() self:go_home() end
    self:with_session(function(session, why, failed)
        if not session then
            if why ~= "cancelled" then
                Env.show_text("OGS", "Could not sign in: " .. tostring(why) .. (failed and ("\n\n" .. failed:report()) or ""), up)
            else up() end
            return
        end
        Env.with_progress("Loading your games…", function()
            local games, err = self.auth:overview()
            if not games and err == "not_signed_in" then
                self:disconnect()
                Env.info("Your OGS sign-in expired. Signing in again…", 2)
                return self:my_games(up)
            end
            if not games then Env.info("Could not load your games (" .. App.error_text(err) .. ")."); return up() end
            if #games == 0 then Env.info("You have no running games on OGS.\nUse Find a game to start one."); return up() end
            self:show_games(session, games, up)
        end)
    end)
end

function App:show_games(session, games, up)
    local Menu = require("ui/widget/menu")
    local me = self.auth.user and self.auth.user.id
    local items, waiting = {}, 0
    for _, g in ipairs(games) do
        local mine_black = g.black.id == me
        local opp = mine_black and g.white or g.black
        if g.my_turn then waiting = waiting + 1 end
        items[#items + 1] = {
            text = (g.my_turn and "● " or "   ") .. name_of(opp),
            mandatory = (g.width or "?") .. "x" .. (g.height or "?") .. (g.speed and ("  " .. g.speed) or "")
                .. (g.my_turn and "  your move" or "  waiting"),
            game = g, title = name_of(g.black) .. " vs " .. name_of(g.white),
        }
    end
    local menu
    menu = Menu:new{
        title = string.format("OGS  ·  %d to move", waiting), item_table = items, items_per_page = 12,
        covers_fullscreen = true, is_borderless = true, is_popout = false, title_multilines = true,
        onMenuSelect = function(_, item)
            UIManager:close(menu)
            self:play(session, item.game.id, item.title, function() self:my_games(up) end)
        end,
        close_callback = function() UIManager:close(menu); up() end,
    }
    UIManager:show(menu)
end

-- ---------------------------------------------------------------------------
-- Playing
-- ---------------------------------------------------------------------------

function App:play(session, game_id, title, up)
    up = up or function() self:go_home() end
    local ctl = Controller.new{
        session = session, game_id = game_id, title = title, show_text = Env.show_text,
        choose = Env.choice_dialog,
        ask_text = function(t, initial, ok_label, cb) Env.text_dialog(t, initial, ok_label, cb, false) end,
    }
    ctl:open()
    local screen = GameScreen:new{ controller = ctl, on_close = up }
    ctl.on_change = function() screen:update() end
    UIManager:show(screen)
    UIManager:setDirty(nil, "full")
    return screen
end

-- ---------------------------------------------------------------------------
-- Find a game
-- ---------------------------------------------------------------------------

function App:choose_match(up)
    up = up or function() self:go_home() end
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local buttons = {}
    for _, m in ipairs(App.MATCHES) do
        buttons[#buttons + 1] = { { text = m.label, callback = function()
            UIManager:close(dialog)
            Env.safe("find a game", function() self:find(m, up) end)
        end } }
    end
    buttons[#buttons + 1] = { { text = "Cancel", callback = function() UIManager:close(dialog); up() end } }
    dialog = ButtonDialog:new{ title = "Find a game", buttons = buttons }
    UIManager:show(dialog)
end

function App:find(match, up)
    self:with_session(function(session, why, failed)
        if not session then
            if why ~= "cancelled" then Env.show_text("OGS", "Could not sign in: " .. tostring(why), up) else up() end
            return
        end
        local prefs = session.ogs:automatch_prefs{ size = match.size, speed = match.speed }
        local screen
        local ctl = Find.new{
            session = session, prefs = prefs, label = match.label, correspondence = match.speed == "correspondence",
            on_found = function(game_id)
                UIManager:scheduleIn(0.1, function()
                    Env.safe("open game", function()
                        screen:close()
                        self:play(session, game_id, match.label, up)
                    end)
                end)
            end,
            leave = function() screen:close() end,
        }
        screen = GameScreen:new{ controller = ctl, on_close = function() if not ctl.found then up() end end }
        ctl.on_change = function() screen:update() end
        UIManager:show(screen)
        UIManager:setDirty(nil, "full")
        ctl:begin()
    end)
end

return App
