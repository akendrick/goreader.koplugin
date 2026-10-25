--[[
    goreader/book/cover.lua - the cover picture of an EPUB.

    An EPUB says where its cover is in the package file (the .opf): an item marked
    properties="cover-image", or <meta name="cover" content="item-id">, or just an
    image called cover. `Cover.find_path` follows those clues; `Cover.read` pulls the
    picture's bytes out of the zip with KOReader's archiver. No picture decoding here.
--]]

local Cover = {}

local function attrs_of(tag)
    local a = {}
    for k, v in tag:gmatch('([%w:_%-]+)%s*=%s*"([^"]*)"') do a[k] = v end
    for k, v in tag:gmatch("([%w:_%-]+)%s*=%s*'([^']*)'") do a[k] = a[k] or v end
    return a
end

local function url_decode(s)
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

-- "OPS/../images/c.jpg" -> "images/c.jpg"
local function normalise(path)
    local out = {}
    for part in path:gmatch("[^/]+") do
        if part == ".." then out[#out] = nil elseif part ~= "." then out[#out + 1] = part end
    end
    return table.concat(out, "/")
end

local function is_image(media) return type(media) == "string" and media:lower():match("^image/") ~= nil end

--[[ read(path) -> bytes | nil reads a file of the book. Returns the cover's path inside the zip, or nil. ]]
function Cover.find_path(read)
    local container = read("META-INF/container.xml")
    local opf_path = container and container:match('full%-path%s*=%s*"([^"]+)"')
    if not opf_path then return nil end
    opf_path = url_decode(opf_path)
    local opf = read(opf_path)
    if not opf then return nil end
    local dir = opf_path:match("^(.*)/[^/]*$") or ""

    local items, by_id = {}, {}
    for tag in opf:gmatch("<item%s([^>]*)>") do
        local a = attrs_of(tag)
        if a.href then items[#items + 1] = a; if a.id then by_id[a.id] = a end end
    end
    local function resolved(item) return normalise((dir ~= "" and (dir .. "/") or "") .. url_decode(item.href)) end

    for _, it in ipairs(items) do                                   -- EPUB 3
        if it.properties and (" " .. it.properties .. " "):find(" cover%-image ") and is_image(it["media-type"]) then return resolved(it) end
    end
    for tag in opf:gmatch("<meta%s([^>]*)>") do                      -- EPUB 2
        local a = attrs_of(tag)
        if a.name == "cover" and a.content and by_id[a.content] and is_image(by_id[a.content]["media-type"]) then
            return resolved(by_id[a.content])
        end
    end
    for _, it in ipairs(items) do                                   -- an image with "cover" in its name
        if is_image(it["media-type"]) and ((it.id or ""):lower():find("cover", 1, true) or it.href:lower():find("cover", 1, true)) then
            return resolved(it)
        end
    end
    for _, it in ipairs(items) do                                   -- the first picture there is
        if is_image(it["media-type"]) then return resolved(it) end
    end
    return nil
end

--[[ The cover's bytes: bytes, path | nil, reason. `archiver` is KOReader's ffi/archiver (or a stand-in). ]]
function Cover.read(archiver, epub_path)
    local reader = archiver.Reader:new()
    if not reader:open(epub_path) then return nil, "unreadable" end
    local names, lower = {}, {}
    for entry in reader:iterate() do
        if entry.mode == "file" then names[entry.path] = true; lower[entry.path:lower()] = entry.path end
    end
    local function read(path)
        local real = names[path] and path or lower[path:lower()]
        if not real then return nil end
        return reader:extractToMemory(real)
    end
    local path = Cover.find_path(read)
    if not path then reader:close(); return nil, "no cover" end
    local bytes = read(path)
    reader:close()
    if not bytes or #bytes == 0 then return nil, "empty" end
    return bytes, path
end

return Cover
