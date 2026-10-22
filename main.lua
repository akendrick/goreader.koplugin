--[[
    GOReader - KOReader plugin entry point.

    In the book reader: taps on a prepared Go book's diagrams open the
    interactive board (goreader.ui.diagramview).
--]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager       = require("ui/uimanager")
local InfoMessage     = require("ui/widget/infomessage")
local logger          = require("logger")
local _               = require("gettext")

local Prepare = require("goreader.book.prepare")
local Gobooks = require("goreader.book.gobooks")

local GOReader = WidgetContainer:extend{
    name = "goreader",
    is_doc_only = false,
}

function GOReader:init()
    self.side_cache = {}
    if self.ui.menu then self.ui.menu:registerToMainMenu(self) end
    if self.ui.document and self.ui.link then self:_hook_links() end
end

-- ---------------------------------------------------------------------------
-- Book mode: figures
-- ---------------------------------------------------------------------------

-- The side file for a chapter, read from the open book
function GOReader:_side_text(key)
    if self.side_cache[key] then return self.side_cache[key] end
    local path = Prepare.side_path(key)
    local text
    local doc = self.ui.document
    if doc and doc.getDocumentFileContent then
        local ok, data = pcall(doc.getDocumentFileContent, doc, path)
        if ok and type(data) == "string" and #data > 0 then text = data end
    end
    if not text and doc and doc.file then                    -- fall back to reading the zip ourselves
        local ok, Archiver = pcall(require, "ffi/archiver")
        if ok then
            local reader = Archiver.Reader:new()
            if reader:open(doc.file) then
                local data = reader:extractToMemory(path)
                reader:close()
                if data and #data > 0 then text = data end
            end
        end
    end
    if text then self.side_cache[key] = text end
    return text
end

function GOReader:_hook_links()
    local plugin = self
    local link = self.ui.link
    local original = link.onGotoLink
    link.onGotoLink = function(l, lnk, ...)
        local url = type(lnk) == "table" and lnk.xpointer or nil
        if type(url) == "string" and url:sub(1, #Prepare.SCHEME) == Prepare.SCHEME then
            return plugin:onFigureTapped(url, lnk)
        end
        return original(l, lnk, ...)
    end
    logger.info("GOReader: link hook installed")
end

function GOReader:onFigureTapped(url, lnk)
    logger.info("GOReader: diagram tapped", url, "a_xpointer", lnk and lnk.a_xpointer, "link_y", lnk and lnk.link_y)
    local key, n = Prepare.parse_link(url)
    if not key then
        UIManager:show(InfoMessage:new{ text = _("GOReader: unreadable diagram link.") })
        return true
    end
    local side = self:_side_text(key)
    if not side then
        UIManager:show(InfoMessage:new{ text = _("GOReader: the diagram data is missing from this book. Prepare it again.") })
        return true
    end
    local xml = Prepare.figure_from_side(side, n)
    local spec, why = xml and Gobooks.parse_figure(xml)
    if not spec then
        UIManager:show(InfoMessage:new{ text = _("GOReader: cannot read this diagram: ") .. tostring(why or "not found") })
        return true
    end

    -- where the diagram is on the screen (top edge), if KOReader can tell us
    local top
    if lnk and lnk.a_xpointer and self.ui.document.getScreenPositionFromXPointer then
        local ok, y = pcall(self.ui.document.getScreenPositionFromXPointer, self.ui.document, lnk.a_xpointer)
        if ok and type(y) == "number" then top = y end
    end
    top = top or (lnk and lnk.link_y and (lnk.link_y - 100)) or nil

    local DiagramView = require("goreader.ui.diagramview")
    UIManager:show(DiagramView:new{ spec = spec, top = top })
    return true
end

-- ---------------------------------------------------------------------------
-- Menu
-- ---------------------------------------------------------------------------

function GOReader:addToMainMenu(menu_items)
    menu_items.goreader = {
        text = _("GOReader"),
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                text = _("About this book"),
                enabled_func = function() return self.ui.document ~= nil end,
                callback = function()
                    local doc = self.ui.document
                    local prepared = doc and self:_side_text("ch1") ~= nil
                    UIManager:show(InfoMessage:new{
                        text = prepared and _("This is a prepared Go book: tap a diagram to play it.")
                                         or _("Not a prepared Go book (no interactive diagrams found)."),
                    })
                end,
            },
        },
    }
end

return GOReader
