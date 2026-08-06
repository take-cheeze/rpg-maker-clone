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
  player and other events. A route's **Begin Jump / End Jump** block hops to the
  destination its enclosed moves add up to, in one move and testing only where it
  lands — so a jump clears what it passes over, the way the real runtime's does
- Tiles are blitted from the map's real ChipSet graphic — lower/upper chips,
  water and terrain autotiles assembled from quarter-tiles, and animated tiles —
  falling back to colour blocks only when the chipset image is missing
- Rendering is checked against the **genuine RPG Maker 2000 runtime**:
  `scripts/compare-nepheshel-wine.bash` boots the real `RPG_RT.exe` under wine
  and this engine on the same game, drives both headlessly with the same key
  script and diffs the frames. Windows, the selection cursor, window text and
  the message panel now land on RPG_RT's pixels; the residual difference is the
  font (RPG_RT uses Windows' MS Gothic, we use Shinonome, with matching
  metrics). See `docs/adr/0021-nepheshel-render-parity-under-wine.md`
- An **in-game map** is diffed the same way, by resuming both runtimes from one
  save (`scripts/compare-nepheshel-save-wine.bash`, with
  `scripts/gen-rpg2k-save.rb --clear-scene --map <id>` placing the party and the
  camera). Nepheshel's town, an interior and an open-water map now render
  **pixel-identical** to RPG_RT — tile layers, autotiles, upper/lower layering
  and event sprites all on its exact pixels

### Events, menu & saving
- Map events run through an event-command interpreter: messages and choices,
  switches/variables (set from constants, other variables, random rolls, actor
  stats or gold/timer), party/gold/item changes, actor HP/MP and base-stat
  changes and full heal, actor name / title / sprite changes, conditional
  branches, teleport, waits, numeric input (Input Number), BGM/SE playback,
  Call Event (run a common event / another event's page), Move Event (force a
  move route onto an event or the player), Halt All Movement (cancel every forced
  route), Change / Trade Event Location (snap or swap event/player tiles), Change
  Map Tileset (swap the map's chipset), Tile Substitution (rewrite a tile id on a
  map layer, drawing and passability both), Weather Effects (set rain/snow type
  and strength), Set
  Transparent Flag (hide/show the hero), Flash Sprite (pulse a character with a
  decaying colour), Enter/Exit Vehicle, Open Save Menu / Open Main Menu, Fade Out
  BGM, Return to Title, Game Over (the database's `GameOver/` picture over its
  game-over music, dismissed back to the title) and Erase
  Event (remove an event from
  the map) — **every RPG2000 event command now has a handler**. An event that
  **wipes the party** ends the game the same way, without needing a Game Over
  command: every command that can knock the last member out re-checks, as the
  real runtime does, so a damage floor that kills you is fatal. Events start on the action button, on
  player touch (walking into them),
  on event touch (either they walk into the party or the party walks into them —
  which is how a game's roaming monsters start a fight), auto-start, or run continuously as
  a parallel background process, gated by their page/switch conditions;
  auto-start and parallel common events run too. Pages are re-selected **while
  the map runs**, so setting the switch an event's page 2 waits on turns it into
  that page there and then — keeping where it stands — rather than only on the
  next visit to the map
- A command that names **"this event"** rather than an event id resolves to the
  event running it, on both sides: the scene already steered Move Event and
  friends that way, and the interpreter now answers the reads too — the
  orientation conditional branch, the Control Variables character operand and a
  Call Event onto another of this event's pages. **Show Choices** honours its
  cancel setting as well: the cancel key picks the choice the command names, or
  runs its dedicated **[Cancel]** branch, and a block that forbids cancelling
  swallows the key
- **Erase / Show Screen** run the transition style the command asks for, each at
  its own RPG2000 length — including "use the configured transition", which
  reads the Change Screen Transitions setting seeded from the game's database.
  The blinds, the vertical / horizontal stripes and the border-to-centre /
  centre-to-border windows are drawn as a mask over the map; the styles that need
  the scene itself moved or resampled (scrolls, zoom, mosaic, wave, random
  blocks) still run as a fade of the correct length
- A troop's **battle-event pages** run during a fight: their conditions (switch,
  variable, turn, enemy/actor HP, plus RPG2003's per-battler turn counters and
  party fatigue) are re-checked each turn, and a matching page runs the ordinary
  command set plus the battle-only commands — Change Monster HP / MP / Condition,
  Show Hidden Monster, Change Battle Background, the battle Show Battle
  Animation, the battle Conditional Branch and Terminate Battle. A page whose
  condition box is entirely unticked never fires, which is how RPG_RT reads it
