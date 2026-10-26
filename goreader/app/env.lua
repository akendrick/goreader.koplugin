--[[
    goreader/app/env.lua - the device side of things: network, storage, errors.
    Only used inside KOReader; the logic it feeds is tested elsewhere.
--]]

local UIManager   = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local logger      = require("logger")

local Env = {}

Env.ROOT = "/mnt/onboard/GOReader"

-- Run fn; a Lua error becomes a message on screen (and in the log), not a crash
function Env.safe(what, fn, ...)
    local ok, err = xpcall(fn, function(e) return debug.traceback(tostring(e), 2) end, ...)
    if not ok then
        logger.err("GOReader " .. what .. ":", err)
        UIManager:show(InfoMessage:new{ text = "GOReader error in " .. what .. ":\n" .. tostring(err):match("^[^\n]*") })
    end
    return ok
end

function Env.log(level, text)
    if level == "warn" then logger.warn("GOReader:", text)
    elseif level == "error" then logger.err("GOReader:", text)
    else logger.info("GOReader:", text) end
end

-- Text of a GET request, or nil + reason
function Env.http_get(url)
    local http       = require("socket.http")
    local socket     = require("socket")
    local socketutil = require("socketutil")
    local ltn12      = require("ltn12")
    local sink = {}
    socketutil:set_timeout(15, 30)
    local code, _, status = socket.skip(1, http.request{
        url = url, method = "GET", headers = { ["User-Agent"] = "GOReader/0.1" },
        sink = ltn12.sink.table(sink),
    })
    socketutil:reset_timeout()
    if code ~= 200 then return nil, "HTTP " .. tostring(code or status or "error") end
    return table.concat(sink)
end

-- Everything the OGS session needs from the device
function Env.ogs_env()
    local socket = require("socket")
    local WS = require("goreader.services.websocket")
    return {
        http_get = Env.http_get,
        connect = function(host, port) return WS.koreader_socket(host, port, 15) end,
        sleep = socket.sleep,
        now_ms = function() return math.floor(socket.gettime() * 1000) end,
        log = Env.log,
    }
end

-- Make sure Wi-Fi is up, then run fn (KOReader asks the user if it is off)
function Env.when_online(fn)
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if ok and NetworkMgr and NetworkMgr.runWhenOnline then
        NetworkMgr:runWhenOnline(function() Env.safe("network", fn) end)
    else
        Env.safe("network", fn)
    end
end

-- Show a working message, then run fn on the next tick so the message paints first
function Env.with_progress(text, fn)
    local info = InfoMessage:new{ text = text }
    UIManager:show(info)
    UIManager:scheduleIn(0.2, function()
        Env.safe(text, function()
            local ok, err = xpcall(fn, function(e) return debug.traceback(tostring(e), 2) end)
            UIManager:close(info)
            if not ok then error(err, 0) end
        end)
    end)
end

function Env.show_text(title, text, on_close)
    local ok, TextViewer = pcall(require, "ui/widget/textviewer")
    if ok and TextViewer then
        UIManager:show(TextViewer:new{ title = title, text = text, justified = false, close_callback = on_close })
    else
        UIManager:show(InfoMessage:new{ text = text })
    end
end

--[[ A text box with Cancel / OK. cb(text) on OK, cb(nil) on cancel.
     multiline = true allows new lines (notes). ]]
