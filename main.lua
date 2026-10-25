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

local Booklist = require("goreader.book.booklist")
local Env = require("goreader.app.env")
local Prepare = require("goreader.book.prepare")
local Gobooks = require("goreader.book.gobooks")

local GOReader = WidgetContainer:extend{
    name = "goreader",
    is_doc_only = false,
}

function GOReader:init()
    self.side_cache = {}
    if self.ui.menu then self.ui.menu:registerToMainMenu(self) end
    local ok, Dispatcher = pcall(require, "dispatcher")
    if ok then                                  -- a gesture/shortcut action: "Open GOReader books"
        Dispatcher:registerAction("goreader_home", {
            category = "none", event = "OpenGOReader", title = _("Open GOReader"), general = true })
        Dispatcher:registerAction("goreader_books", {
            category = "none", event = "OpenGOReaderBooks", title = _("Open Go books"), general = true })
        -- bind this to any gesture (Settings > Taps and gestures) to leave a Go book
        Dispatcher:registerAction("goreader_exit_book", {
            category = "none", event = "GOReaderExitBook", title = _("Go book: close / exit"), reader = true })
    end
    if self.ui.document and self.ui.link then self:_hook_links() end
    if self:_is_go_book() then
        self:_register_exit_zone()
        self:_install_corner_intercept()
    elseif not self.ui.document then
        self:_run_pending()
    end
end

-- ---------------------------------------------------------------------------
-- Leaving a Go book: tap the top-right corner
-- ---------------------------------------------------------------------------

-- Prepared Go books carry "(GOReader)" in their name, or live in the GOReader books folder
function GOReader:_is_go_book()
    local doc = self.ui and self.ui.document
    if not (doc and type(doc.file) == "string") then return false end
    return doc.file:find("(GOReader)", 1, true) ~= nil or doc.file:find("/GOReader/books/", 1, true) ~= nil
end

-- The top-right corner: where a tap leaves the book
GOReader.CORNER = { x = 0.84, y = 0.07 }

function GOReader:_in_corner(pos)
    if type(pos) ~= "table" or not pos.x or not pos.y then return false end
    local Screen = require("device").screen
    return pos.x >= Screen:getWidth() * GOReader.CORNER.x and pos.y <= Screen:getHeight() * GOReader.CORNER.y
end

--[[ KOReader decides what a tap does by walking an ordered list of "touch zones";
     the order depends on which plugin registered what, and other zones (gestures,
     menu, links) can come first. Taking the tap in the reader's own gesture handler
     does not depend on that order. ]]
function GOReader:_install_corner_intercept()
    local ui, plugin = self.ui, self
    if ui._goreader_intercept then return end
    local original = ui.onGesture
    if type(original) ~= "function" then return end
    ui._goreader_intercept = true
    ui.onGesture = function(this, ev, ...)
        if type(ev) == "table" and ev.ges == "tap" and plugin:_in_corner(ev.pos) then
            logger.info("GOReader: corner tap, opening the exit dialog")
            plugin:showExitDialog()
            return true
        end
        return original(this, ev, ...)
    end
    logger.info("GOReader: exit corner installed")
end

function GOReader:onGOReaderExitBook()
    self:showExitDialog()
    return true
end

local EXIT_OVERRIDES = {
    "tap_top_left_corner", "tap_top_right_corner", "tap_left_bottom_corner", "tap_right_bottom_corner",
    "readerfooter_tap", "readerconfigmenu_ext_tap", "readerconfigmenu_tap", "readermenu_ext_tap", "readermenu_tap",
    "tap_forward", "tap_backward",
}

function GOReader:_register_exit_zone()
    if not self.ui.registerTouchZones then return end
    self.ui:registerTouchZones({ {
        id = "goreader_exit_corner", ges = "tap",
        screen_zone = { ratio_x = 0.84, ratio_y = 0, ratio_w = 0.16, ratio_h = 0.07 },
        overrides = EXIT_OVERRIDES,
        handler = function() self:showExitDialog(); return true end,
    } })
    logger.info("GOReader: exit corner zone registered")
end

function GOReader:showExitDialog()
    local now = os.time()
    if self.exit_shown_at and now - self.exit_shown_at < 1 then return end     -- one tap, one dialog
    self.exit_shown_at = now
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local function choose(what)
        return function()
            UIManager:close(dialog)
            self:leaveBook(what)
        end
    end
    dialog = ButtonDialog:new{
        title = _("Go book"),
        buttons = {
            { { text = _("Close book, back to the Go books list"), callback = choose("books") } },
            { { text = _("Close book, back to GOReader"), callback = choose("home") } },
            { { text = _("Exit KOReader"), callback = choose("quit") } },
            { { text = _("Keep reading"), callback = choose(nil) } },
        },
    }
    UIManager:show(dialog)
    return dialog
