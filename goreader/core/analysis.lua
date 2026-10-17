--[[
    goreader/core/analysis.lua - engine analysis of a game (priority c).

    Stores per-move winrates, score leads and candidate moves inside the SGF,
    finds the mistakes, and turns the engine's better lines into variations a
    reader can step through. It does not run an engine: it consumes analysis
    from KataGo (JSON) or from an already-annotated SGF.

    Storage (private SGF properties, ignored by other programs):
        GA[wr=0.5321 sl=3.4 v=120]
            position AFTER this node: Black's winrate (0..1), Black's score
            lead in points, visits behind the number
        GV[pd wr=0.55 sl=3.8 v=80 pv=pd,dd,qp]     (list property)
            candidate next moves from the position after this node: move,
            Black's winrate / lead if it is played, visits, and the engine's
            continuation
    All numbers are from BLACK's point of view.

    Coordinates: col 1..N left to right, row 1..N top to bottom.
--]]

local SGF  = require("goreader.core.sgf")
local GTP  = require("goreader.engine.gtp")

local Analysis = {}

Analysis.THRESHOLDS = { inaccuracy = 0.05, mistake = 0.10, blunder = 0.20 }   -- winrate lost

-- ---------------------------------------------------------------------------
-- Encoding values into properties
-- ---------------------------------------------------------------------------

local function fmt(n) return string.format("%.4g", n) end

local function coord(col, row)
    if not col then return "pass" end
    return SGF.coord_to_sgf(col, row)
end

local function parse_fields(str)
    local f = {}
    for k, v in str:gmatch("(%a+)=(%S+)") do f[k] = v end
    return f
end

