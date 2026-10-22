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