function Env.text_dialog(title, initial, ok_label, cb, multiline)
    local InputDialog = require("ui/widget/inputdialog")
    local dlg
    dlg = InputDialog:new{
        title = title, input = initial or "", input_type = "text", allow_newline = multiline and true or false,
        buttons = {{
            { text = "Cancel", callback = function() UIManager:close(dlg); cb(nil) end },
            { text = ok_label or "OK", is_enter_default = not multiline, callback = function()
                local t = dlg:getInputText() or ""
                UIManager:close(dlg); cb(t) end },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

-- A dialog with one button per choice: choices = { {id, label}, ... }; cb(id)
function Env.choice_dialog(title, choices, cb)
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local buttons = {}
    for _, c in ipairs(choices) do
        buttons[#buttons + 1] = { { text = c[2], callback = function() UIManager:close(dialog); cb(c[1]) end } }
    end
    dialog = ButtonDialog:new{ title = title, buttons = buttons }
    UIManager:show(dialog)
end

--[[ The Wi-Fi network list, without having to know KOReader's long-press trick:
     switches Wi-Fi on if needed, scans, and shows the list. Tap another network
     to move to it, tap "disconnect" on the current one, tap "edit" on a saved one
     to forget it or change its password. ]]
function Env.show_wifi_networks()
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isWifiOn() then
        -- the same as pressing and holding "Wi-Fi connection": turns Wi-Fi on, then shows the list
        NetworkMgr:toggleWifiOn(nil, true, true)
        return
    end
    local info = InfoMessage:new{ text = "Scanning for networks…" }
    UIManager:show(info)
    UIManager:forceRePaint()
    local list, err = NetworkMgr:getNetworkList()
    if list ~= nil and #list == 0 then list, err = NetworkMgr:getNetworkList() end   -- the first scan is sometimes empty
    UIManager:close(info)
    if list == nil then
        UIManager:show(InfoMessage:new{ text = "Could not scan for networks:\n" .. tostring(err) })
        return
    end
    if #list == 0 then
        UIManager:show(InfoMessage:new{ text = "No Wi-Fi networks found.\nTurn Wi-Fi off and on again, or move closer to the router." })
        return
    end
    UIManager:show(require("ui/widget/networksetting"):new{ network_list = list })
end

--[[ "Full screen refresh every N moves" for OGS games (a setting, 0 to 100): moves normally refresh
     only what changed; every Nth one is a full flashing refresh to clear ghosting.
     1 = every move, 0 = never (except when a game loads or changes phase). ]]
function Env.set_refresh_every()
    local s = Env.settings()
    local current = s:get("view.ogs_refresh_every")
    Env.text_dialog("Full refresh every how many moves?\n(1 = every move, 0 = never)", tostring(current), "Save", function(text)
        if text == nil then return end
        local n = tonumber((text:gsub("%s+", "")))
        if not n or n ~= math.floor(n) or n < 0 or n > 100 then
            Env.info("Enter a whole number from 0 to 100.")
            return
        end
        s:set("view.ogs_refresh_every", n); s:save()
        Env.info(n == 0 and "Moves will not do a full refresh." or (n == 1 and "Every move will do a full refresh."
            or ("A full refresh every " .. n .. " moves.")), 3)
    end)
end

--[[ "OGS button activation pause during live game": how long the buttons are ignored after the server
     has sent your move back (0 = off, up to 5 seconds, in half seconds). A small dialog that steps the
     value and shows it again, so a few presses reach the number wanted. ]]
Env.PAUSE_DEFAULT = 1

function Env.pause_text(v)
    if v == 0 then return "off" end
    if v == 1 then return "1 second" end
    return (v == math.floor(v) and string.format("%d", v) or string.format("%.1f", v)) .. " seconds"
end

function Env.set_button_pause()
    local s = Env.settings()
    local function show()
        local v = s:get("view.ogs_button_pause")
        Env.choice_dialog("OGS button activation pause during live game:\n" .. Env.pause_text(v), {
            { "less", "Shorter  (- 0.5 s)" }, { "more", "Longer  (+ 0.5 s)" },
            { "off", "Off" }, { "default", "Back to " .. Env.pause_text(Env.PAUSE_DEFAULT) }, { "done", "Done" },
        }, function(choice)
            local n = v
            if choice == "less" then n = math.max(0, v - 0.5)
            elseif choice == "more" then n = math.min(5, v + 0.5)
            elseif choice == "off" then n = 0
            elseif choice == "default" then n = Env.PAUSE_DEFAULT
            else return end
            s:set("view.ogs_button_pause", n); s:save()
            show()
        end)
    end
    show()
end

--[[ Optional parts of GOReader. Off until turned on here; when off they are not shown anywhere
     (home tiles, KOReader menu). `Env.FEATURES` lists them in the order shown. ]]
Env.FEATURES = {
    { key = "features.joseki", label = "Joseki dictionary", note = "experimental beta feature" },
    { key = "features.dgs",    label = "Dragon Go Server" },
}

function Env.feature_on(key)
    local ok, s = pcall(Env.settings)
    return ok and s and s:get(key) == true or false
end

function Env.feature_text(f)
    return f.label .. (f.note and ("  (" .. f.note .. ")") or "") .. ":  " .. (Env.feature_on(f.key) and "ON" or "OFF")
end

function Env.set_features()
    local s = Env.settings()
    local function show()
        local choices = {}
        for i, f in ipairs(Env.FEATURES) do choices[#choices + 1] = { "f" .. i, Env.feature_text(f) } end
        choices[#choices + 1] = { "done", "Done" }
        Env.choice_dialog("Optional features\nTap one to turn it on or off. It then shows up on the home screen.", choices, function(id)
            local n = tonumber(id:match("^f(%d+)$"))
            local f = n and Env.FEATURES[n]
            if not f then return end
            s:set(f.key, not (s:get(f.key) == true)); s:save()
            show()
        end)
    end
    show()
end

--[[ Board coordinates (the letters and numbers along the edges) on every board except Go books:
     on by default. Off, the board grows a little into the space they took. ]]
function Env.coordinates_on()
    local ok, s = pcall(Env.settings)
    if not ok or not s then return true end
    return s:get("view.coordinates") ~= false
end

function Env.set_coordinates()
    local s = Env.settings()
    local on = Env.coordinates_on()
    Env.choice_dialog("Board coordinates (A-T and 1-19 along the edges)\nNow: " .. (on and "ON" or "OFF")
        .. "\nOff gives the boards a little more room. Go books are not affected.", {
        { "on", "On" }, { "off", "Off" }, { "cancel", "Cancel" } }, function(choice)
        if choice ~= "on" and choice ~= "off" then return end
        s:set("view.coordinates", choice == "on"); s:save()
        Env.info("Board coordinates are " .. (choice == "on" and "on" or "off") .. ".", 2)
    end)
end

function Env.info(text, timeout)
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout })
end

-- Settings and saved sign-ins (never passwords for OGS; the DGS password is
-- kept in secrets.json because the DGS quick API needs it for every login)
function Env.settings()
    if Env._settings then return Env._settings end
    local lfs = require("libs/libkoreader-lfs")
    local Storage  = require("goreader.services.storage")
    local Settings = require("goreader.services.settings")
    local storage = Storage.new{ root = Env.ROOT, fs = Storage.lfs_fs(lfs) }
    local s = Settings.new{ storage = storage }
    s:load()
    Env._settings = s
    return s
end

return Env