- **Status conditions show on the battle screen**, where until now they were only
  simulated — a poisoned hero and a healthy one looked identical. The status
  panel gained a condition column carrying the *significant* state (death first,
  then the highest `priority`, ties to the later id, as RPG_RT resolves it),
  drawn in the state's own palette colour, or the database's "normal" term when
  the battler is clear. That tie rule decides the answer more often than it
  sounds: 22 of Nepheshel's 25 states share priority 50. The action banner
  announces each condition an action lands or lifts using the state row's own
  sentences (`message_actor` / `message_enemy` / `message_recovery`), which are
  worded from the speaker's side — Nepheshel's 恐怖 reads 「ゼロは恐怖に陥った！」
  of a party member but 「スライムは恐れおののいた！」 of an enemy. Being downed
  goes through the same path, so it reads 「スライムを倒した！」 rather than an
  invented English string. And a battle page's **Change Monster Condition** now
  redraws the panel: it writes straight to the live combatant, so nothing had
  told the screen it was out of date
- The **field windows show a condition too** — the menu party list, the item and
  skill target lists, and the status screen, which are the three RPG_RT draws one
  in. The target lists are the point: they are where you pick who to use an
  antidote on, and a downed actor used to read only as `HP 0/120`. All of them
  and the battle panel resolve it through one place, so the menu and the fight
  cannot disagree about which state a battler is showing
- The **RPG2003-only event commands** run too — the low opcodes the 2003 editor
  emits for the features RPG2000 never had. **Change Class** (1008) moves an
  actor to a database class, re-reading its growth curve, learn table and EXP
  curve from the class row and honouring the command's skill and parameter modes
  (keep / reset / add, keep / halve / reset); **Change Battle Commands** (1009)
  edits an actor's battle-command list; **Force Flee** (1006), **Enable Combo**
  (1007) and **Call Common Event** (1005) act inside a battle-event page; and the
  English-release **Open Load Menu** (5001) / **Exit Game** (5002) leave the map
  for the loader or quit
- Message text reveals gradually (a typewriter effect; a button press completes
  it, then dismisses), expands the common control codes (`\v[n]` variable,
  `\n[n]` actor name, `\\`) and draws `\c[n]` colour changes
- Countdown timers can be set/started/stopped from events — RPG2000's one and
  RPG2003's second, each with its own on-screen window, read back by Control
  Variables and Conditional Branch, and pausing for a battle unless the start
  command said otherwise
- Press the cancel button to open a menu (party status, Save, End Game); "New
  Game" state can be saved and reloaded from the title's "Continue"

### RPG Maker XP

- An **RPG Maker XP** project (a folder with `Game.ini` and a `Data/*.rxdata`
  database) runs **its own engine**: the ~90 Ruby sections inside
  `Data/Scripts.rxdata` are evaluated the way `RGSS104E.dll` evaluates them, so
  the game's own title screen, map, menus, battle system and any community
  scripts are what you play. There is no second, reimplemented engine — a
  reimplementation can only ever reproduce the *default* scripts, and every game
  worth running customises them (see
  [`docs/adr/0030-rgss-only-the-games-own-engine.md`](docs/adr/0030-rgss-only-the-games-own-engine.md))
