# GOReader backend

UI-independent core of GOReader. Plain Lua (5.1 / LuaJIT compatible), no
KOReader dependencies, so everything here runs and is tested on a desktop.
The KOReader UI (screens, widgets) is a separate layer still to be written.

## Layout

```
goreader/
  core/
    sgf.lua        parse / write / tree; turn detection incl. handicap and PL
    rules.lua      legality, ko / superko, captures, undo, handicap, scoring
    game.lua       a game in progress: rules + SGF kept in step, save / load
  engine/
    gtp.lua        GTP scripts, response parsing, one-shot process runner
    engines.lua    Pachi, GNU Go and generic adapters (same interface)
  services/
    storage.lua    library outside the plugin folder, atomic writes, import
```

Require as `require("goreader.core.game")` etc. Coordinates everywhere:
`col 1..N` left to right, `row 1..N` top to bottom, colours `"B"` / `"W"`.

## Using it

```lua
local Game    = require("goreader.core.game")
local Engines = require("goreader.engine.engines")
local Storage = require("goreader.services.storage")

local game   = Game.new{ size = 9, handicap = 0, black = "You", white = "Pachi" }
local engine = Engines.pachi{ level = 5, path = "/mnt/onboard/GOReader/bin/pachi" }

local ok, why = game:play(5, 5)                 -- human move; false + reason if illegal
local m = engine:genmove(game:position(), game:to_move())
if m.kind == "move" then game:play(m.col, m.row)
elseif m.kind == "pass" then game:pass()
else game:resign() end

local dead  = engine:dead_stones(game:position())   -- at the end
local score = game:finish(dead)                      -- writes RE into the SGF
Storage.new():save_game(game:to_sgf(), "You vs Pachi 2026-10-15")
```

`Game:undo(n)`, `Game:resign(color)`, `Game.from_sgf(text)` (replays the main
line through the rules and reports `move N: reason` for an illegal move).

## Engine interface

Any engine (local process, remote KataGo, OGS) only has to provide:

| method | returns |
|---|---|
| `genmove(position, color)` | `{kind="move",col,row}` / `{kind="pass"}` / `{kind="resign"}` or `nil, err` |
| `dead_stones(position)` | list of `{col,row}` or `nil, err` |
| `final_score(position)` | `{winner, text}` or `nil, err` |
| `describe()` | label for the UI |

`position` is `Game:position()`: `{size, komi, setup={B,W}, moves, to_move}`.

Local engines run in one-shot mode: a fresh process per request is fed a
complete GTP script (`gtp.lua`), so there are no long-lived pipes to hang.

## Strength

`Engines.PACHI_PLAYOUTS` (levels 1..10) are **uncalibrated placeholders**.
They must be tuned by benchmarking on the Kobo and by playing games. GNU Go
uses its own `--level 0..10`.

## Tests

```
lua tests/run.lua          # from the repository root; 106 tests
```

`tests/fake_engine.lua` is a tiny GTP engine used to test the process path
without Pachi installed.

## Known data issues found while building this

* `gobook.koplugin/sgf/9x9-beginner.sgf` has coordinates outside a 9x9 board
  (move 34 onward); GoBook silently ignored them. GOReader reports it.
* `gobook.koplugin/sgf/ear-reddening-1846.sgf` is inconsistent at move 215
  (a move on a point holding a live stone); a hand-typed record.
* All 15 real DGS games in `~/Downloads` (3,174 moves) replay cleanly.
