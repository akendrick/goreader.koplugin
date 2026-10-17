--[[
    goreader/core/ogsgame.lua - an OGS game as seen from a client.

    Turns OGS's game/<id>/gamedata, move, clock and phase events into our own
    Game (rules + SGF record) plus the extra things a screen needs: who is who,
    whose turn it is, what the clocks show, stone removal, the result.

    It works the same for a game you play and one you only watch.

    Field shapes follow the official client (goban). Anything not confirmed
    against the live server is marked UNVERIFIED and the code is lenient:
    move_number is taken to be 1-based; a move may arrive as [x, y, time] or as
    two letters; a gap or a mismatch asks the caller to reload the game.
--]]

local Game = require("goreader.core.game")
local OGS  = require("goreader.services.ogs")

local OGSGame = {}
OGSGame.__index = OGSGame

local floor = math.floor

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

-- OGS rank number (a float such as 30.79): 0 = 30 kyu ... 29 = 1 kyu,
-- 30 = 1 dan ... 38 = 9 dan; the fraction is dropped, as OGS shows it.
-- Seen in a real session: 30.79 and 26.6 for players shown as 1d and 4k.
function OGSGame.rank_text(n)
    if type(n) ~= "number" then return "" end
    n = floor(n)
    if n < 30 then return (30 - n) .. "k" end
    return (n - 29) .. "d"
end

-- A move as OGS sends it -> col,row | "pass" | nil
local function decode(m)
    if type(m) == "table" then
        local x, y = m[1], m[2]
        if type(x) ~= "number" or type(y) ~= "number" then return nil end
        if x < 0 or y < 0 then return "pass" end
        return x + 1, y + 1
    end
    return OGS.decode_move(m)
end

OGSGame.decode_move = decode

local function fmt_time(sec)
    sec = math.max(0, floor(sec + 0.5))
    if sec >= 86400 then return floor(sec / 86400) .. "d " .. floor((sec % 86400) / 3600) .. "h" end
    if sec >= 3600 then
        return string.format("%d:%02d:%02d", floor(sec / 3600), floor((sec % 3600) / 60), sec % 60)
    end
    return string.format("%d:%02d", floor(sec / 60), sec % 60)
end
OGSGame.format_time = fmt_time

-- ---------------------------------------------------------------------------
-- Construction and loading
-- ---------------------------------------------------------------------------

function OGSGame.new()
    return setmetatable({
        loaded = false, game = nil, raw_moves = {}, phase = "play",
        players = { B = {}, W = {} }, time_control = nil, clock = nil,
        removed = {}, desynced = false,
    }, OGSGame)
end

--[[ Rebuild from a full gamedata event. Returns true, or nil + reason. ]]
function OGSGame:load(data)
    if type(data) ~= "table" then return nil, "no game data" end
    local w, h = data.width, data.height
    if type(w) ~= "number" or w ~= h then return nil, "only square boards are supported" end
    local pb, pw = (data.players or {}).black or {}, (data.players or {}).white or {}
    local handicap = data.handicap or 0
    local game, err = Game.new{
        size = w, komi = data.komi, handicap = handicap,
        rules = ({ japanese = "Japanese", korean = "Korean" })[tostring(data.rules or ""):lower()] or "Chinese",
        black = pb.username or data.black_name, white = pw.username or data.white_name,
        black_rank = OGSGame.rank_text(pb.rank or pb.ranking),
        white_rank = OGSGame.rank_text(pw.rank or pw.ranking),
        name = data.game_name or data.name,
        allow_suicide = data.allow_self_capture == true,
    }
    if not game then return nil, err end

    self.game, self.size, self.handicap = game, w, handicap
    self.free_handicap = data.free_handicap_placement and handicap > 0
    self.game_id = data.game_id or data.id
    self.players = {
        B = { id = pb.id or data.black_player_id, name = pb.username, rank = pb.rank or pb.ranking },
        W = { id = pw.id or data.white_player_id, name = pw.username, rank = pw.rank or pw.ranking },
    }
    self.time_control = type(data.time_control) == "table" and data.time_control or nil
    self.phase = data.phase or "play"
    self.raw_moves, self.desynced, self.removed = {}, false, {}
    self.initial_player = (data.initial_player == "white") and "W" or "B"

    for _, m in ipairs(data.moves or {}) do
        local ok, why = self:_play(m)
        if not ok then
            self.desynced = true
            self.problem = why
            break
        end
    end
    if data.clock then self.clock = data.clock end
    self:_set_outcome(data)
    if data.removed then self:set_removed(data.removed) end
    self.loaded = true
    return true
end

-- Colour of the next move, taking free handicap placement into account
function OGSGame:_next_color()
    local g = self.game
    local n = g:move_count()
    if self.free_handicap and n < self.handicap then return "B" end
    if self.free_handicap and n == self.handicap then return "W" end
    return g:to_move()
end

