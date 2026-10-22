--[[
    goreader/app/ogs_app.lua - the OGS test interface in KOReader's menus.

        Connection test        step-by-step report of reaching OGS
        Watch live games       pick a game, watch it move by move, read the chat
        Listen to a chat room  read-only snapshot of global-english
        Disconnect

    Signs in as a guest, so nothing here can play a move or post chat.
--]]

local UIManager  = require("ui/uimanager")
local Env        = require("goreader.app.env")
local Session    = require("goreader.app.ogs_session")
local Controller = require("goreader.ui.ogs_controller")
local GameScreen = require("goreader.ui.gamescreen")
local OGSGame    = require("goreader.core.ogsgame")
local Chat       = require("goreader.core.chat")

local App = {}
App.__index = App

function App.new() return setmetatable({ session = nil }, App) end

-- A connected session, opening one if needed; calls cb(session) or cb(nil, why)
function App:with_session(cb)
    if self.session and self.session:is_open() then return cb(self.session) end
    Env.when_online(function()
        Env.with_progress("Connecting to OGS…", function()
            local s = Session.new(Env.ogs_env())
            local ok, why = s:open()
            if ok then self.session = s; cb(s) else self.session = nil; cb(nil, why, s) end
        end)
    end)
end

function App:connection_test()
    Env.when_online(function()
        Env.with_progress("Testing the connection to OGS…", function()
            local s = Session.new(Env.ogs_env())
            local ok, why = s:open()
            local verdict
            if ok then
                local games
                s.ogs:list_games("live", { hide_19x19 = true }, 0, 5, function(r) games = r end)
                for _ = 1, 30 do s:pump(); if games then break end; require("socket").sleep(0.1) end
                s.steps[#s.steps + 1] = { name = "ask for the live game list", ok = games ~= nil, ms = 0,
                                          info = games and (#games .. " games listed") or "no answer" }
                verdict = "All good: OGS can be reached from this device."
                self.session = s
            else
                verdict = "Could not connect: " .. tostring(why)
                s:close()
            end
            Env.show_text("OGS connection test", verdict .. "\n\n" .. s:report())
        end)
    end)
end

-- ---------------------------------------------------------------------------
-- Watching
-- ---------------------------------------------------------------------------

local function player_text(p)
    if type(p) ~= "table" then return "?" end
    return (p.username or "?") .. " (" .. OGSGame.rank_text(p.rank) .. ")"
end

function App:show_game_list(session, games, size_label)
    local Menu = require("ui/widget/menu")
    local items = {}
    for _, g in ipairs(games) do
        items[#items + 1] = {
            text = player_text(g.black) .. "  vs  " .. player_text(g.white),
            mandatory = (g.width or "?") .. "x" .. (g.height or "?") .. "  move " .. tostring(g.move_number or "?"),
            game = g,
        }
    end
    local menu
    menu = Menu:new{
        title = "Live games (" .. size_label .. ")", item_table = items,
        covers_fullscreen = true, is_borderless = true, is_popout = false, title_multilines = true,
        onMenuSelect = function(_, item)
            UIManager:close(menu)
            self:watch(session, item.game)
        end,
        close_callback = function() UIManager:close(menu) end,
    }
    UIManager:show(menu)
end

function App:watch(session, game)
    local title = (game.black and game.black.username or "?") .. " vs " .. (game.white and game.white.username or "?")
    local ctl = Controller.new{ session = session, game_id = game.id, title = title,
                                show_text = Env.show_text }
    ctl:open()
    local screen = GameScreen:new{ controller = ctl }
    ctl.on_change = function() screen:update() end
    UIManager:show(screen)
    UIManager:setDirty(nil, "full")
end

local FILTERS = {
    { label = "9x9 and 13x13", where = { hide_19x19 = true, hide_other = true } },
    { label = "all sizes", where = {} },
    { label = "no bot games", where = { hide_bot_games = true, hide_19x19 = true } },
}

function App:watch_live(filter_index)
    local f = FILTERS[filter_index or 1]
    self:with_session(function(session, why, failed)
        if not session then
            Env.show_text("OGS", "Could not connect: " .. tostring(why) .. (failed and ("\n\n" .. failed:report()) or ""))
            return
        end
        local results, err
        local done = false
        session.ogs:list_games("live", f.where, 0, 40, function(r, e) results, err = r, e; done = true end)
        for _ = 1, 100 do
            session:pump()
            if done then break end
            require("socket").sleep(0.1)
        end
        if not results then Env.info("Could not get the game list: " .. tostring(err and (err.message or err.code) or "no answer")); return end
        if #results == 0 then Env.info("No live games match (" .. f.label .. ")."); return end
        self:show_game_list(session, results, f.label)
    end)
end

function App:choose_filter()
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local buttons = {}
    for i, f in ipairs(FILTERS) do
        buttons[#buttons + 1] = { { text = f.label, callback = function()
            UIManager:close(dialog); self:watch_live(i) end } }
    end
    dialog = ButtonDialog:new{ title = "Which games?", buttons = buttons }
    UIManager:show(dialog)
end

-- ---------------------------------------------------------------------------
-- Chat room (read-only snapshot)
-- ---------------------------------------------------------------------------

function App:listen_room(channel)
    channel = channel or "global-english"
    self:with_session(function(session, why)
        if not session then Env.info("Could not connect: " .. tostring(why)); return end
        local chat = Chat.new()
        local topic
        session.ogs:on("chat-message", function(ev) if ev.channel == channel then chat:add_room(ev) end end)
        session.ogs:on("chat-topic", function(ev) if ev.channel == channel then topic = ev.topic end end)
        session.ogs:join_room(channel)
        Env.with_progress("Listening to " .. channel .. "…", function()
            for _ = 1, 40 do session:pump(); require("socket").sleep(0.25) end
            session.ogs:leave_room(channel)
            local lines = chat:room(channel)
            local out = {}
            for _, l in ipairs(lines) do out[#out + 1] = Chat.line_text(l, OGSGame.rank_text(l.rank)) end
            Env.show_text("Room " .. channel .. " (" .. #lines .. " lines)",
                (topic and (topic .. "\n\n") or "") .. (#out > 0 and table.concat(out, "\n") or "Nothing arrived."))
        end)
    end)
end

function App:disconnect()
    if self.session then self.session:close(); self.session = nil end
    Env.info("Disconnected from OGS.", 2)
end

-- Entries for the GOReader menu
function App:menu_items()
    return {
        text = "OGS (test)",
        sub_item_table = {
            { text = "Connection test", callback = function() Env.safe("connection test", function() self:connection_test() end) end },
            { text = "Watch live games", callback = function() Env.safe("watch", function() self:choose_filter() end) end },
            { text = "Listen to chat room (global-english)", callback = function() Env.safe("chat room", function() self:listen_room() end) end },
            { text = "Disconnect", callback = function() Env.safe("disconnect", function() self:disconnect() end) end },
        },
    }
end

return App
