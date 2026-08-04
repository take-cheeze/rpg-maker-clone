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
- Events move on their own: each event walks per its page's movement type
  (random, vertical/horizontal pacing, approaching or fleeing the hero) or runs a
  custom move route, paced by its move frequency and blocked by terrain, the
  player and other events
- Tiles are blitted from the map's real ChipSet graphic — lower/upper chips,
  water and terrain autotiles assembled from quarter-tiles, and animated tiles —
  falling back to colour blocks only when the chipset image is missing

### Events, menu & saving
- Map events run through an event-command interpreter: messages and choices,
  switches/variables (set from constants, other variables, random rolls, actor
  stats or gold/timer), party/gold/item changes, actor HP/MP and base-stat
  changes and full heal, actor name / title / sprite changes, conditional
  branches, teleport, waits, numeric input (Input Number), BGM/SE playback,
  Call Event (run a common event / another event's page), Move Event (force a
  move route onto an event or the player), Halt All Movement (cancel every forced
  route), Change / Trade Event Location (snap or swap event/player tiles), Set
  Transparent Flag (hide/show the hero), Return to Title and Erase
  Event (remove an event from
  the map). Events start on the action button, on
  player touch (walking into them),
  on event touch (they walk into the player), auto-start, or run continuously as
  a parallel background process, gated by their page/switch conditions;
  auto-start and parallel common events run too
- Message text reveals gradually (a typewriter effect; a button press completes
  it, then dismisses), expands the common control codes (`\v[n]` variable,
  `\n[n]` actor name, `\\`) and draws `\c[n]` colour changes
- A countdown timer can be set/started/stopped from events
- Press the cancel button to open a menu (party status, Save, End Game); "New
  Game" state can be saved and reloaded from the title's "Continue"

### RPG Maker XP

- Alongside RPG Maker 2000/2003 (LCF) projects, an **RPG Maker XP** project
  (a folder with `Game.ini` and a `Data/*.rxdata` database) now loads and boots.
  XP stores its whole database as Ruby `Marshal` dumps, which load straight
  through the bundled marshal reader into a typed `RPG::*` schema
  (`mruby-rpgxp`); the RGSS value types (`Table`, `Color`, `Tone`, `Rect`) are
  the same native classes the rest of the engine already uses
- The engine reads `Game.ini`, shows the **title screen** (the game's title
  graphic behind a New Game / Continue / Shutdown window, with the database's
  title BGM and cursor/decision sound effects) and, on **New Game**, builds the
  party and enters a walkable **map**: the three XP tile layers are drawn as
  placeholder colour blocks (real tileset/autotile rendering is planned, as on
  the RPG2000 side), the party leader walks from its character graphic, and
  movement uses the tileset's passage flags with a follow camera
