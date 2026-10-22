--[[
    goreader/book/gobooks.lua - Smart Go "gobooks.com" interactive diagrams.

    Those EPUBs draw every diagram as an inline SVG plus a little JavaScript
    (gobooks.js). KOReader does not run scripts, so the diagrams are dead
    pictures there, and its SVG renderer drops the stones (it ignores <use>
    and CSS classes). This module reads the diagram markup and gives us:

      parse_figure(xml)     the diagram as data: board lines, stones, labels,
                            when each appears and disappears, tap targets
      Diagram               the same state machine the book's script has
                            (replay frames, quiz transitions), no drawing
      static_svg(spec, n)   a plain SVG of frame n that KOReader can draw
      figures(chapter)      where the diagrams are in a chapter file

    How the book's script works, for reference
        slider value  = the current frame (0..max)
        <g gb:v="a b c ...">   visible when an ODD number of the listed
                               frames are <= the current frame
        <rect gb:s="from,to[,r1,r2..] ...">  a tap target (quiz): when the
                               frame equals `from`, go to `to`, then after a
                               short delay to one of the replies at random;
                               a tap that matches nothing resets to frame 0
        the last drawn rect under the finger wins (SVG paint order)
--]]

local Gobooks = {}

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

local function attrs_of(s)
    local a = {}
    for name, value in s:gmatch('([%w:_%-]+)%s*=%s*"([^"]*)"') do a[name] = value end
    return a
end

local function num(v, default)
    local n = tonumber(v)
    if n == nil then return default end
    return n
end

