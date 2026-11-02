--[[
    goreader/app/awake.lua - keep the reader awake (and so online) while a live game is on screen

    Watching or playing a live OGS game needs the Wi-Fi connection, and the Kobo drops it when it
    falls asleep. While at least one game screen holds the reader awake, this
      * asks KOReader not to enter standby (UIManager:preventStandby), and
      * once a minute tells KOReader the reader is in use (an "InputEvent"), which restarts its
        auto-suspend, auto-dim and Wi-Fi-off-when-idle timers.
    Every start() hands back a token; stop(token) gives it back (stopping twice is harmless).
    Whatever is not available on a given KOReader version is skipped quietly.
]]

local Awake = {}

Awake.INTERVAL = 60                      -- seconds between "still in use" signals

local holders, count, running = {}, 0, false

local function ui() local ok, m = pcall(require, "ui/uimanager"); return ok and m or nil end

local function ping()
    local uim = ui()
    if not uim then return end
    local okE, Event = pcall(require, "ui/event")
    if okE and Event and uim.broadcastEvent then pcall(uim.broadcastEvent, uim, Event:new("InputEvent")) end
end

local function tick()
    if count == 0 then running = false; return end
    ping()
    local uim = ui()
    if uim and uim.scheduleIn then uim:scheduleIn(Awake.INTERVAL, tick) end
end

function Awake.start()
    local token = {}
    holders[token] = true
    count = count + 1
    if count == 1 then
        local uim = ui()
        if uim and uim.preventStandby then pcall(uim.preventStandby, uim) end
        ping()
        if uim and uim.scheduleIn then
            if running and uim.unschedule then uim:unschedule(tick) end
            uim:scheduleIn(Awake.INTERVAL, tick); running = true
        end
    end
    return token
end

function Awake.stop(token)
    if not token or not holders[token] then return end
    holders[token] = nil
    count = count - 1
    if count == 0 then
        local uim = ui()
        if uim then
            if uim.unschedule then uim:unschedule(tick) end
            if uim.allowStandby then pcall(uim.allowStandby, uim) end
        end
        running = false
    end
end

function Awake.active() return count > 0 end

return Awake
