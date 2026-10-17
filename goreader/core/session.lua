--[[
    goreader/core/session.lua - the play-against-the-computer controller.

    This is the logic behind the Play screen, with no UI in it. The screen
    calls the human_* methods and listens for events; the session drives the
    engine, handles passing, scoring, undo and resignation.

    States
        "human"    waiting for the human's move
        "engine"   the engine is choosing a move
        "scoring"  both passed; dead stones are being agreed
        "over"     finished, result known

    Events (on_event(name, data)):
        "turn"          { who = "human" }
        "thinking"      { color }
        "human_move"    { col, row, captured }
        "human_pass"    {}
        "engine_move"   { col, row, captured }
        "engine_pass"   {}
        "scoring"       { dead = { {col,row}, ... } }   engine's proposal
        "game_over"     { result, reason = "resign"|"score", score? }
        "error"         { message, retry = true|false }
        "warning"       { message }
        "undo"          { count }

    `scheduler(fn)` decides when engine work runs. The default runs it
    immediately; on the device pass something like
    function(fn) UIManager:scheduleIn(0.1, fn) end so "thinking" can be drawn
    first. A generation counter discards results that arrive after an undo.
--]]

local Session = {}
Session.__index = Session

local function other(color) return color == "B" and "W" or "B" end

--[[ opts:
       game       Game (core/game.lua)
       engine     object with genmove / dead_stones (engine/engines.lua)
       human      "B" or "W"          default "B"
       scheduler  function(fn)        default: run now
       on_event   function(name, data)
--]]
function Session.new(opts)
    assert(opts.game and opts.engine, "game and engine are required")
    local human = opts.human or "B"
    return setmetatable({
        game         = opts.game,
        engine       = opts.engine,
        human        = human,
        engine_color = other(human),
        scheduler    = opts.scheduler or function(fn) fn() end,
        on_event     = opts.on_event or function() end,
        state        = "human",
        dead         = {},          -- set: "col,row" -> true (whole groups)
        generation   = 0,
        last_error   = nil,
    }, Session)
end

function Session:emit(name, data)
    self.on_event(name, data or {})
end

-- ---------------------------------------------------------------------------
-- Starting and engine turns
-- ---------------------------------------------------------------------------

function Session:start()
    if self.game:is_over() then
        if self.game.resigned then self.state = "over"
        else self:enter_scoring() end
        return
    end
    if self.game:to_move() == self.human then
        self.state = "human"
        self:emit("turn", { who = "human" })
    else
        self:request_engine()
    end
end

function Session:request_engine()
    if self.state == "over" or self.state == "scoring" then return end
    self.state = "engine"
    self.generation = self.generation + 1
    local gen = self.generation
    self:emit("thinking", { color = self.engine_color })
    self.scheduler(function()
        if gen ~= self.generation or self.state ~= "engine" then return end
        local m, err = self.engine:genmove(self.game:position(), self.engine_color)
        if gen ~= self.generation or self.state ~= "engine" then return end  -- undone meanwhile
        self:apply_engine(m, err)
    end)
end

function Session:apply_engine(m, err)
    if not m then
        self.last_error = err or "engine failed"
        self:emit("error", { message = self.last_error, retry = true })
        return
    end
    self.last_error = nil
    if m.kind == "resign" then
        self.game:resign(self.engine_color)
        self.state = "over"
        self:emit("game_over", { result = self.game:result(), reason = "resign" })
    elseif m.kind == "pass" then
        self.game:pass()
        self:emit("engine_pass")
        self:after_move()
    else
        local ok, res = self.game:play(m.col, m.row)
        if not ok then
            self.last_error = "engine proposed an illegal move (" .. tostring(res) .. ")"
            self:emit("error", { message = self.last_error, retry = true })
            return
        end
        self:emit("engine_move", { col = m.col, row = m.row, captured = res })
        self:after_move()
    end
end

-- Ask the engine again after an error
function Session:retry_engine()
    if self.state == "engine" then
        self.last_error = nil
        self:request_engine()
    end
end

function Session:after_move()
    if self.game:is_over() then
        self:enter_scoring()
    else
        self.state = "human"
        self:emit("turn", { who = "human" })
    end
end

-- ---------------------------------------------------------------------------
-- Human moves
-- ---------------------------------------------------------------------------