end

-- Closing the book destroys this plugin instance; the choice is carried to the
-- next one (created with the file manager) in the Env module.
function GOReader:leaveBook(what)
    if not what then return end
    if what == "quit" then
        local Event = require("ui/event")
        UIManager:broadcastEvent(Event:new("Exit"))
        return
    end
    Env.pending = what
    if self.ui.onHome then self.ui:onHome() else self.ui:onClose() end
end

function GOReader:_run_pending()
    local what = Env.pending
    if not what then return end
    Env.pending = nil
    UIManager:scheduleIn(0.4, function()
        if what == "books" then self:showBookList() else self:showHome() end
    end)
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
-- Go books list (works even when KOReader shows a virtual library, not folders)
-- ---------------------------------------------------------------------------

function GOReader:openBook(path)
    if self.ui.document then
        if self.ui.switchDocument then return self.ui:switchDocument(path) end
        UIManager:show(InfoMessage:new{ text = _("Close the current book first, then open this one.") })
        return
    end
    local ReaderUI = require("apps/reader/readerui")
    ReaderUI:showReader(path)
end

function GOReader:onOpenGOReaderBooks()
    self:showBookList()
    return true
end

local LIBRARY_ROOT = "/mnt/onboard"
local CACHE_FILE = Env.ROOT .. "/bookcache.json"

local function load_cache()
    local json = require("goreader.services.json")
    local f = io.open(CACHE_FILE, "rb")
    if not f then return {} end
    local text = f:read("*a"); f:close()
    local ok, t = pcall(json.decode, text)
    return (ok and type(t) == "table") and t or {}
end

local function save_cache(cache)
    local json = require("goreader.services.json")
    local f = io.open(CACHE_FILE, "wb")
    if f then f:write(json.encode(cache)); f:close() end
end

-- Interactive Go books anywhere in the library (found by what is inside them)
function GOReader:_find_books()
    local lfs = require("libs/libkoreader-lfs")
    local LibraryBooks = require("goreader.book.library_books")
    local Archiver = require("ffi/archiver")
    local cache = load_cache()
    local list = LibraryBooks.list{ root = LIBRARY_ROOT, books_dir = Booklist.DEFAULT_DIR, lfs = lfs, archiver = Archiver, cache = cache }
    save_cache(cache)
    return list
end

-- Open a book; an original is prepared first (a copy is written, the original is never changed)
function GOReader:openBookEntry(book)
    if book.prepared then return self:openBook(book.path) end
    Env.with_progress(_("Preparing the book for interactive diagrams…\nThis happens once."), function()
        local lfs = require("libs/libkoreader-lfs")
        lfs.mkdir(Env.ROOT)
        lfs.mkdir(Booklist.DEFAULT_DIR)
        local stats, why = require("goreader.book.library_books").prepare(book.source, book.dst, require("ffi/archiver"))
        if not stats then
            UIManager:show(InfoMessage:new{ text = _("Could not prepare this book: ") .. tostring(why) })
            return
        end
        self:openBook(book.dst)
    end)
end

function GOReader:showBookList()
    Env.with_progress(_("Looking for Go books…"), function() self:_show_book_menu() end)
end

function GOReader:_show_book_menu()
    local ok, books = pcall(function() return self:_find_books() end)
    if not ok or type(books) ~= "table" then
        logger.warn("GOReader: library scan failed:", tostring(books))
        -- fall back to the books folder alone
        local lfs = require("libs/libkoreader-lfs")
        books = Booklist.scan(Booklist.DEFAULT_DIR, lfs)
    end
    if not books or #books == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No interactive Go books found in the library.\nBooks from gobooks.com are recognised wherever they are stored.") })
        self:showHome()
        return
    end
    local Menu = require("ui/widget/menu")
    local menu
    menu = Menu:new{
        title = _("Go books"),
        item_table = Booklist.menu_items(books),
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        title_multilines = true,
        onMenuSelect = function(_, item)
            UIManager:close(menu)
            Env.safe("open book", function() self:openBookEntry(item.book or { prepared = true, path = item.path }) end)
        end,
        close_callback = function() UIManager:close(menu); self:showHome() end,
    }
    UIManager:show(menu)
end

-- ---------------------------------------------------------------------------
-- Menu
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- The home window: where leaving any game or list brings you back to
-- ---------------------------------------------------------------------------

