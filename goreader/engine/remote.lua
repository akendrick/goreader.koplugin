--[[
    goreader/engine/remote.lua - a KataGo analysis server over HTTPS.

    The reader sends one JSON query per request in KataGo's own analysis
    format and gets KataGo's answer back, so the server can be a very thin
    wrapper around `katago analysis` (on the Synology NAS, the VPS, or a Mac).
    It implements the same methods as the local engines (genmove, dead_stones,
    final_score, describe) plus analyse() and review_positions() for the
    review screen.

        POST <url>/analyze      body: KataGo query (see build_query)
                                reply: one response object, or a JSON array of
                                       them when analyzeTurns lists several turns
        header X-Api-Key        optional shared secret

    HTTPS only; the key is never logged. All network access goes through the
    injected `post(url, body, headers, timeout)` -> code, body | nil, err.
--]]

local json     = require("goreader.services.json")
local GTP      = require("goreader.engine.gtp")
local Rules    = require("goreader.core.rules")
local Analysis = require("goreader.core.analysis")

local Remote = {}
Remote.__index = Remote

Remote.MAX_VISITS = 2000         -- a cap, whatever the settings say: protects a small NAS
Remote.DEAD_THRESHOLD = 0.6      -- |ownership| above this against the stone = dead

--[[ opts: url (https://...), post (required), api_key, visits (default 100),
            timeout (s, default 60), rules ("chinese"|"japanese"),
            loss_budget (winrate; >0 lets genmove play a slightly weaker move),
            random (function() -> 0..1), log ]]
function Remote.new(opts)
    assert(opts and opts.post, "a post function is required")
    local url = tostring(opts.url or "")
    if not url:match("^https://") then return nil, "remote engine needs an https:// address" end
    return setmetatable({
        url = url:gsub("/+$", ""), post = opts.post, api_key = opts.api_key,
        visits = math.min(opts.visits or 100, Remote.MAX_VISITS),
        timeout = opts.timeout or 60, rules = opts.rules or "chinese",
        loss_budget = opts.loss_budget or 0, random = opts.random or math.random,
        log = opts.log or function() end, counter = 0,
    }, Remote)
end

function Remote:describe()
    local host = self.url:match("^https://([^/]+)") or self.url
    return "KataGo @ " .. host
end

-- ---------------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------------

local function gtp_color(c) return c end

--[[ Build the KataGo query for a Game:position().
     extra = { maxVisits, analyzeTurns, includeOwnership, ... } merged in. ]]
function Remote:build_query(position, extra)
    self.counter = self.counter + 1
    local size = position.size
    local q = {
        id = "goreader-" .. self.counter,
        rules = self.rules, komi = position.komi,
        boardXSize = size, boardYSize = size,
        initialStones = {}, moves = {},
        reportAnalysisWinratesAs = "BLACK",
        maxVisits = self.visits,
    }
    local setup = position.setup or { B = {}, W = {} }
    for _, color in ipairs({ "B", "W" }) do
        for _, p in ipairs(setup[color] or {}) do
            q.initialStones[#q.initialStones + 1] = { gtp_color(color), GTP.vertex(p[1], p[2], size) }
        end
    end
    for _, m in ipairs(position.moves or {}) do
        q.moves[#q.moves + 1] = { m.color, m.col and GTP.vertex(m.col, m.row, size) or "pass" }
    end
    -- who moves first: White when a handicap is given and there are no moves yet
    local first = (#q.initialStones > 0 and (position.moves or {})[1] == nil) and position.to_move or nil
    if first then q.initialPlayer = first end
    for k, v in pairs(extra or {}) do q[k] = v end
    q.maxVisits = math.min(q.maxVisits, Remote.MAX_VISITS)
    return q
end

-- Send a query; returns the decoded reply (table or array), or nil + reason
function Remote:ask(query)
    local headers = { ["Content-Type"] = "application/json" }
    if self.api_key then headers["X-Api-Key"] = self.api_key end
    local code, body = self.post(self.url .. "/analyze", json.encode(query), headers, self.timeout)
    if not code then
        self.log("warn", "remote engine unreachable: " .. tostring(body))
        return nil, "network: " .. tostring(body)
    end
    if code == 401 or code == 403 then return nil, "unauthorized" end
    if code ~= 200 then return nil, "http_" .. tostring(code) end
    local data = json.decode(body or "")
    if type(data) ~= "table" then return nil, "bad_json" end
    if data.error then return nil, "engine error: " .. tostring(data.error) end
    return data
end

local function first_response(data)
    if data[1] ~= nil then return data[1] end
    return data
end

-- ---------------------------------------------------------------------------
-- The engine interface
-- ---------------------------------------------------------------------------

--[[ Analysis of the position as an Analysis info table (Black's point of view),
     or nil + reason. ]]
function Remote:analyse(position, extra)
    local data, err = self:ask(self:build_query(position, extra))
    if not data then return nil, err end
    local resp = first_response(data)
    local info, why = Analysis.from_katago(resp, {
        size = position.size, to_move = position.to_move, perspective = "BLACK" })
    if not info then return nil, why end
    info.raw = resp
    return info
end

function Remote:genmove(position, color)
    if color ~= position.to_move then return nil, "engine asked to move out of turn" end
    local info, err = self:analyse(position)
    if not info then return nil, err end
    local cands = info.candidates
    if #cands == 0 then return { kind = "pass" } end

    -- winrate from the mover's side, to compare candidates
    local function mine(c) return color == "B" and c.winrate or (1 - c.winrate) end
    local best = cands[1]
    local pick = best
    if self.loss_budget > 0 then
        local pool, total = {}, 0
        for _, c in ipairs(cands) do
            if mine(best) - mine(c) <= self.loss_budget then
                pool[#pool + 1] = c; total = total + math.max(1, c.visits or 1)
            end
        end
        local x = self.random() * total
        for _, c in ipairs(pool) do
            x = x - math.max(1, c.visits or 1)
            if x <= 0 then pick = c; break end
        end
    end
    if not pick.col then return { kind = "pass" } end
    return { kind = "move", col = pick.col, row = pick.row, winrate = mine(pick) }
end

-- Replay the position to know which stones are on the board
local function board_of(position)
    local r = Rules.new(position.size, { komi = position.komi })
    for _, c in ipairs({ "B", "W" }) do
        for _, p in ipairs((position.setup or {})[c] or {}) do r:setup_stone(c, p[1], p[2]) end
    end
    for _, m in ipairs(position.moves or {}) do
        if m.col then r:play(m.color, m.col, m.row) else r:pass(m.color) end
    end
    return r
end

function Remote:dead_stones(position)
    local data, err = self:ask(self:build_query(position, { includeOwnership = true }))
    if not data then return nil, err end
    local resp = first_response(data)
    local own = resp.ownership
    local size = position.size
    if type(own) ~= "table" or #own ~= size * size then return nil, "no ownership in the reply" end
    local rules = board_of(position)
    local dead = {}
    for row = 1, size do
        for col = 1, size do
            local stone = rules:get(col, row)
            local o = own[(row - 1) * size + col]
            if stone == "B" and o < -Remote.DEAD_THRESHOLD then dead[#dead + 1] = { col, row }
            elseif stone == "W" and o > Remote.DEAD_THRESHOLD then dead[#dead + 1] = { col, row } end
        end
    end
    return dead
end

function Remote:final_score(position)
    local info, err = self:analyse(position)
    if not info then return nil, err end
    local lead = info.score
    if not lead then return nil, "no score in the reply" end
    local winner = lead > 0 and "B" or (lead < 0 and "W" or nil)
    local text = winner and string.format("%s+%.1f", winner, math.abs(lead)) or "0"
    return { winner = winner, text = text }
end

--[[ Analyse several turns of one game in a single request, for the review
     screen. `position` is the whole game; `turns` lists turn numbers (0 =
     empty board). Returns { [turn] = response } ready for Analysis.annotate
     (with perspective "BLACK"), or nil + reason. ]]
function Remote:review_positions(position, turns)
    local data, err = self:ask(self:build_query(position, { analyzeTurns = turns }))
    if not data then return nil, err end
    local list = data[1] ~= nil and data or { data }
    local by_turn = {}
    for _, r in ipairs(list) do
        if type(r) == "table" and r.turnNumber ~= nil then by_turn[r.turnNumber] = r end
    end
    if next(by_turn) == nil then return nil, "no analysed turns in the reply" end
    return by_turn
end

-- ---------------------------------------------------------------------------
-- KOReader transport (not covered by the tests)
-- ---------------------------------------------------------------------------

function Remote.koreader_post()
    return function(url, body, headers, timeout)
        local http  = require("socket.http")
        local ltn12 = require("ltn12")
        local socketutil = require("socketutil")
        local sink = {}
        local h = { ["Content-Length"] = tostring(#body) }
        for k, v in pairs(headers or {}) do h[k] = v end
        socketutil:set_timeout(timeout or 60, (timeout or 60) * 2)
        local ok, code = http.request{
            url = url, method = "POST", headers = h,
            source = ltn12.source.string(body), sink = ltn12.sink.table(sink),
        }
        socketutil:reset_timeout()
        if not ok then return nil, tostring(code) end
        return code, table.concat(sink)
    end
end

return Remote
