# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added
- Honour `RPG_RT.ini`'s `[RPG_RT] FullPackageFlag`: when set to `1` the game is
  treated as a self-contained ("full") package and RTP lookups are disabled by
  clearing `RTP_DIR`, so bitmaps are resolved only from the game directory
- Terminal gaming support using the DEC sixel graphics protocol
  - Added `--sixel` flag to render frames to a sixel-capable terminal instead
    of opening an SDL window, plus `--sixel_scale` for integer upscaling
  - Implemented a windowless LVGL display backend with a sixel flush callback
    and a monotonic-clock tick/delay source (`mruby-rgss/src/sixel.cxx`)
  - Wired terminal keyboard input (arrows/WASD, confirm, cancel, quit) into the
    RGSS::Input module via `Graphics.update`
  - Switched to the terminal's alternate screen buffer while a game is running
    so it no longer scribbles sixels over the shell history; on exit (including
    fatal signals) the pre-game screen contents and cursor are restored
  - Documented the decision in `docs/adr/0001-terminal-gaming-sixel.md`
- Terminal gaming support using iTerm2's inline-image protocol
  - Added `--iterm` flag to render frames to the terminal via the OSC 1337
    `File=` sequence, plus `--iterm_scale` for integer upscaling. Each frame is
    PNG-encoded (via stb_image_write) and emitted base64-encoded, so it renders
    in terminals that don't support sixel — including VS Code's integrated
    terminal, iTerm2 and WezTerm
  - Refactored the windowless terminal backend so both the sixel and iTerm2
    encoders share one core (`mruby-rgss/src/terminal.cxx`: raw-mode input,
    monotonic tick/delay source, alternate-screen handling); each protocol is
    now just a frame encoder (`sixel.cxx` / `iterm.cxx`)
  - Documented the decision in `docs/adr/0002-terminal-gaming-iterm2.md`
- Expanded the `mruby-rgss` RGSS built-in class library:
  - `RGSS::Color` — floating point RGBA color with clamping, `set`, `==`,
    `to_s` and Marshal (`_dump`/`_load`) support
  - `RGSS::Tone` — red/green/blue/gray tone with clamping, `set`, `==`,
    `to_s` and Marshal support
  - `RGSS::Table` — 1/2/3 dimensional 16bit integer array (`[]`, `[]=`,
    `xsize`/`ysize`/`zsize`/`dim`, `resize`) with the RGSS Marshal format,
    used for map/tile data
  - `RGSS::Bitmap` — added `width`, `height`, `rect`, `clear`, `fill_rect`,
    `get_pixel`, `set_pixel`, `blt` (with opacity alpha-blending) and
    font-aware, alignment-aware `draw_text`
  - `RGSS::Rect` — added `==`, `to_s`, Marshal support and fixed the instance
    type so `Rect.new` no longer trips the DATA assertion
  - `RGSS::Font` — name/size/bold/italic/color plus class-level defaults and
    `Font.exist?`; `Bitmap#font`/`Bitmap#font=` accessors
  - `RGSS::Audio` — inert stubs for the standard bgm/bgs/me/se API that warn
    (once per method) to stderr when called
  - `RGSS::Graphics` — `frame_count` (advanced by `update`), `frame_rate`,
    and `freeze`/`transition`/`frame_reset` stubs that warn (once per method)
    to stderr when called
  - Tests covering the new value classes, bitmap pixel operations and Marshal
    round-trips
- Title screen menu implementation
  - Added window component to display menu items (New Game, Continue, Shutdown)
  - Implemented menu navigation with keyboard input (up/down arrows)
  - Added selection highlighting with cursor
  - Implemented basic menu item selection functionality
- RPG Maker 2000 style windows
  - `RGSS::Window` now renders a real windowskin: a stretched 32x32 background
    tile plus the 8px frame border (corners and edges) taken from the System
    graphic, with the selection cursor and contents composited on top
  - Falls back to a plain dark panel with a light border when no windowskin can
    be loaded
  - Parsed the System graphic name (`system_graphic`, LDB chunk 19) from the
    database and used it as the title menu windowskin
  - Sized and centred the title menu window to fit its labels, matching the
    reference title layout
  - Added `RGSS::Bitmap#stretch_blt` (nearest-neighbour scaled blit with
    opacity alpha-blending) plus a test
- Input module implementation
  - Added key constants (UP, DOWN, LEFT, RIGHT, A, B, C, etc.)
  - Implemented input state tracking (press, trigger, repeat)
  - Added directional input helpers (dir4, dir8)

### Changed
- Updated documentation to reflect new title screen functionality
- Marked "Show window component for title scene" as completed in TODO list
- Enhanced database term schema with comprehensive RPG Maker 2000/2003 terms:
  - Added battle menu command terms
  - Added save/load related terms
  - Added status and equipment terms
  - Fixed shutdown term ID (changed from 116 to 117)
