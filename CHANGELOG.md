# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added
- Audio playback: `RGSS::Audio` is now backed by SDL_mixer instead of inert
  stubs, so games play sound. Looping **BGM** and **BGS**, one-shot **ME**
  (music effects that interrupt the BGM and then let it resume, tracked per
  frame from `Graphics.update`) and overlapping **SE** sound effects are all
  supported, with per-channel volume mapped from the RPG 0..100 scale. The
  public API resolves a game-supplied name to a real file the same way `Bitmap`
  does — searching `GAME_DIR`/`RTP_DIR` crossed with the `Music/`, `Sound/` and
  `Audio/*` sub-folders and the known extensions (`.ogg`, `.wav`, `.mid`,
  `.mp3`, `.flac`) — and the event interpreter's *Play BGM* / *Play SE* commands
  now forward the command's volume and tempo. SDL is kept out of the
  `mruby-rgss` gem (which is also built for the terminal-only, Emscripten and
  standalone-test variants): the gem's native `Audio` primitives call through a
  plain function table (`include/rgss_audio.hxx`) that the executable fills with
  the SDL_mixer backend (`src/sdl_audio.cxx`) at startup, mirroring the SDL
  keyboard bridge. With no backend installed every call is a graceful no-op.
  Pitch/tempo is accepted but not applied (SDL_mixer has no pitch control), and
  MIDI playback depends on the SDL_mixer build having a synth; a file that fails
  to load is logged once and skipped. See ADR 0005
- The title menu plays the database's cursor-move sound effect (System > cursor
  SE) when the selection moves up or down, the first consumer of the new SE
  playback
- Built-in CPU/memory profiler for finding performance bottlenecks, enabled with
  `--profile` (report cadence tunable via `--profile_interval_ms`, default
  1000ms). Once a second it prints a summary line to stderr with the measured
  frame rate, per-frame CPU **work** time (the frame span minus the fps-cap
  sleep) and a breakdown of named sub-sections — `scene.update`, `input.update`
  and the `gfx.*` phases of `Graphics.update` (z-ordering, bitmap invalidation,
  LVGL handling) — each with its average/max time and share of the frame, plus
  memory use: process RSS, the LVGL heap pool (used bytes + fragmentation) and
  mruby allocation activity (live blocks and allocations/sec). Custom sections
  can be timed from Ruby with `RGSS::Profiler.section("name") { ... }`, and
  `RGSS::Profiler.stats` returns the current interval as a Hash. When
  `--profile` is off the profiler does no work — every timing/sampling entry
  point returns on a single predicted branch — so the default build is
  unaffected. A Chrome trace can be exported with `--profile_trace=FILE` (or
  `RGSS::Profiler.trace_start`/`trace_stop` from Ruby to trace a specific
  window): every frame and section is streamed as a Chrome Trace Event and each
  memory sample as counters, producing a file that `chrome://tracing` and
  Perfetto load as a flame chart with memory graphs. The stream is written
  incrementally and stays loadable even if the process is killed mid-run
- Keyboard input now works in the SDL window backend: an SDL event watch (added
  in `src/sdl_input.cxx`) observes key events without stealing them from LVGL's
  own event pump, translates them to `RGSS::Input` key ids (arrows;
  Z/Enter/Space = C, X/Esc = B, C = A; A/S/D = X/Y/Z; Q/PgUp = L, W/PgDn = R;
  Shift/Ctrl/Alt and F5–F9), and feeds them into `RGSS::Input` from
  `Graphics.update`, mirroring the existing terminal backend. Previously
  `RGSS::Input.update` was a stub and games were only controllable under the
  `--sixel`/`--iterm` terminal backends
- `RGSS::Viewport` is now a functional display object rather than a stub: it
  wraps an LVGL container that positions and **clips** its sprites to a `rect`,
  scrolls their content by `ox`/`oy`, hides via `visible`, and takes part in
  `z` ordering against top-level sprites. Sprites created with
  `Sprite.new(viewport)` are parented to it, and z ordering is now resolved
  per LVGL parent so sprites inside a viewport stack among themselves while the
  viewport stacks on the screen. LVGL delete events invalidate the mruby
  wrappers so a viewport can safely own (and free) its child sprites
