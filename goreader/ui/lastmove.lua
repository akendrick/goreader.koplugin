-- "Black R17" / "White passed": the last move in words, for status lines.
local GTP = require("goreader.engine.gtp")

local Last = {}

function Last.text(last, size, move_number)
    if not last then return nil end
    local who = last.color == "B" and "Black" or "White"
    local what = last.pass and "passed" or (last.col and GTP.vertex(last.col, last.row, size)) or nil
    if not what then return nil end
    local t = who .. " " .. what
    if move_number and move_number > 0 then t = t .. " (#" .. move_number .. ")" end
    return t
end

return Last
