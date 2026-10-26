# GOReader (beta) for KOReader

**A Go (weiqi / baduk) plugin for KOReader, built for e-ink readers. Version 0.1.1-beta.**

Mainly a Go playing and recording app, with online play on OGS and an interactive Go book reader.
Written and tested on a Kobo Forma; other KOReader devices may work but are untested.

## What it does

A home screen of tiles (open it from KOReader's main menu, first entry: **GOReader**):

* **Play**
  * **SGF editor**: record a game being played on a real board, saved after every move.
  * **vs Player**: two people play face to face on the reader (Black's controls upside-down at the top).
  * **vs Computer**: play GNU Go (9x9, 13x13, 19x19, handicap, 10 levels).
* **OGS** (online-go.com)
  * **Play**: sign in, see your games, find a game (quick match), play with a CONFIRM MOVE step, pass, resign, undo, count, one-tap chat messages.
  * **Watch**: browse and watch live games (19x19 first), with chat.
  * **Chat**: read a chat room.
* **Saved games**: thumbnails of your games (about move 40, players and result), with a review screen: variations, comments, your own notes.
* **Go books**: interactive diagrams in Go books (see below), shown as a grid of covers.
* **Settings**: Wi-Fi networks, screen refresh, button pause, quick messages, optional features.

Optional features, off until switched on in **Settings > Optional features**:
**Dragon Go Server** (your games, play with a confirm step) and the **Joseki dictionary** (experimental beta).

## Go books

Tap a diagram in a Go book from gobooks.com and it becomes interactive: step through, play the moves,
answer the quizzes. Books are found anywhere in the library by what is inside them. An original EPUB is
turned into a prepared copy the first time you open it (your original is never changed); the first open
takes a while and later opens are quick. In a book, tap the top-right corner, or open the menu, to leave it.

## Install

1. Download the zip from the latest release (or this repository) and copy the **`goreader.koplugin`** folder to
   `koreader/plugins/` on your device.
2. Restart KOReader. **GOReader** is the first entry in the main menu.

On a Kobo the folder is `/mnt/onboard/.adds/koreader/plugins/goreader.koplugin`.

GOReader keeps its files in `GOReader/` on the reader (`/mnt/onboard/GOReader` on a Kobo): saved games,
prepared books, settings. A KOReader update does not touch them.

### Optional extras

* **GNU Go** for *vs Computer*: put an ARM build of the `gnugo` program at `GOReader/bin/gnugo`.
* **Kogo's Joseki Dictionary** for the joseki screen: put `kjd.sgf` at `GOReader/joseki/kjd.sgf`. It is not
  included here; check its terms of use.

## Status

Beta. It works on the author's device, but plenty is new: expect rough edges. Please report problems with the
KOReader log (`crash.log`) if something fails.

Not included yet: Go problems (tsumego, shelved) and other languages.

## License

GOReader is free software under the **GNU Affero General Public License v3.0** (see [LICENSE](LICENSE)),
the same license as KOReader. Copyright (C) 2026 akendrick.

Kogo's Joseki Dictionary and GNU Go are separate works with their own terms and are not part of this repository.

## For developers

See [DEVELOPMENT.md](DEVELOPMENT.md). The code is pure Lua (LuaJIT-compatible) with the game logic separate from
the KOReader screens, and is covered by a test suite that runs without a device.
