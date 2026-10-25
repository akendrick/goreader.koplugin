--[[
    goreader/core/quick_messages.lua - the one-tap chat messages for OGS games.

    A plain list of short texts. These functions return a NEW list (or nil + a reason),
    so the caller saves only what was accepted.
--]]

local QM = {}

QM.DEFAULTS = {
    "Hello, have fun!", "Good luck!", "Thanks!", "gg, thank you for the game",
    "One moment please", "OK", "Sorry, my e-ink screen is slow",
}

QM.MAX_COUNT = 20
QM.MAX_LENGTH = 100            -- characters (OGS chat takes more, but these are meant to be short)

local function copy(list) local t = {}; for i, v in ipairs(list) do t[i] = v end; return t end

-- Text as it would be saved: control characters and runs of spaces removed. nil + reason when unusable.
function QM.clean(text)
    if type(text) ~= "string" then return nil, "empty" end
    text = text:gsub("[%z\1-\8\11\12\14-\31\127]", ""):gsub("[\t\n\r]", " "):gsub(" +", " ")
    text = text:match("^%s*(.-)%s*$")
    if text == "" then return nil, "empty" end
    -- count characters, not bytes
    local chars = 0
    for _ in text:gmatch("[^\128-\191]") do chars = chars + 1 end
    if chars > QM.MAX_LENGTH then return nil, "too_long" end
    return text
end

local function index_of(list, text, except)
    for i, v in ipairs(list) do if v == text and i ~= except then return i end end
end

function QM.add(list, text)
    local t, why = QM.clean(text)
    if not t then return nil, why end
    if #list >= QM.MAX_COUNT then return nil, "full" end
    if index_of(list, t) then return nil, "duplicate" end
    local out = copy(list)
    out[#out + 1] = t
    return out
end

function QM.edit(list, i, text)
    if not list[i] then return nil, "missing" end
    local t, why = QM.clean(text)
    if not t then return nil, why end
    if index_of(list, t, i) then return nil, "duplicate" end
    local out = copy(list)
    out[i] = t
    return out
end

function QM.delete(list, i)
    if not list[i] then return nil, "missing" end
    local out = copy(list)
    table.remove(out, i)
    return out
end

function QM.reset() return copy(QM.DEFAULTS) end

-- For the settings schema: a list of at most MAX_COUNT usable texts
function QM.valid_list(v)
    if type(v) ~= "table" or #v > QM.MAX_COUNT then return false end
    for _, t in ipairs(v) do
        if type(t) ~= "string" or QM.clean(t) ~= t then return false end
    end
    return true
end

QM.REASONS = {
    empty = "The message is empty.", too_long = "That message is too long (at most " .. QM.MAX_LENGTH .. " characters).",
    duplicate = "That message is already in the list.", full = "The list is full (" .. QM.MAX_COUNT .. " messages). Delete one first.",
    missing = "That message is gone.",
}

return QM