- XP stores its whole database as Ruby `Marshal` dumps, which load straight
  through the bundled marshal reader into a typed `RPG::*` schema
  (`mruby-rpgxp`); the RGSS value types (`Table`, `Color`, `Tone`, `Rect`) are
  the same native classes the rest of the engine already uses
- The **RGSS class library** those scripts run against is this engine: `Bitmap`,
  `Sprite`, `Viewport`, `Window`, `Plane`, `Tilemap`, `Graphics`, `Input`,
  `Audio` and the value types are native (`mruby-rgss`), and the Ruby classes the
  player supplies rather than the project — **`RPG::Sprite`** (the battler and
  character sprite base: whiten / appear / escape / collapse, the floating damage
  pop-up, blinking, and `RPG::Animation` playback with each frame's sound and
  flash), **`RPG::Weather`** and **`RPG::Cache`** — are supplied too
  (`mruby-rpgxp/mrblib/rgss_library.rb`). The gap between what a game calls and
  what exists is tracked in
  [`docs/rpgxp-rgss-api-gap.md`](docs/rpgxp-rgss-api-gap.md)
- The scripts own their whole blocking main loop (`$scene.main while $scene`),
  which is driven one frame per callback through an mruby `Fiber`, so the
  browser build keeps its frame budget without Asyncify
  ([`docs/adr/0023-rpgxp-script-host-frame-driver.md`](docs/adr/0023-rpgxp-script-host-frame-driver.md))
