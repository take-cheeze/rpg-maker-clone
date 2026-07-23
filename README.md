# RPG Maker Clone implemented with mruby

## Features

### Title Screen
- Displays the title image from the game's data
- Shows a menu with options for New Game, Continue, and Shutdown
- Supports keyboard navigation (up/down) and selection (enter/Z)

### Terminal gaming
- Render the game to a terminal instead of an SDL window, using either the DEC
  **sixel** protocol or **iTerm2's inline-image** protocol
- Run with `--sixel` (optionally `--sixel_scale=N` to upscale the picture):

  ```sh
  ./rpg_maker_clone --sixel --sixel_scale=2 --game_dir path/to/game
  ```

- Or with `--iterm` (optionally `--iterm_scale=N`), which encodes each frame as
  a PNG and works in terminals that don't speak sixel — including **VS Code's
  integrated terminal**:

  ```sh
  ./rpg_maker_clone --iterm --iterm_scale=2 --game_dir path/to/game
  ```

- Controls: arrow keys or `WASD` to move, `Z`/`Enter`/`Space` to confirm,
  `X`/`Esc` to cancel, `Q` or `Ctrl-C` to quit
- `--sixel` works in terminals such as `xterm -ti vt340`, mlterm, foot, WezTerm
  and Windows Terminal; `--iterm` works in iTerm2, WezTerm and VS Code
- Either backend prints its emit rate (frame size, MB/s, fps) to stderr about
  once a second; this is on by default and can be turned off with
  `--noterm_stats`. Redirect stderr to keep the numbers off the game screen:

  ```sh
  ./rpg_maker_clone --iterm --game_dir path/to/game 2>stats.log
  ```

## TODO
- Run zip file directly
- Editor with [imgui](https://github.com/ocornut/imgui)
- Implement New Game and Continue functionality