local function parse_pv(text, size)
    local out = {}
    if not text then return out end
    for tok in text:gmatch("[^,]+") do
        if tok == "pass" then out[#out + 1] = { pass = true }
        else
            local c = SGF.sgf_to_coord(tok, size)
            if c then out[#out + 1] = { col = c.col, row = c.row } end
        end
    end
    return out
end

--[[ info = {
       winrate  Black's winrate after this node (0..1)
       score    Black's score lead (points), optional
       visits   optional
       candidates = { { col,row (nil = pass), winrate, score, visits,
                        pv = { {col,row}, ... } }, ... }   best first
     }
--]]
function Analysis.set(node, info)
    local parts = { "wr=" .. fmt(info.winrate) }
    if info.score  then parts[#parts + 1] = "sl=" .. fmt(info.score) end
    if info.visits then parts[#parts + 1] = "v=" .. tostring(math.floor(info.visits)) end
    node.props["GA"] = { table.concat(parts, " ") }
    node.props["GV"] = nil
    if info.candidates and #info.candidates > 0 then
        local list = {}
        for _, c in ipairs(info.candidates) do
            local p = { coord(c.col, c.row), "wr=" .. fmt(c.winrate) }
            if c.score  then p[#p + 1] = "sl=" .. fmt(c.score) end
            if c.visits then p[#p + 1] = "v=" .. tostring(math.floor(c.visits)) end
            if c.pv and #c.pv > 0 then
                local mv = {}
                for _, m in ipairs(c.pv) do mv[#mv + 1] = coord(m.col, m.row) end
                p[#p + 1] = "pv=" .. table.concat(mv, ",")
            end
            list[#list + 1] = table.concat(p, " ")
        end
        node.props["GV"] = list
    end
end

function Analysis.get(node, size)
    size = size or 19
    local ga = node.props["GA"]
    if not ga or not ga[1] then return nil end
    local f = parse_fields(ga[1])
    local wr = tonumber(f.wr)
    if not wr then return nil end
    local info = { winrate = wr, score = tonumber(f.sl), visits = tonumber(f.v), candidates = {} }
    for _, line in ipairs(node.props["GV"] or {}) do
        local move = line:match("^(%S+)")
        local cf = parse_fields(line)
        local cand = { winrate = tonumber(cf.wr), score = tonumber(cf.sl),
                       visits = tonumber(cf.v), pv = parse_pv(cf.pv, size) }
        if move ~= "pass" then
            local c = SGF.sgf_to_coord(move, size)
            if c then cand.col, cand.row = c.col, c.row end
        end
        if cand.winrate and (cand.col or move == "pass") then
            info.candidates[#info.candidates + 1] = cand
        end
    end
    return info
end

function Analysis.has(node) return node.props["GA"] ~= nil end

-- ---------------------------------------------------------------------------
-- From KataGo's analysis engine
-- ---------------------------------------------------------------------------

--[[ Convert one KataGo analysis response (decoded JSON) to an info table.
       opts.size         board size
       opts.to_move      "B" or "W": who is to move in the analysed position
       opts.perspective  "SIDETOMOVE" (KataGo's default) or "BLACK"
--]]
function Analysis.from_katago(resp, opts)
    local size = opts.size or 19
    local flip = (opts.perspective ~= "BLACK") and opts.to_move == "W"
    local function wr(x) return flip and (1 - x) or x end
    local function sl(x) if x == nil then return nil end return flip and -x or x end

    local root = resp.rootInfo
    if not root or not root.winrate then return nil, "no rootInfo.winrate" end
    local info = { winrate = wr(root.winrate), score = sl(root.scoreLead),
                   visits = root.visits, candidates = {} }

    local infos = {}
    for _, mi in ipairs(resp.moveInfos or {}) do infos[#infos + 1] = mi end
    table.sort(infos, function(a, b) return (a.order or 0) < (b.order or 0) end)
    for _, mi in ipairs(infos) do
        local c, r = GTP.parse_vertex(mi.move, size)
        if c and mi.winrate then
            local cand = { winrate = wr(mi.winrate), score = sl(mi.scoreLead),
                           visits = mi.visits, pv = {} }
            if c == "pass" then cand.col, cand.row = nil, nil
            elseif c ~= "resign" then cand.col, cand.row = c, r end
            for _, v in ipairs(mi.pv or {}) do
                local pc, pr = GTP.parse_vertex(v, size)
                if pc == "pass" then cand.pv[#cand.pv + 1] = { pass = true }
                elseif pc and pc ~= "resign" then cand.pv[#cand.pv + 1] = { col = pc, row = pr } end
            end
            if cand.col or c == "pass" then info.candidates[#info.candidates + 1] = cand end
        end
    end
    return info
end

--[[ Attach analysis to the main line of `game`. `responses` maps the turn
     number (moves played so far, 0 = empty board) to a KataGo response.
     Returns the number of positions annotated.
--]]
function Analysis.annotate(game, responses, opts)
    opts = opts or {}
    local size = game.board_size
    local n, node, count = 0, game.root, 0
    local to_move = game:current_color()                 -- at the root
    while node do
        local resp = responses[n]
        if resp then
            local info = Analysis.from_katago(resp, {
                size = size, to_move = to_move, perspective = opts.perspective })
            if info then Analysis.set(node, info); count = count + 1 end
        end
        local child = node.children[1]
        if not child then break end
        local color = child:move()
        if color then n = n + 1; to_move = (color == "B") and "W" or "B" end
        node = child
    end
    return count
end

-- ---------------------------------------------------------------------------
-- Reading it back
-- ---------------------------------------------------------------------------

-- Main-line positions with analysis: list of { move, color, winrate, score }
-- (move 0 is the empty board). Good for a winrate graph.
function Analysis.series(game)
    local out, node, n = {}, game.root, 0
    while node do
        local info = Analysis.get(node, game.board_size)
        local color = node:move()
        if color then n = n + 1 end
        if info then
            out[#out + 1] = { move = n, color = color, winrate = info.winrate, score = info.score }
        end
        node = node.children[1]
    end
    return out
end

local function for_mover(wr, color) return color == "B" and wr or (1 - wr) end

--[[ Rate every main-line move. For each move that has analysis before and
     after it:
       loss_wr     winrate the mover gave up compared with the engine's best
                   (>= 0; 0 when they played the best move)
       loss_score  same in points, when scores are available
       kind        "inaccuracy" | "mistake" | "blunder" | nil
       best        the engine's top candidate from the position (or nil)
--]]
function Analysis.review(game, opts)
    opts = opts or {}
    local th = opts.thresholds or Analysis.THRESHOLDS
    local out = {}
    local node, n = game.root, 0
    while node do
        local child = node.children[1]
        if not child then break end
        local color, coord_str = child:move()
        if color then
            n = n + 1
            local before = Analysis.get(node, game.board_size)
            local after  = Analysis.get(child, game.board_size)
            if before and after then
                local best = before.candidates[1]
                local played_wr = for_mover(after.winrate, color)
                local best_wr
                if best then best_wr = for_mover(best.winrate, color)
                else best_wr = for_mover(before.winrate, color) end
                local loss_wr = math.max(0, best_wr - played_wr)

                local loss_score
                if after.score and (best and best.score or before.score) then
                    local bs = best and best.score or before.score
                    local sign = (color == "B") and 1 or -1
                    loss_score = math.max(0, (bs - after.score) * sign)
                end

                local kind
                if loss_wr >= th.blunder then kind = "blunder"
                elseif loss_wr >= th.mistake then kind = "mistake"
                elseif loss_wr >= th.inaccuracy then kind = "inaccuracy" end

                local played
                local c = coord_str and SGF.sgf_to_coord(coord_str, game.board_size)
                if c then played = { col = c.col, row = c.row } end
                out[#out + 1] = {
                    move = n, color = color, played = played,
                    wr_before = for_mover(before.winrate, color), wr_after = played_wr,
                    loss_wr = loss_wr, loss_score = loss_score, kind = kind, best = best,
                    node = child,
                }
            end
        end
        node = child
    end
    return out
end

-- Counts and average loss per colour
function Analysis.summary(reviews)
    local s = { B = { moves = 0, loss = 0, inaccuracy = 0, mistake = 0, blunder = 0 },
                W = { moves = 0, loss = 0, inaccuracy = 0, mistake = 0, blunder = 0 } }
    for _, r in ipairs(reviews) do
        local t = s[r.color]
        t.moves = t.moves + 1
        t.loss = t.loss + r.loss_wr
        if r.kind then t[r.kind] = t[r.kind] + 1 end
    end
    for _, t in pairs(s) do t.avg_loss = (t.moves > 0) and (t.loss / t.moves) or 0 end
    return s
end

-- The worst moves, largest loss first
function Analysis.worst(reviews, count, only_color)
    local list = {}
    for _, r in ipairs(reviews) do
        if r.kind and (not only_color or r.color == only_color) then list[#list + 1] = r end
    end
    table.sort(list, function(a, b) return a.loss_wr > b.loss_wr end)
    local out = {}
    for i = 1, math.min(count or 5, #list) do out[i] = list[i] end
    return out
end

--[[ Alternatives to the move played at `node` (a main-line node): the engine's
     candidates from the position before it. Each has played = true if it is
     the move that was actually played.
--]]
function Analysis.alternatives(game, node, limit)
    local parent = node.parent
    if not parent then return {} end
    local info = Analysis.get(parent, game.board_size)
    if not info then return {} end
    local _, played = node:move()
    local pc = played and SGF.sgf_to_coord(played, game.board_size)
    local color = node:move()
    local out = {}
    for _, c in ipairs(info.candidates) do
        local item = {
            col = c.col, row = c.row,
            winrate = for_mover(c.winrate, color or "B"),
            score = c.score, visits = c.visits, pv = c.pv,
            played = (pc ~= nil and c.col == pc.col and c.row == pc.row),
        }
        out[#out + 1] = item
        if limit and #out >= limit then break end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Text for the screen and for SGF comments
-- ---------------------------------------------------------------------------

local function pct(x) return string.format("%.1f%%", x * 100) end

-- "Black 53.2%  +3.4"
function Analysis.describe(info)
    if not info then return "" end
    local s = "Black " .. pct(info.winrate)
    if info.score then s = s .. string.format("  %+.1f", info.score) end
    return s
end

local LABEL = { inaccuracy = "Inaccuracy", mistake = "Mistake", blunder = "Blunder" }

function Analysis.comment_for(review, size)
    if not review.kind then return nil end
    local text = string.format("%s: lost %s", LABEL[review.kind], pct(review.loss_wr))
    if review.loss_score then text = text .. string.format(" (%.1f points)", review.loss_score) end
    if review.best and review.best.col then
        text = text .. ". Better: " .. GTP.vertex(review.best.col, review.best.row, size or 19)
            .. " (" .. pct(for_mover(review.best.winrate, review.color)) .. ")"
    end
    return text
end

-- ---------------------------------------------------------------------------
-- Turning the engine's better lines into variations
-- ---------------------------------------------------------------------------

--[[ For each mistake, add the engine's preferred line as a variation branching
     where the mistake was made, with a comment on the played move. The main
     line stays first. Returns the number of variations added.
       opts.min_kind   "inaccuracy" | "mistake" (default) | "blunder"
       opts.max_moves  length of the engine line to add (default 8)
--]]
function Analysis.add_suggestions(game, reviews, opts)
    opts = opts or {}
    local order = { inaccuracy = 1, mistake = 2, blunder = 3 }
    local min_level = order[opts.min_kind or "mistake"]
    local max_moves = opts.max_moves or 8
    local added = 0
    for _, r in ipairs(reviews) do
        if r.kind and order[r.kind] >= min_level then
            local text = Analysis.comment_for(r, game.board_size)
            if text then
                local old = r.node:get("C", "")
                r.node.props["C"] = { old ~= "" and (old .. "\n" .. text) or text }
            end
            local best = r.best
            if best and best.col then
                local parent = r.node.parent
                local line = { { col = best.col, row = best.row } }
                for i = 2, math.min(#best.pv, max_moves) do
                    local m = best.pv[i]
                    if m.col then line[#line + 1] = m end
                end
                local color, cur = r.color, parent
                for _, m in ipairs(line) do
                    local node = SGF.Node.new(cur)
                    node.props[color] = { SGF.coord_to_sgf(m.col, m.row) }
                    table.insert(cur.children, node)
                    if cur == parent then
                        node.props["C"] = { "Engine suggestion (" .. pct(for_mover(best.winrate, r.color)) .. ")" }
                    end
                    cur, color = node, (color == "B") and "W" or "B"
                end
                added = added + 1
            end
        end
    end
    return added
end

return Analysis