function Session:human_play(col, row)
    if self.state ~= "human" then return false, "not_your_turn" end
    local ok, res = self.game:play(col, row)
    if not ok then return false, res end
    self:emit("human_move", { col = col, row = row, captured = res })
    self:request_engine()
    return true, res
end

function Session:human_pass()
    if self.state ~= "human" then return false, "not_your_turn" end
    self.game:pass()
    self:emit("human_pass")
    if self.game:is_over() then self:enter_scoring() else self:request_engine() end
    return true
end

function Session:human_resign()
    if self.state == "over" then return false, "game_over" end
    self.generation = self.generation + 1            -- drop any pending engine move
    self.game:resign(self.human)
    self.state = "over"
    self:emit("game_over", { result = self.game:result(), reason = "resign" })
    return true
end

-- ---------------------------------------------------------------------------
-- Undo
-- ---------------------------------------------------------------------------

-- Take back moves until it is the human's turn again (normally the engine's
-- last reply and the human's move before it). Returns the number undone.
function Session:undo()
    if self.state == "over" or self.state == "scoring" then return 0 end
    -- nothing to take back until the human has actually moved
    local human_moves = 0
    for _, m in ipairs(self.game:position().moves) do
        if m.color == self.human then human_moves = human_moves + 1 end
    end
    if human_moves == 0 then return 0 end
    self.generation = self.generation + 1            -- cancel a move being thought about
    local n = 0
    repeat
        local done = self.game:undo(1)
        if done == 0 then break end
        n = n + done
    until self.game:to_move() == self.human or self.game:move_count() == 0
    self:emit("undo", { count = n })
    if self.game:to_move() == self.human then
        self.state = "human"
        self:emit("turn", { who = "human" })
    else
        self:request_engine()                        -- engine plays first from here
    end
    return n
end

-- ---------------------------------------------------------------------------
-- Scoring
-- ---------------------------------------------------------------------------

function Session:enter_scoring()
    self.state = "scoring"
    self.dead = {}
    local list, err = self.engine:dead_stones(self.game:position())
    if list then
        for _, p in ipairs(list) do self.dead[p[1] .. "," .. p[2]] = true end
    else
        self:emit("warning", { message = "engine could not suggest dead stones: " .. tostring(err) })
    end
    self:emit("scoring", { dead = self:dead_list() })
end

function Session:dead_list()
    local out = {}
    for key in pairs(self.dead) do
        local c, r = key:match("^(%d+),(%d+)$")
        out[#out + 1] = { tonumber(c), tonumber(r) }
    end
    table.sort(out, function(a, b) if a[2] ~= b[2] then return a[2] < b[2] end return a[1] < b[1] end)
    return out
end

-- Mark or unmark the whole group at (col,row) as dead.
function Session:toggle_dead(col, row)
    if self.state ~= "scoring" then return false, "not_scoring" end
    local group = self.game.rules:group_at(col, row)
    if not group then return false, "empty" end
    local first = group[1]
    local mark = not self.dead[first[1] .. "," .. first[2]]
    for _, p in ipairs(group) do
        local key = p[1] .. "," .. p[2]
        if mark then self.dead[key] = true else self.dead[key] = nil end
    end
    return true, mark
end

function Session:preview_score()
    return self.game.rules:score(self:dead_list())
end

function Session:confirm_score()
    if self.state ~= "scoring" then return nil, "not_scoring" end
    local score = self.game:finish(self:dead_list())
    self.state = "over"
    self:emit("game_over", { result = score.text, reason = "score", score = score })
    return score
end

-- Disagree with the scoring and carry on playing: removes the closing passes.
function Session:continue_playing()
    if self.state ~= "scoring" then return false, "not_scoring" end
    local passes = self.game.rules:consecutive_passes()
    self.game:undo(passes)
    self.dead = {}
    if self.game:to_move() == self.human then
        self.state = "human"
        self:emit("turn", { who = "human" })
    else
        self:request_engine()
    end
    return true
end

function Session:is_over() return self.state == "over" end

function Session:status()
    return {
        state      = self.state,
        to_move    = self.game:to_move(),
        moves      = self.game:move_count(),
        captures   = self.game.rules:captures(),
        last_error = self.last_error,
        result     = self.game:result(),
    }
end

return Session
