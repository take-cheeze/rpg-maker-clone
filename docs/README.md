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

## Third party libraries
- Third party libraries is placed to `3rd/` directory

## Development flow
- For basic testing run `clear ; cmake --build build && cmake --build build -t test` to run basic tests
