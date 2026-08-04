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
- ✅ Tilemap rendering — `Scene::Map` blits the lower/upper layers from the
  map's real ChipSet graphic via `Game::ChipsetLayout` (a port of EasyRPG
  Player's `TilemapLayer` geometry): single-chip lower (block E) / upper
  (block F) tiles, water (blocks A/B) and terrain (block D) autotiles assembled
  from four 8×8 quarter-tiles per the combination encoded in the tile id, the
  two animated block-C tiles, and water/animation frame cycling. Falls back to
  the previous solid-colour blocks when the chipset image is missing.
  Passability still drives collision. Geometry is pinned by
  `scripts/rpg2k_render_check.rb`. Remaining: tile-replacement (Replace Chipset
  Tiles) substitution and screen-tone tinting of tiles.
- ✅ Parallax background — `Scene::Map` draws the map's `Panorama/<name>`
  backdrop behind the tile layers (a sprite at z = -1). `Game::Parallax` ports
  EasyRPG's parallax model: a looping axis tiles the image and scrolls it at
  half the camera rate with optional time-based autoscroll (`parallax_sx/sy`),
  while a non-looping axis anchors it — fixed to the screen for the common
  full-screen backdrop, panned across its excess for a larger image. Grounded
  in the real Nepheshel data (all 45 parallax maps' images resolve and every
  offset stays in range across a camera sweep) and pinned by
  `scripts/rpg2k_render_check.rb`. The scroll *rate* mirrors EasyRPG's formulae
  but still wants a native/wine visual diff to confirm.
