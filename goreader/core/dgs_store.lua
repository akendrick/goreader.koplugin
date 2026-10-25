--[[
    goreader/core/dgs_store.lua - Dragon Go Server games kept in the Saved Games folder.

    A running game is downloaded once and saved as dgs-<opponent>-<id>.sgf. Next time
    the list of your games is fetched, each one is compared with what is on the reader
    by its DGS move id (it changes with every move): if it is the same the saved file is
    used and nothing is downloaded. A changed game is downloaded again, and any notes
    you wrote on moves of the old file are carried over into the new one.

    An index (dgs-index.json) remembers which move id each saved file is at. Files
    are plain SGF, so they also show up in Saved games.
--]]

local json    = require("goreader.services.json")
local SGF     = require("goreader.core.sgf")
local Storage = require("goreader.services.storage")

local Store = {}
Store.__index = Store

--[[ opts: storage (services/storage), index_path (default <root>/dgs-index.json) ]]
function Store.new(opts)
    local st = assert(opts.storage)
    return setmetatable({
        storage = st, index_path = opts.index_path or (st.root .. "/dgs-index.json"), index = nil,
    }, Store)
end

-- The file name used for a game; the same one the replay screen saves your notes to
function Store.file_name(opponent, gid)
    return "dgs-" .. Storage.sanitize(opponent or "opponent", "opponent") .. "-" .. tostring(gid) .. ".sgf"
end

function Store:path(opponent, gid) return self.storage.dirs.games .. "/" .. Store.file_name(opponent, gid) end

function Store:_load()
    if self.index then return self.index end
    local text = self.storage:read(self.index_path)
    local ok, t = pcall(json.decode, text or "")
    self.index = (ok and type(t) == "table") and t or {}
    return self.index
end

function Store:_save()
    self.storage:write(self.index_path, json.encode(self.index or {}))
end

local function looks_like_sgf(text) return type(text) == "string" and text:match("^%s*%(%s*;") ~= nil end

-- The saved text of a game whatever its move, or nil
function Store:read_local(opponent, gid)
    local text = self.storage:read(self:path(opponent, gid))
    if looks_like_sgf(text) then return text end
end

--[[ The saved game if it is at this move id, else nil. Returns text, path. ]]
function Store:lookup(gid, move_id, opponent)
    local e = self:_load()[tostring(gid)]
    if not e or move_id == nil or tostring(e.move_id) ~= tostring(move_id) then return nil end
    local text = self:read_local(opponent, gid)
    if not text then return nil end
    return text, self:path(opponent, gid)
end

-- Notes (move comments) you wrote in `old` are put into `new` where the same move is at the same place
function Store.merge_notes(old_text, new_text)
    local ok, merged = pcall(function()
        local og, ng = SGF.parse(old_text), SGF.parse(new_text)
        if not og or not ng then return new_text end
        local function line(game)
            local out, n = {}, game.root
            while n do out[#out + 1] = n; n = n.children[1] end
            return out
        end
        local a, b = line(og), line(ng)
        local changed = false
        for i = 2, math.min(#a, #b) do
            local o, n = a[i], b[i]
            local same = (o.props.B and n.props.B and o.props.B[1] == n.props.B[1])
                      or (o.props.W and n.props.W and o.props.W[1] == n.props.W[1])
            if same and o.props.C and o.props.C[1] ~= "" and (not n.props.C or n.props.C[1] ~= o.props.C[1]) then
                n.props.C = { o.props.C[1] }
                changed = true
            end
        end
        if not changed then return new_text end
        return SGF.write(ng)
    end)
    if ok and type(merged) == "string" then return merged end
    return new_text
end

--[[ Save a downloaded game and remember its move id. Notes from an earlier saved copy are kept.
     Returns the text as saved, path | nil, reason. ]]
function Store:record(gid, move_id, opponent, text)
    if not looks_like_sgf(text) then return nil, "not_sgf" end
    local path = self:path(opponent, gid)
    local old = self:read_local(opponent, gid)
    local out = old and Store.merge_notes(old, text) or text
    local ok, err = self.storage:write(path, out)
    if not ok then return nil, err end
    self:_load()[tostring(gid)] = { move_id = tostring(move_id), file = Store.file_name(opponent, gid) }
    self:_save()
    return out, path
end

function Store:forget_all() self.index = {}; self:_save() end

return Store
