--[[
    goreader/core/joseki.lua - navigating a joseki dictionary (no UI).

    The dictionary is an SGF tree such as Kogo's Joseki Dictionary: every
    joseki is stored in ONE corner (top right, points counted from the top
    left) and each node lists its continuations as labels, LB[pd:A][nc:B].
    A "view" shows it in any of the four corners by mirroring coordinates.

    Sandbox: playing a move that is not in the book drops into free play.
    Those moves go on a private "shadow" node, never into the shared tree,
    so exploring cannot change the dictionary (GoBook had that bug).

    Coordinates: SGF coordinates (col, row from the top left) unless a name
    says "display". Display coordinates are what is drawn for the chosen
    corner.
--]]

local SGF = require("goreader.core.sgf")

local Joseki = {}

local SIZE = 19
Joseki.CORNERS = { "ne", "nw", "se", "sw" }

-- ---------------------------------------------------------------------------
-- Corner mirroring (each mapping is its own inverse)
-- ---------------------------------------------------------------------------

function Joseki.mirror(col, row, corner)
    if corner == "nw" then return SIZE - col + 1, row end
    if corner == "se" then return col, SIZE - row + 1 end
    if corner == "sw" then return SIZE - col + 1, SIZE - row + 1 end
    return col, row                                   -- "ne"
end

-- Display window used for a corner view: the 11x11 block next to the corner
Joseki.VIEW_N = 11
local COL0 = SIZE - Joseki.VIEW_N + 1                 -- first display column shown

function Joseki.in_corner_window(dcol, drow)
    return dcol >= COL0 and dcol <= SIZE and drow >= 1 and drow <= Joseki.VIEW_N
end

-- Display coordinates -> position inside the corner window (0-based), or nil
function Joseki.window_index(dcol, drow)
    if not Joseki.in_corner_window(dcol, drow) then return nil end
    return dcol - COL0, drow - 1
end

-- ---------------------------------------------------------------------------
-- Comments: "title line, ---- rule, description"
-- ---------------------------------------------------------------------------