function OGSGame:_play(m)
    local c, r = decode(m)
    if c == nil then return nil, "unreadable move" end
    local g = self.game
    local want = self:_next_color()
    if g:to_move() ~= want then g.rules:set_turn(want) end
    local ok, why
    if c == "pass" then ok = g:pass() else ok, why = g:play(c, r) end
    if not ok then return nil, "move " .. (#self.raw_moves + 1) .. ": " .. tostring(why) end
    self.raw_moves[#self.raw_moves + 1] = m
    return true
end

local function same_move(a, b)
    local c1, r1 = decode(a)
    local c2, r2 = decode(b)
    return c1 == c2 and r1 == r2
end

--[[ A game/<id>/move event: { move_number, move }.
     Returns "applied", "duplicate", or "resync" (reload the game with
     game/connect) together with a reason. ]]
function OGSGame:apply_move(ev)
    if not self.loaded then return "resync", "game not loaded" end
    if self.desynced then return "resync", "out of step" end
    local n = ev.move_number
    local count = #self.raw_moves
    if type(n) == "number" then
        if n <= count then
            if same_move(self.raw_moves[n], ev.move) then return "duplicate" end
            return "resync", "move " .. n .. " differs"
        elseif n > count + 1 then
            return "resync", "missed " .. (n - count - 1) .. " move(s)"
        end
    end
    local ok, why = self:_play(ev.move)
    if not ok then self.desynced = true; self.problem = why; return "resync", why end
    return "applied"
end

function OGSGame:set_phase(p) self.phase = p end

-- ---------------------------------------------------------------------------
-- Players and turn
-- ---------------------------------------------------------------------------

function OGSGame:color_of(player_id)
    if self.players.B.id == player_id then return "B" end
    if self.players.W.id == player_id then return "W" end
    return nil
end

-- "B" / "W" / nil (a spectator)
OGSGame.my_color = OGSGame.color_of

function OGSGame:to_move()
    if self.clock and self.clock.current_player then
        return self:color_of(self.clock.current_player) or self.game:to_move()
    end
    return self.game and self.game:to_move()
end

function OGSGame:is_my_turn(my_id)
    return self.phase == "play" and self:color_of(my_id) ~= nil and self:to_move() == self:color_of(my_id)
end

function OGSGame:move_count() return #self.raw_moves end

-- ---------------------------------------------------------------------------
-- Clocks
-- ---------------------------------------------------------------------------

function OGSGame:apply_clock(clock)
    if type(clock) ~= "table" then return end
    if self.clock then
        for k, v in pairs(clock) do self.clock[k] = v end
    else
        self.clock = clock
    end
end

--[[ What one player's clock shows at server time `now_ms`.
     Returns { text, main, periods, period_time, overtime, lost, ticking } ]]
function OGSGame:player_clock(color, now_ms)
    local c = self.clock
    if not c then return { text = "", ticking = false } end
    local t = (color == "B") and c.black_time or c.white_time
    local system = (self.time_control or {}).system
    local ticking = (self:to_move() == color) and self.phase == "play" and not c.pause and not c.paused_since
    local elapsed = 0
    if ticking and c.last_move and now_ms then elapsed = math.max(0, (now_ms - c.last_move) / 1000) end
    local out = { ticking = ticking }

    if t == nil or system == "none" then out.text = ""; return out end
    if type(t) == "number" then                        -- "simple": seconds, or a plain total
        out.main = math.max(0, t - elapsed); out.text = fmt_time(out.main)
        out.lost = ticking and out.main <= 0
        return out
    end
    local main = t.thinking_time or 0
    if system == "byoyomi" or t.periods then
        local periods, ptime = t.periods or 0, t.period_time or (self.time_control or {}).period_time or 0
        if main > 0 then
            if elapsed <= main then
                out.main = main - elapsed; out.periods = periods; out.period_time = ptime
                out.text = fmt_time(out.main) .. (periods > 0 and (" +" .. periods .. "x" .. fmt_time(ptime)) or "")
                return out
            end
            elapsed = elapsed - main                   -- spill into overtime
        end
        out.overtime = true
        if ptime <= 0 then out.lost = periods <= 0; out.text = "0:00"; return out end
        local used = floor(elapsed / ptime)
        out.periods = periods - used
        if out.periods <= 0 then out.lost = true; out.periods = 0; out.text = "0:00"; return out end
        out.period_time = ptime - (elapsed % ptime)
        out.text = out.periods .. "x " .. fmt_time(out.period_time)
        return out
    end
    if system == "canadian" or t.moves_left then
        local left, block = t.moves_left or 0, t.block_time or (self.time_control or {}).period_time or 0
        if main > 0 and elapsed <= main then
            out.main = main - elapsed; out.text = fmt_time(out.main); return out
        end
        elapsed = math.max(0, elapsed - main)
        out.overtime, out.moves_left = true, left
        out.period_time = block - elapsed
        out.lost = out.period_time <= 0
        out.text = fmt_time(math.max(0, out.period_time)) .. "/" .. left
        return out
    end
    out.main = math.max(0, main - elapsed)             -- fischer and absolute
    out.lost = ticking and out.main <= 0
    out.text = fmt_time(out.main)
    return out
end

-- ---------------------------------------------------------------------------
-- Stone removal and result
-- ---------------------------------------------------------------------------

function OGSGame:set_removed(text_or_list)
    local list = text_or_list
    if type(text_or_list) == "string" then list = OGS.unpack_stones(text_or_list) end
    self.removed = list or {}
end

function OGSGame:removed_text() return OGS.pack_stones(self.removed) end

function OGSGame:_set_outcome(data)
    if not data.outcome and not data.winner then return end
    self.outcome = data.outcome
    local winner
    if data.winner then winner = self:color_of(data.winner) end
    if not winner and data.winner_color then winner = data.winner_color == "white" and "W" or "B" end
    if not winner then return end
    self.winner = winner
    local o = tostring(data.outcome or "")
    local pts = o:match("^(%d+%.?%d*)%s*point")
    local suffix = pts or (o:lower():find("resign") and "R") or (o:lower():find("time") and "T") or ""
    self.result_text = winner .. "+" .. suffix
    self.game.result_text = self.result_text
    self.game.sgf:set_result(self.result_text)
end

function OGSGame:set_outcome(data) self:_set_outcome(data) end

function OGSGame:result() return self.result_text end
function OGSGame:to_sgf() return self.game and self.game:to_sgf() end

return OGSGame
