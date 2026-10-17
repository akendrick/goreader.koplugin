--[[
    goreader/services/storage.lua - the game library on disk.

    * The library lives OUTSIDE the plugin folder (default
      /mnt/onboard/GOReader) so a KOReader update cannot delete it.
    * Every write is atomic (temp file, size check, rename) and reports
      failure instead of ignoring it.
    * File names built from player names are sanitised.

    The filesystem is injected (`fs`), so this runs under plain Lua in tests
    and under KOReader's lfs on the device.
--]]

local Storage = {}
Storage.__index = Storage

Storage.DEFAULT_ROOT = "/mnt/onboard/GOReader"

-- ---------------------------------------------------------------------------
-- Filesystem adapters
-- ---------------------------------------------------------------------------

local function shq(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

-- os.execute returns 0 on Lua 5.1/LuaJIT and true on 5.2+
local function succeeded(r) return r == true or r == 0 end

-- Works anywhere with a POSIX shell (macOS, Linux, busybox on the Kobo).
function Storage.shell_fs()
    local fs = {}
    function fs.mkdirs(path) return succeeded(os.execute("mkdir -p " .. shq(path) .. " 2>/dev/null")) end
    function fs.is_dir(path) return succeeded(os.execute("test -d " .. shq(path))) end
    function fs.exists(path) return succeeded(os.execute("test -e " .. shq(path))) end
    function fs.list(dir)
        local out = {}
        local p = io.popen("ls -1A " .. shq(dir) .. " 2>/dev/null")
        if not p then return out end
        for line in p:lines() do out[#out + 1] = line end
        p:close()
        return out
    end
    function fs.rename(a, b) return os.rename(a, b) end
    function fs.remove(path) return os.remove(path) end
    function fs.size(path)
        local f = io.open(path, "rb"); if not f then return nil end
        local n = f:seek("end"); f:close(); return n
    end
    return fs
end

-- KOReader's lfs (device).
function Storage.lfs_fs(lfs)
    local fs = {}
    function fs.exists(path) return lfs.attributes(path) ~= nil end
    function fs.is_dir(path)
        local a = lfs.attributes(path); return a ~= nil and a.mode == "directory"
    end
    function fs.mkdirs(path)
        local cur = ""
        for part in path:gmatch("[^/]+") do
            cur = cur .. "/" .. part
            if not lfs.attributes(cur) then
                local ok = lfs.mkdir(cur)
                if not ok and not lfs.attributes(cur) then return false end
            end
        end
        return true
    end
    function fs.list(dir)
        local out = {}
        local ok, iter, state = pcall(lfs.dir, dir)
        if not ok then return out end
        for name in iter, state do
            if name ~= "." and name ~= ".." then out[#out + 1] = name end
        end
        return out
    end
    function fs.rename(a, b) return os.rename(a, b) end
    function fs.remove(path) return os.remove(path) end
    function fs.size(path)
        local a = lfs.attributes(path); return a and a.size
    end
    return fs
end

-- ---------------------------------------------------------------------------
-- Names
-- ---------------------------------------------------------------------------

-- Keep letters, digits, dot, dash and underscore; everything else becomes "-".
-- Path separators, "..", control characters and non-ASCII are all removed.
function Storage.sanitize(name, fallback)
    name = tostring(name or "")
    name = name:gsub("[\128-\255]", "")          -- non-ASCII
    name = name:gsub("[^%w%._%-]+", "-")
    name = name:gsub("%.%.+", ".")               -- no ".."
    name = name:gsub("%-+", "-"):gsub("^[%-%._]+", ""):gsub("[%-%._]+$", "")
    if #name > 60 then name = name:sub(1, 60):gsub("[%-%._]+$", "") end
    if name == "" then return fallback or "game" end
    return name
end

-- ---------------------------------------------------------------------------
-- Library
-- ---------------------------------------------------------------------------

--[[ opts: root (default DEFAULT_ROOT), fs (default shell_fs()) ]]
function Storage.new(opts)
    opts = opts or {}
    local root = (opts.root or Storage.DEFAULT_ROOT):gsub("/+$", "")
    return setmetatable({
        root = root,
        fs   = opts.fs or Storage.shell_fs(),
        dirs = { games = root .. "/games", import = root .. "/import", dgs = root .. "/dgs" },
    }, Storage)
end

function Storage:ensure()
    for _, d in pairs(self.dirs) do
        if not self.fs.mkdirs(d) then return false, "cannot create " .. d end
    end
    return true
end

-- Path in `dir` that does not exist yet: base.ext, base-2.ext, ...
function Storage:unique_path(dir, base, ext)
    local path = dir .. "/" .. base .. ext
    local n = 2
    while self.fs.exists(path) do
        path = dir .. "/" .. base .. "-" .. n .. ext
        n = n + 1
        if n > 9999 then break end
    end
    return path
end

-- Write `data` to `path` atomically. Returns true, or false + reason.
function Storage:write(path, data)
    local tmp = path .. ".tmp"
    local f, err = io.open(tmp, "wb")
    if not f then return false, "cannot open for writing: " .. tostring(err) end
    local ok, werr = f:write(data)
    local cok, cerr = f:close()
    if not ok or cok == nil then
        self.fs.remove(tmp)
        return false, "write failed: " .. tostring(werr or cerr)
    end
    local size = self.fs.size(tmp)
    if size ~= #data then
        self.fs.remove(tmp)
        return false, string.format("short write (%s of %d bytes)", tostring(size), #data)
    end
    local rok, rerr = self.fs.rename(tmp, path)
    if not rok then
        self.fs.remove(tmp)
        return false, "rename failed: " .. tostring(rerr)
    end
    return true
end

function Storage:read(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, tostring(err) end
    local t = f:read("*a"); f:close()
    return t
end

--[[ Save an SGF string under games/. `name` is a human title (e.g. players
     and date); it is sanitised. Returns path or nil, reason.
     If `path` is given, that game is overwritten in place instead.
--]]
function Storage:save_game(sgf_text, name, path)
    local ok, err = self:ensure()
    if not ok then return nil, err end
    if not path then
        path = self:unique_path(self.dirs.games, Storage.sanitize(name, "game"), ".sgf")
    end
    local wok, werr = self:write(path, sgf_text)
    if not wok then return nil, werr end
    return path
end

function Storage:list_games(dir)
    dir = dir or self.dirs.games
    local out = {}
    for _, name in ipairs(self.fs.list(dir)) do
        if name:match("%.[sS][gG][fF]$") and not name:match("^%._") then
            out[#out + 1] = { name = name, path = dir .. "/" .. name }
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

function Storage:delete_game(path)
    -- only ever delete inside the library
    if path:sub(1, #self.root + 1) ~= self.root .. "/" then
        return false, "outside the library"
    end
    if path:find("/%.%./") or path:find("/%.%.$") then return false, "bad path" end
    local ok, err = self.fs.remove(path)
    if not ok then return false, tostring(err) end
    return true
end

--[[ Move .sgf files dropped into import/ (e.g. over USB) into games/.
     Returns moved_count, errors (list of strings).
--]]
function Storage:import_dropped()
    local moved, errors = 0, {}
    self:ensure()
    for _, f in ipairs(self:list_games(self.dirs.import)) do
        local base = Storage.sanitize(f.name:gsub("%.[sS][gG][fF]$", ""), "game")
        local dest = self:unique_path(self.dirs.games, base, ".sgf")
        local text, rerr = self:read(f.path)
        if not text then
            errors[#errors + 1] = f.name .. ": " .. tostring(rerr)
        else
            local ok, werr = self:write(dest, text)
            if ok then
                self.fs.remove(f.path)
                moved = moved + 1
            else
                errors[#errors + 1] = f.name .. ": " .. tostring(werr)
            end
        end
    end
    return moved, errors
end

return Storage
