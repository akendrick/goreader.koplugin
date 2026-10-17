--[[
    goreader/engine/engines.lua - engine adapters (Pachi, GNU Go, generic).

    An engine object offers:
        engine:genmove(position, color)   -> { kind="move"|"pass"|"resign", col, row } | nil, err
        engine:dead_stones(position)      -> { {col,row}, ... } | nil, err
        engine:final_score(position)      -> { winner, text } | nil, err
        engine:describe()                 -> short label for the UI

    `position` comes from Game:position(). Each call starts a fresh engine
    process and replays the game (see gtp.lua), so engines hold no state.

    A remote engine (KataGo behind knotwork.ca) can implement the same four
    methods and be dropped in without touching the game screens.
--]]

local GTP = require("goreader.engine.gtp")

local Engines = {}

-- Pachi playouts per move for levels 1..10. UNCALIBRATED: placeholders to be
-- tuned by benchmarking on the device and playing games. Pachi refuses to run
-- with fewer than 500 playouts ("minimum 500 playouts"), so level 1 is 500.
Engines.PACHI_MIN_PLAYOUTS = 500
Engines.PACHI_PLAYOUTS = { 500, 750, 1000, 1500, 2000, 3000, 4000, 6000, 8000, 12000 }

local Engine = {}
Engine.__index = Engine

-- spec: { name, cmdline, pre = {cmds}, env = {popen=..}, label }
function Engines.generic(spec)
    return setmetatable({
        name = spec.name or "engine", cmdline = assert(spec.cmdline),
        pre = spec.pre or {}, env = spec.env, label = spec.label,
    }, Engine)
end

function Engine:describe()
    return self.label or self.name
end

-- Run the position plus `final` commands; returns the response to the last one.
function Engine:_ask(position, final)
    local cmds = GTP.position_commands(position, { pre = self.pre, final = final })
    local responses, err = GTP.run(self.cmdline, cmds, self.env)
    if not responses then return nil, err end
    local want = #cmds                        -- the last command is the question
    if #responses < want then
        return nil, string.format("engine stopped early (%d of %d replies)", #responses, want)
    end
    for i = 1, want - #final do               -- setup / play commands
        if not responses[i].ok then
            return nil, "engine rejected '" .. cmds[i] .. "': " .. responses[i].text
        end
    end
    local reply = responses[want]
    if not reply.ok then return nil, "engine error: " .. reply.text end
    return reply.text
end

function Engine:genmove(position, color)
    local text, err = self:_ask(position, { "genmove " .. GTP.color_name(color) })
    if not text then return nil, err end
    return GTP.parse_genmove(text, position.size)
end

function Engine:dead_stones(position)
    local text, err = self:_ask(position, { "final_status_list dead" })
    if not text then return nil, err end
    return GTP.parse_vertex_list(text, position.size)
end

function Engine:final_score(position)
    local text, err = self:_ask(position, { "final_score" })
    if not text then return nil, err end
    return GTP.parse_score(text)
end

-- ---------------------------------------------------------------------------
-- Pachi
-- ---------------------------------------------------------------------------

--[[ opts:
       path       default "pachi"
       level      1..10 (see PACHI_PLAYOUTS), or
       playouts   explicit playouts per move (wins over level)
       threads    default 1
       tree_mb    memory cap for the search tree, default 128 (512 MB device)
       data_dir   folder holding patterns_mm.gamma / patterns_mm.spat
                  (set as DATA_DIR for the process)
       extra      list of extra arguments
       env        for tests
--]]
function Engines.pachi(opts)
    opts = opts or {}
    local playouts = opts.playouts
    if playouts then playouts = math.max(Engines.PACHI_MIN_PLAYOUTS, playouts) end
    if not playouts then
        local lvl = math.max(1, math.min(10, opts.level or 5))
        playouts = Engines.PACHI_PLAYOUTS[lvl]
    end
    local parts = {
        opts.path or "pachi",
        "-t", "=" .. tostring(playouts),
        "--nodcnn",
        "threads=" .. tostring(opts.threads or 1),
        "max_tree_size=" .. tostring(opts.tree_mb or 128),
    }
    for _, a in ipairs(opts.extra or {}) do parts[#parts + 1] = a end
    local cmd = table.concat(parts, " ")
    if opts.data_dir then cmd = "DATA_DIR='" .. opts.data_dir .. "' " .. cmd end
    return Engines.generic{
        name = "pachi", cmdline = cmd, env = opts.env,
        label = "Pachi (" .. playouts .. " playouts)",
    }
end

-- ---------------------------------------------------------------------------
-- GNU Go
-- ---------------------------------------------------------------------------

--[[ opts:
       path    default "gnugo"
       level   0..10, default 8
       rules   "chinese" (default) | "japanese"
--]]
function Engines.gnugo(opts)
    opts = opts or {}
    local level = math.max(0, math.min(10, opts.level or 8))
    local rules = (opts.rules == "japanese") and "--japanese-rules" or "--chinese-rules"
    local cmd = table.concat({
        opts.path or "gnugo", "--mode", "gtp", "--level", tostring(level), rules,
    }, " ")
    return Engines.generic{
        name = "gnugo", cmdline = cmd, env = opts.env,
        label = "GNU Go (level " .. level .. ")",
    }
end

return Engines
