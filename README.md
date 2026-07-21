# RPG Maker Clone implemented with mruby

## Features

### Title Screen
- Displays the title image from the game's data
- Shows a menu with options for New Game, Continue, and Shutdown
- Supports keyboard navigation (up/down) and selection (enter/Z)

### Terminal gaming (sixel)
- Render the game to any sixel-capable terminal instead of an SDL window
- Run with `--sixel` (optionally `--sixel_scale=N` to upscale the picture):

  ```sh
  ./rpg_maker_clone --sixel --sixel_scale=2 --game_dir path/to/game
  ```

- Controls: arrow keys or `WASD` to move, `Z`/`Enter`/`Space` to confirm,
  `X`/`Esc` to cancel, `Q` or `Ctrl-C` to quit
- Works in terminals such as `xterm -ti vt340`, mlterm, foot, WezTerm and
  Windows Terminal

## TODO
- Run zip file directly
- Editor with [imgui](https://github.com/ocornut/imgui)
- Implement New Game and Continue functionality
