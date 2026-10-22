--[[
    goreader/book/library_books.lua - finding interactive Go books anywhere in
    the library, and preparing an original EPUB on the device the first time it
    is opened. The original file is never changed: a prepared copy "<name>
    (GOReader).epub" is written next to the others in the books folder.

    Everything that touches the device is injected (lfs, KOReader's
    ffi/archiver), so it is tested with fakes.
--]]

local Prepare  = require("goreader.book.prepare")
local Gobooks  = require("goreader.book.gobooks")
local Booklist = require("goreader.book.booklist")

local Lib = {}

Lib.MAX_DEPTH = 6
Lib.CHAPTERS_TO_CHECK = 15
Lib.SKIP_DIRS = { [".adds"] = true, [".kobo"] = true, [".Trashes"] = true, ["GOReader"] = false }

-- ---------------------------------------------------------------------------
-- Walking the library
-- ---------------------------------------------------------------------------

--[[ Every .epub below `root` (hidden folders and the Kobo system folders are
     skipped): list of { path, size, mtime }. ]]
function Lib.find_epubs(root, lfs, max_depth)
    local out = {}
    local function walk(dir, depth)
        local ok, iter, state = pcall(lfs.dir, dir)
        if not ok then return end
        for name in iter, state do
            if name:sub(1, 1) ~= "." then
                local path = dir .. "/" .. name
                local a = lfs.attributes(path)
                if a and a.mode == "directory" then
                    if depth < (max_depth or Lib.MAX_DEPTH) and not Lib.SKIP_DIRS[name] then walk(path, depth + 1) end
                elseif a and a.mode == "file" and name:lower():match("%.epub$") then
                    out[#out + 1] = { path = path, size = a.size, mtime = a.modification }
                end
            end
        end
    end
    walk((root:gsub("/+$", "")), 0)
    table.sort(out, function(a, b) return a.path < b.path end)
    return out
end

-- ---------------------------------------------------------------------------
-- What is inside an EPUB
-- ---------------------------------------------------------------------------

local function is_chapter(path) return path:lower():match("%.x?html?$") and not path:find("^META%-INF/") end

--[[ "prepared" (has GOReader side files), "original" (interactive gobooks
     diagrams, not yet prepared) or nil (an ordinary book or unreadable). ]]
function Lib.classify(path, Archiver)
    local reader = Archiver.Reader:new()
    if not reader:open(path) then return nil end
    local chapters = {}
    for entry in reader:iterate() do
        if entry.mode == "file" then
            if entry.path:sub(1, #Prepare.SIDE_DIR) == Prepare.SIDE_DIR then reader:close(); return "prepared" end
            if is_chapter(entry.path) then chapters[#chapters + 1] = entry.path end
        end
    end
    local kind
    for i = 1, math.min(#chapters, Lib.CHAPTERS_TO_CHECK) do
        local data = reader:extractToMemory(chapters[i])
        if data and Gobooks.is_gobooks(data) then kind = "original"; break end
    end
    reader:close()
    return kind
end

-- Write a prepared copy of `src` to `dst` (through a temporary file). Returns stats or nil, reason.
function Lib.prepare(src, dst, Archiver, rename)
    local reader = Archiver.Reader:new()
    if not reader:open(src) then return nil, "cannot read the book" end
    local order = {}
    for entry in reader:iterate() do
        if entry.mode == "file" then order[#order + 1] = entry.path end
    end
    local tmp = dst .. ".tmp"
    local writer = Archiver.Writer:new()
    if not writer:open(tmp, "epub") then reader:close(); return nil, "cannot write " .. tmp end
    writer:setZipCompression("deflate")
    local mtime = os.time()
    local failed
    local stats = Prepare.book{
        entries = function() return order end,
        read = function(path) return reader:extractToMemory(path) or "" end,
        write_entry = function(path, data)
            if path == "mimetype" then            -- the EPUB rule: first, and stored
                writer:setZipCompression("store")
                if not writer:addFileFromMemory(path, data, mtime) then failed = path end
                writer:setZipCompression("deflate")
            elseif not writer:addFileFromMemory(path, data, mtime) then failed = failed or path end
        end,
    }
    writer:close(); reader:close()
    if failed then os.remove(tmp); return nil, "could not write " .. failed end
    if stats.figures == 0 then os.remove(tmp); return nil, "no interactive diagrams found" end
    local ok = (rename or os.rename)(tmp, dst)
    if not ok then return nil, "could not save " .. dst end
    return stats
end

-- ---------------------------------------------------------------------------
-- The list for the menu
-- ---------------------------------------------------------------------------

function Lib.prepared_path(book_dir, source_path)
    local name = source_path:match("([^/]+)$"):gsub("%.[eE][pP][uU][bB]$", "")
    return book_dir:gsub("/+$", "") .. "/" .. name .. " (GOReader).epub"
end

--[[ opts: root, books_dir, lfs, archiver, cache (table, updated in place),
     progress(i, n) optional.
     Returns list of { title, path, size, prepared, source, dst } sorted by title:
     prepared books open directly; originals have prepared=false and are
     prepared on first open (source -> dst). ]]
function Lib.list(opts)
    local lfs, cache = opts.lfs, opts.cache or {}
    local found = Lib.find_epubs(opts.root, lfs)
    local prepared_by_title, originals = {}, {}
    local out = {}
    for i, f in ipairs(found) do
        if opts.progress then opts.progress(i, #found) end
        local key = f.path
        local c = cache[key]
        if not (c and c.size == f.size and c.mtime == f.mtime) then
            local ok, kind = pcall(Lib.classify, f.path, opts.archiver)
            c = { size = f.size, mtime = f.mtime, kind = ok and kind or false }
            cache[key] = c
        end
        local file = f.path:match("([^/]+)$")
        local title = Booklist.title(file)
        if c.kind == "prepared" or file:find("(GOReader)", 1, true) then
            prepared_by_title[title:lower()] = true
            out[#out + 1] = { title = title, path = f.path, size = f.size, prepared = true }
        elseif c.kind == "original" then
            originals[#originals + 1] = { title = title, source = f.path, size = f.size }
        end
    end
    for _, o in ipairs(originals) do
        if not prepared_by_title[o.title:lower()] then
            local dst = Lib.prepared_path(opts.books_dir, o.source)
            local a = lfs.attributes(dst)
            if a and a.mode == "file" then
                out[#out + 1] = { title = o.title, path = dst, size = a.size, prepared = true }
            else
                out[#out + 1] = { title = o.title, path = dst, size = o.size, prepared = false, source = o.source, dst = dst }
            end
        end
    end
    table.sort(out, function(a, b)
        if a.title:lower() ~= b.title:lower() then return a.title:lower() < b.title:lower() end
        return a.path < b.path
    end)
    return out, cache
end

return Lib
