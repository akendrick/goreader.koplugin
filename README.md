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
    session.lua    play-vs-computer controller (turns, pass, resign, undo, scoring)
    problems.lua   Go problems from SGF; right/wrong, hint, solution
    joseki.lua     joseki dictionary navigation in any corner, sandbox
    analysis.lua   AI review data in the SGF (GA/GV), mistakes, suggestions
    ogsgame.lua    an OGS game: gamedata/move/clock/phase -> Game, clocks, result
    ogsplay.lua    play or watch one OGS game: stage/confirm moves, resync, chat
    chat.lua       game chat store: cleaning, mute, rate limit
  engine/
    gtp.lua        GTP scripts, response parsing, one-shot process runner
    engines.lua    Pachi, GNU Go and generic adapters (same interface)
    remote.lua     KataGo over https via server/katago_broker.py
  services/
    storage.lua    library outside the plugin folder, atomic writes, import
    settings.lua   validated settings, separate token storage
    library.lua    list / sort / filter / page saved games (9 per page)
    json.lua       dependency-free JSON
    dgs.lua        Dragon Go Server client (HTTP transport injected)
    websocket.lua  RFC 6455 client in pure Lua (socket injected)
    ogs.lua        OGS realtime protocol (frames, ids, ping, per-game events)
```

Outside the plugin: `server/` (KataGo broker, Python), `tools/` (engine
matches, annotate), `OGS_RESEARCH.md`, `GOREADER_PLAN.md`.

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

Calibration (`tools/calibrate.sh`, results in `tools/out/summary.txt`), 9x9
against GNU Go level 10: GNU Go 1/3/5/7 score 25/38/38/48 %. Pachi at its
500-playout minimum already scores 92 %, and more playouts do not change that,
so Pachi cannot be made weaker by playouts alone. For a 9 kyu the default
opponent is GNU Go; Pachi is the strong option. Device speed (playouts per
second on the Forma) is still unmeasured. `Engines.PACHI_PLAYOUTS` stays a
placeholder until then.

## Tests

```
lua tests/run.lua          # from the repository root; 397 tests
python3 server/test_broker.py      # broker
bash tools/selftest_annotate.sh    # broker + annotate tool end to end
```

`tests/fake_engine.lua` is a tiny GTP engine used to test the process path
without Pachi installed.

## Known data issues found while building this

* `gobook.koplugin/sgf/9x9-beginner.sgf` has coordinates outside a 9x9 board
  (move 34 onward); GoBook silently ignored them. GOReader reports it.
* `gobook.koplugin/sgf/ear-reddening-1846.sgf` is inconsistent at move 215
  (a move on a point holding a live stone); a hand-typed record.
* All 15 real DGS games in `~/Downloads` (3,174 moves) replay cleanly.