- Both an **unpacked** project (a loose `Data/` folder) and an **encrypted
  archive** load: a packed release that ships only a `Game.rgssad` (RPG Maker XP;
  RPG Maker VX's same-format `Game.rgss2a` too) or a VX Ace `Game.rgss3a` is
  decrypted transparently, so the database *and* the graphics and audio a game
  asks for load with no loose files present. Loose files, when present, shadow
  the archive (as in RGSS)
- The window is sized to XP's native 640×480 automatically
- **CI plays both beds, headlessly**: `scripts/rpgxp_boot_check.bash` boots the
  editor-shaped OpenGame test bed and the *released* **Pray for You**
  (`Game.ini` + `Game.rgssad`, nothing loose — 69 maps, 1107 event pages, 15,797
  event commands), taps the confirm key on each game's own title screen, and logs
  every scene the game reaches as `[RPGXP-HOST-SCENE]`. Pray for You walks its
  own `Scene_logo → Scene_Title → Scene_Map`; the test bed is then made to walk
  its party (`[RPGXP-HOST-MOVE]`), which is what proves a game's own
  `Game_Player` is reading input and stepping across its own passability, and to
  open its own menu (`[RPGXP-HOST-MENU]`) — the first thing a game draws out of
  its own `Window` subclasses, windowskin and font — and, in a second pass, to
  fight in its own battle scene (`[RPGXP-HOST-BATTLE]`), where every enemy is one
  of its own `Sprite_Battler`s on top of `RPG::Sprite`, and to open its own save
  screen (`[RPGXP-HOST-SAVE]`), the one place a game reads a file's timestamp
  back and writes a file of its own.
  `scripts/rpgxp_script_host_check.rb` covers the same ground under CRuby —
  every section of both bundles evaluates, and the RGSS standard library behaves
- `scripts/compare-rpgxp-wine.bash` diffs our frames against the **genuine RGSS
  runtime**, booting the project's own `Game.exe`/`RGSS104E.dll` under wine on
  the same key script (install the RTP into that prefix with
  `scripts/rtp_xp_install.bash` so both runtimes read the same assets). It found
  four bugs that had kept an XP project from drawing its RTP art at all: the XP
  RTP registry key was never read, `.jpg` was missing from the asset search,
  truecolour images came out with red and blue exchanged, and an RGBA image
  loaded opaque drew garbage. See
  [`docs/adr/0025-rpgxp-cross-runtime-testing.md`](docs/adr/0025-rpgxp-cross-runtime-testing.md)
  and [`docs/adr/0027-rpgxp-released-game-parity.md`](docs/adr/0027-rpgxp-released-game-parity.md)

### RPG Maker VX / VX Ace

- An **RPG Maker VX** (RGSS2) or **VX Ace** (RGSS3) project is recognised as
  itself instead of being mistaken for XP, and its whole **database loads**: the
  `Data/*.rvdata` / `*.rvdata2` files are Ruby `Marshal` dumps like XP's, read
  through a typed RGSS2/RGSS3 `RPG::*` schema (`mruby-rpgvx`) — VX Ace's feature
  system, `damage`/`effects` usables, per-map tilesets and region layer; VX's
  per-actor `parameters` tables, areas and game-wide `System#passages`
- Which edition a folder holds is detected from `Data/System.rvdata[2]` or, for
  a **packed release** (which ships no loose `Data/` at all), from its encrypted
  archive: VX's `Game.rgss2a` and VX Ace's `Game.rgss3a` both decrypt through the
  same reader the XP side uses, so a single-archive release loads too
- The window is sized to VX's native 544×416 automatically
- A VX/VX Ace game's engine *is* its script bundle, so a project that ships
  `Data/Scripts.rvdata[2]` is driven by the same **RGSS script host** as XP, on
  by default here too; there is no built-in title/map flow to fall back to, so a
  project without scripts (or a boot with `RGSS_SCRIPT_HOST=0`) says so rather
  than opening a blank window. See
  [`docs/adr/0024-rpgvx-rgss2-rgss3-data-layer.md`](docs/adr/0024-rpgvx-rgss2-rgss3-data-layer.md)
- The **RGSS2/RGSS3 built-ins** those scripts call on their way to a first frame
  are in place: keys named as symbols (`Input.trigger?(:C)`, which VX and VX Ace
  use exclusively), `Graphics.width`/`height`/`wait`/`fadeout`, the `Window`
  open/close and padding surface with VX's `Window.new(x, y, w, h)` shape, the
  `RPG::BGM`/`BGS`/`ME`/`SE` records **playing themselves**
  (`$game_system.battle_bgm.play`), and RGSS3's `rgss_main` wrapper. What is
  still missing before a VX game *draws* — the nine-sheet VX tilemap, viewport
  tone/flash and scene transitions — is measured against the stock VX Ace script
  set in
  [`docs/rpgvx-rgss-api-gap.md`](docs/rpgvx-rgss-api-gap.md)
- Have a VX / VX Ace project? `ruby scripts/rpgvx_testbed_check.rb path/to/Game`
  loads its whole database and reports any field the schema is missing — the
  editors are commercial and no open-source test bed exists, so that check is
  how the schema gets validated against genuine editor output

### RPG Maker MV / MZ (the JavaScript makers)

- An **MV** (`js/rpg_core.js`) or **MZ** (`js/rmmz_core.js`) project runs its
  *own* JavaScript: rather than reimplement the engine, the binary embeds
  [quickjs-ng](https://github.com/quickjs-ng/quickjs) and provides the browser
  host the game expects — `window`/`document`/`XMLHttpRequest`/`Image`,
  `requestAnimationFrame` and timers, `localStorage` and NW.js `require('fs')`
  saves — so the corescript, PIXI and any plugins execute unmodified. See
  [`docs/adr/0004-javascript-maker-mv-quickjs.md`](docs/adr/0004-javascript-maker-mv-quickjs.md)
- **MV** draws through PIXI's Canvas2D renderer, mapped onto native RGBA
  surfaces (`fillRect`/`drawImage`/`getImageData`, the full 2D transform, PNG
  decoding and stb_truetype text), presented on-screen each frame. It boots to
  the title, starts a New Game, walks the map, opens the menu, shows messages,
  reaches `Scene_Battle`, and round-trips a save — all exercised headlessly in CI
  against a real downloaded MV game
- **MZ** ships PIXI v5, which is **WebGL-only**, so it renders through a native
  **surfaceless-EGL GLES2** backend instead: `canvas.getContext("webgl")` returns
  a real context (`mruby-mvjs/src/mvwebgl.cxx`), PIXI renders the scene into its
  FBO, and the frame is read back onto the screen sprite. MZ **boots through the
  title screen into its start map, with a held key walking the player** — the
  game is advanced by pumping the host once per frame, which is what drives
  rmmz's own `requestAnimationFrame` loop (PIXI's ticker updates *and* renders
  the scene) and delivers the asynchronous loads `Scene_Boot` waits on. Keyboard
  and pointer input are fed into rmmz's `Input`/`TouchInput`. This is younger
  than the MV path and is still being brought up against real games — the
  headless CI smoke is what the claim rests on, and it is not yet a blocking
  check
- MZ **plays animations** too — with a caveat worth knowing, because MZ has two
  animation systems and only one of them is reachable. `isMVAnimation` routes by
  data shape: an animation carrying a `frames` array draws as sprite cells
  (`Sprite_AnimationMV`) and works end to end here, including the per-cell blend
  modes; anything else goes to Effekseer, whose WASM runtime is started by the
  `main.js` this host bypasses, so such an animation runs its sound and flash
  timings on schedule and draws **no visuals**. Nothing hangs and nothing errors,
  which is exactly why it is documented rather than left to be discovered
- MZ also **shows messages, opens the party menu, saves and fights**, each
  exercised headlessly the way the MV path is: a message queued through
  `$gameMessage` opens `Window_Message` over the map, `Scene_Map`'s own
  `callMenu` reaches `Scene_Menu`, a save round-trips through the real
  `DataManager` and a Battle Processing command run through the map interpreter
  lands in `Scene_Battle` — and, in `battle_play` mode, that fight is **played
  out**: confirm is tapped through the party, actor and target windows until the
  enemy's HP reaches zero and the victory sequence hands back to the map. That
  mode was written because reaching `Scene_Battle` is true the moment the scene
  is pushed, before its first update, and it immediately showed that MZ's
  battles had never actually run — the test bed's enemy had an empty
  `battlerName`, which is the one value `Sprite_Enemy` treats as "nothing
  changed", so its bitmap stayed undefined and `updateFrame` threw on every
  frame inside `Scene_Battle.update`, freezing the fight before the first
  window opened. MZ's save path is a **promise chain** (JsonEx → pako
  → localforage) rather than MV's synchronous call, so the probe starts it and
  polls until it settles, then re-enters the map the way `Scene_Load` does —
  and the state is **checked back**: six fields (gold, a switch, a variable, an
  actor's HP, the inventory, the player's position) are moved off their defaults
  before the save, overwritten between the save and the load, and compared after
  it, because a settled promise chain is also what a load that restores nothing
  looks like