- `RGSS::Sprite` / `RGSS::Viewport` gained a `visible` / `visible=` accessor

### Changed
- `RGSS::Window` is now assembled from three layered sprites inside a viewport
  (windowskin background+frame, selection cursor, and contents/text) instead of
  compositing everything into one sprite's bitmap. The viewport clips the layers
  to the window rectangle, and updating the cursor or text no longer re-blits
  the windowskin
- Playable gameplay after "New Game": `RPG2k#start_new_game` builds the party
  (`Game::Party`/`Game::Actor`) from the database, reads the start position from
  the map tree, loads the starting map and enters a walkable `Scene::Map`. The
  map scene renders the lower/upper tile layers (as colour blocks derived from
  tile ids, pending real chipset blitting), draws the party leader from their
  `CharSet` graphic, and supports grid movement with pixel interpolation, walk
  animation, edge/tile/event collision (chipset `passable_data_lower`) and an
  edge-clamped follow camera
- Event system: `Game::Interpreter` runs a decoded RPG2000 command list — Show
  Message/Choices, Control Switches/Variables, Change Gold/Items/Party,
  Conditional Branch/Else/End, Loop/Break, Label/Jump, Timer, Teleport, Wait,
  Play BGM/SE and End Event — backed by global `Game::Switches`/`Game::Variables`
  and party inventory. `Game::EventPage` selects an event's active page from
  switch/variable/item/actor conditions, and `Game::CommonEvent` runs auto-start
  and parallel common events. Action-button and auto-start events trigger on the
  map, a message/choice window renders over it (with `\v[n]`/`\n[n]`/`\\` control
  codes expanded), and Teleport transfers between maps
- Main menu (`Scene::Menu`), opened over the map with the cancel button: shows
  party status with Save and End Game (item/skill/equip/status are placeholders)
- Save & Continue: the game state (position, switches, variables, party,
  inventory, gold, hp/mp, timer) serialises to a portable `Marshal` save
  (`Game::State#to_h` / `State.load`), written by the menu's Save command and
  reloaded from the title's "Continue"
- Decoding for the LCF `:event` (event command list, `LCF::EventCommand`),
  `:int8_array` and `:int32_array` schema types, and `Array2D#each` for walking
  sparse event/actor tables
- Filled in the LCF database schemas (`mruby-lcf/mrblib/schema.rb`) from the
  VIPRPG 200X analysis notes: skills, items, enemies, enemy groups, terrain,
  attributes, states, battle animations, classes, and the full terminology and
  system sections, plus switches/variables
  - Documented the decision in `docs/adr/0002-lcf-database-schema-fields.md`
- Honour `RPG_RT.ini`'s `[RPG_RT] FullPackageFlag`: when set to `1` the game is
  treated as a self-contained ("full") package and RTP lookups are disabled by
  clearing `RTP_DIR`, so bitmaps are resolved only from the game directory
- Populated the LCF map, map tree and save data schemas from the VIPRPG 200X
  analysis notes (`mruby-lcf/mrblib/schema.rb`):
  - `MAP_UNIT` (`LcfMapUnit`) — chipset/size, scroll and parallax settings, the
    lower/upper tile layers and the full map event tree (events → pages →
    appearance condition and move route)
  - `SAVE_DATA` (`LcfSaveData`) — save title (file-select screen fields), the
    system block (scene, switches/variables, message/face settings, BGM/SE
    overrides, transitions, permissions) and hero/vehicle positions
  - Map tree: fixed the area-rect field (was a typo `type: :Araa`), renamed the
    editor-only chunk 3 to `indentation` and gave encounters an enemy-group
    default; the reader now loads all three map-tree sections (properties, tree
    order and initial positions) instead of only the first