- ✅ Character sprites — the party leader and every map event render from their
  CharSet graphic (`Game::CharSet`, 4-direction, 3 walk frames). Events also
  draw a chipset tile when their graphic is a tile substitution (empty CharSet
  name), composite into the correct layer relative to the hero (below / above /
  same-layer y-sorted), honour the translucent flag, and pick their walk frame
  from the page's animation type (`Game::EventGraphic`: walk-while-moving,
  continuous, fixed-direction, fixed-graphic, spin). Events also **slide
  smoothly between tiles** (per-step pixel interpolation, mirroring the player):
  a single-tile step eases across over `TILE/SPEED` frames while the walk
  animation cycles, and a longer hop snaps. Grounded in the real Nepheshel data
  and pinned by `scripts/rpg2k_render_check.rb` /
  `scripts/rpg2k_scene_check.rb`. Remaining polish: vehicle sprites
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
  Change HP/MP, Full Heal, Change Parameters, Change EXP/Level, Change
  Equipment, Conditional Branch/Else/End,
  Loop/Break/End, Label/Jump, Timer, Teleport, Memorize/Recall Location,
  Store Terrain/Event ID, Wait, Play BGM/SE, Memorize / Play Memorized BGM,
  Message Options, Change Face Graphic, Input Number, Key Input Processing,
  Change Actor
  Name / Title / Sprite, Set Transparent Flag, Change Main Menu / Save Access,
  Change Teleport / Escape Access, Set Teleport / Escape Target,
  Change Encounter Rate, Change System BGM / SFX, Show Inn, Open Shop,
  Enemy Encounter,
  Erase / Show Screen, Tint Screen, Flash Screen, Shake Screen, Pan Screen,
  Show/Move/Erase Picture,
  Weather Effects, Call
  Event, Move Event, Change / Trade Event Location, Change Map Tileset, Proceed
  With Movement, Halt All Movement,
  Erase Event, Return to Title, End Event) with a per-frame step cap so a bad
  loop can't hang. **Memorize Location** stores the player's current map id, x and y
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
  resumes it once none remain. **Halt All Movement** cancels every forced route
  at once (the player's and each event's). **Input Number** suspends on a
  digit-entry widget and writes the entered value to a variable. **Key Input
  Processing** waits for (or, in no-wait mode, samples) a chosen set of buttons
  and writes the pressed key's RPG2000 code to a variable — the scene drives it
  for foreground and parallel events alike, following RPG_RT's pre-1.50 /
  1.50+ parameter layouts (number / operator keys and mouse are not modelled). **Change Actor
  Name / Title / Sprite** rename a party actor, set its status-screen title or
  swap its CharSet graphic (the scene reloads the leader's on-screen sprite);
  these edits survive Save / Continue. **Set Transparent Flag** hides or shows
  the party leader's map sprite (persisted in the save), and **Return to Title
  Screen** stops the event and returns the app to a fresh title. **Change Event
  Location** snaps a character (player / this event / a map event) to a tile and
  **Trade Event Locations** swaps two of them, refreshing collision. **Change Map
  Tileset** swaps the current map's chipset and rebuilds its tile graphic (until
  the next map load). **Erase
  Event** removes the running event from the map for the rest of the visit (its
  marker, movement, collision and any parallel process). **Change
  HP/MP**, **Full Heal**, **Change Parameters**, **Change EXP**, **Change Level**
  and **Change Equipment** apply to a fixed actor, a variable-selected actor or
  the whole party, clamped to each actor's maxima (Change HP honours the
  allow-death floor; Change Parameters re-clamps current HP/MP when a maximum is
  lowered; **Change EXP** re-derives the level from the RPG2000 standard curve
  (`Game::Actor#exp_for_level`, ported from EasyRPG's `CalculateExp` off the
  row's exp_basic/increase/correction) and **Change Level** rescales base stats
  through the per-level growth curve, both keeping EXP and level consistent
  without refilling current HP/MP, matching RPG_RT; Change Equipment folds an
  equipped item's bonuses into the effective stats). **Control
  Variables** reads not just constants and other variables but also a **random**
  range, an **actor stat** (level / EXP / HP / MP / max HP-MP / attack / defence /
  spirit / agility) and **game quantities** (party gold, timer seconds).
  Conditional Branch covers switch / variable / **timer** / gold / item
  conditions and the **actor** sub-conditions (in party, name, level ≥, HP ≥,
  item equipped, skill known; state is not modelled). **Show / Move / Erase
  Picture** (11110/11120/11130) are implemented: a `Game::Picture` per shown id
  (centre position, zoom, opacity, tone and the scroll-with-map flag) held on
  `Game::State`, decoded with EasyRPG's parameter layout (literal or
  variable-sourced coordinates, transparency → opacity); Move eases every
  parameter to its target over the duration and its wait flag suspends the
  interpreter (`:picture`) until the move settles; `Scene::Map` composites the
  pictures (id-ordered, zoomed via `stretch_blt`, at their opacity) into a layer
  above the map and below the message window. Picture **tone** is carried but not
  yet drawn (needs the same native tone support as the screen tint). **Weather
  Effects** (11070) records the map weather type (none / rain / snow) and strength
  on `Game::State` — the Ruby-half model only, like the tint overlay, so it
  round-trips through the save but drawing the rain/snow particles is native
  renderer work still to come.
  **Set Teleport / Escape Target** (11810 / 11830), **Change Encounter Rate**
  (11740) and **Change System BGM / SFX** (10660 / 10670) record their payloads
  on `Game::State` — a per-map teleport-target registry, a single escape target,
  the encounter step rate and per-slot system music / sound overrides — and
  round-trip through the save, but nothing consumes them yet (the Teleport /
  Escape skills, encounter system and battle / menu scenes are not built), so
  they are modelled for save fidelity like the access flags.
  **Show Inn** (10730) is a playable game-mode: a priced inn opens a greeting
  window with Accept / Cancel choices (Accept gated on whether the party can
  afford it) plus a gold window, staying deducts the price and fully heals the
  party, and either outcome routes into the command's optional `[Stay]` /
  `[No Stay]` handler branches (structured and skipped like Show Choices).
  `Game::Interpreter` owns the gameplay and suspends on an `:inn` wait that
  `Scene::Map` drives; the inn fade and jingle are presentation still to come.
  **Open Shop** (10720) is a playable game-mode too: a `Game::Shop` holds the
  goods and buy / sell rules and performs the transactions (buy at the database
  price, sell at half, party 99-item / gold caps enforced), tracking whether
  anything was traded to pick the command's `[Transaction]` / `[No Transaction]`
  branches. The interpreter suspends on a `:shop` wait; `Scene::Map` drives the
  buy / sell menus (one unit per confirm — the quantity selector is a later
  refinement).
  **Enemy Encounter** (10710) starts the battle path: `Game::Enemy` / `Game::Troop`
  instantiate a database enemy group into live members and total its EXP / gold,
  and the command decodes its troop id, escape / defeat modes and first-strike
  and routes the `[Victory]` / `[Escape]` / `[Defeat]` handler branches on the
  outcome (the "end event processing" escape mode abandons the event). The
  interpreter suspends on a `:battle` wait; the turn-based battle screen is not
  built, so `Scene::Map` resolves an encounter as an immediate victory granting
  the troop's EXP and gold — a placeholder until the battle system lands.
  The remaining commands (the battle system proper, EXP gain / level-up
  messages, ...) are TODO
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
  text inset). The `\c[n]` **text is blended with the game's own windowskin**:
  rather than a flat colour, `Scene::Map` fills each coloured run's glyphs from
  the windowskin's colour swatch through the new native `Bitmap#blend_text`, so
  the swatch's shading reads as a top-to-bottom gradient on the text the way
  RPG2000 draws it (`Game::MessagePalette` locates each swatch — a 10×2 grid of
  16×16 cells from y = 48, per EasyRPG's layout), falling back to a flat colour
  only when no windowskin loaded or for an out-of-range index. Auto-positioning
  the window away from the hero (when not pinned) and the mirrored-face flag are
  later refinements
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
  flag pauses the interpreter until the effect settles (a `:screen` wait,
  resumed by the scene once `Game::Screen#busy?` clears). The tint is the Ruby
  half only — **applying** it as an `RGSS::Viewport` tone is native (C++) work
  still to come, so it does not yet change what is drawn. **Shake Screen**
  (11050) also drives `Game::Screen`: a timed, float-free triangle-wave
  horizontal offset (amplitude from power, rate from speed) that `Scene::Map`
  subtracts from the camera, so — unlike the tint — the shake **is** visible
  with the current renderer. **Flash Screen** (11040) drives `Game::Screen` too:
  a colour + strength that fades to zero over the duration; like the tint it is
  the Ruby half (drawing the full-screen colour overlay at its strength needs
  the same alpha-blend / viewport support in C++). **Pan Screen** (11060) drives
  `Game::Screen` as well: lock / unlock freeze or resume the camera's hero
  follow, and pan / reset scroll a pixel offset toward a target that `Scene::Map`
  adds to the camera (so — like the shake — the pan **is** visible; while locked
  the view holds where locking began). **Erase Screen** (11010) / **Show Screen**
  (11020) drive `Game::Screen` too: a fade level (0 visible .. 255 black) that
  eases like the tint over a fixed transition and is held erased until a Show,
  recording the requested transition style (fade / block / stripe / scroll) for
  fidelity while modelling only the fade. All share the `:screen` wait, so event
  timing around them is correct. **Show Picture** now renders (see the
  interpreter bullet above). Weather remains, and the tint / flash / screen-fade
  overlays still need `RGSS::Viewport` tone/alpha support in C++ to actually
  darken or colour what is drawn

#### Menus, save, battle
- 🚧 Menu scene — opens over the map (cancel button); shows party status and a
  command list. Save, End Game, **Item**, **Equip** and **Status** work; only
  **Skill** remains a placeholder (it shares the battle effect formula, so it is
  best built with / after the battle system). The **Item** command opens
  `Scene::ItemMenu`: it lists the party's usable **medicines** (database item type
  6) and **skill books** (type 7) with their held counts. A medicine heals its
  target — a single-target item a chosen ally, an all-ally item (scope 1) the
  whole party — restoring HP/SP (flat + percentage of max, clamped); a skill book
  teaches its skill (item field 53) to a chosen ally who does not already know it.
  Either consumes one on a use that had any effect, and greys out / reports a use
  with no effect (a full target, or an actor who already knows the skill). The
  **Equip** command
  opens `Scene::EquipMenu`: it shows a party member's five equipment slots and
  stats (LEFT/RIGHT cycle members), and for a chosen slot lists the bag's fitting
  items (plus Remove); equipping swaps the previously-worn item back into the bag
  and recomputes stats. The **Status** command opens `Scene::StatusMenu`: a
  read-only per-member detail (name/title, level, EXP and EXP-to-next, HP/MP, the
  six stats and the equipped items; LEFT/RIGHT cycle members). The decision logic
  is on `Game::Party` (`field_items` / `item_recovery` / `item_effective?` /
  `use_item` for items; `equip_candidates` / `equip_from_bag` / `unequip_to_bag`
  for equip) and `Game::Actor` (`next_level_exp` / `exp_to_next` for status),
  covered by `scripts/rpg2k_logic_check.rb`; the RGSS windows are the
  untestable-here UI. Seed (8) / switch (9) item use, the item usable-occasion
  gate, and two-handed / dual-wield equipping are later refinements.
  **Change Main Menu Access** (11960) and **Change Save Access** (11930) gate it:
  the menu will not open while menu access is forbidden, and the Save command
  reports that saving is disallowed while save access is off (both flags default
  on and persist in the save)
