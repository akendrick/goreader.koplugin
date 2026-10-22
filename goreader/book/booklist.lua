--[[
    goreader/book/booklist.lua - the Go books on the device, for a menu.

    KOReader on a Kobo can show a "virtual library" instead of folders, so a
    GOReader menu lists the books folder itself and opens a book directly.
--]]

local Booklist = {}

Booklist.DEFAULT_DIR = "/mnt/onboard/GOReader/books"

-- "sg0189_sg_shup_sample (GOReader).epub" -> "sg0189 sg shup sample"
function Booklist.title(file_name)
    local t = file_name:gsub("%.[eE][pP][uU][bB]$", ""):gsub("%s*%(GOReader%)%s*$", "")
    t = t:gsub("[_]+", " "):gsub("%s+", " ")
    return (t:match("^%s*(.-)%s*$"))
end

--[[ lfs: anything with dir(path) and attributes(path) like LuaFileSystem.
     Returns a list of { title, path, prepared, size } sorted by title, or
     nil + reason when the folder cannot be read. ]]
function Booklist.scan(dir, lfs)
    dir = (dir or Booklist.DEFAULT_DIR):gsub("/+$", "")
    local attr = lfs.attributes(dir)
    if not attr or attr.mode ~= "directory" then return nil, "no_folder" end
    local ok, iter, state = pcall(lfs.dir, dir)
    if not ok then return nil, "unreadable" end
    local out = {}
    for name in iter, state do
        if name:lower():match("%.epub$") and not name:match("^%.") then
            local path = dir .. "/" .. name
            local a = lfs.attributes(path)
            if a and a.mode == "file" then
                out[#out + 1] = { title = Booklist.title(name), path = path, file = name,
                                  prepared = name:find("(GOReader)", 1, true) ~= nil, size = a.size }
            end
        end
    end
    table.sort(out, function(a, b)
        if a.title:lower() ~= b.title:lower() then return a.title:lower() < b.title:lower() end
        return a.file < b.file
    end)
    return out
end

function Booklist.size_text(bytes)
    if not bytes then return "" end
    if bytes >= 1048576 then return string.format("%.1f MB", bytes / 1048576) end
    return string.format("%d KB", math.max(1, math.floor(bytes / 1024 + 0.5)))
end

-- Menu rows for KOReader's Menu widget: { text, path }
function Booklist.menu_items(books)
    local items = {}
    for _, b in ipairs(books) do
        items[#items + 1] = {
            text = b.title .. (b.prepared and "" or "  (not prepared)"),
            mandatory = Booklist.size_text(b.size),
            path = b.path,
        }
    end
    return items
end

return Booklist
