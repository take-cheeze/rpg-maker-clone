# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added
- MV render capture: a `--mv_screenshot=PATH` flag writes a PNG of the rendered
  MV frame a couple of seconds into the boot (`MV::JS.screenshot` encodes the
  live PIXI canvas via stb_image_write), and the CI smoke test uploads it as the
  `mv-screenshot` artifact — so the actual on-screen output can be inspected as
  the maker is brought up, not just the engine's log. With the boot fixes below,
  the KinoAR/Lunatic-Core test bed now reaches `Scene_Title` cleanly
  (`[MV] scene: Scene_Boot -> Scene_Title`).
- MV boot now reaches PIXI init and continues through `Graphics.initialize`
  (milestone M4/M5): with the JS host in place PIXI 4.x starts in Canvas mode
  against the Canvas2D bridge. Cleared the init-time blockers that followed: the
  bundled **FPSMeter** debug overlay (which throws when instantiated on this
  host) is replaced with a no-op exposing the tick/show/hide methods MV drives
  each frame; the **document/element shim** gained the surface
  `Graphics.initialize` walks (`getElementsByTagName('head')`, element
  `getElementsByTagName` for `_disableContextMenu`, a `<style>.sheet.insertRule`,
  `createTextNode`, child-returning `appendChild`, `classList`); a silent
  **`AudioContext`** stub lets `SceneManager.initAudio` succeed (real Web Audio →
  `RGSS::Audio` is a later milestone); and `document.getElementsByTagName('script')`
  now returns a readable entry so `Utils.canReadGameFiles`/`checkFileAccess`
  passes. The whole `SceneManager.initialize` sequence now completes, and a
  `document.fonts` (`FontFaceSet`) stub reporting the game font ready makes
  `Scene_Boot` advance to the title instead of looping forever on MV's
  measured-text-width font check (which a font-agnostic `measureText` can't
  satisfy). `window` also gained the inert event/lifecycle methods MV wires up
  (`addEventListener`/`removeEventListener`/`dispatchEvent`/`close`), since
  `Graphics._setupEventHandlers`, `Input` and `TouchInput` register listeners on
  it; and the canvas gradient factories (`createLinearGradient` etc.) return
  chainable stubs so `Bitmap.gradientFillRect` doesn't crash. With these, the MV
  test bed (KinoAR/Lunatic-Core) now **boots end-to-end with no engine errors** —
  through PIXI init, `SceneManager.initialize`, `Scene_Boot` and on into the
  scene graph — and `MV#main_loop` logs each scene transition so the boot's
  progress is visible in the smoke test. Covered by `mruby-mvjs/test`.
- MV boot resilience (milestone M4): script evaluation now follows browser
  semantics — a `<script>` that throws while executing is logged and the next
  one still runs, instead of aborting the whole engine. Previously the
  `iphone-inline-video` library (an iOS-only inline-video shim MV bundles) threw
  `invalid 'in' operand` under quickjs and took the entire boot down with it.
  `MV#boot` now catches and logs each script's (and `window.onload`'s) errors and
  carries on, and installs a no-op `makeVideoPlayableInline` fallback so video
  creation can't crash later on this (video-less) host.
- MV transform-aware canvas drawing (milestone M4): the `CanvasRenderingContext2D`
  shim now tracks the full 2D transform — `save`/`restore`, `translate`/`scale`/
  `rotate`/`transform`/`setTransform`/`resetTransform` — and `drawImage` honours
  it. PIXI's canvas renderer positions every sprite by setting the transform and
  drawing at the origin, so without this all sprites piled up at (0,0); now they
  land where they belong. `drawImage` rasterises by walking the transformed dest
  rect's device-space bounding box and inverse-mapping each pixel, so scale,
  rotation and translation all work with no gaps; `fillRect`/`clearRect` map
  their rect through the matrix (exact for translate/scale). Covered by
  `mruby-mvjs/test/canvas_test.rb`.