local function decode_entities(s)
    return (s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&amp;", "&"))
end

local function style_attrs(style)
    local out = {}
    for k, v in (style or ""):gmatch("([%w%-]+)%s*:%s*([^;]+)") do out[k] = v:match("^%s*(.-)%s*$") end
    return out
end

-- Numbers in a string, in order ("1,2 -3.5")
local function numbers(s)
    local out = {}
    for n in s:gmatch("[%-+]?%d*%.?%d+") do out[#out + 1] = tonumber(n) end
    return out
end

-- "M12,11V445M444,11V445M11,12H445" -> list of { x1, y1, x2, y2 }
-- Absolute M, L, H, V and Z only (all the books use).
function Gobooks.path_segments(d)
    local segs = {}
    local x, y, sx, sy = 0, 0, 0, 0
    for cmd, args in d:gmatch("([MLHVZmlhvz])([^MLHVZmlhvz]*)") do
        local n = numbers(args)
        if cmd == "M" then x, y = n[1] or x, n[2] or y; sx, sy = x, y
            for i = 3, #n, 2 do
                segs[#segs + 1] = { x, y, n[i], n[i + 1] }; x, y = n[i], n[i + 1]
            end
        elseif cmd == "L" then
            for i = 1, #n, 2 do
                segs[#segs + 1] = { x, y, n[i], n[i + 1] }; x, y = n[i], n[i + 1]
            end
        elseif cmd == "H" then
            for i = 1, #n do segs[#segs + 1] = { x, y, n[i], y }; x = n[i] end
        elseif cmd == "V" then
            for i = 1, #n do segs[#segs + 1] = { x, y, x, n[i] }; y = n[i] end
        elseif cmd == "Z" or cmd == "z" then
            if x ~= sx or y ~= sy then segs[#segs + 1] = { x, y, sx, sy }; x, y = sx, sy end
        end
    end
    return segs
end

-- ---------------------------------------------------------------------------
-- Parsing one diagram
-- ---------------------------------------------------------------------------

local function parse_defs(svg)
    local defs = {}
    local block = svg:match("<defs>(.-)</defs>") or ""
    for tag, attr_text in block:gmatch("<(%a+)([^>]*)>") do
        local a = attrs_of(attr_text)
        if a.id then
            if tag == "circle" then
                defs[a.id] = { kind = "circle", r = num(a.r, 10), fill = a.fill, stroke = a.stroke,
                               sw = num(a["stroke-width"], 1) }
            elseif tag == "polyline" then
                defs[a.id] = { kind = "polyline", points = numbers(a.points or ""), stroke = a.stroke,
                               sw = num(a["stroke-width"], 1), fill = a.fill }
            elseif tag == "path" then
                defs[a.id] = { kind = "lines", segs = Gobooks.path_segments(a.d or ""), stroke = a.stroke,
                               sw = num(a["stroke-width"], 1) }
            end
        end
    end
    return defs
end

-- CSS classes in <style>: .wt { font-size: 18px; fill: white; ... }
local function parse_classes(svg)
    local classes = {}
    local css = svg:match("<style[^>]*>(.-)</style>") or ""
    for name, body in css:gmatch("%.([%w_%-]+)%s*{([^}]*)}") do
        local st = style_attrs(body)
        classes[name] = { size = num((st["font-size"] or ""):match("[%d%.]+"), 16), fill = st.fill or "black" }
    end
    return classes
end

local function shape_from(tag, a, inner)
    if tag == "use" then
        local ref = (a["xlink:href"] or a.href or ""):match("^#(.+)$")
        if ref then return { kind = "use", x = num(a.x, 0), y = num(a.y, 0), ref = ref } end
    elseif tag == "text" then
        return { kind = "text", x = num(a.x, 0), y = num(a.y, 0), class = a.class,
                 text = decode_entities((inner or ""):gsub("<[^>]*>", "")) }
    elseif tag == "path" then
        return { kind = "lines", segs = Gobooks.path_segments(a.d or ""), stroke = a.stroke or "black",
                 sw = num(a["stroke-width"], 1) }
    elseif tag == "rect" and not a["gb:s"] and not a.onmousedown then
        local st = style_attrs(a.style)
        return { kind = "rect", x = num(a.x, 0), y = num(a.y, 0), w = num(a.width, 0), h = num(a.height, 0),
                 stroke = st.stroke or a.stroke, sw = num(st["stroke-width"] or a["stroke-width"], 1),
                 fill = st.fill or a.fill }
    elseif tag == "circle" then
        return { kind = "circle", cx = num(a.cx, 0), cy = num(a.cy, 0), r = num(a.r, 1),
                 fill = a.fill, stroke = a.stroke, sw = num(a["stroke-width"], 1) }
    elseif tag == "line" then
        return { kind = "lines", segs = { { num(a.x1, 0), num(a.y1, 0), num(a.x2, 0), num(a.y2, 0) } },
                 stroke = a.stroke or "black", sw = num(a["stroke-width"], 1) }
    end
    return nil
end

local function thresholds(v)
    if not v then return nil end
    local t = {}
    for n in v:gmatch("%-?%d+") do t[#t + 1] = tonumber(n) end
    return t
end

local function transitions(s)
    local out = {}
    for item in s:gmatch("%S+") do
        local nums = {}
        for n in item:gmatch("%-?%d+") do nums[#nums + 1] = tonumber(n) end
        if #nums >= 2 then
            local replies = {}
            for i = 3, #nums do replies[#replies + 1] = nums[i] end
            out[#out + 1] = { from = nums[1], to = nums[2], replies = replies }
        end
    end
    return out
end

--[[ In these books only the FIRST diagram of a chapter carries the stone
     shapes (<defs>) and the label styles (<style>); every later diagram reuses
     them. context() pulls them out of a diagram that has them, and
     inject() puts them into one that lacks them, so each diagram is complete
     on its own. ]]
function Gobooks.context(xml)
    local defs = xml:match("<defs>.-</defs>")
    local style = xml:match("<style[^>]*>.-</style>")
    if not defs and not style then return nil end
    return { defs = defs, style = style }
end

function Gobooks.inject(xml, ctx)
    if not ctx then return xml end
    local has_defs = xml:find("<defs>", 1, true) ~= nil
    local has_style = xml:find("<style", 1, true) ~= nil
    local add = {}
    if not has_defs and ctx.defs then add[#add + 1] = ctx.defs end
    if not has_style and ctx.style then add[#add + 1] = ctx.style end
    if #add == 0 then return xml end
    local s, e = xml:find("<svg[^>]*>")
    if not s then return xml end
    return xml:sub(1, e) .. "\n" .. table.concat(add, "\n") .. xml:sub(e + 1)
end

--[[ Parse one `<div class="fig ...">` (or just its <svg>) into a spec. Returns
     spec or nil + reason. `ctx` (see context()) supplies shapes and styles the
     diagram itself does not carry. See the file header for what a spec contains. ]]
function Gobooks.parse_figure(xml, ctx)
    xml = Gobooks.inject(xml, ctx)
    local svg = xml:match("<svg.-</svg>")
    if not svg then return nil, "no svg" end
    local head = svg:match("<svg([^>]*)>")
    local sa = attrs_of(head)
    local vb = numbers(sa.viewBox or "")
    local width, height = vb[3] or num(sa.width, 0), vb[4] or num(sa.height, 0)
    if width <= 0 or height <= 0 then return nil, "no size" end

    local spec = {
        width = width, height = height,
        defs = parse_defs(svg), classes = parse_classes(svg),
        items = {}, taps = {}, caption = nil, kind = "replay",
        frame0 = 0, max = 0,
    }

    local slider = xml:match('<input[^>]*type="range"[^>]*>')
    if slider then
        local s = attrs_of(slider)
        spec.max, spec.frame0 = num(s.max, 0), num(s.value, 0)
    end
    local cap = xml:match("<figcaption[^>]*>(.-)</figcaption>")
    if cap then spec.caption = decode_entities(cap:gsub("<[^>]*>", ""):match("^%s*(.-)%s*$")) end
    spec.size_class = xml:match('<div class="fig%s+(%S+)')
    spec.div_class = xml:match('<div class="([^"]*)"')          -- e.g. "fig c10 center"

    -- everything after <defs>/<style>, walking tags in order
    local body = svg:gsub("<defs>.-</defs>", ""):gsub("<style[^>]*>.-</style>", "")
    local pos, group = 1, nil
    while true do
        local s, e, tag, attr_text, selfclose = body:find("<(/?[%w]+)([^>]*)>", pos)
        if not s then break end
        pos = e + 1
        if tag == "g" then
            group = { v = thresholds(attrs_of(attr_text)["gb:v"]) }
        elseif tag == "/g" then
            group = nil
        elseif tag:sub(1, 1) ~= "/" and tag ~= "svg" then
            local a = attrs_of(attr_text)
            local inner
            if tag == "text" then
                local ts, te = body:find("</text>", pos, true)
                if ts then inner = body:sub(pos, ts - 1); pos = te + 1 end
            end
            if tag == "rect" and (a["gb:s"] or (a.onmousedown and a.onmousedown:find("tap"))
                                   or (a.onmousedown and a.onmousedown:find("toggle"))) then
                local isquiz = a.onmousedown and a.onmousedown:find("tap") ~= nil
                spec.taps[#spec.taps + 1] = {
                    x = num(a.x, 0), y = num(a.y, 0), w = num(a.width, 0), h = num(a.height, 0),
                    transitions = a["gb:s"] and transitions(a["gb:s"]) or nil,
                    toggle = (a.onmousedown and a.onmousedown:find("toggle") ~= nil) or nil,
                }
                if isquiz then spec.kind = "quiz" end
            else
                local shape = shape_from(tag, a, inner)
                if shape then
                    shape.v = group and group.v or nil
                    spec.items[#spec.items + 1] = shape
                end
            end
        end
    end
    return spec
end

-- ---------------------------------------------------------------------------
-- The state machine
-- ---------------------------------------------------------------------------

local Diagram = {}
Diagram.__index = Diagram
Gobooks.Diagram = Diagram

-- Visible when an odd number of the listed frames are <= the frame
local function visible_at(v, frame)
    if not v then return true end
    local count = 0
    for _, m in ipairs(v) do
        if m <= frame then count = count + 1 else break end
    end
    return count % 2 == 1
end
Gobooks.visible_at = visible_at

function Diagram.new(spec)
    return setmetatable({ spec = spec, frame = spec.frame0 or 0 }, Diagram)
end

function Diagram:max() return self.spec.max end
function Diagram:is_quiz() return self.spec.kind == "quiz" end

function Diagram:set(n)
    n = math.max(0, math.min(self.spec.max, math.floor(n)))
    local changed = n ~= self.frame
    self.frame = n
    return changed
end

function Diagram:to_start() return self:set(0) end
function Diagram:to_end() return self:set(self.spec.max) end

-- The book's own buttons wrap around: past the end goes to 0, before 0 to the end
function Diagram:next()
    local v = self.frame + 1
    if v > self.spec.max then v = 0 end
    self.frame = v
    return true
end

function Diagram:prev()
    local v = self.frame - 1
    if v < 0 then v = self.spec.max end
    self.frame = v
    return true
end

--[[ A tap at (x, y) in diagram coordinates (the viewBox). Returns
       { frame, reset = bool, replies = {frames}|nil, matched = bool }
     `replies`, when present, are the candidates for the opponent's answer:
     the caller picks one at random and applies it after ~0.4 s (apply()). ]]
function Diagram:tap(x, y)
    local hit
    for _, t in ipairs(self.spec.taps) do                  -- last drawn wins
        if x >= t.x and x < t.x + t.w and y >= t.y and y < t.y + t.h then hit = t end
    end
    if not hit then return { frame = self.frame, matched = false } end
    if hit.transitions then
        for _, tr in ipairs(hit.transitions) do
            if tr.from == self.frame then
                self.frame = math.min(tr.to, self.spec.max)
                return { frame = self.frame, matched = true,
                         replies = (#tr.replies > 0) and tr.replies or nil }
            end
        end
    end
    if hit.toggle then return { frame = self.frame, matched = true, toggle = true } end
    self.frame = 0                                         -- a tap that matches nothing resets
    return { frame = 0, matched = false, reset = true }
end

-- Apply a chosen reply frame (after the delay)
function Diagram:apply(frame) self.frame = math.max(0, math.min(self.spec.max, frame)); return self.frame end

-- Which board points can be tapped right now (diagram coordinates of the
-- rect centres), for highlighting or for tests
function Diagram:active_taps()
    local out = {}
    for _, t in ipairs(self.spec.taps) do
        if t.transitions then
            for _, tr in ipairs(t.transitions) do
                if tr.from == self.frame then
                    out[#out + 1] = { x = t.x + t.w / 2, y = t.y + t.h / 2, to = tr.to }
                    break
                end
            end
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Drawing instructions for one frame (drawing itself lives in the UI)
-- ---------------------------------------------------------------------------

--[[ Flat list of primitives for the current frame, in paint order:
       { op = "line",   x1, y1, x2, y2, sw, color }
       { op = "circle", cx, cy, r, fill, stroke, sw }
       { op = "rect",   x, y, w, h, stroke, sw, fill }
       { op = "text",   x, y, text, size, color }
     All in diagram coordinates. `use` references are expanded from <defs>. ]]
function Diagram:ops(frame)
    frame = frame or self.frame
    local spec, ops = self.spec, {}
    local function add_def(def, ox, oy)
        if def.kind == "circle" then
            ops[#ops + 1] = { op = "circle", cx = ox, cy = oy, r = def.r, fill = def.fill, stroke = def.stroke, sw = def.sw }
        elseif def.kind == "polyline" then
            local p = def.points
            for i = 1, #p - 3, 2 do
                ops[#ops + 1] = { op = "line", x1 = ox + p[i], y1 = oy + p[i + 1], x2 = ox + p[i + 2],
                                  y2 = oy + p[i + 3], sw = def.sw, color = def.stroke or "black" }
            end
        elseif def.kind == "lines" then
            for _, s in ipairs(def.segs) do
                ops[#ops + 1] = { op = "line", x1 = ox + s[1], y1 = oy + s[2], x2 = ox + s[3], y2 = oy + s[4],
                                  sw = def.sw, color = def.stroke or "black" }
            end
        end
    end
    for _, it in ipairs(spec.items) do
        if visible_at(it.v, frame) then
            if it.kind == "use" then
                local def = spec.defs[it.ref]
                if def then add_def(def, it.x, it.y) end
            elseif it.kind == "text" then
                local cls = spec.classes[it.class or ""] or { size = 16, fill = "black" }
                ops[#ops + 1] = { op = "text", x = it.x, y = it.y, text = it.text, size = cls.size, color = cls.fill }
            elseif it.kind == "lines" then
                for _, s in ipairs(it.segs) do
                    ops[#ops + 1] = { op = "line", x1 = s[1], y1 = s[2], x2 = s[3], y2 = s[4], sw = it.sw, color = it.stroke }
                end
            elseif it.kind == "rect" then
                ops[#ops + 1] = { op = "rect", x = it.x, y = it.y, w = it.w, h = it.h, stroke = it.stroke, sw = it.sw, fill = it.fill }
            elseif it.kind == "circle" then
                ops[#ops + 1] = { op = "circle", cx = it.cx, cy = it.cy, r = it.r, fill = it.fill, stroke = it.stroke, sw = it.sw }
            end
        end
    end
    return ops
end

-- ---------------------------------------------------------------------------
-- A plain SVG KOReader can draw (no <use>, <defs> or classes)
-- ---------------------------------------------------------------------------

local function fmt(n)
    local s = string.format("%.3f", n):gsub("0+$", ""):gsub("%.$", "")
    return s
end

local function esc(s) return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")) end

-- Labels (move numbers) are drawn at this fraction of the book's size: the book
-- assumes narrow Helvetica; a standard sans-serif needs to be smaller to fit a stone.
Gobooks.LABEL_SCALE = 0.8
Gobooks.FONT_STACK = "Noto Sans, DejaVu Sans, Helvetica, Arial, sans-serif"

function Gobooks.static_svg(spec, frame)
    local d = Diagram.new(spec)
    frame = frame or spec.frame0
    local out = { string.format(
        '<svg xmlns="http://www.w3.org/2000/svg" version="1.1" viewBox="0 0 %s %s" width="%s" height="%s">',
        fmt(spec.width), fmt(spec.height), fmt(spec.width), fmt(spec.height)) }
    for _, o in ipairs(d:ops(frame)) do
        if o.op == "line" then
            out[#out + 1] = string.format('<line x1="%s" y1="%s" x2="%s" y2="%s" stroke="%s" stroke-width="%s"/>',
                fmt(o.x1), fmt(o.y1), fmt(o.x2), fmt(o.y2), o.color or "black", fmt(o.sw or 1))
        elseif o.op == "circle" then
            out[#out + 1] = string.format('<circle cx="%s" cy="%s" r="%s" fill="%s" stroke="%s" stroke-width="%s"/>',
                fmt(o.cx), fmt(o.cy), fmt(o.r), o.fill or "none", o.stroke or "none", fmt(o.sw or 1))
        elseif o.op == "rect" then
            out[#out + 1] = string.format('<rect x="%s" y="%s" width="%s" height="%s" fill="%s" stroke="%s" stroke-width="%s"/>',
                fmt(o.x), fmt(o.y), fmt(o.w), fmt(o.h), o.fill or "none", o.stroke or "none", fmt(o.sw or 1))
        elseif o.op == "text" then
            -- KOReader's SVG renderer ignores dy, so the baseline is placed explicitly
            local size = (o.size or 16) * Gobooks.LABEL_SCALE
            out[#out + 1] = string.format(
                '<text x="%s" y="%s" font-size="%s" font-family="%s" fill="%s" text-anchor="middle">%s</text>',
                fmt(o.x), fmt(o.y + size * 0.36), fmt(size), Gobooks.FONT_STACK, o.color or "black", esc(o.text))
        end
    end
    out[#out + 1] = "</svg>"
    return table.concat(out, "\n")
end

-- ---------------------------------------------------------------------------
-- Finding diagrams in a chapter file
-- ---------------------------------------------------------------------------

function Gobooks.is_gobooks(text)
    return text:find('xmlns:gb="https://gobooks.com"', 1, true) ~= nil
end

--[[ The diagrams of a chapter, in order: { index, first, last, xml } where
     first/last are byte offsets of the whole <div class="fig ..."> element. ]]
function Gobooks.figures(text)
    local out, pos = {}, 1
    while true do
        local s = text:find('<div class="fig', pos, true)
        if not s then break end
        local depth, p = 0, s
        local last
        while true do
            local ds, de = text:find("</?div[ >]", p)
            if not ds then break end
            if text:sub(ds, ds + 1) == "</" then depth = depth - 1 else depth = depth + 1 end
            p = de
            if depth == 0 then
                last = text:find(">", ds, true)
                break
            end
        end
        if not last then break end
        out[#out + 1] = { index = #out + 1, first = s, last = last, xml = text:sub(s, last) }
        pos = last + 1
    end
    return out
end

return Gobooks
