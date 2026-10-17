--[[
    goreader/core/sgf.lua — SGF (Smart Game Format) parser and writer
    Ported from GoBook; adds turn detection that understands handicap and PL,
    path/setup helpers for engines, and handicap/rules options in new_game.
    Supports: FF[4], GM[1] (Go), all standard SGF properties
    Handles: variations, comments, marks, labels, game info
--]]

local SGF = {}

-- ---------------------------------------------------------------------------
-- COORDINATE UTILITIES
-- ---------------------------------------------------------------------------

-- Convert SGF coordinate string (e.g. "pd") to {col, row} (1-indexed, col A=1)
-- SGF uses 'a'=1 .. 's'=19, row 'a'=top (row 19 in display convention)
function SGF.sgf_to_coord(s, board_size)
    if not s or s == "" or s == "tt" then return nil end  -- tt = pass in some formats
    board_size = board_size or 19
    -- Malformed/truncated coordinates (wrong length, or letters outside
    -- 'a'..'a'+board_size-1) must not crash the parser — treat them as "no
    -- coordinate" like an empty/pass value, rather than indexing string.byte
    -- past the end of a short string (which returns nil and throws on the
    -- arithmetic below) or returning an out-of-range col/row that later
    -- crashes board-array indexing.
    if #s ~= 2 then return nil end
    local col = string.byte(s, 1) - string.byte('a') + 1
    local row = string.byte(s, 2) - string.byte('a') + 1
    if col < 1 or col > board_size or row < 1 or row > board_size then return nil end
    return { col = col, row = row }
end

-- Convert {col, row} back to SGF coordinate string
function SGF.coord_to_sgf(col, row)
    return string.char(string.byte('a') + col - 1) ..
           string.char(string.byte('a') + row - 1)
end

-- Convert SGF coord to display notation (e.g. col=4,row=16 on 19x19 → "D4")
-- Display: col A–T (skipping I), row 1–19 (1 = bottom)
function SGF.coord_to_display(col, row, board_size)
    board_size = board_size or 19
    local col_letters = "ABCDEFGHJKLMNOPQRST"  -- no I
    local display_col = col_letters:sub(col, col)
    local display_row = board_size - row + 1
    return display_col .. tostring(display_row)
end

-- ---------------------------------------------------------------------------
-- NODE
-- ---------------------------------------------------------------------------

local Node = {}
Node.__index = Node

function Node.new(parent)
    return setmetatable({
        props    = {},      -- { PROPNAME = { val1, val2, ... } }
        children = {},      -- list of child Nodes (variations)
        parent   = parent,  -- parent Node or nil for root
        _board   = nil,     -- cached board state (populated lazily)
    }, Node)
end

-- Get first value of a property, or default
function Node:get(prop, default)
    local vals = self.props[prop]
    if vals and vals[1] then return vals[1] end
    return default
end

-- Get all values of a property
function Node:get_all(prop)
    return self.props[prop] or {}
end

-- True if node has a non-empty comment
function Node:has_comment()
    local c = self:get("C")
    return c and c ~= ""
end

-- The move played on this node: returns "B" or "W", coord_str, or nil if no move
function Node:move()
    if self.props["B"] then return "B", self.props["B"][1] end
    if self.props["W"] then return "W", self.props["W"][1] end
    return nil
end

-- True if this node is a pass
function Node:is_pass()
    local color, coord = self:move()
    if not color then return false end
    return coord == "" or coord == "tt"
end

-- Move number: walk up tree counting move nodes
function Node:move_number()
    local n = 0
    local cur = self
    while cur do
        if cur.props["B"] or cur.props["W"] then n = n + 1 end
        cur = cur.parent
    end
    return n
end

-- Number of children (variations)
function Node:num_children()
    return #self.children
end

-- Main line child (first child)
function Node:main_child()
    return self.children[1]
end

-- ---------------------------------------------------------------------------
-- PARSER
-- ---------------------------------------------------------------------------

local Parser = {}
Parser.__index = Parser

function Parser.new(text)
    return setmetatable({
        text = text,
        pos  = 1,
    }, Parser)
end

function Parser:peek()
    return self.text:sub(self.pos, self.pos)
end

function Parser:consume()
    local c = self.text:sub(self.pos, self.pos)
    self.pos = self.pos + 1
    return c
end

