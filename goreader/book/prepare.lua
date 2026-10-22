--[[
    goreader/book/prepare.lua - make a gobooks EPUB readable in KOReader.

    The book file you own is never touched. Preparing builds a private copy in
    which every interactive diagram is replaced by

        <a href="goreader://fig/<chapter>/<n>"> a plain SVG of the diagram </a>

    The plain SVG draws the stones (KOReader's own SVG renderer drops the
    original's <use> references) and the link lets GOReader know which diagram
    was tapped. The original diagram markup is kept in a side file inside the
    copy (META-INF/goreader/<chapter>.figs) and is what the interactive board
    plays from.

        local new_text, figs_blob, count = Prepare.chapter(text, "ch1")
--]]

local Gobooks = require("goreader.book.gobooks")

local Prepare = {}

Prepare.SCHEME = "goreader://fig/"
Prepare.SIDE_DIR = "META-INF/goreader/"
local SEP = "\n<!--GOREADER-FIG %d-->\n"

-- "OPS/ch1.xhtml" -> "ch1"
function Prepare.chapter_key(path)
    local base = path:match("([^/]+)$") or path
    return (base:gsub("%.[xX]?[hH][tT][mM][lL]?$", ""):gsub("[^%w_%-]", "_"))
end

function Prepare.side_path(key) return Prepare.SIDE_DIR .. key .. ".figs" end

-- The link target for diagram n of a chapter, and back
function Prepare.link(key, n) return Prepare.SCHEME .. key .. "/" .. n end

function Prepare.parse_link(url)
    local key, n = tostring(url or ""):match("^" .. Prepare.SCHEME:gsub("%p", "%%%0") .. "([%w_%-]+)/(%d+)$")
    if not key then return nil end
    return key, tonumber(n)
end

--[[ Rewrite one chapter. Returns nil when it has no diagrams to handle.
     Otherwise: new_text, side_file_text, number_of_diagrams, ctx_out.
     `ctx` is the stone/label context carried over from earlier chapters, for a
     chapter whose first diagram does not carry its own. Every diagram is made
     self-contained (see Gobooks.context) before it is drawn and stored. ]]
function Prepare.chapter(text, key, ctx)
    if not Gobooks.is_gobooks(text) then return nil end
    local figs = Gobooks.figures(text)
    if #figs == 0 then return nil end

    local out, side, last, count = {}, {}, 1, 0
    for _, fig in ipairs(figs) do
        local own = Gobooks.context(fig.xml)                -- keep what earlier diagrams defined, add or replace what this one defines
        if own then ctx = { defs = own.defs or (ctx and ctx.defs), style = own.style or (ctx and ctx.style) } end
        local xml = Gobooks.inject(fig.xml, ctx)
        local spec = Gobooks.parse_figure(xml)
        out[#out + 1] = text:sub(last, fig.first - 1)
        if spec then
            count = count + 1
            side[#side + 1] = SEP:format(fig.index) .. xml
            local div_class = spec.div_class or "fig center"
            local caption = ""
            if spec.caption and spec.caption ~= "" then
                caption = "<figcaption>" .. spec.caption:gsub("&", "&amp;"):gsub("<", "&lt;") .. "</figcaption>"
            end
            out[#out + 1] = string.format(
                '<div class="%s"><a href="%s" style="text-decoration:none;color:inherit"><figure class="svg">%s%s</figure></a></div>',
                div_class, Prepare.link(key, fig.index), Gobooks.static_svg(spec), caption)
        else
            out[#out + 1] = fig.xml                       -- leave an unreadable diagram alone
        end
        last = fig.last + 1
    end
    out[#out + 1] = text:sub(last)
    if count == 0 then return nil end
    return table.concat(out), table.concat(side), count, ctx
end

--[[ The original markup of diagram n, from a side file's text. ]]
function Prepare.figure_from_side(side_text, n)
    local marker = SEP:format(n)
    local s, e = side_text:find(marker, 1, true)
    if not s then return nil end
    local nxt = side_text:find("\n<!%-%-GOREADER%-FIG %d+%-%->\n", e + 1)
    return side_text:sub(e + 1, (nxt or #side_text + 1) - 1)
end

--[[ Prepare a whole book through an injected archive interface:
       io.entries()                       -> list of entry paths in order
       io.read(path)                      -> bytes
       io.write_entry(path, bytes, keep)  -> add to the output (keep: copy as is)
     Chapters (xhtml/html) are rewritten, everything else is copied unchanged.
     Returns { chapters = n, figures = n }. ]]
function Prepare.book(io)
    local stats = { chapters = 0, figures = 0 }
    local ctx
    for _, path in ipairs(io.entries()) do
        local data = io.read(path)
        local handled = false
        if path:lower():match("%.x?html?$") and not path:find("^META%-INF/") then
            local new, side, n, ctx_out = Prepare.chapter(data, Prepare.chapter_key(path), ctx)
            if new then
                ctx = ctx_out
                io.write_entry(path, new)
                io.write_entry(Prepare.side_path(Prepare.chapter_key(path)), side)
                stats.chapters, stats.figures = stats.chapters + 1, stats.figures + n
                handled = true
            end
        end
        if not handled then io.write_entry(path, data, true) end
    end
    return stats
end

return Prepare
