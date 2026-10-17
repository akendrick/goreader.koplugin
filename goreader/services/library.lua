--[[
    goreader/services/library.lua - the list of saved games.

    Reads just enough of each SGF to show a row (players, result, date, size,
    number of moves), sorts, filters and pages the list. Titles shown on the
    reader drop non-Latin characters (the e-ink fonts lack them); the full
    text is kept for searching.

        local lib = Library.new{ storage = st }
        lib:scan()
        local page = lib:page(1, 9, { sort = "recent", filter = "ann" })
--]]

local Library = {}
Library.__index = Library

-- ASCII-only display text
function Library.latin_only(s)
    s = tostring(s or ""):gsub("[\128-\255]", ""):gsub("%s+", " ")
    return s:match("^%s*(.-)%s*$")
end

-- Value of the first NAME[...] property (handles \] escapes), or nil.
-- Lua patterns have no alternation, so the value is scanned by hand.
local function prop(head, name)
    local from = 1
    while true do
        local s, e = head:find(name .. "[", from, true)
        if not s then return nil end
        local before = s > 1 and head:sub(s - 1, s - 1) or ";"
        if not before:match("%u") then               -- not the tail of a longer name
            local buf, i = {}, e + 1
            while i <= #head do
                local c = head:sub(i, i)
                if c == "\\" then buf[#buf + 1] = head:sub(i + 1, i + 1); i = i + 2
                elseif c == "]" then return table.concat(buf)
                else buf[#buf + 1] = c; i = i + 1 end
            end
            return table.concat(buf)
        end
        from = e + 1
    end
end

-- Read the header fields of an SGF text
function Library.read_header(text)
    local head = text:sub(1, 4096)
    local moves = 0
    for _ in text:gmatch(";[BW]%[") do moves = moves + 1 end
    local size = tonumber((prop(head, "SZ") or "19"):match("^%d+")) or 19
    return {
        black = prop(head, "PB") or "", white = prop(head, "PW") or "",
        black_rank = prop(head, "BR") or "", white_rank = prop(head, "WR") or "",
        result = prop(head, "RE") or "", date = prop(head, "DT") or "",
        name = prop(head, "GN") or "", event = prop(head, "EV") or "",
        size = size, moves = moves,
    }
end

function Library.new(opts)
    return setmetatable({ storage = assert(opts.storage), entries = {}, errors = {} }, Library)
end

local function title_for(h, file_name)
    local b, w = Library.latin_only(h.black), Library.latin_only(h.white)
    if b ~= "" and w ~= "" then return b .. " vs " .. w end
    local n = Library.latin_only(h.name)
    if n ~= "" then return n end
    return (file_name:gsub("%.[sS][gG][fF]$", ""))
end

--[[ Read every game's header. Returns the number of games. Unreadable files
     are listed in self.errors, not fatal. ]]
function Library:scan()
    self.entries, self.errors = {}, {}
    for _, f in ipairs(self.storage:list_games()) do
        local text, err = self.storage:read(f.path)
        if not text then
            self.errors[#self.errors + 1] = f.name .. ": " .. tostring(err)
        elseif not text:match("^%s*%(%s*;") then
            self.errors[#self.errors + 1] = f.name .. ": not an SGF file"
        else
            local h = Library.read_header(text)
            h.path, h.file = f.path, f.name
            h.title = title_for(h, f.name)
            h.finished = h.result ~= ""
            h.search = (h.black .. " " .. h.white .. " " .. h.name .. " " .. h.event .. " " .. f.name):lower()
            self.entries[#self.entries + 1] = h
        end
    end
    return #self.entries
end

local SORTS = {
    name   = function(a, b) return a.title:lower() < b.title:lower() end,
    date   = function(a, b) if a.date ~= b.date then return a.date > b.date end return a.file < b.file end,
    recent = function(a, b) if a.date ~= b.date then return a.date > b.date end return a.file > b.file end,
    moves  = function(a, b) if a.moves ~= b.moves then return a.moves > b.moves end return a.file < b.file end,
}

--[[ opts: sort ("name" | "date" | "recent" | "moves"), filter (text, matches
     players, game name, event and file name), unfinished (only games without a result) ]]
function Library:page(page, per_page, opts)
    opts = opts or {}
    per_page = math.max(1, per_page or 9)
    local list = {}
    local needle = opts.filter and opts.filter:lower():match("^%s*(.-)%s*$") or ""
    for _, e in ipairs(self.entries) do
        if (needle == "" or e.search:find(needle, 1, true)) and not (opts.unfinished and e.finished) then
            list[#list + 1] = e
        end
    end
    table.sort(list, SORTS[opts.sort or "recent"] or SORTS.recent)
    local pages = math.max(1, math.ceil(#list / per_page))
    page = math.max(1, math.min(page or 1, pages))
    local items = {}
    for i = (page - 1) * per_page + 1, math.min(#list, page * per_page) do items[#items + 1] = list[i] end
    return { items = items, page = page, pages = pages, total = #list }
end

-- One-line description for a row: "19x19  W+R  2026-10-03  187 moves"
function Library.describe(e)
    local parts = { e.size .. "x" .. e.size }
    if e.result ~= "" then parts[#parts + 1] = Library.latin_only(e.result) end
    if e.date ~= "" then parts[#parts + 1] = Library.latin_only(e.date) end
    parts[#parts + 1] = e.moves .. (e.moves == 1 and " move" or " moves")
    return table.concat(parts, "  ")
end

return Library
