# TODOs of this project

## RPG Maker 2k
- 🚧 Support all data schema of LCF — the core database, map tree and map-unit
  chunks needed for boot and gameplay are covered and validated against a real
  test-bed by `scripts/lcf_testbed_check.rb`. Transcribed from the 200X共通
  解析まとめ wiki: item armour-option flags (25–28) and the item/skill
  `使用時アニメ` weapon fields (the shared `BATTLER_ANIMATION` union),
  skill switch/occasion chunks (13, 16, 18, 19), and the `battle_anime2`
  attack-motion + `基本と拡張`/`武器` pose object lists (chunks 2, 10, 11).
  The remaining map-unit chunks that appear in real data (42, 50, 60–62, 90 —
  save/encounter/parallax metadata) are **not documented on the wiki's マップ
  page**, so they still need to be derived from the test-bed walk. These are
  editor/battle/2003 details not on the walkable-game critical path
- ✅ Show window component for title scene
- ✅ Implement New Game functionality — builds the party, loads the start map
  and enters a walkable `Scene::Map` with events
- ✅ Implement Continue functionality — loads a saved game (portable `Marshal`
  save; the LCF `.lsd` format is a later refinement)

### Issue items needed to run Nepheshel

The runtime now boots past the title into gameplay: "New Game" builds the party,
loads the starting map and enters a walkable `Scene::Map` where the player can
move, talk to / trigger events (a working event-command interpreter with
messages, choices, switches/variables, party/gold/item changes, conditionals and
teleport), open a menu, save, and continue. The remaining work is mostly **the
parts that need the native build + real game assets to develop and verify**:
authentic chipset/charset rendering, audio, and the battle system. Everything
landed so far is exercised by unit tests (`mruby-lcf/test`) and by host harnesses
that load the pure-Ruby sources under CRuby, since the full SDL/mruby binary
can't be built or run in this environment. The LCF loaders are smoke-tested
against real downloaded test-bed projects (`scripts/lcf_testbed_check.rb`, run in
CI after the download step), which parses a genuine game's
`RPG_RT.ldb`/`.lmt`/`Map*.lmu` end to end and catches format surprises the
synthetic unit tests can't; the gameplay logic (`game.rb`/`interpreter.rb`) is
checked by `scripts/rpg2k_logic_check.rb` (pure move-route / interpreter logic)
and `scripts/rpg2k_scene_check.rb` (the map scene driving event movement behind
RGSS stubs).

The work below is roughly ordered by the critical path to a walkable game
(1 → 2 → 3 → 4/5/6 → 7/8/9); battle and full menus can follow.

#### Boot into gameplay (unblocks everything)
- ✅ LMU map parsing — `MAP_UNIT` schema in `schema.rb` (`LCF::MapUnit`):
  dimensions, chipset id, lower/upper tile layers and events. Also fixed
  multi-part file parsing so the map tree exposes its `initial` start position,
  fixed nested `Array2D` fields (e.g. the actor table), and implemented the
  `int16_array`/`short_array` element types. Covered by `mruby-lcf/test`.
- ✅ New Game logic — `RPG2k#start_new_game` builds the party from the database
  (`Game::Party`/`Game::Actor`), reads the start position from the map tree,
  loads the starting map and pushes `Scene::Map` (replaces the TODO in
  `Scene::Title#update`)
- ✅ Map scene (`Scene::Map`) — hosts the running `Game::State`, renders the
  lower/upper tile layers, draws the party leader from their CharSet graphic,
  and supports grid movement with pixel interpolation, walk animation,
  edge/tile/event collision and an edge-clamped follow camera

#### Map & characters
- 🚧 Tilemap rendering — `Scene::Map` currently draws each tile as a solid
  colour block derived from its tile id (a navigable placeholder) and reads
  chipset passability for collision; real chipset blitting (lower/upper chip
  graphics, autotile assembly, tile animation) is the remaining work
