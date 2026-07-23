# TODOs of this project

## RPG Maker 2k
- Support all data schema of LCF
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
landed so far is exercised by unit tests (`mruby-lcf/test` and a host harness),
since the full SDL/mruby binary can't be built or run in this environment.

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
  animation and edge/tile/event collision. Move-route processing still to come

#### Event system
- 🚧 Event pages — page conditions (switch/variable/item/actor) are implemented
  (`Game::EventPage`), and action-button + auto-start triggers run; touch,
  event-touch and parallel triggers plus move routes are still to come
- 🚧 Event command interpreter — `Game::Interpreter` runs a solid subset (Show
  Message + Choices, Control Switches/Variables, Change Gold/Items/Party,
  Conditional Branch/Else/End, Loop/Break/End, Label/Jump, Timer, Teleport,
  Wait, Play BGM/SE, End Event) with a per-frame step cap so a bad loop can't
  hang; the remaining ~90 commands (Move Event, pictures, screen effects,
  battles, actor stat changes, Call Event, ...) are TODO
- 🚧 Message window — renders text lines and a choice cursor and expands the
  common message control codes (`\v[n]` variable, `\n[n]` actor name, `\\`;
  colour/speed/wait codes are consumed). Face graphics, per-code colour changes
  and gradual text reveal are still TODO
- 🚧 Common events — auto-start and parallel common events run on the map
  (`Game::CommonEvent`), gated by their switch when `need_flag` is set; true
  concurrent parallel execution (running every frame alongside the player) is
  still simplified to a once-per-visit start
- 🚧 Screen effects — the game **timer** works (Timer Operation command +
  `Game::State` countdown); transitions/fade, tint, flash, shake, Show Picture
  and weather remain. `RGSS::Viewport` now exists (position/clip/scroll/z), but
  most of these still need more `RGSS::Sprite`/`Viewport` support in C++
  (opacity, tone, flash) before they can be driven from Ruby

#### Menus, save, battle
- 🚧 Menu scene — opens over the map (cancel button); shows party status and a
  command list. Save and End Game work; item / skill / equip / status are
  placeholders still to be built from the parsed `term`/item/skill/actor data
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
- Audio playback — replace the inert `RGSS::Audio` stubs with real
  BGM/BGS/ME/SE (WAV/MIDI). Needs a C++ audio backend (SDL/`3rd/timidity`) that
  can only be built and verified natively
- ✅ RTP resolution / `FullPackageFlag` (issue #40) — `RPG_RT.ini`'s
  `FullPackageFlag=1` clears `RTP_DIR`, and `Bitmap` lookup already falls back
  from the game directory to the RTP (with `.png`/`.xyz`/`.bmp` extensions)

## RPG Maker with RGSS
- Support game library features of RGSS which could be found in https://www.rpgmaker.fixato.org/Manual/RPGVXAce/rgss/

## RPG Maker with JavaScript
