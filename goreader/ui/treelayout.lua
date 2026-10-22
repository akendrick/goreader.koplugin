--[[
    goreader/ui/treelayout.lua - lays out an SGF's variation tree on a grid.

        column = how many moves from the start      row = which line (variation)
        the main line is row 0; each further branch gets the next free row

    Pure data: the tree view draws it and maps taps back to nodes.
--]]

local TreeLayout = {}

--[[ Returns { nodes = { {node, col, row, parent (index|nil), number, color} ... },
               index = { [node] = i }, rows = n, cols = n }
     Nodes are in depth-first order, the main line first. ]]
function TreeLayout.build(game)
    local nodes, index = {}, {}
    local rows, cols = 1, 1
    local row_counter = 0
    local stack = { { node = game.root, col = 0, row = 0, parent = nil, fresh = false } }
    while #stack > 0 do
        local it = table.remove(stack)
        local row = it.row
        if it.fresh then row_counter = row_counter + 1; row = row_counter end
        local color = it.node:move()
        local i = #nodes + 1
        nodes[i] = { node = it.node, col = it.col, row = row, parent = it.parent,
                     number = it.node:move_number(), color = color }
        index[it.node] = i
        if row + 1 > rows then rows = row + 1 end
        if it.col + 1 > cols then cols = it.col + 1 end
        local kids = it.node.children
        for k = #kids, 1, -1 do                       -- pushed in reverse so the first child is handled first
            local child = kids[k]
            local counts = (child.props["B"] ~= nil or child.props["W"] ~= nil)
            stack[#stack + 1] = { node = child, col = it.col + (counts and 1 or 0), row = row,
                                  parent = i, fresh = (k > 1) }
        end
    end
    return { nodes = nodes, index = index, rows = rows, cols = cols }
end

-- Line segments to draw: { x1, y1, x2, y2 } in grid units (column, row)
function TreeLayout.links(layout)
    local out = {}
    for _, n in ipairs(layout.nodes) do
        if n.parent then
            local p = layout.nodes[n.parent]
            if p.row == n.row then out[#out + 1] = { p.col, p.row, n.col, n.row }
            else                                              -- down from the fork, then along
                out[#out + 1] = { p.col, p.row, p.col, n.row }
                out[#out + 1] = { p.col, n.row, n.col, n.row }
            end
        end
    end
    return out
end

-- The node nearest to grid position (col, row) within `radius` cells, or nil
function TreeLayout.node_at(layout, col, row, radius)
    radius = radius or 0.45
    local best, best_d
    for i, n in ipairs(layout.nodes) do
        local d = math.max(math.abs(n.col - col), math.abs(n.row - row))
        if d <= radius and (not best_d or d < best_d) then best, best_d = i, d end
    end
    return best
end

return TreeLayout
