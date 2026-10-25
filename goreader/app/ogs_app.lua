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

function App.new(opts) return setmetatable({ session = nil, home = opts and opts.home }, App) end

function App:go_home() if self.home then self.home() end end

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

function App:connection_test(up)
    up = up or function() self:go_home() end
    Env.when_online(function()
        Env.with_progress("Testing the connection to OGS…", function()
            local s = Session.new(Env.ogs_env())
            local ok, why = s:open()
            local verdict
            if ok then
                local games, gerr
                local t0 = require("socket").gettime()
                s.ogs:list_games("live", { hide_9x9 = true, hide_13x13 = true, hide_other = true }, 0, 5,
                    function(r, e) games, gerr = r, e end)
                for _ = 1, 60 do s:pump(); if games or gerr then break end; require("socket").sleep(0.1) end
                s.steps[#s.steps + 1] = { name = "ask for 19x19 live games", ok = games ~= nil,
                    ms = math.floor((require("socket").gettime() - t0) * 1000),
                    info = games and (#games .. " games listed")
                        or (gerr and ("the server said: " .. tostring(gerr.message or gerr.code)) or "no answer") }
                verdict = "All good: OGS can be reached from this device."
                self.session = s
            else
                verdict = "Could not connect: " .. tostring(why)
                s:close()
            end
            Env.show_text("OGS connection test", verdict .. "\n\n" .. s:report(), up)
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

function App:show_game_list(session, games, size_label, filter_index, page, total, up)
    up = up or function() self:go_home() end
    local Menu = require("ui/widget/menu")
    local items = {}
    for _, g in ipairs(games) do
        items[#items + 1] = {
            text = player_text(g.black) .. "  vs  " .. player_text(g.white),
            mandatory = (g.width or "?") .. "x" .. (g.height or "?") .. "  move " .. tostring(g.move_number or "?"),
            game = g,
        }
    end
    local f = App.FILTERS[filter_index or 1]
    local more_available = (f.order == "weak") and (App.page_start(f, total, (page or 0) + 1) < App.page_start(f, total, page or 0))
                           or (f.order ~= "weak" and #games >= App.PAGE)
    if more_available then
        items[#items + 1] = { text = "More games ▸", mandatory = "", more = true }
    end
    if (page or 0) > 0 then
        table.insert(items, 1, { text = "◂ Previous games", mandatory = "", previous = true })
    end
    local menu
    menu = Menu:new{
        title = "Live games (" .. size_label .. ")" .. ((page or 0) > 0 and ("  ·  page " .. ((page or 0) + 1)) or ""),
        item_table = items, items_per_page = 12,
        covers_fullscreen = true, is_borderless = true, is_popout = false, title_multilines = true,
        onMenuSelect = function(_, item)
            UIManager:close(menu)
            if item.more then return Env.safe("games", function() self:watch_live(filter_index, (page or 0) + 1, up) end) end
            if item.previous then return Env.safe("games", function() self:watch_live(filter_index, (page or 0) - 1, up) end) end
            -- leaving the game comes back to THIS list, one level up
            self:watch(session, item.game, function()
                self:show_game_list(session, games, size_label, filter_index, page, total, up)
            end)
        end,
        close_callback = function() UIManager:close(menu); up() end,
    }
    UIManager:show(menu)
end

function App:watch(session, game, up)
    up = up or function() self:go_home() end
    local title = (game.black and game.black.username or "?") .. " vs " .. (game.white and game.white.username or "?")
    local ctl = Controller.new{ session = session, game_id = game.id, title = title,
                                show_text = Env.show_text, refresh_every = Env.settings():get("view.ogs_refresh_every"),
                                quick_replies = Env.settings():get("ogs.quick_replies"),
                                button_pause = Env.settings():get("view.ogs_button_pause") }
    ctl:open()
    local screen = GameScreen:new{ controller = ctl, on_close = up }
    ctl.on_change = function() screen:update() end
    UIManager:show(screen)
    UIManager:setDirty(nil, "full")
end

-- Which games to list. OGS sorts by rank, strongest first; "weakest first" asks
-- for the other end of the list, where the kyu games are.
local ONLY_19 = { hide_9x9 = true, hide_13x13 = true, hide_other = true }
local FILTERS = {
    { label = "19x19, strongest first", where = ONLY_19 },
    { label = "19x19, weakest first (kyu games)", where = ONLY_19, order = "weak" },
    { label = "19x19, no bot games", where = { hide_9x9 = true, hide_13x13 = true, hide_other = true, hide_bot_games = true } },
    { label = "9x9 and 13x13", where = { hide_19x19 = true, hide_other = true } },
    { label = "all sizes", where = {} },
}
App.FILTERS = FILTERS
App.PAGE = 40

--[[ Where the next page of a list starts. `total` is how many games match
     (known after the first query); `page` counts from 0. Weakest-first pages
     walk backwards from the end of the list. ]]
function App.page_start(filter, total, page)
    page = page or 0
    if filter.order == "weak" then
        return math.max(0, (total or App.PAGE) - App.PAGE * (page + 1))
    end
    return App.PAGE * page
end

--[[ Filter a list of games on the device, used when the server refuses our
     filter: keeps the board sizes and bot setting of `where`. ]]
function App.local_filter(games, where)
    local out = {}
    for _, g in ipairs(games) do
        local w = g.width
        local keep = true
        if where.hide_19x19 and w == 19 then keep = false end
        if where.hide_13x13 and w == 13 then keep = false end
        if where.hide_9x9 and w == 9 then keep = false end
        if where.hide_other and w ~= 9 and w ~= 13 and w ~= 19 then keep = false end
        if where.hide_bot_games and g.bot_game then keep = false end
        if keep then out[#out + 1] = g end
    end
    return out
end

function App:watch_live(filter_index, page, up)
    up = up or function() self:go_home() end
    local f = FILTERS[filter_index or 1]
    page = page or 0
    self:with_session(function(session, why, failed)
        if not session then
            Env.show_text("OGS", "Could not connect: " .. tostring(why) .. (failed and ("\n\n" .. failed:report()) or ""),
                function() up() end)
            return
        end
        local function ask(from, limit)
            local results, err, data
            local done = false
            session.ogs:list_games("live", f.where, from, limit, function(r, e, d) results, err, data, done = r, e, d, true end)
            for _ = 1, 100 do
                session:pump()
                if done then break end
                require("socket").sleep(0.1)
            end
            return results, err, data
        end
        local total
        if f.order == "weak" or page > 0 then
            local _, err, data = ask(0, 1)                       -- just to learn how many games match
            total = data and data.size
            if not total then Env.info("Could not get the game list: " .. tostring(err and (err.message or err.code) or "no answer")); up(); return end
        end
        local from = App.page_start(f, total, page)
        local limit = App.PAGE
        if f.order == "weak" and total and total < App.PAGE * (page + 1) then limit = math.max(1, total - App.PAGE * page) end
        local results, err = ask(from, limit)
        if not results then
            -- The server may not like our filter: ask for everything and filter here
            Env.log("warn", "OGS game list failed (" .. tostring(err and (err.message or err.code) or "no answer") .. "), retrying without a filter")
            local all, err2 = ask(0, 300)
            if not all then
                Env.info("Could not get the game list.\n" .. tostring(err and (err.message or err.code) or "no answer")
                    .. "\n(and without a filter: " .. tostring(err2 and (err2.message or err2.code) or "no answer") .. ")")
                up()
                return
            end
            results = App.local_filter(all, f.where)
            if f.order ~= "weak" then
                local trimmed = {}
                for i = from + 1, math.min(#results, from + limit) do trimmed[#trimmed + 1] = results[i] end
                results = trimmed
            end
            total = total or #results
        end
        if #results == 0 then Env.info("No live games match (" .. f.label .. ")."); up(); return end
        if f.order == "weak" then                               -- show the weakest players' games first
            local rev = {}
            for i = #results, 1, -1 do rev[#rev + 1] = results[i] end
            results = rev
        end
        self:show_game_list(session, results, f.label, filter_index, page, total, up)
    end)
end

function App:choose_filter(up)
    up = up or function() self:go_home() end
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local buttons = {}
    for i, f in ipairs(FILTERS) do
        buttons[#buttons + 1] = { { text = f.label, callback = function()
            UIManager:close(dialog)
            -- exiting the list comes back to this dialog, one level up
            self:watch_live(i, 0, function() self:choose_filter(up) end) end } }
    end
    buttons[#buttons + 1] = { { text = "Cancel", callback = function() UIManager:close(dialog); up() end } }
    dialog = ButtonDialog:new{ title = "Which games?", buttons = buttons }
    UIManager:show(dialog)
end

-- ---------------------------------------------------------------------------
-- Chat room (read-only snapshot)
-- ---------------------------------------------------------------------------

function App:listen_room(channel, up)
    channel = channel or "global-english"
    up = up or function() self:go_home() end
    self:with_session(function(session, why)
        if not session then Env.info("Could not connect: " .. tostring(why)); up(); return end
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
                (topic and (topic .. "\n\n") or "") .. (#out > 0 and table.concat(out, "\n") or "Nothing arrived."),
                function() up() end)
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
