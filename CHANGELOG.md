# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added
- LCF map (`.lmu`) parsing: a `MAP_UNIT` schema for `LCF::MapUnit` covering
  dimensions, chipset id, the lower/upper tile layers and the event table
- New Game now boots into gameplay setup: `RPG2k#start_new_game` builds the
  initial party from the database (`Game::Party`/`Game::Actor`), reads the start
  position from the map tree, loads the starting map and enters a new
  `Scene::Map` (the tilemap/player renderer is still to come). Selecting
  "Continue" warns that saved-game loading is not implemented yet
- `System.party` (the initial party actor id list) to the database schema, and
  the `int16_array`/`short_array` LCF element types (used by actor stats, map
  tile layers and packed id lists)

### Fixed
- `LCF::MapTree` now parses all three parts of the map tree (map properties,
  tree, and the `initial` start-position block) instead of only the first, so
  the New Game start map/position are available
- Nested `Array2D` fields (such as the database's actor table) parse correctly:
  raw-string tables are now wrapped in a stream like `Array1D` already did,
  instead of raising

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