- MV on-screen present (milestone M4): the MV canvas is now drawn to the screen
  each frame. `MV#boot` creates one full-screen `RGSS::Sprite`/`Bitmap`, and
  `MV::JS.present` copies MV's PIXI canvas (resolved from the running game's
  renderer view / `Graphics._canvas`) into that bitmap — swapping R/B for the
  RGBA→ARGB8888 layout and marking it dirty so `Graphics.update` repaints it.
  mruby-rgss gained a small exported accessor (`include/rgss_bitmap.hxx`,
  `rgss::bitmap_pixels`) so the present blits straight into the bitmap's buffer.
  Covered by `mruby-mvjs/test/canvas_test.rb`. (Correct sprite positioning still
  needs transform-aware `drawImage`, which PIXI's canvas renderer relies on.)
- MV PNG image loading and asset path rooting (milestone M4): `new Image()` now
  decodes a game PNG through stb_image (`__mv_imageLoad` in `mvcanvas.cxx`)
  straight into a native RGBA canvas, exposing `width`/`height` and firing
  `onload`/`onerror` asynchronously (on the next host frame) as the browser
  contract MV's `Bitmap` loader expects; the decoded image is a first-class
  `drawImage` source. Because the process is not chdir'd into the game dir,
  MV's game-relative asset requests (`data/*.json`, `img/*.png`, saves) are now
  rooted at the game directory via a shared `mv_resolve_path`, configured from
  Ruby with `MV::JS.base_dir=` at boot. Covered by `mruby-mvjs/test`
  (`canvas_test.rb` image decode/draw, `host_test.rb` base-dir resolution).
- `scripts/download-lunatic-core.bash`: fetches a small, complete RPG Maker MV
  project (KinoAR/Lunatic-Core — full corescript + `data/*.json` + `img/`) into
  the git-ignored `data/` dir as the MV test bed, mirroring the RPG Maker 2000
  Nepheshel download. It is detected as an MV game by `src/main.cxx`
  (`js/rpg_core.js` + `data/System.json`) and is downloaded, never vendored.
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
- The event interpreter now supports **Call Event**. A Call Event command
  suspends the current command list and runs a referenced list to completion,
  then resumes where it left off, via a call stack on `Game::Interpreter` and a
  resolver the scene supplies (common events by id; a map event's page from the
  loaded map). This makes *call-only* common events (start condition 5) — which
  auto-start and parallel processing never reach — actually run, and lets events
  share logic. Nested calls unwind correctly and recursion is bounded
  (`MAX_CALL_DEPTH`) so a self-calling event terminates instead of hanging.
  Conditional Branch also gained the **timer** condition (compare the countdown
  timer's seconds). `Scene::Map` wires a resolver over its common and map events
  (refreshed on teleport). Covered by new checks in
  `scripts/rpg2k_logic_check.rb` and `scripts/rpg2k_scene_check.rb`.
- Events now move on the map. Decoded move routes (`LCF.parse_move_commands`)
  and event-page movement settings, which previously only parsed, now drive
  events at runtime. A new `Game::MoveRoute` executor runs a decoded route
  against a movable `Game::Character` — all of the RPG2000 move-route commands
  (cardinal/diagonal/random/toward-hero/away-hero/forward moves, the face and
  turn commands, wait/jump markers, switch on/off, change graphic, play sound,
  and the speed/frequency/through/animation/transparency/facing-lock toggles),
  honouring the route's repeat and skippable flags (a blocked non-skippable move
  turns to face the obstacle and retries). `Game::MoveType` implements the
  autonomous walk types (random, vertical/horizontal bounce, approach and flee
  the hero), and a small `Game::Rng` supplies the randomness they need (mruby is
  built here without `mruby-random`). `Scene::Map` gives every event a
  `Game::Character`, steps it each frame per its page's move type or custom move
  route — paced by the event's move frequency — through a `MapWorld` adapter that
  reports passability, the hero position and switch/sound side effects, and keeps
  events from overlapping each other, the player or impassable tiles. Two host
  harnesses cover the new code under CRuby (the SDL/mruby binary can't run in
  CI's cheap path): `scripts/rpg2k_logic_check.rb` exercises the pure move-route,
  movement-type and interpreter logic, and `scripts/rpg2k_scene_check.rb`
  constructs the actual `Scene::Map` behind RGSS stubs and ticks it to verify the
  event-movement wiring. Both run in CI next to the LCF test-bed check.
- Wio Terminal (Seeed, ATSAMD51) port — P1 hardware bring-up. A new PlatformIO
  target (`platformio.ini`, `app/wio/`) builds an Arduino firmware around a new
  LVGL display + input HAL (`mruby-rgss/src/wio.cxx`): the 320×240 ILI9341 LCD is
  driven in LVGL partial-render mode (a small draw buffer, not a 150 KB full
  framebuffer that would exhaust the 192 KB SRAM), the tick/delay source comes
  from Arduino `millis()`/`delay()`, and the three buttons + 5-way switch are
  scanned into `RGSS::Input` via `rgss_wio_poll` (`wio_input_bridge.cxx`), called
  from `Graphics.update` next to the SDL/terminal poll hooks. A `wio` mruby ARM
  cross-build (`MRUBY_TARGET=wio` in `build_config.rb`) and SD-backed newlib
  syscalls (`app/wio/src/sd_syscalls.cxx`) are scaffolded for the later
  interpreter/asset slices. All of it is additive and guarded (`WIO_TERMINAL`),
  so the desktop and wasm builds are unchanged. Design and memory budget in
  `docs/adr/0007-wio-terminal-port.md`; a CI job compiles the firmware.
- The WebAssembly build now loads an RPG Maker project **at runtime** instead of
  requiring one to be baked into the page at compile time, so a single build
  plays any game. A new Emscripten shell (`src/shell.html`) offers a loader that
  accepts a local `.zip`, a direct `.zip` URL, or a GitHub repository
  (`owner/repo`, `owner/repo@ref`, or a `github.com` URL, resolved to its
  `codeload` archive). The zip is unpacked in the browser with the native
  `DecompressionStream` API — no third-party JavaScript — the folder containing
  `RPG_RT.ldb` (RPG2k) or `Game.ini` (XP) is located (top-level wrapper folders,
  as GitHub archives use, are handled) and mounted at `/game`, then the exported
  `rpg_start_game()` constructs the game and starts the frame loop. Under
  Emscripten `main()` now sets up the interpreter and display and returns to the
  browser, deferring game construction until a project is present; a project
  baked in with `-DWASM_GAME_DIR` still auto-starts. Cross-origin downloads
  (GitHub, most `.zip` URLs) need a CORS proxy — the loader has an optional
  field for one — or the always-works local-file path. Downloaded archives are
  cached (Cache Storage, keyed by the resolved URL) so re-loading the same URL
  or repo skips the network; the loader can force a fresh download or clear the
  cache. The URL and CORS-proxy fields persist across reloads (localStorage) and
  are mirrored into the page's `?url=`/`?proxy=` query string, so a project link
  is bookmarkable and shareable and a `?url=` link auto-loads
- On-screen game keypad for the browser (WebAssembly) build so the game is
  playable by touch or mouse without a physical keyboard. A custom Emscripten
  shell page (`src/shell.html`) draws `<button>` elements — a D-pad plus OK (C),
  Cancel (B), Dash (Shift), the L/R shoulders and the A/X/Y/Z buttons — laid out
  responsively beneath the game canvas. Each button's pointer handlers call
  `Module._rgss_wasm_key`, a tiny bridge exported from `src/wasm_keypad.cxx` that
  feeds the very same input buffer as the SDL keyboard watch, so a tapped button
  is indistinguishable from a pressed key (including `RGSS::Input` trigger/repeat
  timing). Pointer capture and a window-blur handler prevent stuck keys, and
  physical keyboard input keeps working exactly as before. Wired up only for the
  Emscripten target via `--shell-file` in `CMakeLists.txt`
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
  to load is logged once and skipped. See ADR 0006
- The title menu plays the database's cursor-move sound effect (System > cursor
  SE) when the selection moves up or down, the first consumer of the new SE
  playback
- Move-route command decoding for the LCF loaders: `LCF.parse_move_commands`
  and `LCF::MoveCommand` decode the compact move-command layout (bare commands
  plus the string/integer parameters that Switch On/Off, Change Graphic and Play
  Sound Effect carry), exposed through a new `:move_commands` schema type wired
  into the event-page and common-event `move_route.commands` chunk. Previously
  that chunk was mis-declared as an event-command blob and failed to parse on
  real maps
- Event-page condition schema now covers its trailing RPG2003 chunks
  (`timer2_sec`, `compare_operator`), so a real map's condition data parses with
  no unknown chunks. The RPG2000 runtime still compares variables with `>=`
- `scripts/lcf_testbed_check.rb`: a host smoke-test that runs the pure-Ruby LCF
  parser (`mruby-lcf/mrblib/{lcf,schema}.rb`) over real downloaded test-bed
  projects — walking every schema field of a game's `RPG_RT.ldb`, `RPG_RT.lmt`
  and `Map*.lmu` and asserting structural invariants (layer sizes match the map
  dimensions, move-command ids are in range, events iterate). It auto-discovers
  games under `data/` and now runs in CI after the test-bed download step,
  exercising the loaders against genuine editor output rather than only the
  synthetic blobs the unit tests use
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
- On-screen **log console** for the `--sixel`/`--iterm` terminal backends: a
  fixed block of rows drawn above the game image (like the control legend and
  emit-rate stats) that mirrors the engine's `ng-log` output. The last few
  messages are tailed newest-at-the-bottom and coloured by severity (dim info,
  yellow warnings, red errors); rows are truncated to the terminal width so a
  long line cannot wrap and shift the image. On by default, disabled with
  `--noterm_console`, and sized with `--term_console_lines=N` (default 5). While
  a terminal backend is active, `ng-log`'s own `stderr` output is suppressed
  (down to `FATAL`) so messages appear only in the console instead of scribbling
  over the picture. The executable installs an `nglog::LogSink`
  (`src/log_console.cxx`) that feeds the buffer through the shared
  `terminal.cxx`, so the `mruby-rgss` gem keeps no compile-time dependency on
  `ng-log`. Documented in `docs/adr/0005-terminal-log-console.md`

### Fixed
- LCF map-tree `scrollbar_x` / `scrollbar_y` (chunks 5/6) are now read as signed
  ints instead of booleans; real games store multi-byte scrollbar positions
  there, which raised `invalid bool size` when parsing an actual `RPG_RT.lmt`

### Changed
- Bumped the vendored mruby submodule to the 4.0.0 release (from a 3.3.0-era
  snapshot). `build_config.rb` drops the `mruby-print` gem (removed in 4.0;
  `Kernel#p`/`#print` are now in the core and `mruby-io` supplies
  `#print`/`#puts`/`#printf`) and the `disable_presym` calls (presym is always
  enabled in 4.0, and bytecode serializes symbols by name so the host `mrbc`
  and the emscripten target stay compatible). `CMakeLists.txt` also exposes
  mruby's generated build-tree include dir on the `mruby` target, since `mruby.h`
  now unconditionally pulls in the generated `mruby/presym/id.h`. mruby 4.0 also
  removed per-state allocators (`mrb_open_allocf`), so the native build now
  overrides the global `mrb_basic_alloc_func` to share lvgl's heap pool, and the
  profiler's allocation hook moved to the matching `(ptr, size)` signature. The
  `mruby-bigint` gem is now enabled: mruby 4.0's compiler encodes integer
  literals wider than 32 bits (e.g. the `0xFFFFFFFF` masks in the LCF codecs) as
  bignum literals that need it at runtime. The `mruby-marshal` submodule is
  bumped to pick up its 4.0 fix (`Marshal.dump` is registered with its real
  arity so mruby 4.0's stricter argument-count check accepts the optional
  port/limit arguments)
- Bumped the bundled LVGL to v9.5.0 (from a v9.2.0 development snapshot)
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
- Bumped the bundled LVGL to v9.5.0 (from a v9.2.0 development snapshot)
- `RGSS::Window` is now assembled from three layered sprites inside a viewport
  (windowskin background+frame, selection cursor, and contents/text) instead of
  compositing everything into one sprite's bitmap. The viewport clips the layers
  to the window rectangle, and updating the cursor or text no longer re-blits
  the windowskin
- Updated documentation to reflect new title screen functionality
- Marked "Show window component for title scene" as completed in TODO list
- Enhanced database term schema with comprehensive RPG Maker 2000/2003 terms:
  - Added battle menu command terms
  - Added save/load related terms
  - Added status and equipment terms
  - Fixed shutdown term ID (changed from 116 to 117)