function Parser:skip_whitespace()
    while self.pos <= #self.text and self.text:sub(self.pos, self.pos):match("%s") do
        self.pos = self.pos + 1
    end
end

-- Parse a property value: content between [ and ], handling \] escapes
function Parser:parse_prop_value()
    -- Expect opening [
    self:skip_whitespace()
    if self:peek() ~= "[" then return nil end
    self:consume()  -- eat [

    local val = {}
    while self.pos <= #self.text do
        local c = self:consume()
        if c == "\\" then
            -- escaped character: include literally (except newlines which are soft)
            local next = self:consume()
            if next ~= "\n" and next ~= "\r" then
                table.insert(val, next)
            end
        elseif c == "]" then
            break
        else
            table.insert(val, c)
        end
    end
    return table.concat(val)
end

-- Parse one SGF node starting after the ; has been consumed
function Parser:parse_node(parent)
    local node = Node.new(parent)

    while self.pos <= #self.text do
        self:skip_whitespace()
        local c = self:peek()

        -- End of node: next node, variation start/end, or EOF
        if c == ";" or c == ")" or c == "(" or c == "" then
            break
        end

        -- Read property identifier (uppercase letters)
        if c:match("[%u%l]") then
            local prop_id = {}
            while self.pos <= #self.text and self:peek():match("[%u%l]") do
                table.insert(prop_id, self:consume():upper())
            end
            prop_id = table.concat(prop_id)

            -- Read one or more property values
            local values = {}
            self:skip_whitespace()
            while self:peek() == "[" do
                local v = self:parse_prop_value()
                if v then table.insert(values, v) end
                self:skip_whitespace()
            end
            node.props[prop_id] = values
        else
            -- Unexpected character, skip
            self:consume()
        end
    end

    return node
end

-- Parse a sequence of nodes and their variations
function Parser:parse_sequence(parent)
    local first_node = nil
    local current_parent = parent

    while self.pos <= #self.text do
        self:skip_whitespace()
        local c = self:peek()

        if c == ";" then
            self:consume()  -- eat ;
            local node = self:parse_node(current_parent)
            if current_parent then
                table.insert(current_parent.children, node)
            end
            if not first_node then first_node = node end
            current_parent = node

        elseif c == "(" then
            self:consume()  -- eat (
            self:parse_sequence(current_parent)
            self:skip_whitespace()
            if self:peek() == ")" then self:consume() end  -- eat )

        elseif c == ")" then
            break  -- end of this sequence

        else
            self:consume()  -- skip unexpected char
        end
    end

    return first_node
end

-- Parse a full SGF text, return list of game root nodes
function Parser:parse()
    local games = {}
    self:skip_whitespace()

    while self.pos <= #self.text do
        self:skip_whitespace()
        if self:peek() == "(" then
            self:consume()  -- eat (
            local root = self:parse_sequence(nil)
            if root then table.insert(games, root) end
            self:skip_whitespace()
            if self:peek() == ")" then self:consume() end
        elseif self:peek() == "" then
            break
        else
            self:consume()
        end
    end

    return games
end

-- ---------------------------------------------------------------------------
-- BOARD STATE
-- ---------------------------------------------------------------------------
-- Compute board state at a given node by replaying from root.
-- Returns a 2D array: board[row][col] = "B", "W", or nil
-- Also returns captures: { B = n, W = n }

local function empty_board(size)
    local b = {}
    for r = 1, size do
        b[r] = {}
        for c = 1, size do
            b[r][c] = nil
        end
    end
    return b
end

local function copy_board(board, size)
    local b = {}
    for r = 1, size do
        b[r] = {}
        for c = 1, size do
            b[r][c] = board[r][c]
        end
    end
    return b
end

-- Flood-fill to find all stones in a group and count liberties
local function group_info(board, size, row, col, visited)
    local color = board[row][col]
    if not color then return {}, 0 end
    visited = visited or {}
    local key = row * 100 + col
    if visited[key] then return {}, 0 end
    visited[key] = true

    local stones = { {row, col} }
    local liberties = 0
    local neighbors = {{-1,0},{1,0},{0,-1},{0,1}}

    for _, d in ipairs(neighbors) do
        local nr, nc = row + d[1], col + d[2]
        if nr >= 1 and nr <= size and nc >= 1 and nc <= size then
            if board[nr][nc] == nil then
                liberties = liberties + 1
            elseif board[nr][nc] == color then
                local sub_stones, sub_lib = group_info(board, size, nr, nc, visited)
                for _, s in ipairs(sub_stones) do table.insert(stones, s) end
                liberties = liberties + sub_lib
            end
        end
    end
    return stones, liberties
end

-- Remove a group from the board, return number of stones removed
local function remove_group(board, stones)
    for _, s in ipairs(stones) do
        board[s[1]][s[2]] = nil
    end
    return #stones
end

-- Apply a single move to board in-place, return captures count
local function apply_move(board, size, color, coord_str)
    if not coord_str or coord_str == "" or coord_str == "tt" then
        return 0  -- pass
    end
    local coord = SGF.sgf_to_coord(coord_str, size)
    if not coord then return 0 end
    local row, col = coord.row, coord.col
    if row < 1 or row > size or col < 1 or col > size then return 0 end
    if board[row][col] ~= nil then return 0 end  -- occupied

    board[row][col] = color
    local opponent = color == "B" and "W" or "B"
    local captured = 0

    -- Check neighbors for capture
    local neighbors = {{-1,0},{1,0},{0,-1},{0,1}}
    for _, d in ipairs(neighbors) do
        local nr, nc = row + d[1], col + d[2]
        if nr >= 1 and nr <= size and nc >= 1 and nc <= size then
            if board[nr][nc] == opponent then
                local stones, libs = group_info(board, size, nr, nc, {})
                if libs == 0 then
                    captured = captured + remove_group(board, stones)
                end
            end
        end
    end

    -- Suicide: if the just-played stone's own group is left with zero
    -- liberties (and didn't capture its way out of it above), it's dead on
    -- arrival — remove it too so the board reflects actual play instead of
    -- leaving an illegal "dead stone" sitting on the board. (This matters
    -- most in variation/sandbox play, where the user can try out any shape.)
    do
        local stones, libs = group_info(board, size, row, col, {})
        if libs == 0 then
            remove_group(board, stones)
            -- (Not folded into the capture tally — `captured` here counts
            -- stones removed *for* the mover, and attributing a suicide to
            -- the opponent would need a second counter build_board doesn't
            -- track. Dead stones simply vanish, which is what matters for
            -- showing the resulting position correctly.)
        end
    end

    return captured
end

-- Build board state at a node by walking from root
-- Returns board, captures_B, captures_W, board_size
function SGF.build_board(node, board_size)
    -- Collect path from root to node
    local path = {}
    local cur = node
    while cur do
        table.insert(path, 1, cur)
        cur = cur.parent
    end

    -- Get board size from root node
    local root = path[1]
    local sz_str = root and root:get("SZ", tostring(board_size))
    local size = tonumber(sz_str) or board_size or 19

    local board = empty_board(size)
    local caps = { B = 0, W = 0 }

    for _, n in ipairs(path) do
        -- Handle setup stones (AB, AW, AE)
        for _, coord_str in ipairs(n:get_all("AB")) do
            local c = SGF.sgf_to_coord(coord_str, size)
            if c then board[c.row][c.col] = "B" end
        end
        for _, coord_str in ipairs(n:get_all("AW")) do
            local c = SGF.sgf_to_coord(coord_str, size)
            if c then board[c.row][c.col] = "W" end
        end
        for _, coord_str in ipairs(n:get_all("AE")) do
            local c = SGF.sgf_to_coord(coord_str, size)
            if c then board[c.row][c.col] = nil end
        end

        -- Handle moves
        local color, coord = n:move()
        if color and coord then
            local captured = apply_move(board, size, color, coord)
            local opponent = color == "B" and "W" or "B"
            caps[color] = (caps[color] or 0)  -- player's own captures count opponent stones
            -- captured stones come off opponent's side, counted for current player
            if color == "B" then
                caps["B"] = caps["B"] + captured
            else
                caps["W"] = caps["W"] + captured
            end
        end
    end

    return board, caps.B, caps.W, size
end

-- ---------------------------------------------------------------------------
-- GAME OBJECT
-- ---------------------------------------------------------------------------

local Game = {}
Game.__index = Game

function Game.new(root, board_size)
    local size = board_size or 19
    if root then
        local sz = root:get("SZ")
        if sz then size = tonumber(sz) or size end
    end
    return setmetatable({
        root       = root or Node.new(nil),
        board_size = size,
        current    = root,  -- current navigation position
    }, Game)
end

-- Convenience accessors for game info
function Game:black_player() return self.root:get("PB", "Black") end
function Game:white_player() return self.root:get("PW", "White") end
function Game:black_rank()   return self.root:get("BR", "") end
function Game:white_rank()   return self.root:get("WR", "") end
function Game:komi()         return tonumber(self.root:get("KM", "6.5")) end
function Game:result()       return self.root:get("RE", "") end
function Game:date()         return self.root:get("DT", "") end
function Game:name()         return self.root:get("GN", "") end

-- Navigation
function Game:go_to_root()
    self.current = self.root
end

function Game:go_next(variation_index)
    variation_index = variation_index or 1
    local child = self.current.children[variation_index]
    if child then
        self.current = child
        return true
    end
    return false
end

function Game:go_prev()
    if self.current.parent then
        self.current = self.current.parent
        return true
    end
    return false
end

function Game:go_forward(n)
    n = n or 1
    for _ = 1, n do
        if not self:go_next() then break end
    end
end

function Game:go_to_end()
    while self:go_next() do end
end

function Game:go_to_node(target)
    -- Walk entire tree to find the node, then set current
    local function find(node)
        if node == target then return true end
        for _, child in ipairs(node.children) do
            if find(child) then return true end
        end
        return false
    end
    if find(self.root) then
        self.current = target
        return true
    end
    return false
end

-- Current board state (recomputed each time — cache if performance needed)
function Game:board_state()
    return SGF.build_board(self.current, self.board_size)
end

-- Current move number
function Game:move_number()
    return self.current:move_number()
end

-- Total number of moves along the main line (children[1] at every branch),
-- independent of which node is currently selected — pairs with
-- move_number() for a "current / total" display. Uses the same counting
-- convention as Node:move_number() (only nodes with a B/W property count,
-- so passes are included but pure setup/comment nodes are not).
function Game:total_moves()
    local n = 0
    local cur = self.root
    while cur do
        if cur.props["B"] or cur.props["W"] then n = n + 1 end
        cur = cur.children[1]
    end
    return n
end

-- Whose turn is it at the current node
function Game:current_color()
    -- The side to move is the opposite of whoever moved last on the path
    -- from the root to here (not move-count parity, which is wrong once
    -- there are passes of the setup kind or handicap stones).
    local n = self.current
    while n do
        local color = n:move()
        if color then return color == "B" and "W" or "B" end
        n = n.parent
    end
    -- No move played yet: an explicit PL wins, then handicap (White first),
    -- otherwise Black.
    local pl = self.root:get("PL")
    if pl == "B" or pl == "W" then return pl end
    local ha = tonumber(self.root:get("HA", "0")) or 0
    if ha >= 2 then return "W" end
    if self.root.props["AB"] and not self.root.props["AW"] then return "W" end
    return "B"
end

-- Moves from the root to the current node, in order.
-- Each entry: { color = "B"|"W", col = n|nil, row = n|nil } (col nil = pass).
function Game:path_moves()
    local nodes, n = {}, self.current
    while n do table.insert(nodes, 1, n); n = n.parent end
    local out = {}
    for _, node in ipairs(nodes) do
        local color, coord = node:move()
        if color then
            local c = SGF.sgf_to_coord(coord, self.board_size)
            out[#out + 1] = { color = color, col = c and c.col, row = c and c.row }
        end
    end
    return out
end

-- Setup stones on the root node: { B = { {col,row}, ... }, W = { ... } }
function Game:setup_stones()
    local out = { B = {}, W = {} }
    for _, key in ipairs({ "B", "W" }) do
        for _, coord in ipairs(self.root:get_all("A" .. key)) do
            local c = SGF.sgf_to_coord(coord, self.board_size)
            if c then out[key][#out[key] + 1] = { c.col, c.row } end
        end
    end
    return out
end

function Game:set_result(text)
    if text and text ~= "" then self.root.props["RE"] = { text }
    else self.root.props["RE"] = nil end
end

-- Add a move at current position, return the new node
function Game:add_move(color, col, row)
    local coord_str = SGF.coord_to_sgf(col, row)
    -- Check if this variation already exists
    for _, child in ipairs(self.current.children) do
        local c, cs = child:move()
        if c == color and cs == coord_str then
            self.current = child
            return child
        end
    end
    -- Create new node
    local node = Node.new(self.current)
    node.props[color] = { coord_str }
    table.insert(self.current.children, node)
    self.current = node
    return node
end

-- Add a pass
function Game:add_pass(color)
    local node = Node.new(self.current)
    node.props[color] = { "" }
    table.insert(self.current.children, node)
    self.current = node
    return node
end

-- Delete current node and all its descendants, go to parent
function Game:delete_current()
    local parent = self.current.parent
    if not parent then return false end  -- can't delete root
    -- Remove from parent's children
    for i, child in ipairs(parent.children) do
        if child == self.current then
            table.remove(parent.children, i)
            break
        end
    end
    self.current = parent
    return true
end

-- ---------------------------------------------------------------------------
-- WRITER
-- ---------------------------------------------------------------------------

local function escape_sgf(s)
    -- Escape ] and \ in SGF text values
    s = s:gsub("\\", "\\\\")
    s = s:gsub("]", "\\]")
    return s
end

local function write_node(node)
    local parts = { ";" }
    -- Write properties in a consistent order
    local order = { "B", "W", "AB", "AW", "AE", "PB", "PW", "BR", "WR",
                    "KM", "RE", "DT", "GN", "SZ", "FF", "GM", "CA",
                    "C", "TR", "SQ", "CR", "MA", "LB", "TB", "TW" }
    local written = {}

    for _, key in ipairs(order) do
        if node.props[key] then
            written[key] = true
            table.insert(parts, key)
            for _, val in ipairs(node.props[key]) do
                table.insert(parts, "[" .. escape_sgf(val) .. "]")
            end
        end
    end

    -- Any remaining properties not in the order list
    for key, vals in pairs(node.props) do
        if not written[key] then
            table.insert(parts, key)
            for _, val in ipairs(vals) do
                table.insert(parts, "[" .. escape_sgf(val) .. "]")
            end
        end
    end

    return table.concat(parts)
end

local function write_tree(node)
    local parts = {}
    table.insert(parts, "(")
    table.insert(parts, write_node(node))

    -- If exactly one child, continue inline
    local cur = node
    while #cur.children == 1 do
        cur = cur.children[1]
        table.insert(parts, "\n")
        table.insert(parts, write_node(cur))
    end

    -- Multiple children = variations
    for _, child in ipairs(cur.children) do
        table.insert(parts, "\n")
        table.insert(parts, write_tree(child))
    end

    table.insert(parts, ")")
    return table.concat(parts)
end

function SGF.write(game)
    return write_tree(game.root)
end

-- ---------------------------------------------------------------------------
-- PUBLIC API
-- ---------------------------------------------------------------------------

-- Parse SGF text, return first Game (or all games)
function SGF.parse(text)
    local parser = Parser.new(text)
    local roots = parser:parse()
    if #roots == 0 then return nil end
    local games = {}
    for _, root in ipairs(roots) do
        table.insert(games, Game.new(root))
    end
    return games[1], games  -- first game, all games
end

-- Create a new empty game
function SGF.new_game(options)
    options = options or {}
    local size = options.board_size or 19
    local root = Node.new(nil)
    root.props["FF"] = { "4" }
    root.props["GM"] = { "1" }
    root.props["CA"] = { "UTF-8" }
    root.props["SZ"] = { tostring(size) }
    root.props["KM"] = { tostring(options.komi or 6.5) }
    if options.black_name then root.props["PB"] = { options.black_name } end
    if options.white_name then root.props["PW"] = { options.white_name } end
    if options.black_rank then root.props["BR"] = { options.black_rank } end
    if options.white_rank then root.props["WR"] = { options.white_rank } end
    if options.date       then root.props["DT"] = { options.date }       end
    if options.game_name  then root.props["GN"] = { options.game_name }  end
    if options.rules      then root.props["RU"] = { options.rules }      end
    if options.handicap and options.handicap >= 2 then
        root.props["HA"] = { tostring(options.handicap) }
    end
    if options.setup_black and #options.setup_black > 0 then
        local list = {}
        for _, pt in ipairs(options.setup_black) do
            list[#list + 1] = SGF.coord_to_sgf(pt[1], pt[2])
        end
        root.props["AB"] = list
    end
    local game = Game.new(root, size)
    game.current = root
    return game
end

-- Expose Node and Game for external use
SGF.Node = Node
SGF.Game = Game

return SGF