function Joseki.parse_comment(node)
    local raw = node:get("C", "")
    if raw == "" then return "", "" end
    local lines = {}
    for l in (raw .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = l end
    local title, title_i = "", 0
    for i, l in ipairs(lines) do
        local s = l:match("^%s*(.-)%s*$")
        if s ~= "" and not s:match("^%-+$") then title = s; title_i = i; break end
    end
    local desc = {}
    for i = title_i + 1, #lines do
        local s = lines[i]:match("^%s*(.-)%s*$")
        if not s:match("^%-+$") then desc[#desc + 1] = lines[i] end
    end
    return title, (table.concat(desc, "\n"):match("^%s*(.-)%s*$") or "")
end

-- ---------------------------------------------------------------------------
-- Dictionary and views
-- ---------------------------------------------------------------------------

local Dict = {}
Dict.__index = Dict
local View = {}
View.__index = View

-- `game` is an SGF.Game for the whole dictionary
function Joseki.new(game)
    return setmetatable({ game = game, root = game.root }, Dict)
end

function Joseki.load(text)
    local game = SGF.parse(text)
    if not game then return nil, "could not parse the dictionary" end
    return Joseki.new(game)
end

-- Number of nodes (for information; walks the whole tree)
function Dict:node_count()
    local n, stack = 0, { self.root }
    while #stack > 0 do
        local node = table.remove(stack)
        n = n + 1
        for _, c in ipairs(node.children) do stack[#stack + 1] = c end
    end
    return n
end

function Dict:view(corner)
    return setmetatable({
        dict = self, corner = corner or "ne", full = false,
        current = self.root, sandbox = false, sandbox_node = nil,
    }, View)
end

-- The "game" interface SGF.build_board needs: a cursor over the shared tree
function View:is_root() return self.current == self.dict.root end

function View:set_corner(corner) self.corner = corner end
function View:toggle_full() self.full = not self.full; return self.full end

-- Stones at the current position, in display coordinates for this corner:
-- list of { col, row, color }
function View:stones()
    local board = SGF.build_board(self.current, SIZE)
    local out = {}
    for row = 1, SIZE do
        for col = 1, SIZE do
            local color = board[row][col]
            if color then
                local dc, dr = Joseki.mirror(col, row, self.corner)
                out[#out + 1] = { col = dc, row = dr, color = color }
            end
        end
    end
    return out
end

function View:move_number() return self.current:move_number() end

-- Next colour to play from here
function View:to_move()
    local n = self.current
    while n do
        local c = n:move()
        if c then return c == "B" and "W" or "B" end
        n = n.parent
    end
    return "B"
end

-- Last move as display coordinates, or nil
function View:last_move()
    local color, coord = self.current:move()
    if not color then return nil end
    local c = SGF.sgf_to_coord(coord, SIZE)
    if not c then return nil end
    local dc, dr = Joseki.mirror(c.col, c.row, self.corner)
    return { col = dc, row = dr, color = color }
end

-- Continuations offered by the book: list of { label, col, row } in DISPLAY
-- coordinates, in the order written. Duplicates are dropped.
function View:choices()
    if self.sandbox then return {} end
    local out, seen = {}, {}
    for _, lb in ipairs(self.current:get_all("LB")) do
        local coord, label = lb:match("^(..):(.*)$")
        if coord and label and not seen[coord .. label] then
            seen[coord .. label] = true
            local c = SGF.sgf_to_coord(coord, SIZE)
            if c then
                local dc, dr = Joseki.mirror(c.col, c.row, self.corner)
                out[#out + 1] = { label = label:upper(), col = dc, row = dr, coord = coord }
            end
        end
    end
    return out
end

function View:comment()
    local title, desc = Joseki.parse_comment(self.current)
    if self:is_root() then
        title = "Kogo's Joseki Dictionary"
        desc = "Tap a variation (A-I) to explore."
    end
    return title, desc
end

local function child_by_coord(node, coord)
    for _, child in ipairs(node.children) do
        local _, c = child:move()
        if c == coord then return child end
    end
end

--[[ Play at display coordinates. Returns
       "book"     followed a move in the dictionary
       "sandbox"  left the book (or kept playing off-book)
       nil, why   not possible (occupied / off the window)
--]]
function View:play(dcol, drow)
    local col, row = Joseki.mirror(dcol, drow, self.corner)     -- self-inverse
    if col < 1 or col > SIZE or row < 1 or row > SIZE then return nil, "off_board" end
    local board = SGF.build_board(self.current, SIZE)
    if board[row][col] then return nil, "occupied" end

    local coord = SGF.coord_to_sgf(col, row)
    if self.sandbox then
        self:_sandbox_add(col, row)
        return "sandbox"
    end

    local child = child_by_coord(self.current, coord)
    if child then
        self.current = child
        return "book"
    end

    -- off book: enter the sandbox on a private shadow of the current node
    self.sandbox_node = self.current
    self.sandbox = true
    local shadow = SGF.Node.new(self.current.parent)
    shadow.props = self.current.props
    self.shadow = shadow
    self.current = shadow
    self:_sandbox_add(col, row)
    return "sandbox"
end

function View:_sandbox_add(col, row)
    local node = SGF.Node.new(self.current)
    node.props[self:to_move()] = { SGF.coord_to_sgf(col, row) }
    table.insert(self.current.children, node)       -- only ever the shadow subtree
    self.current = node
end

-- Follow a book continuation by its letter (A, B, ...)
function View:play_label(label)
    if self.sandbox then return false end
    for _, ch in ipairs(self:choices()) do
        if ch.label == label:upper() then
            local node = child_by_coord(self.current, ch.coord)
            if node then self.current = node; return true end
        end
    end
    return false
end

function View:back()
    if not self.current.parent then return false end
    self.current = self.current.parent
    -- the shadow stands in for the book node: arriving on it means we are
    -- back in the book
    if self.sandbox and self.current == self.shadow then
        self:return_from_sandbox()
    end
    return true
end

-- Next move along the book's main line
function View:forward()
    if self.sandbox then
        local c = self.current.children[1]
        if c then self.current = c; return true end
        return false
    end
    local c = self.current.children[1]
    if not c then return false end
    self.current = c
    return true
end

function View:reset()
    self.current = self.dict.root
    self.sandbox, self.sandbox_node, self.shadow = false, nil, nil
end

function View:return_from_sandbox()
    if self.sandbox_node then self.current = self.sandbox_node end
    self.sandbox, self.sandbox_node, self.shadow = false, nil, nil
end

return Joseki