function GOReader:_apps()
    if not self.apps then
        local home = function() self:showHome() end
        self.apps = {
            dgs = require("goreader.app.dgs_app").new{ home = home },
            ogs = require("goreader.app.ogs_app").new{ home = home },
            review = require("goreader.app.review_app").new{ home = home },
            sgf = require("goreader.app.sgf_app").new{ home = home },
            ogsplay = require("goreader.app.ogs_play_app").new{ home = home },
            vs = require("goreader.app.vs_app").new{ home = home },
            joseki = require("goreader.app.joseki_app").new{ home = home },
            problems = require("goreader.app.problems_app").new{ home = home },
        }
    end
    return self.apps
end

-- Everything GOReader can do: the home window and the main menu list the same entries
function GOReader:_entries()
    local apps = self:_apps()
    return {
        { text = "SGF Game", mandatory = "record / play", what = "sgf game", run = function() apps.sgf:open() end },
        { text = "Play the computer", mandatory = "GNU Go", what = "play the computer", run = function() apps.vs:open() end },
        { text = "Saved games (review)", mandatory = "SGF", what = "saved games", run = function() apps.review:open_library() end },
        { text = "Dragon Go Server", mandatory = "your games", what = "dragon go server", run = function() apps.dgs:open() end },
        { text = "Play on OGS", mandatory = "your account", what = "play on ogs", run = function() apps.ogsplay:open() end },
        { text = "Watch OGS games", mandatory = "live", what = "ogs", run = function() apps.ogs:choose_filter() end },
        { text = "Go books", mandatory = "interactive", what = "books", run = function() self:showBookList() end },
        { text = "OGS chat room", mandatory = "read only", what = "ogs chat", run = function() apps.ogs:listen_room() end },
        { text = "Joseki dictionary", mandatory = "Kogo's", what = "joseki", run = function() apps.joseki:open() end },
        { text = "Go problems", mandatory = "tsumego", what = "problems", run = function() apps.problems:open() end },
        { text = "Wi-Fi networks", mandatory = "change / forget", what = "wi-fi", run = function() Env.show_wifi_networks() end },
        { text = "OGS connection test", mandatory = "", what = "ogs test", run = function() apps.ogs:connection_test() end },
    }
end

function GOReader:showHome()
    if self.home_menu then UIManager:close(self.home_menu); self.home_menu = nil end
    local Menu = require("ui/widget/menu")
    local apps = self:_apps()
    local items = {}
    for _, e in ipairs(self:_entries()) do
        items[#items + 1] = { text = e.text, mandatory = e.mandatory,
            callback = function() UIManager:close(self.home_menu); self.home_menu = nil; Env.safe(e.what, e.run) end }
    end
    local menu
    menu = Menu:new{
        title = _("GOReader"), item_table = items,
        covers_fullscreen = true, is_borderless = true, is_popout = false, title_multilines = false,
        items_per_page = 8,
        onMenuSelect = function(_, item) item.callback() end,
        close_callback = function() UIManager:close(menu); self.home_menu = nil end,
    }
    self.home_menu = menu
    UIManager:show(menu)
    UIManager:setDirty(nil, "full")
end

function GOReader:onOpenGOReader() self:showHome(); return true end

-- KOReader lists only the entries named in its menu order: put GOReader at the top of the main list
function GOReader:_put_menu_first()
    for _, name in ipairs({ "ui/elements/filemanager_menu_order", "ui/elements/reader_menu_order" }) do
        local ok, order = pcall(require, name)
        if ok and type(order) == "table" and type(order.main) == "table" then
            local present = false
            for _, id in ipairs(order.main) do if id == "goreader" then present = true end end
            if not present then table.insert(order.main, 1, "goreader") end
        end
    end
end

function GOReader:addToMainMenu(menu_items)
    local subs = {}
    if self:_is_go_book() then                     -- inside a Go book: leaving it comes first
        subs[#subs + 1] = { text = _("Close this book, back to the Go books list"), callback = function() self:leaveBook("books") end }
        subs[#subs + 1] = { text = _("Close this book, back to GOReader"), callback = function() self:leaveBook("home") end }
        subs[#subs + 1] = { text = _("Exit KOReader"), callback = function() self:leaveBook("quit") end }
    end
    for _, e in ipairs(self:_entries()) do
        subs[#subs + 1] = { text = e.text, callback = function() Env.safe(e.what, e.run) end }
    end
    menu_items.goreader = { text = _("GOReader"), sorting_hint = "main", sub_item_table = subs }
    self:_put_menu_first()
end

return GOReader
