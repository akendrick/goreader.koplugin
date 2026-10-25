--[[
    goreader/app/covers.lua - book covers as pictures to draw (KOReader side).

        Covers.get(epub_path, width, height) -> Blitbuffer | nil

    The picture is pulled from the EPUB, decoded at about the size wanted and kept for the
    session. Any trouble (no cover, a format KOReader cannot decode) gives nil, and the
    screen draws a plain book picture instead.
--]]

local Cover = require("goreader.book.cover")

local Covers = {}
local cache = {}

function Covers.get(path, width, height)
    local key = path .. "|" .. width .. "x" .. height
    local c = cache[key]
    if c ~= nil then return c or nil end
    local ok, result = pcall(function()
        local Archiver = require("ffi/archiver")
        local bytes = Cover.read(Archiver, path)
        if not bytes then return nil end
        local RenderImage = require("ui/renderimage")
        return RenderImage:renderImageData(bytes, #bytes, true, width, height)
    end)
    local bb = ok and result or nil
    if not bb then                                   -- say why in the log, so a missing cover can be looked into
        local lok, logger = pcall(require, "logger")
        if lok and logger then logger.info("GOReader: no cover for " .. path .. (ok and "" or (": " .. tostring(result)))) end
    end
    cache[key] = bb or false
    return bb
end

function Covers.clear() cache = {} end

return Covers
