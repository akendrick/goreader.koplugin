--[[
    goreader/services/settings.lua - user settings and saved sign-ins.

    * One JSON file in the library (settings.json); every value is checked
      against a schema, so a hand-edited or damaged file can never put the
      app in a state it cannot display.
    * A damaged file is kept as settings.json.bad and defaults are used.
    * Passwords are never stored. Tokens (DGS session, OGS token) go in a
      separate secrets.json, readable by the owner only where chmod works.
    * Online games always ask for CONFIRM MOVE; that is not a setting.
--]]

local json = require("goreader.services.json")

local Settings = {}
Settings.__index = Settings

local function enum(...)
    local set = {}
    for _, v in ipairs({ ... }) do set[v] = true end
    return function(v) return set[v] == true end
end

local function int_between(a, b)
    return function(v) return type(v) == "number" and v == math.floor(v) and v >= a and v <= b end
end

local function is_bool(v) return type(v) == "boolean" end
local function short_string(v) return type(v) == "string" and #v <= 64 end
local function name_list(v)
    if type(v) ~= "table" then return false end
    for _, n in ipairs(v) do if type(n) ~= "string" or #n > 64 then return false end end
    return #v <= 200
end

Settings.SCHEMA = {
    ["play.size"]        = { default = 9,        check = enum(9, 13, 19) },
    ["play.engine"]      = { default = "gnugo",  check = enum("gnugo", "pachi", "remote") },
    ["play.level"]       = { default = 3,        check = int_between(1, 10) },
    ["play.human_color"] = { default = "B",      check = enum("B", "W", "random") },
    ["play.handicap"]    = { default = 0,        check = function(v) return v == 0 or int_between(2, 9)(v) end },
    ["play.rules"]       = { default = "Chinese", check = enum("Chinese", "Japanese") },
    ["view.coordinates"] = { default = true,     check = is_bool },
    ["view.move_numbers"] = { default = false,   check = is_bool },
    ["view.games_per_page"] = { default = 9,     check = int_between(3, 20) },
    ["dgs.user"]         = { default = "",       check = short_string },
    ["ogs.user"]         = { default = "",       check = short_string },
    ["ogs.chat"]         = { default = true,     check = is_bool },
    ["ogs.muted"]        = { default = {},       check = name_list },
    ["remote.url"]       = { default = "",       check = function(v) return type(v) == "string" and #v <= 200 and (v == "" or v:match("^https://")) ~= nil end },
}

local function copy(v)
    if type(v) ~= "table" then return v end
    local t = {}
    for i, x in ipairs(v) do t[i] = x end
    return t
end

--[[ opts: storage (services/storage), file (default root/settings.json),
            secrets_file (default root/secrets.json) ]]
function Settings.new(opts)
    local st = assert(opts.storage, "storage is required")
    local self = setmetatable({
        storage = st,
        file = opts.file or (st.root .. "/settings.json"),
        secrets_file = opts.secrets_file or (st.root .. "/secrets.json"),
        values = {}, secrets = {}, warning = nil,
    }, Settings)
    for k, def in pairs(Settings.SCHEMA) do self.values[k] = copy(def.default) end
    return self
end

-- Load from disk. Always leaves usable values. Returns true, or false + why.
function Settings:load()
    self.warning = nil
    local text = self.storage:read(self.file)
    if text then
        local data = json.decode(text)
        if type(data) ~= "table" or data[1] ~= nil then
            self.storage.fs.rename(self.file, self.file .. ".bad")
            self.warning = "settings file was damaged; defaults restored"
        else
            for k, v in pairs(data) do
                local def = Settings.SCHEMA[k]
                if def and def.check(v) then self.values[k] = copy(v) end
            end
        end
    end
    local stext = self.storage:read(self.secrets_file)
    if stext then
        local s = json.decode(stext)
        if type(s) == "table" and s[1] == nil then self.secrets = s end
    end
    return self.warning == nil, self.warning
end

function Settings:get(key)
    assert(Settings.SCHEMA[key], "unknown setting: " .. tostring(key))
    return copy(self.values[key])
end

-- Returns true, or nil + reason
function Settings:set(key, value)
    local def = Settings.SCHEMA[key]
    if not def then return nil, "unknown setting" end
    if not def.check(value) then return nil, "invalid value for " .. key end
    self.values[key] = copy(value)
    return true
end

function Settings:reset(key)
    local def = Settings.SCHEMA[key]
    if def then self.values[key] = copy(def.default) end
end

function Settings:save()
    local ok, err = self.storage:ensure()
    if not ok then return nil, err end
    local wok, werr = self.storage:write(self.file, json.encode(self.values))
    if not wok then return nil, werr end
    return true
end

-- ---------------------------------------------------------------------------
-- Secrets (tokens only; never passwords)
-- ---------------------------------------------------------------------------

function Settings:get_secret(name) return self.secrets[name] end

function Settings:set_secret(name, value)
    if type(name) ~= "string" or name == "" then return nil, "bad name" end
    if value ~= nil and type(value) ~= "string" then return nil, "bad value" end
    self.secrets[name] = value
    local ok, err = self.storage:ensure()
    if not ok then return nil, err end
    local wok, werr = self.storage:write(self.secrets_file, json.encode(self.secrets))
    if not wok then return nil, werr end
    -- owner-only where the filesystem supports it (the Kobo's FAT volume does not)
    os.execute("chmod 600 '" .. self.secrets_file:gsub("'", "'\\''") .. "' 2>/dev/null")
    return true
end

function Settings:forget_secrets()
    self.secrets = {}
    self.storage.fs.remove(self.secrets_file)
end

return Settings