- **Common events** run too, and they are two separate things: a *parallel*
  common event is not a map event — it exists only while its switch is on and
  carries its own interpreter — while *Call Common Event* nests a child
  interpreter inside the calling one. `common` mode drives both from one command
  list and reports them separately, since driving one proves nothing about the
  other. Neither had ever executed: the bed's `CommonEvents.json` was empty
- MZ also **leaves the start map**: `transfer` mode runs a Transfer Player
  command through the map interpreter to the bed's second map and asserts the
  map id changed, the player landed on the requested tile, and the destination
  map's *own* parallel event ran — the last being what separates the id moving
  from the map actually being fetched, built and set running. Nothing before it
  had ever loaded a second map, so `DataManager.loadMapData` and `Scene_Map`
  re-creating itself were uncovered. It also caught the bed writing an
  undeclared variable, which `Game_Variables.setValue` ignores in silence
- The menu is **used**, not just opened, for the same reason: `menu_play` mode
  hands the party a Potion and wounds the actor through event commands, then
  taps confirm through the command window, the item category, the item list and
  the actor window until the item heals and is spent, and cancel back out to the
  map. It asserts the HP rose, the inventory paid for it and the map came back.
  That walk worked first time — but it found the bed had shipped **no items at
  all**, so `Scene_Item` had been opening onto an empty list, and `menu` mode
  reported the same `reached_menu=true` either way