- Both an **unpacked** project (a loose `Data/` folder) and an **encrypted
  archive** load: a packed release that ships only a `Game.rgssad` (RPG Maker XP;
  RPG Maker VX's same-format `Game.rgss2a` too) is decrypted transparently, so
  the database loads with no loose files present. Loose files, when present,
  shadow the archive (as in RGSS). VX Ace's `Game.rgss3a` is detected but not yet
  decoded
- The window is sized to XP's native 640×480 automatically. Running the game's
  own bundled RGSS scripts (`Data/Scripts.rxdata`) is future work; see
  [`docs/adr/0010-rpgxp-rgss-data-layer.md`](docs/adr/0010-rpgxp-rgss-data-layer.md)

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

- Controls: arrow keys or `WASD` to move, `Z`/`Enter`/`Space` to confirm (C),
  `X`/`Esc` to cancel (B), `C` for the A button, `Q` or `Ctrl-C` to quit. The
  same reference is drawn as a one-line legend on the top row above the game
  image
- `--sixel` works in terminals such as `xterm -ti vt340`, mlterm, foot, WezTerm
  and Windows Terminal; `--iterm` works in iTerm2, WezTerm and VS Code
- Either backend draws its emit rate (frame size, MB/s, fps) on-screen just
  under the control legend, refreshed about once a second; this is on by default
  and can be turned off with `--noterm_stats`
- Both backends also show a **log console** above the game image that mirrors
  the engine's `ng-log` output on-screen — otherwise those messages would land
  on `stderr` and scribble over the terminal picture. The last few messages are
  tailed (newest at the bottom, coloured by severity: dim info, yellow warnings,
  red errors). On by default; turn it off with `--noterm_console` or change how
  many rows it reserves with `--term_console_lines=N` (default 5):

  ```sh
  ./rpg_maker_clone --sixel --term_console_lines=8 --game_dir path/to/game
  ```

### Profiling

- Measure where frame time goes with the built-in CPU/memory profiler, enabled
  with `--profile`:

  ```sh
  ./rpg_maker_clone --profile --game_dir path/to/game
  ```

- About once a second (tune with `--profile_interval_ms=N`) it prints a summary
  line to stderr, e.g.:

  ```
  [profiler] fps=60.0 frame(work) avg=3.21ms max=8.40ms n=60 | mem rss=45.20MB lv_used=1.83MB lv_frag=12% live_blocks=48213 allocs/s=91234 | sections: scene.update avg=1.90ms max=6.10ms n=60 (59%) gfx.lvgl avg=0.80ms max=1.20ms n=60 (25%) gfx.zorder avg=0.20ms max=0.90ms n=17 (6%)
  ```

- `frame(work)` is per-frame CPU time (the frame span minus the fps-cap sleep);
  the `sections` list is the bottleneck breakdown — `scene.update`,
  `input.update` and the `gfx.*` phases of `Graphics.update` — sorted hottest
  first, each with its average/max time and share of the frame. The memory
  fields cover process RSS, the LVGL heap pool and mruby allocation churn (live
  blocks and allocations/sec; the allocation counters need the native build)
- Game/engine Ruby code can time its own hot spots with
  `RGSS::Profiler.section("name") { ... }`, and read the live numbers back as a
  Hash with `RGSS::Profiler.stats`
- For a visual timeline, export a **Chrome trace** with `--profile_trace=FILE`
  (implies `--profile`):

  ```sh
  ./rpg_maker_clone --profile_trace=trace.json --game_dir path/to/game
  ```

  Every frame and section is streamed as a Chrome Trace Event and the memory
  samples as counters. Open the file in `chrome://tracing` or
  [ui.perfetto.dev](https://ui.perfetto.dev) to see the frames and their
  sections as a flame chart with memory graphs underneath. Ruby code can trace a
  specific window (e.g. one battle) with
  `RGSS::Profiler.trace_start("trace.json")` / `RGSS::Profiler.trace_stop`. The
  stream stays loadable even if the process is killed mid-run, so it is safe to
  trace a long session and stop it with `Ctrl-C`

### Play in the browser (WebAssembly)

- The runtime cross-compiles to WebAssembly with Emscripten and ships a page
  (`index.html` + `index.js` + `index.wasm`) that **loads an RPG Maker project at
  runtime** — one build plays any game, nothing has to be baked in at compile
  time.

  ```sh
  emcmake cmake -S . -B wasm-build -GNinja
  cmake --build wasm-build
  python3 scripts/serve.py wasm-build --port 8000   # then open localhost:8000
  ```

- The page's loader accepts three sources for an RPG Maker 2000/2003 (RPG2k) or
  XP project:
  - **a local `.zip`** — always works, no network;
  - **a direct `.zip` URL** — the host must allow cross-origin fetches (CORS);
  - **a GitHub repository** — `owner/repo`, `owner/repo@ref`, or a
    `github.com/owner/repo` URL, resolved to its `codeload` zip archive.
- The zip is unpacked in the browser with the native `DecompressionStream` API
  (no third-party JavaScript), the folder containing `RPG_RT.ldb` (RPG2k) or
  `Game.ini` (XP) is located and mounted at `/game` in the virtual filesystem,
  and the game starts. A zip wrapped in a top-level folder (as GitHub archives
  always are) is handled automatically.
- Because browsers block cross-origin downloads unless the host opts in, GitHub
  and most arbitrary `.zip` URLs need a **CORS proxy**: enter its prefix in the
  loader's optional field, or simply download the zip and use the local-file
  path, which needs no network. You can self-host the proxy as a free Cloudflare
  Worker (code in [`cors-proxy/`](cors-proxy/)) — see
  [`docs/cors-proxy.md`](docs/cors-proxy.md) for the one-command deploy.
- Downloaded archives are **cached** (via the Cache Storage API, keyed by the
  resolved URL), so re-loading the same URL or repo skips the network. Tick
  *Re-download (ignore cache)* to force a fresh copy (e.g. to pick up new commits
  on a GitHub `HEAD` archive), or *Clear cached archives* to drop the whole
  cache.
- The URL and proxy fields are **remembered across reloads** and mirrored into
  the address bar as a `?url=…&proxy=…` query, so the page is bookmarkable and
  shareable — opening a link with a `?url=` auto-loads that project. (Values are
  also kept in `localStorage`, so a plain reload restores whatever was last
  typed even without a query string.)
- A project can still be **baked into the page** at build time with
  `-DWASM_GAME_DIR=/abs/path/to/game`; that page auto-starts the game with no
  interaction (and the loader is skipped).
- The page draws an **on-screen keypad** (D-pad plus OK/Cancel/Dash, the L/R
  shoulders and the A/X/Y/Z buttons) beneath the canvas, so the game is playable
  by touch or mouse without a physical keyboard; the keyboard keeps working too.
- CI publishes this page automatically: pushes to `master` deploy it to
  **GitHub Pages**, and every pull request gets a **Cloudflare Pages** preview
  URL commented on the PR. See [`docs/deploy.md`](docs/deploy.md) for the
  one-time repo setup (Pages source + Cloudflare secrets).

### Audio

- `RGSS::Audio` plays real music and sound through an
  [SDL_mixer](https://github.com/libsdl-org/SDL_mixer) back-end: looping **BGM**
  and **BGS**, one-shot **ME** (music effects that interrupt the BGM and then let
  it resume) and overlapping **SE** sound effects, with per-channel volume
- Filenames from the game data are resolved the same way graphics are — under
  `GAME_DIR`/`RTP_DIR`, in the `Music/`, `Sound/` and `Audio/*` sub-folders, and
  with the usual extensions (`.ogg`, `.wav`, `.mid`, `.mp3`, `.flac`) — so the
  event interpreter's *Play BGM* / *Play SE* commands are audible
- Playable formats depend on the SDL_mixer build (WAV/OGG everywhere; MIDI needs
  a synth such as Timidity/FluidSynth). Pitch/tempo is accepted for API
  compatibility but not applied (SDL_mixer has no pitch control)

## TODO
- Editor with [imgui](https://github.com/ocornut/imgui)
- Chipset tile-replacement (Replace Chipset Tiles) and screen-tone tinting of
  tiles; the map scene already blits real chipset graphics with autotiles and
  tile animation
- Battle system and the item/skill/equip/status menu screens
- Audio pitch/tempo control and a guaranteed MIDI synth in the build
