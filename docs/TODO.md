# TODOs of this project

## RPG Maker 2k
- Support all data schema of LCF
- ✅ Show window component for title scene
- 🚧 Implement New Game functionality — builds the initial party from the
  database, reads the start position from the map tree and loads the starting
  map into a `Scene::Map`; the map/player renderer is the remaining piece
- Implement Continue functionality (blocked on `LCF::SaveData` schema)

### Issue items needed to run Nepheshel

Today the runtime boots only to the title screen: `RPG2k` loads the database
(`RPG_RT.ldb`) and map tree (`RPG_RT.lmt`), shows the title image plus the
New Game / Continue / Shutdown menu, and stops there. "New Game" and
"Continue" are TODO stubs (`mruby-rpg2k/mrblib/main.rb`). The RGSS primitives
(`Bitmap`, `Window`, `Sprite`, `Font`, `Input`) exist, but `Tilemap` is an
empty stub, `Audio`/`Graphics` are warn-once stubs, and there is no LMU (map)
schema, event interpreter, or battle code.

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
- Event pages — page conditions (switch/variable/item) and trigger types
  (action / touch / auto-start / parallel)
- Event command interpreter — the ~100+ RPG2000 commands (Show Message,
  Choices, switches/variables, conditional branches, Teleport, Move Event,
  Change Items/Party, ...)
- Message window — text with control codes (`\v`, `\n`, `\c`, `\.`), face
  graphics, choice cursor
- Common events — parallel and auto-start common events
- Screen effects — transitions/fade, tint, flash, shake, Show Picture,
  weather, timer

#### Menus, save, battle
- Menu scene — item / skill / equip / status / save, driven by the already
  parsed `term` and item/skill/actor data
- Save & Continue — `LCF::SaveData` has a header but no schema/logic; needed
  for the Continue path
- Battle system — enemy groups, battle scene, actions/damage/states,
  animations, game-over scene (large; Nepheshel uses the default RPG2000
  battle)

#### Assets & infrastructure
- Audio playback — replace the inert `RGSS::Audio` stubs with real
  BGM/BGS/ME/SE (WAV/MIDI)
- RTP resolution / `FullPackageFlag` (issue #40) — `RPG_RT.ini`'s
  `FullPackageFlag=1` disables RTP; resource lookup must fall back between the
  game directory and the RTP

## RPG Maker with RGSS
- Support game library features of RGSS which could be found in https://www.rpgmaker.fixato.org/Manual/RPGVXAce/rgss/

## RPG Maker with JavaScript