- All of that is **on screen**, not just in the scene graph: the title and its
  command window, the map with the player sprite and the touch UI, message
  windows with their text, and the party menu over a blurred map background. It
  used to draw only the tilemap, because two calls in the native WebGL wrapper
  quietly dropped their data — `texSubImage2D` (a no-op, so every bitmap
  redrawn after its first upload was lost: window contents, text, the tile
  atlas) and `bufferData` with a bare `ArrayBuffer`, which is what PIXI's sprite
  batcher uploads, so every batched sprite drew from an empty vertex buffer.
  Overlapping **windows clip each other** properly too: MZ draws every scene
  inside a filter render texture (each scene carries a `ColorFilter`), and the
  wrapper's renderbuffer calls were stubs, so the stencil `WindowLayer` masks
  with had nothing to write to and every window overpainted its neighbours. All
  three are covered at the pixel level on the real EGL backend by
  `mruby-mvjs/test/gl_test.rb`
- The MZ engine is not redistributable (unlike MV's MIT corescript), so
  `data/mz-sample` commits only an authored database and art —
  `scripts/gen-mz-sample.py` writes both — and
  `scripts/download-mz-corescript.bash` fetches the engine at build time.
  `scripts/mz_boot_check.bash` boots that bed headlessly and asserts what the
  requested `MZ_MODE` claims — `play` (the default: the map is reached and a held
  key moves the player), `message`, `transfer`, `common`, `menu`, `menu_play`,
  `animation`, `save`, `battle` or `battle_play`, each with its own success line so a probe that
  merely ran cannot pass. A run ends as soon as its probes have reported rather
  than idling out its `--timeout_ms`, so the budget is a ceiling for the slowest
  host instead of the time every run takes — a cut-off run reports nothing at
  all, which had made a battle that was still swinging look like one that never
  landed a hit; `ruby
  scripts/mz_testbed_check.rb path/to/Game` validates any MZ project's
  boot-critical data and system art without a build
- Those assertions all read the engine's **log**, which is how the empty frames
  above went unnoticed for a milestone. `scripts/mz_frame_check.rb` reads the
  **captured PNGs** instead: that each frame kept its art (a map frame that lost
  its tiles is 99.5% a single colour; a message window whose contents never
  uploaded has 18 distinct colours in its band where text puts 105), and that
  each mode's frame differs from the plain map frame the way that mode claims —
  the message window changes the bottom band and nothing above it, the menu and
  battle scenes replace the screen, the animation's burst changes the middle of
  the frame and nothing at its edges, and the save round-trip lands back on the
  map. Reverting the `texSubImage2D` fix leaves every boot-check mode reporting
  OK and fails the frame check, which is the point of it — as does renaming the
  animation's sheet away, which the log reports as `played=true` because the
  cell sprite is there, holding a placeholder bitmap

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

### Build natively without Nix

- The supported build is the Nix flake (`nix develop`), which pins every
  dependency. On a plain Debian/Ubuntu box that has a C++ toolchain but no Nix —
  an agent container, a bare CI image — `scripts/native-build-without-nix.bash`
  gets to the same place:

  ```sh
  scripts/native-build-without-nix.bash            # -> ./build/rpg_maker_clone
  VERIFY=0 scripts/native-build-without-nix.bash   # build only, skip the checks
  ```

  It installs the SDL2 headers, initialises the `3rd/` submodules (empty in a
  plain clone), puts `rake` where `/bin/sh` can find it — mruby builds itself
  with it — and fetches the two Unicode mapping tables the flake supplies through
  `$cp932_table` / `$jis0208_table`, checking each against flake.nix's own
  sha256 so the build consumes the bytes Nix would hand it. It then proves the
  result works rather than just linking: `--rgss_effect_probe` under Xvfb, which
  measures real pixels, followed by both game boot checks on real project data.

### Play in the browser (WebAssembly)

- The runtime cross-compiles to WebAssembly with Emscripten and ships a page
  (`index.html` + `index.js` + `index.wasm`) that **loads an RPG Maker project at
  runtime** — one build plays any game, nothing has to be baked in at compile
  time.

  ```sh
  ./scripts/download-freepats.bash                  # MIDI instruments, once
  emcmake cmake -S . -B wasm-build -GNinja
  cmake --build wasm-build
  python3 scripts/serve.py wasm-build --port 8000   # then open localhost:8000
  ```

  The first line is what makes an RPG2000 project's `.mid` BGM audible in the
  page; it is picked up automatically by the configure that follows (see the
  audio section below). Skip it for a page ~32 MiB lighter and silent on MIDI.

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
- CI publishes this page: pushes to `master` deploy it to **GitHub Pages**, and
  commenting `/preview` on a pull request builds that PR and posts a
  **Cloudflare Pages** preview URL back on it. See
  [`docs/deploy.md`](docs/deploy.md) for the one-time repo setup (Pages source +
  Cloudflare secrets).

### Reporting an error

When the engine dies on a Ruby exception it no longer just prints a backtrace
and quits — it assembles **one copy-pasteable report** so a bug can be reported
without a terminal, a build tree or a rebuild. The report holds the exception
and its backtrace, the revision and build type it came from, the platform, the
project that was loaded, where the engine caught the failure, and the tail of
the runtime log (the `[RPG2k]` / `[RGSS]` lines that led up to it — usually the
part that explains it). Nothing else is collected.

- **In the browser**, a crash replaces the frozen canvas with an error panel
  holding the report and a **Copy error report** button (or **Download** for a
  `.md` file). The page adds what only it knows: the address, the browser, which
  project was loaded and its own log tail. A problem that does *not* crash the
  game — a wrong picture, silence where there should be music — has the same
  report a click away under *Runtime log → Copy diagnostics*. Errors thrown by
  the page or the wasm runtime itself are reported the same way.
- **On the desktop**, the report is printed to stderr between
  `----- BEGIN RPG MAKER CLONE ERROR REPORT -----` / `----- END ... -----`
  markers and written to `error-report.md` in the working directory. Point it
  somewhere else with `--error_dump=path/to/report.md`, or pass an empty value
  to write no file.
- The log tail comes from `RGSS::ErrorReport`, which tees `$stderr` through a
  bounded ring buffer (`mruby-rgss/mrblib/error_report.rb`); nothing about the
  existing logging changes. The report path is itself tested end to end —
  `--error_dump_probe` raises a real exception and checks the resulting report
  still carries the exception, the backtrace, the captured log and the run
  context (the `error_dump` ctest), and `scripts/error_report_check.rb` checks
  the capture on CRuby. See
  [`docs/adr/0027-copyable-error-report.md`](docs/adr/0027-copyable-error-report.md).

### Text and fonts

- Window and menu text is rasterised with **stb_truetype** from the project's
  own font: RPG Maker XP/VX pick a family name out of the project's `Fonts/`
  folder (`RGSS::Font#name`, matched leniently against the file names), MV/MZ
  load the first font under `fonts/` — `.ttf`/`.otf`, or the `.woff` that MZ
  projects actually ship, unpacked to the sfnt inside it. Size, bold, italic,
  outline, shadow and the colours all come from the `Font`
- **Projects that ship no font get one once you fetch it.** On Windows the
  maker's default resolves to a system font (`MS PGothic`) that is not ours to
  redistribute, so a project can easily ship none — and then every window drew
  with the built-in 12px **shinonome** bitmap font whatever size it asked for
  (MV/MZ, whose text is all TrueType, drew nothing at all). Run
  `./scripts/download-default-font.bash` to install
  [M PLUS 1p](assets/fonts/README.md) into `assets/fonts/` (~1.7 MiB,
  git-ignored, SIL Open Font License); the engine finds it at startup and the
  XP/VX/MV/MZ runtimes fall back to it. A font the project *does* ship still
  wins, `RPG_DEFAULT_FONT` overrides the choice, and `-DWASM_DEFAULT_FONT=ON`
  bakes it into the web page. See
  [`docs/adr/0028-bundled-default-ui-font.md`](docs/adr/0028-bundled-default-ui-font.md)
- **RPG2000/2003 keeps shinonome deliberately.** Its metrics match RPG_RT's MS
  Gothic, which is what the render-parity comparisons above are measured
  against, so the fallback is opt-in per maker (`RGSS::Font.default_path`) and
  RPG2000 does not opt in

### Audio

- `RGSS::Audio` plays real music and sound through an
  [SDL_mixer](https://github.com/libsdl-org/SDL_mixer) back-end: looping **BGM**
  and **BGS**, one-shot **ME** (music effects that interrupt the BGM and then let
  it resume) and overlapping **SE** sound effects, with per-channel volume
- Filenames from the game data are resolved the same way graphics are — under
  `GAME_DIR`/`RTP_DIR`, in the `Music/`, `Sound/` and `Audio/*` sub-folders, and
  with the usual extensions (`.ogg`, `.wav`, `.mid`, `.mp3`, `.flac`) — so the
  event interpreter's *Play BGM* / *Play SE* commands are audible
- **MIDI plays once you fetch the instruments.** RPG2000 projects ship most of
  their music as `.mid`, which carries note events but no audio, so SDL_mixer's
  built-in TiMidity synthesiser needs a patch set to make any sound. Run
  `./scripts/download-freepats.bash` to install
  [FreePats](assets/timidity/README.md) into `assets/timidity/` (~32 MiB,
  git-ignored); the engine finds it at startup. Without it, MIDI loads and plays
  silence — `RGSS::Audio.midi_available?` and a startup warning report that.
  `TIMIDITY_CFG` points the engine at a different (e.g. fuller) patch set
- MIDI is synthesised for **BGM and ME** only — SE and BGS play as mixer
  samples, which SDL_mixer never synthesises MIDI for. Pitch/tempo is accepted
  for API compatibility but not applied (SDL_mixer has no pitch control)
- **MIDI works in the browser too.** Emscripten's SDL2_mixer port compiles one
  decoder per requested format and defaults to OGG-only, so the build asks for
  `-sSDL2_MIXER_FORMATS=ogg,mid` to get the TiMidity decoder, and the page
  carries the patch set as ~32 MiB of packaged data. That happens on its own:
  `-DWASM_MIDI_PATCHES` defaults to `AUTO`, which packages the patches whenever
  `scripts/download-freepats.bash` has already run — so download first, then
  configure. Pass `ON` to require them regardless (what CI does, because its
  download runs alongside the configure), or `OFF` for a slimmer page whose
  `.mid` playback is silent. A page without them says so in its on-screen log
  rather than just going quiet
- The patches ride in their own `timidity*.data` packages rather than the
  runtime's `index.data`, split to keep every published file under Cloudflare
  Pages' 25 MiB per-file limit so PR previews can deploy
  (`scripts/pack-timidity-data.py`, ADR 0031). Serving the page means serving
  `timidity.js` and those packages alongside `index.*`

## TODO
- Editor with [imgui](https://github.com/ocornut/imgui)
- Chipset tile-replacement (Replace Chipset Tiles) and screen-tone tinting of
  tiles; the map scene already blits real chipset graphics with autotiles and
  tile animation
- Battle system and the item/skill/equip/status menu screens
- Audio pitch/tempo control (SDL_mixer exposes none), and MIDI for SE/BGS, which
  play as samples rather than through the synthesiser