- 🚧 Character sprites — the party leader renders from its CharSet graphic
  (`Game::CharSet`, 4-direction, 3 walk frames); NPC/event sprites are drawn as
  markers for now
- ✅ Movement & collision — grid movement with pixel interpolation, walk
  animation and edge/tile/event collision. Move-route *data* decodes
  (`LCF.parse_move_commands` / `LCF::MoveCommand`, wired into the event-page and
  common-event `move_route` schema) **and now drives events at runtime**: a
  `Game::MoveRoute` executor walks a decoded route (all cardinal/diagonal/random/
  toward/away/forward moves, faces and turns, wait/jump, switch on-off, change
  graphic, play sound, speed/frequency/through/transparency/lock toggles, with
  repeat + skippable handling) and `Game::Character`/`Game::MoveType` model the
  movable entity and autonomous walk (random / vertical / horizontal / toward /
  away). `Scene::Map` gives each event a `Game::Character`, steps it per its page
  move type or custom route (paced by move frequency) and keeps events off each
  other, the player and impassable tiles. Covered by
  `scripts/rpg2k_logic_check.rb` (pure logic) and `scripts/rpg2k_scene_check.rb`
  (scene integration under host Ruby)

#### Event system
- ✅ Event pages — page conditions (switch/variable/item/actor) are implemented
  (`Game::EventPage`), and all five start triggers now run: **action button**
  (0), **player touch** (1, walking into the event), **event touch** (2, the
  event walking into the player), **auto-start** (3) and **parallel** (4, a
  background interpreter per event, driven by `Scene::Map#step_parallels`). A
  page's autonomous move type / custom move route also drives the event at
  runtime (see Movement & collision). The interpreter's *Set Move Route* (Move
  Event) command is now wired up too: it decodes the route packed into the
  command's parameters and applies it as a forced route to the target — a map
  event (including "this event") or the player, overriding page movement until
  it finishes. Still to come: vehicle targets (boat/ship/airship), which are not
  modelled yet
- 🚧 Event command interpreter — `Game::Interpreter` runs a solid subset (Show
  Message + Choices, Control Switches/Variables, Change Gold/Items/Party,
  Change HP/MP, Full Heal, Change Parameters, Conditional Branch/Else/End,
  Loop/Break/End, Label/Jump, Timer, Teleport, Memorize/Recall Location,
  Store Terrain/Event ID, Wait, Play BGM/SE, Memorize / Play Memorized BGM,
  Message Options, Change Face Graphic, Change Main Menu / Save Access, Tint
  Screen, Call Event, Move Event, Proceed With Movement, Erase Event, End Event)
  with a per-frame step cap so a bad loop
  can't hang. **Memorize Location** stores the player's current map id, x and y
  into three variables, and **Recall to Location** teleports back to a location
  held in three variables (routed through the same teleport the Teleport command
  uses). **Call Event**
  suspends the current list, runs the referenced common event (or map-event
  page) to completion via a resolver + call stack — so call-only common events,
  which auto-start/parallel never reach, now run — and returns to the caller;
  recursion is bounded. **Move Event** decodes the forced move route packed into
  the command's parameters and hands it to the scene, which drives the target (a
  map event, "this event" or the player) along it in the background. **Proceed
  With Movement** then pauses the interpreter until every forced route in
  progress has finished — the scene advances those routes while it waits and
  resumes it once none remain. **Erase
  Event** removes the running event from the map for the rest of the visit (its
  marker, movement, collision and any parallel process). **Change
  HP/MP**, **Full Heal** and **Change Parameters** apply to a fixed actor, a
  variable-selected actor or the whole party, clamped to each actor's maxima
  (Change HP honours the allow-death floor; Change Parameters re-clamps current
  HP/MP when a maximum is lowered). **Control Variables** reads not just
  constants and other variables but also a **random** range, an **actor stat**
  (level / HP / MP / max HP-MP / attack / defence / spirit / agility) and **game
  quantities** (party gold, timer seconds). Conditional Branch covers switch /
  variable / **timer** / gold / item conditions and the **actor** sub-conditions
  (in party, name, level ≥, HP ≥; skill / equipment / state are not modelled).
  The remaining commands (pictures, screen effects, battles, EXP/level changes —
  which need the per-level stat growth curves, not yet parsed — ...) are TODO
