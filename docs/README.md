# RPG Maker Clone project

## Scope of this project
- Provide RPG Maker compatible game runtime to run on any environment such like embedded boards
- Current target is to run game Nepheshel which is built by RPG Maker 2000
- Also by using mruby, the support of `RPG Maker XP/VX/VX Ace` which have RGSS will be easier
- For further support of RPG Maker version we need JavaScript support of game engine

## Features

### Title Screen
- Displays the title image from the game's data
- Shows a menu with options for New Game, Continue, and Shutdown
- Supports keyboard navigation (up/down) and selection (enter/Z)
- Menu items are drawn using the game's font system
- Selection is highlighted with a cursor

### Terminal gaming (sixel / iTerm2)
- Alternative display backends that render each frame to the terminal instead of
  opening a window: the DEC sixel protocol (`--sixel`) and iTerm2's inline-image
  protocol (`--iterm`)
- Lets the runtime be played on hosts without a windowing system (headless
  servers, SSH sessions, embedded boards with a serial console); `--iterm` also
  covers terminals that lack sixel support, notably VS Code's integrated
  terminal
- Both backends share the same windowless terminal core
  (`mruby-rgss/src/terminal.cxx`: raw-mode input, monotonic tick/delay source,
  alternate-screen handling) and differ only in the frame encoder
  (`sixel.cxx` / `iterm.cxx`)
  `RGSS::Input`. Key reference:

  | Key(s)                    | `RGSS::Input` action |
  | ------------------------- | -------------------- |
  | `↑` / `W`                 | `UP`                 |
  | `↓` / `S`                 | `DOWN`               |
  | `←` / `A`                 | `LEFT`               |
  | `→` / `D`                 | `RIGHT`              |
  | `Z` / `Enter` / `Space`   | `C` (confirm)        |
  | `X` / `Esc`               | `B` (cancel)         |
  | `C`                       | `A`                  |
  | `Q` / `Ctrl-C`            | quit the runtime     |

  The same reference is drawn as a one-line legend on the top row of the
  terminal, just above the game image (on both backends), so the controls are
  always visible while playing.

  Terminals do not report key-release events, so a key is treated as held for
  a short window (`HOLD_MS`) after its last byte; the terminal's own
  auto-repeat sustains movement while a key stays down.
- Prints an emit-rate report (frame size, MB/s, fps) to stderr about once a
  second so the real per-frame byte cost can be measured; on by default,
  disabled with `--noterm_stats`
- Output is throughput-bound: the sixel path for 320×240 at 60 Hz needs roughly
  20 Mbaud (up to ~70 Mbaud worst case); the iTerm2 path PNG-compresses each
  frame, which shrinks flat tile/sprite regions substantially but spends CPU on
  encoding. Either way the backend targets a local PTY or SSH pipe, not a real
  serial UART
- See `docs/adr/0001-terminal-gaming-sixel.md` and
  `docs/adr/0003-terminal-gaming-iterm2.md` for the design rationale and a full
  bandwidth breakdown

## Third party libraries
- Third party libraries is placed to `3rd/` directory

## Development flow
- For basic testing run `clear ; cmake --build build && cmake --build build -t test` to run basic tests