- 🚧 Save & Continue — the portable `Marshal` save of the game state
  (`Game::State#to_h` / `State.load`) is the authoritative save, written via the
  menu's Save command; "Continue" reloads it. **Reading** the real
  `LCF::SaveData` (`.lsd`) is done (`Game::State.from_lsd`), and **writing** it is
  now done too: `Game::State#to_lsd` builds the `SAVE_DATA` chunks (system 101,
  hero 104, party actors 108, inventory 109) from live game state and
  `SaveData#save_to` writes a genuine `Save<slot>.lsd`, exported alongside the
  Marshal save on every save (ADR 0019, on the `mruby-lcf` serializer of ADR
  0018). It round-trips through `from_lsd` field-for-field
  (`scripts/rpg2k_save_load_check.rb`). The export is now **near-parity** with the
  Marshal save: on top of the four original chunks it also writes the message
  config, current/memorized BGM, the player-transparent flag, the
  menu/save/teleport/escape access flags (all SaveSystem chunk 101), the leader's
  on-map CharSet override (hero chunk 104) and the **title chunk (100)** — the
  `:double` timestamp (via the new `LCF.pack_double`), the leader's
  name/level/HP and the party FaceSets — so a real RPG_RT/EasyRPG file-select
  screen shows the party. Still keeping the Marshal save *primary* (so Continue
  prefers it) are two fields the `.lsd` cannot yet carry: the **game timer**
  (liblcf's SaveSystem has no field for it — needs a documented chunk id) and
  **per-actor name/title overrides for non-leader** members (only the leader's
  name is in the title chunk)
- Battle system — enemy groups, battle scene, actions/damage/states,
  animations, game-over scene (large; Nepheshel uses the default RPG2000
  battle). Needs real assets + the native build to develop against
- Skill menu screen — the Item, Equip and Status screens now exist (see Menu
  scene above); only Skill remains, and it is best built with / after the battle
  system since a skill's HP/SP effect shares that damage/heal formula

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
  gold (operand type 7). **Battle Processing** (301) navigates its result
  branches — If Win (601), If Escape (602), If Lose (603), branch end (604) —
  running only the branch that matches the resolved outcome (a win by default,
  configurable via the interpreter's `battle_outcome`, since there is no battle
  system yet); the real `OpenGame.exe` XP test bed uses this structure. Covered
  by `mruby-rpgxp/test` and driven over the real test bed by
  `scripts/rpgxp_testbed_check.rb`. Still to come: vehicle move-route targets,
  the remaining actor / enemy / character conditional sub-conditions, and the
  many screen-effect / picture commands, plus the battle system itself that
  Battle Processing would drive (skipped for now).
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
- 🚧 **Run the bundled RGSS scripts** — the largest direction: an `eval`-based
  host that runs `Data/Scripts.rxdata` unmodified against the RGSS class library
  (the equivalent of the MV "embed the real engine" choice), which would also
  run community scripts. The **host plumbing now exists** (ADR 0017): a native
  `RGSS.zlib_inflate` decompresses the script sections, `RPGXP::RGSSData`
  exposes `read_object`/`save_object`/`scripts`, and `RPGXP::ScriptHost`
  installs the Kernel `load_data`/`save_data` built-ins and evaluates every
  section at the top level (mruby-eval) so "Main" drives the game. Boot runs the
  host when it is enabled (`RGSS_SCRIPT_HOST`, off by default) and the project
  ships scripts, falling back to the built-in flow otherwise. Decoding, the
  built-ins and top-level evaluation of real script source are covered by
  `mruby-rpgxp/test` and `scripts/rpgxp_script_host_check.rb`. Remaining before
  it can be the default: complete the `mruby-rgss` class library the stock
  scripts call — the precise gap (measured against the real test-bed scripts) is
  tracked in [`docs/rpgxp-rgss-api-gap.md`](rpgxp-rgss-api-gap.md). `Font`,
  `Graphics` timing, `Input` and `Audio` are already covered; the open pieces are
  `Sprite` extended properties, and the empty `Window` / `Tilemap` / `Plane`
  widgets, plus `Kernel#sprintf` and drawing `Graphics.transition/freeze`.
  Also reconcile the scripts' blocking main loop with the emscripten frame loop
  (Asyncify or a per-frame driver), and read graphics/audio out of the encrypted
  archive.
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
  - ✅ Test-bed data guard: `scripts/mv_testbed_check.rb` validates the MV
    `data/*.json` boot invariants under CRuby (no JS engine) — start map size
    (`width*height*6`), tileset/actor/class cross-references, party members —
    and runs as a **blocking** CI step ahead of the non-blocking native MV
    smokes, so a regression in the committed `data/mv-sample` fails the build.
  - ✅ Real-game play smoke: CI drives the downloaded Lunatic-Core bed past the
    title into New Game → map and a movement probe (`--mv_new_game
    --mv_move_test`), not just the title boot — so the fuller real game's
    map/movement/render path is exercised, not only the minimal sample's.
  - ✅ Battle smoke reaches `Scene_Battle`: `--mv_battle_test` now starts the
    fight via a real "Battle Processing" event command (code 301) through the
    map interpreter instead of a bare out-of-loop `SceneManager.push`, which
    deadlocked on the frozen encounter-effect intro. Runs on Lunatic-Core (real
    battlers/battleback) and logs `[MV-BTL] reached_battle=<bool>`.
  - ✅ Menu smoke: `--mv_menu_test` opens `Scene_Menu` via the engine's real
    `callMenu` path (re-asserting `Scene_Map.menuCalling`) and logs
    `[MV-MENU] reached_menu=<bool>`.
  - ✅ Save smoke: `--mv_save_test` runs a save+load round-trip through
    `DataManager` (save → `StorageManager.exists` → load) and logs
    `[MV-SAVE] saved=.. exists=.. loaded=..`, confirming the localStorage-backed
    save path writes and reloads.
  - ✅ Audio smoke: the sample ships an authored `audio/se/Beep.wav` (wired to
    its UI sounds), and `--mv_audio_test` plays it through the
    `AudioManager` → `__mv_audioQueue` → `RGSS::Audio` bridge, logging
    `[MV-AUDIO] op=.. dispatched=.. asset=..` — so the audio path is finally
    exercised end to end (the downloaded beds ship no audio). Audible output
    still wants a device / a native listen; CI only checks dispatch + resolve.
- 🚧 **M6 — MZ.** A WebGL-subset backend on LVGL so PIXI v5 / RPG Maker MZ runs
  on the same foundation (`js/rmmz_*.js`).
  - ✅ M6.1 foundation: an `MZ` class (`mruby-mvjs/mrblib/mz.rb`) detects an MZ
    project (`js/rmmz_core.js` + `data/System.json`), knows the canonical
    `rmmz_*` load order, and is wired into `src/main.cxx`'s maker sniff so an MZ
    game reports the pending WebGL backend cleanly instead of "no project
    found". Covered by `mruby-mvjs/test/mz_test.rb`.
  - 🚧 M6.2 host reuse: run the `rmmz_*` scripts on the shared quickjs host to
    reach `Scene_Boot` in logic; a committed MZ sample is authorable (MZ's
    corescript has an MIT community reimplementation, `stak/rmmz-corescript`,
    fetchable like the MV corescript).
  - 🚧 M6.3 WebGL rendering: the WebGL-subset backend behind PIXI v5 (the bulk
    of the work — MZ dropped the Canvas2D renderer the MV bridge targets).
