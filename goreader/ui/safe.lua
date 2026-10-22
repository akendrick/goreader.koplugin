--[[ goreader/ui/safe.lua - run a callback that leaves a screen; an error is logged and shown, not fatal. ]]
-- Run a callback that leaves a screen; an error is logged and shown instead of crashing KOReader
return function(fn, ...)
    local ok, err = xpcall(fn, function(e) return debug.traceback(tostring(e), 2) end, ...)
    if not ok then
        local lok, logger = pcall(require, "logger")
        if lok and logger then logger.err("GOReader:", err) end
        local iok, Info = pcall(require, "ui/widget/infomessage")
        local uok, UIManager = pcall(require, "ui/uimanager")
        if iok and uok and Info.new then UIManager:show(Info:new{ text = "GOReader error:\n" .. tostring(err):match("^[^\n]*") }) end
    end
    return ok
end
