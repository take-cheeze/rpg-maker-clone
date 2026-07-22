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
- Supports keyboard navigation (up/down, wrapping at the ends and repeating
  while held) and selection (enter/Z)
- Menu items are drawn using the game's font system
- Selection is highlighted with the windowskin's cursor graphic (nine-sliced
  from the System set, matching the RPG2k look)

### Terminal gaming (sixel)
- Alternative display backend that renders each frame to the terminal using the
  DEC sixel protocol, enabled with the `--sixel` flag
- Lets the runtime be played on hosts without a windowing system (headless
  servers, SSH sessions, embedded boards with a serial console)
- Reads keyboard input directly from the terminal and forwards it to
  `RGSS::Input`
- See `docs/adr/0001-terminal-gaming-sixel.md` for the design rationale

## Third party libraries
- Third party libraries is placed to `3rd/` directory

## Development flow
- For basic testing run `clear ; cmake --build build && cmake --build build -t test` to run basic tests
