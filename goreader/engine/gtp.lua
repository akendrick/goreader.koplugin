--[[
    goreader/engine/gtp.lua - Go Text Protocol helpers.

    Pure Lua. Builds GTP scripts, parses responses and converts coordinates.

    We talk to engines in "one-shot" mode: build a complete script (board
    size, komi, setup stones, every move so far, then genmove), feed it to a
    fresh engine process on stdin, and read the replies from stdout. That
    needs only io.popen (one direction) and no long-lived pipes, and it is
    robust on e-ink readers where a stuck process would otherwise hang the UI.

    Coordinates here are GOReader's: col 1..N left to right, row 1..N TOP to
    bottom. GTP uses letters A..T (no I) and rows counted from the BOTTOM.
--]]

local GTP = {}

local LETTERS = "ABCDEFGHJKLMNOPQRSTUVWXYZ"   -- no I

-- (col,row) -> "D4"
function GTP.vertex(col, row, size)
    local letter = LETTERS:sub(col, col)
    assert(letter ~= "", "column out of range")
    return letter .. tostring(size - row + 1)
end

-- "D4" -> col,row    "pass" -> "pass"    "resign" -> "resign"    bad -> nil,err
function GTP.parse_vertex(s, size)
    if not s then return nil, "empty vertex" end
    s = s:gsub("^%s+", ""):gsub("%s+$", ""):upper()
    if s == "PASS" then return "pass" end
    if s == "RESIGN" then return "resign" end
    local letter, num = s:match("^([A-HJ-Z])(%d+)$")
    if not letter then return nil, "bad vertex: " .. s end
    local col = LETTERS:find(letter, 1, true)
    local row = size - tonumber(num) + 1
    if col < 1 or col > size or row < 1 or row > size then
        return nil, "vertex off board: " .. s
    end
    return col, row
end

local function color_name(c)
    if c == "B" then return "black" end
    if c == "W" then return "white" end
    error("bad colour: " .. tostring(c))
end
GTP.color_name = color_name

--[[ Build the command list that recreates `position` (see Game:position())
       position  { size, komi, setup={B=,W=}, moves={ {color,col,row} } }
       opts.pre      extra commands sent right after clear_board/komi
       opts.final    commands appended after the position
     Returns a list of command strings (no trailing newline).
--]]
function GTP.position_commands(position, opts)
    opts = opts or {}
    local cmds = {
        "boardsize " .. position.size,
        "clear_board",
        "komi " .. tostring(position.komi),
    }
    for _, c in ipairs(opts.pre or {}) do cmds[#cmds + 1] = c end
    local setup = position.setup or { B = {}, W = {} }
    for _, p in ipairs(setup.B) do
        cmds[#cmds + 1] = "play black " .. GTP.vertex(p[1], p[2], position.size)
    end
    for _, p in ipairs(setup.W) do
        cmds[#cmds + 1] = "play white " .. GTP.vertex(p[1], p[2], position.size)
    end
    for _, m in ipairs(position.moves or {}) do
        local v = m.col and GTP.vertex(m.col, m.row, position.size) or "pass"
        cmds[#cmds + 1] = "play " .. color_name(m.color) .. " " .. v
    end
    for _, c in ipairs(opts.final or {}) do cmds[#cmds + 1] = c end
    return cmds
end

-- Script text: commands one per line, ending with quit.
function GTP.script(cmds)
    return table.concat(cmds, "\n") .. "\nquit\n"
end

--[[ Parse engine output into responses, in order.
     Each: { ok = bool, text = "..." }.
     Handles "= x", "=12 x", "? error", multi-line bodies ended by a blank
     line, CRLF, and stray chatter before the first response.
--]]
function GTP.parse(output)
    local responses = {}
    local cur
    output = (output or ""):gsub("\r", "")
    for line in (output .. "\n"):gmatch("([^\n]*)\n") do
        local mark, rest = line:match("^([=?])%d*%s?(.*)$")
        if mark then
            cur = { ok = (mark == "="), text = rest }
            responses[#responses + 1] = cur
        elseif line == "" then
            cur = nil
        elseif cur then
            cur.text = cur.text .. "\n" .. line
        end                                   -- else: ignore chatter
    end
    return responses
end

-- A genmove reply -> { kind = "move", col, row } | { kind = "pass" } | { kind = "resign" }
function GTP.parse_genmove(text, size)
    local c, r = GTP.parse_vertex(text, size)
    if c == "pass" then return { kind = "pass" } end
    if c == "resign" then return { kind = "resign" } end
    if not c then return nil, r end
    return { kind = "move", col = c, row = r }
end

-- "D4 D5\nQ16" -> { {col,row}, ... }   (final_status_list output)
function GTP.parse_vertex_list(text, size)
    local out = {}
    for tok in (text or ""):gmatch("%S+") do
        local c, r = GTP.parse_vertex(tok, size)
        if c and c ~= "pass" and c ~= "resign" then out[#out + 1] = { c, r } end
    end
    return out
end

-- "B+3.5" / "W+R" / "0" -> { winner = "B"|"W"|nil, text = ... }
function GTP.parse_score(text)
    text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local w = text:match("^([BW])%+")
    return { winner = w, text = text }
end

--[[ Run a complete script through an engine command.
       cmdline  shell command that starts the engine in GTP mode
       cmds     list of GTP commands (see position_commands)
       env      { popen = io.popen, tmpname = os.tmpname, remove = os.remove }
     Returns the list of parsed responses, or nil + error.
--]]
function GTP.run(cmdline, cmds, env)
    env = env or {}
    local popen   = env.popen   or io.popen
    local tmpname = env.tmpname or os.tmpname
    local remove  = env.remove  or os.remove

    local path = tmpname()
    local f, err = io.open(path, "w")
    if not f then return nil, "cannot write script: " .. tostring(err) end
    f:write(GTP.script(cmds)); f:close()

    local p, perr = popen(cmdline .. " < '" .. path .. "' 2>/dev/null", "r")
    if not p then remove(path); return nil, "cannot start engine: " .. tostring(perr) end
    local out = p:read("*a") or ""
    p:close()
    remove(path)

    if out == "" then return nil, "engine produced no output" end
    return GTP.parse(out)
end

return GTP