- Verified by parsing the bundled Nepheshel `RPG_RT.lmt` and all 543 `Map*.lmu`
  files across both game variants (tile layers match `width * height`).
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
  - Documented the decision in `docs/adr/0003-terminal-gaming-iterm2.md`
- Added a `--term_stats` flag (on by default) that draws the terminal emit
  rate — frame size, MB/s and fps — on-screen just under the control legend,
  refreshed about once a second while a terminal backend is active, so the real
  per-frame byte cost is visible against the estimated bandwidth. Disable with
  `--noterm_stats`; the counter lives in the shared `terminal.cxx`, so both the
  sixel and iTerm2 backends report it
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
- GitHub-hosted test-bed download scripts reachable from sandboxed/proxied
  environments where the tkool CDN is blocked (unlike the existing
  Nepheshel/Pray-for-You scripts):
  - `scripts/download-mtf-meido-action.bash` — RPG Maker 2000 game
    (`data/mtf-meido-action/Debug`: `RPG_RT.ldb`/`.lmt` and 13 `Map*.lmu`)
  - `scripts/download-opengame-xp.bash` — RPG Maker XP project
    (`data/OpenGame.exe/Testbed/XP`: full `Data/*.rxdata` set)
  - Both use a sparse, blob-filtered `git clone`; the CI `build` job now fetches
    them alongside Nepheshel and keys the game cache off all download scripts

### Fixed
- Windowskin (and other graphic) loading now works for PNGs whose `IDAT`
  deflate stream references data before the start of the output. The PNG/zlib
  spec forbids this, so stb_image (and zlib itself) reject such files with
  `bad dist` / "invalid distance too far back" -- but the producers, including
  RPG Maker System graphics, rely on the missing pre-history reading as zeros.
  Added a self-contained tolerant PNG decoder (lenient inflate + scanline
  unfiltering + palette/grayscale/truecolour expansion) in `bmp_init_file` that
  runs only as a fallback after stb_image refuses a file, so those windowskins
  load instead of dropping to the plain panel
- Windowskin loading now works for games whose System graphic is stored in RPG
  Maker's native XYZ format. `RGSS::Bitmap` already searched for `.xyz` files,
  but stb_image could not decode them, so an XYZ windowskin silently fell back
  to the plain panel. Added an XYZ decoder (`"XYZ1"` header + zlib-compressed
  palette and indices) to `bmp_init_file` that also honours the transparent
  colour-key flag. If the standard zlib stream is rejected, the decoder retries
  the payload as raw DEFLATE (no zlib header) before giving up
- `RGSS::Bitmap` load failures now report the decoder's own reason instead of a
  bare "Failed to init bitmap". The XYZ decoder records a detailed diagnostic
  (dimensions, zlib header bytes, compressed/expected sizes and stb's error such
  as `bad dist`), exposed via `Bitmap._load_error`/`Bitmap._stbi_error` and
  included in the raised message; windowskin fallbacks log it to stderr rather
  than swallowing it silently. Bitmap's retry lookups also now forward the
  transparent-colour flag to every candidate path, not just the first
- LCF `File#method_missing` delegates field access with `__send__` instead of
  `send`, so parsed fields (`db.player`, `map_tree.initial`, ...) resolve on
  mruby builds where `Kernel#send` is not exposed on objects that define their
  own `method_missing`
- LCF reader (`mruby-lcf/mrblib/lcf.rb`): booleans are read as their real
  1-byte encoding (previously required a 0-byte chunk and always returned
  `true`); nested `Array2D`/`Array1D` sections wrap a `String` in `StringIO`
  correctly (the old `kind_of? IO` check failed for `StringIO`); added the
  `:int16_array` element type used by the tile layers and the area rect.

### Changed
- Updated documentation to reflect new title screen functionality
- Marked "Show window component for title scene" as completed in TODO list
- Enhanced database term schema with comprehensive RPG Maker 2000/2003 terms:
  - Added battle menu command terms
  - Added save/load related terms
  - Added status and equipment terms
  - Fixed shutdown term ID (changed from 116 to 117)
