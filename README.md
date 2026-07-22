# RPG Maker Clone implemented with mruby

## Features

### Title Screen
- Displays the title image from the game's data
- Shows a menu with options for New Game, Continue, and Shutdown
- Supports keyboard navigation (up/down) and selection (enter/Z)

### Map exploration
- "New Game" builds the initial party from the database, reads the start
  position from the map tree, loads the starting map and enters the map scene
- Walk the party leader around the map with the arrow keys / `WASD`: grid
  movement with smooth stepping, walk animation, tile/edge/event collision and a
  camera that follows the player
- Tiles are currently drawn as colour blocks (real chipset rendering is planned)

### Terminal gaming (sixel)
- Render the game to any sixel-capable terminal instead of an SDL window
- Run with `--sixel` (optionally `--sixel_scale=N` to upscale the picture):

  ```sh
  ./rpg_maker_clone --sixel --sixel_scale=2 --game_dir path/to/game
  ```

- Controls: arrow keys or `WASD` to move, `Z`/`Enter`/`Space` to confirm (C),
  `X`/`Esc` to cancel (B), `C` for the A button, `Q` or `Ctrl-C` to quit
- Works in terminals such as `xterm -ti vt340`, mlterm, foot, WezTerm and
  Windows Terminal

## TODO
- Run zip file directly
- Editor with [imgui](https://github.com/ocornut/imgui)
- Real chipset tile rendering (lower/upper chip graphics, autotiles, tile
  animation); the map scene currently draws placeholder colour-block tiles
- Implement Continue functionality (needs the `LCF::SaveData` schema)