- 🚧 Message window — renders text lines and a choice cursor and expands the
  common message control codes (`\v[n]` variable, `\n[n]` actor name, `\\`;
  speed/wait codes are consumed). Text now **reveals gradually** (a
  `Game::TextReveal` typewriter driven by `Scene::Map`, with a button press
  completing the reveal before dismissing), and `\c[n]` **colour codes** are
  drawn in colour: `Game::Message.parse` splits a line into `{text:, color:}`
  runs and `Scene::Map` draws each run in its palette colour, revealing across
  runs (`Game::Message.visible_segments`). **Message Options** (10120) and
  **Change Face Graphic** (10130) are now handled: a `Game::MessageConfig` on
  `Game::State` (saved with the game) holds the window's transparency, display
  position (top/middle/bottom) and the FaceSet graphic, and `Scene::Map` places
  the window at the configured position, draws it transparent when asked and
  blits the selected 48×48 face cell beside the text (left or right, with the
  text inset). The palette is still a built-in approximation (the real 20-colour
  row from the System windowskin), auto-positioning the window away from the
  hero (when not pinned) and the mirrored-face flag are later refinements
- ✅ Common events — auto-start common events run once on the map, and parallel
  common events now run **continuously** in the background alongside the player
  via their own looping interpreter (`Scene::Map#step_parallels`), each gated by
  its switch when `need_flag` is set (re-checked every frame, so toggling the
  switch starts/stops it). Background processes honour `Wait` but do not drive
  the message/choice UI (those requests are skipped) — full parallel UI is a
  later refinement
- 🚧 Screen effects — the game **timer** works (Timer Operation command +
  `Game::State` countdown). The **Tint Screen** (11030) command now drives a
  `Game::Screen` tint state machine on `Game::State`: it interpolates the four
  RPG2000 channels (red/green/blue/saturation, 0..200) toward their target over
  the command's duration (advanced each frame by `Scene::Map`), and the wait
  flag pauses the interpreter until the transition settles (a `:screen` wait,
  resumed by the scene). This is the Ruby half — **applying** the tint as an
  `RGSS::Viewport` tone is the native (C++) work still to come, so it does not
  yet change what is drawn. Flash and shake will extend `Game::Screen` the same
  way; transitions/fade, Show Picture and weather also remain. `RGSS::Viewport`
  exists (position/clip/scroll/z) but still needs opacity/tone/flash support in
  C++ before these effects are visible

#### Menus, save, battle
- 🚧 Menu scene — opens over the map (cancel button); shows party status and a
  command list. Save and End Game work; item / skill / equip / status are
  placeholders still to be built from the parsed `term`/item/skill/actor data.
  **Change Main Menu Access** (11960) and **Change Save Access** (11930) gate it:
  the menu will not open while menu access is forbidden, and the Save command
  reports that saving is disallowed while save access is off (both flags default
  on and persist in the save)
- 🚧 Save & Continue — implemented with a portable `Marshal` save of the game
  state (`Game::State#to_h` / `State.load`) written via the menu's Save command;
  "Continue" reloads it. Reading/writing the real `LCF::SaveData` (`.lsd`) format
  is still TODO
- Battle system — enemy groups, battle scene, actions/damage/states,
  animations, game-over scene (large; Nepheshel uses the default RPG2000
  battle). Needs real assets + the native build to develop against
- Item / Skill / Equip / Status menu screens — the menu framework and party
  data are in place; these screens still need building

