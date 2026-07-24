# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added
- MV Canvas2D rendering bridge, first slice (milestone M4): `document`,
  `HTMLCanvasElement` and a `CanvasRenderingContext2D` backed by native RGBA8
  buffers (`mruby-mvjs/src/mvcanvas.cxx`). `getContext('2d')` returns the shim
  and `getContext('webgl')` returns `null`, so PIXI.js falls back to its Canvas
  renderer. Implements the drawing subset that renderer uses — `fillRect`
  (with `fillStyle` `#rgb`/`#rrggbb`/`rgba()` and `globalAlpha`), `clearRect`,
  nearest-neighbour scaled `drawImage` (canvas→canvas), `getImageData`, and
  `measureText` — with path/transform/text operations stubbed for now. Canvas
  buffers are display-independent, so the primitives are unit-tested by reading
  pixels back (`mruby-mvjs/test/canvas_test.rb`). On-screen present and PNG
  `Image` loading follow.
- MV JavaScript host environment, first slice (milestone M3): `MV::JS.eval` now
  runs against a **persistent** quickjs-ng runtime/context (state carries across
  calls, as the MV engine expects) instead of a throwaway per call, and the
  context is bootstrapped with the first browser/host globals —
  `window`/`self`/`global`/`globalThis` aliases, a `console`
  (`log`/`info`/`warn`/`error`), a native synchronous file reader
  (`__mv_readFileSync`), and a minimal synchronous `XMLHttpRequest` built on it
  (how MV's `DataManager` loads `data/*.json`). Also the event-loop machinery —
  `setTimeout`/`setInterval`/`clearTimeout`, `requestAnimationFrame`/
  `cancelAnimationFrame` and `performance.now` — driven by a new `MV::JS.pump`
  (`now_ms`) that fires due timers and animation-frame callbacks and drains
  promise microtasks, so the JS game shares the engine's fixed cadence instead
  of blocking; plus passive `navigator`/`location`/`localStorage` stubs. Also
  the NW.js-style `require('fs'|'path')` MV uses for local-file saves (backed by
  native read/write/exists), and `MV::JS.eval_file(path)` to load a script into
  the host. `MV#boot` now evaluates the MV core scripts (`MV::CORE_SCRIPTS`) in
  order via `eval_file`, and `MV#main_loop` advances the host with `MV::JS.pump`
  at 60 fps — wired but still gated behind `MV.runtime_available?` (false) until
  the Canvas2D rendering bridge (M4) lands. Covered by
  `mruby-mvjs/test/host_test.rb`
- Embedded JavaScript engine for RPG Maker MV support (milestone M2): added
  quickjs-ng as the `3rd/quickjs` git submodule and static-linked its `qjs`
  library into both the main executable and the mruby test binary. `MV::JS.eval` (in
  `mruby-mvjs/src/mvjs.cxx`) evaluates JavaScript and marshals scalar results
  (Integer/Float/String/true/false/nil) back to mruby, raising `RuntimeError` on
  a JS exception; `MV.js_available?` reports that the engine is compiled in.
  Covered by `mruby-mvjs/test/js_test.rb`
- Groundwork for JavaScript RPG Maker (MV) support (approach: embed a real
  JavaScript engine and run the game's own scripts, rather than reimplement the
  engine in mruby):
  - New `mruby-mvjs` gem — a thin Ruby orchestration layer (`MV`) that detects
    an MV project (`js/rpg_core.js` + `data/System.json`), knows the canonical
    MV script load order, and defines the boot/pump handshake with a
    clearly-marked seam where the embedded runtime plugs in. The runtime
    (quickjs-ng) is not built into the binary yet, so an MV game is detected but
    reports that support is under construction instead of misbehaving
  - `src/main.cxx` now sniffs the MV directory layout and instantiates `MV`,
    alongside the existing RPG2k/RPGXP detection
  - Host-runnable specs (`mruby-mvjs/test`) covering project detection and the
    script load order
  - Documented the decision, layered architecture and milestone roadmap in
    `docs/adr/0004-javascript-maker-mv-quickjs.md` and `docs/TODO.md`
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

### Fixed
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