#### Assets & infrastructure
- ✅ Audio playback — `RGSS::Audio` now plays real BGM/BGS/ME/SE through an
  SDL_mixer backend (`src/sdl_audio.cxx`), resolving names under
  `Music/`/`Sound/`/`Audio/*`. Remaining polish: pitch/tempo control (SDL_mixer
  exposes none) and guaranteeing a MIDI synth in the build (depends on the
  SDL_mixer build's MIDI support; WAV/OGG work everywhere)
- ✅ RTP resolution / `FullPackageFlag` (issue #40) — `RPG_RT.ini`'s
  `FullPackageFlag=1` clears `RTP_DIR`, and `Bitmap` lookup already falls back
  from the game directory to the RTP (with `.png`/`.xyz`/`.bmp` extensions)

## RPG Maker with RGSS (XP / VX / VXAce)

An RPG Maker XP project stores its whole database as Ruby `Marshal` dumps
(`Data/*.rxdata`) and its game logic as ~90 zlib-deflated RGSS (Ruby 1.8)
scripts in `Data/Scripts.rxdata`. The graphics/audio/value primitives already
exist natively as `mruby-rgss`; the work below brings an XP project up on top of
them, mirroring how the RPG2000 side was staged. Full rationale:
`docs/adr/0010-rpgxp-rgss-data-layer.md`.

- ✅ **Data layer** — `mruby-rpgxp/mrblib/rgss_data.rb` declares the `RPG::*`
  schema so every `Data/*.rxdata` file loads straight through `Marshal.load`
  (the value types `Table`/`Color`/`Tone`/`Rect` round-trip natively in
  mruby-rgss), and `RPGXP::RGSSData` exposes them as a database. Smoke-tested
  against a real project by `scripts/rpgxp_testbed_check.rb` (run in CI) and
  unit-tested in `mruby-rpgxp/test`.
- ✅ **Boot to title** — `RPGXP` reads `Game.ini`, builds the database and shows
  a `Scene::Title` (title graphic + New Game / Continue / Shutdown in an
  XP-styled window, title BGM / cursor & decision SE). `src/main.cxx` sizes the
  window to XP's native 640×480.
- 🚧 **Map scene** — New Game builds the party from `System.party_members`,
  loads the start map and enters a walkable `Scene::Map`: the three tile layers
  render as placeholder colour blocks, the party leader is drawn from its
  `Graphics/Characters` sheet, and movement is grid-based with tileset
  passability and a follow camera. Real tileset/autotile blitting and event
  sprites (events are markers for now) are the remaining rendering work.
- 🚧 **Event system** — event pages select their active page by condition
  (`Game::EventPage`: switch / variable / self-switch, highest match wins) and a
  `Game::Interpreter` runs the XP command list with a suspend/resume model: Show
  Text / Choices, Conditional Branch / Else / End, Loop / Break / Repeat, Label /
  Jump, Call Common Event, Erase Event, Control Switches / Variables / Self
  Switch, Change Gold, Transfer Player and Play BGM/BGS/ME/SE, indent- and
  terminator-driven with a per-frame step cap. **Erase Event** (116) flags the
  running event and `Scene::Map` drops it (its sprite, movement, collision and
  any parallel process) for the rest of the map visit, keyed so it stays gone
  across page re-selection and reappears on a fresh map load. `Scene::Map` starts events on the action button, on
  player touch, on autorun or as a background parallel process, drives a
  message/choice window, and re-selects pages when an event finishes. Events
  also **roam autonomously**: `Game::Character` / `Game::MoveType` /
  `Game::MoveRoute` drive an event's page move type (fixed / random / approach)
  or custom move route (the full XP move-command set), paced by move frequency
  and blocked by terrain / the player / other events, and the **event-touch**
  trigger fires when an event walks into the player. The interpreter's *Set Move
  Route* (209) command is now wired up: it queues the `RPG::MoveRoute` packed
  into the command for its target — the player, "this event" or a map event id —
  and `Scene::Map` drains the queue and drives the target along the route in the
  background (a forced route overrides page movement until it finishes and does
  not survive a map change; a forced player route snaps tile-to-tile and
  suppresses input while active). *Input Number* (103) is implemented too: the
  interpreter suspends with a `:number` request and `Scene::Map` drives a
  digit-entry widget (`Game::NumberInput`) whose value is stored into the target
  variable. The party also carries an **inventory** now (`Game::State` item /
  weapon / armor stores, each id → count capped at 99, persisted in the save):
  *Change Items / Weapons / Armor* (126/127/128) add or remove by a constant or
  a variable amount, the Conditional Branch **item / weapon / armor** possession
  tests (types 8/9/10) run, and Control Variables can read an **item count** as
  its operand. *Change Party Member* (129) adds/removes actors from the party,
  the **actor "is in the party"** conditional (type 4) is evaluated, and Control
  Variables also reads the **"other" game quantities** — map id, party size and
  gold (operand type 7). Covered by `mruby-rpgxp/test` and driven over the real
  test bed by `scripts/rpgxp_testbed_check.rb`. Still to come: vehicle move-route
  targets, the remaining actor / enemy / character conditional sub-conditions,
  and the many screen-effect / picture / battle commands (skipped for now).
- ✅ **Encrypted archives** — a packed release that ships only a `Game.rgssad`
  (RPG Maker XP; VX's same-format `Game.rgss2a`) or a VX Ace `Game.rgss3a` loads:
  `RPGXP::RGSSAD` (`mruby-rpgxp/mrblib/rgssad.rb`) decrypts **both** the version-1
  format (rolling 0xDEADCAFE key) and the version-3 format (a plaintext header
  seed → base key, a fixed-key entry table with per-file data keys) and
  `RPGXP::RGSSData` falls back to whichever archive is present when a `.rxdata` is
  not loose on disk. Covered by `mruby-rpgxp/test` (v1 and v3 round-trips) and by
  `scripts/rpgxp_testbed_check.rb` (packs the real test bed as both `.rgssad` and
  `.rgss3a` and reloads the whole DB through each). Remaining: reading
  **graphics/audio** out of the archive (only the Ruby `Data/` path is wired; the
  native `Bitmap`/`Audio` loaders still read loose files).
- **Menus / save / battle** — the default menu screens, saving in the real
  `.rxdata` save format (a portable Marshal save is used for now), and the
  battle system.
- **Run the bundled RGSS scripts** — the largest possible direction: an
  `eval`-based host that runs `Data/Scripts.rxdata` unmodified against the RGSS
  class library (the equivalent of the MV "embed the real engine" choice),
  which would also run community scripts. Out of scope for the current layer.
- Reference for the RGSS game library:
  https://www.rpgmaker.fixato.org/Manual/RPGVXAce/rgss/

## RPG Maker with JavaScript

Support the JavaScript makers (RPG Maker **MV**, then **MZ**) by embedding a real
JavaScript engine (**quickjs-ng**) and running each game's own scripts
unmodified, rather than reimplementing the engine in mruby. MV is targeted first
because it can render through PIXI.js's Canvas2D path, which maps onto the
existing `mruby-rgss::Bitmap` blit primitives; MZ is WebGL-only and follows.
Full design and rationale: `docs/adr/0004-javascript-maker-mv-quickjs.md`.

- ✅ **M1 — Foundation.** New `mruby-mvjs` gem (thin Ruby orchestration layer:
  MV project detection, canonical script load order, boot/pump handshake with a
  clearly-marked seam for the JS host). MV directory sniffing wired into
  `src/main.cxx` (`js/rpg_core.js` + `data/System.json`). Host-runnable specs
  for the pure logic. No JS engine yet, so an MV game is detected but reports the
  runtime as pending instead of misbehaving.
- ✅ **M2 — Engine host.** quickjs-ng added as the `3rd/quickjs` git submodule and static-linked
  (`qjs` target) into the executable and the mruby test binary. `MV::JS.eval`
  opens a runtime/context, evaluates JavaScript and marshals scalar results
  (Integer/Float/String/true/false/nil), raising `RuntimeError` on a JS
  exception. `MV.js_available?` reports the engine's presence; `runtime_available?`
  stays false until the game host (M3/M4) lands. Covered by `mruby-mvjs/test`.
- 🚧 **M3 — Boot to title.** Host-global shims (`window`/`document`/`navigator`/
  `location`/`requestAnimationFrame`/`setTimeout`/`XMLHttpRequest`/`Image`/
  `localStorage`/`require('fs'|'path')`), the asset/JSON IO bridge, and the
  rAF/event-loop pump — enough to load the core scripts and reach `Scene_Title`.
  - ✅ Persistent JS host (one runtime/context reused across evals), the
    `window`/`self`/`global`/`globalThis` aliases, `console`, a native file
    reader and a synchronous `XMLHttpRequest` (the JSON/asset IO bridge).
  - ✅ Event loop: `setTimeout`/`setInterval`/`clearTimeout`,
    `requestAnimationFrame`/`cancelAnimationFrame`, `performance.now`, and a
    `MV::JS.pump(now_ms)` that fires due timers + animation-frame callbacks and
    drains promise microtasks. Passive `navigator`/`location`/`localStorage`.
  - ✅ NW.js `require('fs'|'path')` (local-file saves), `MV::JS.eval_file`, and
    `MV#boot`/`MV#main_loop` wired to evaluate `MV::CORE_SCRIPTS` and pump the
    host (dormant behind `runtime_available?` until M4 rendering).
  - Remaining: `document`/`Image` (canvas-related, land with rendering in M4),
    then flip `runtime_available?` on so the boot actually reaches
    `Scene_Title`.
- 🚧 **M4 — Rendering.** The Canvas2D → `Bitmap` bridge behind PIXI's Canvas
  renderer, so the title screen and map actually draw through `mruby-rgss`.
  - ✅ `document`/`HTMLCanvasElement`/`CanvasRenderingContext2D` backed by native
    RGBA buffers (`mvcanvas.cxx`): `fillRect`/`clearRect`/`drawImage`/
    `getImageData`/`globalAlpha`/`fillStyle`, WebGL absent so PIXI uses canvas.
    Unit-tested by pixel readback.
  - ✅ PNG `Image` loading (via stb, reusing mruby-rgss's
    `STB_IMAGE_IMPLEMENTATION`): `new Image()` decodes into a native canvas and
    is a `drawImage` source, with async `onload`/`onerror`. Game-relative asset
    paths are rooted at the game dir (`mv_resolve_path` / `MV::JS.base_dir=`).
  - ✅ On-screen present: `MV#boot` creates one full-screen `RGSS::Sprite`/
    `Bitmap` and `MV::JS.present` copies the MV canvas into it each frame (R/B
    swapped for the ARGB8888 layout), via a small `rgss::bitmap_pixels` accessor
    (`include/rgss_bitmap.hxx`). `MV.runtime_available?` is already on.
  - ✅ Transform-aware drawing: the 2D context tracks the full transform
    (`save`/`restore`, `translate`/`scale`/`rotate`/`transform`/`setTransform`),
    and `drawImage` inverse-maps through it so PIXI's sprites (positioned via
    `setTransform` + draw-at-origin) land correctly; `fillRect`/`clearRect` map
    their rect through the matrix.
  - Remaining: `putImageData`/typed-array `ImageData`, and path-based fills
    (`beginPath`/`fill`) that PIXI's Graphics uses for solid shapes — then the
    title screen should composite. This is the point to boot the real MV test
    bed and iterate on whatever the corescript exercises next.
- 🚧 **M5 — Play.** Input (`Input`/`TouchInput`), save/load (the NW.js
  `require('fs')` shim) and audio (Web Audio → `RGSS::Audio`); a walkable MV game
  in the SDL window and the sixel/iTerm2 terminals.
- 🚧 **M6 — MZ.** A WebGL-subset backend on LVGL so PIXI v5 / RPG Maker MZ runs
  on the same foundation (`js/rmmz_*.js`).
