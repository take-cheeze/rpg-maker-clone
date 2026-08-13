# TODOs of this project

## RPG Maker 2k
- 🚧 Support all data schema of LCF — the core database, map tree and map-unit
  chunks needed for boot and gameplay are covered and validated against a real
  test-bed by `scripts/lcf_testbed_check.rb`. Transcribed from the 200X共通
  解析まとめ wiki: item armour-option flags (25–28) and the item/skill
  `使用時アニメ` weapon fields (the shared `BATTLER_ANIMATION` union),
  skill switch/occasion chunks (13, 16, 18, 19), and the `battle_anime2`
  attack-motion + `基本と拡張`/`武器` pose object lists (chunks 2, 10, 11).
  The map-unit chunks that used to be unaccounted for (42, 50, 60–62, 90) are
  **declared now**. They are not the save/encounter/parallax metadata they were
  guessed to be: they are the **RPG2003 random dungeon generator** block plus the
  2k3e save counter, and since the wiki's マップ page does not document them the
  ids, types and defaults come from liblcf's `LMU_Reader::ChunkMap` / `RPG::Map`
  (0x28..0x3E, 0x5A) — chunk 42 is `top_level`, 50 `generator_height`, 60/61/62
  the nine room slots' `generator_x` / `generator_y` / `generator_tile_ids`, 90
  `save_count_2k3e`. The whole block (40–56 as well, which no test bed writes) is
  declared so a real map parses with nothing left over. The bytes confirm the
  reading rather than merely tolerating it: chunk 62 read as **shorts** yields
  ordinary tile ids (49 lower-layer, 10000/10001/10006/10007 upper-layer) where
  an int32 reading gives numbers in the millions, and the fields mtf-meido-action
  omits are exactly the ones already at their liblcf default (`generator_width`
  4, the six `true` flags) — which is what an eliding writer produces. Only that
  game writes them at all, being the RPG2003 test bed; Nepheshel's 543 maps read
  the whole block from its defaults. `lcf_testbed_check.rb` now asserts the
  shape (nine coordinates, eighteen tile ids, every field materialising), and
  that guard was checked by mis-declaring chunk 62 and watching it fail. These
  remain editor-only details off the walkable-game critical path — nothing reads
  them at run time, RPG_RT included
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
that load the pure-Ruby sources under CRuby.
**The native binary can be built and run without Nix after all** —
`scripts/native-build-without-nix.bash` does it on a plain Debian/Ubuntu box, and
this line used to say it could not. Nothing exotic was in the way: SDL2 headers,
the `3rd/` submodules (empty in a plain clone), `rake` reachable from `/bin/sh`
(mruby builds itself with it) and the two Unicode mapping tables the flake
supplies through `$cp932_table` / `$jis0208_table` — downloaded and checked
against flake.nix's own sha256 hashes, so the build consumes the bytes Nix would
hand it. That matters because the CRuby harnesses cannot see mruby/CRuby
divergence (ADR 0021's `module_function` and `Enumerable#none?` bugs both shipped
through green checks) and cannot see rendering at all, while the native build
reaches both: `--rgss_effect_probe` measures real pixels under Xvfb, and the two
boot checks drive real game data to the map. `scripts/rpg2k_command_soak.rb` adds
the other half of that coverage: it runs **every event command of every
downloaded test-bed** (371,762 of them) through the interpreter and fails if one
raises or reaches a handler's "I do not know this" arm, which is the parameter
shapes real games ship rather than the ones fixtures reach. The LCF loaders are smoke-tested
against real downloaded test-bed projects (`scripts/lcf_testbed_check.rb`, run in
CI after the download step), which parses a genuine game's
`RPG_RT.ldb`/`.lmt`/`Map*.lmu` end to end and catches format surprises the
synthetic unit tests can't; the gameplay logic (`game.rb`/`interpreter.rb`) is
checked by `scripts/rpg2k_logic_check.rb` (pure move-route / interpreter logic)
and `scripts/rpg2k_scene_check.rb` (the map scene driving event movement behind
RGSS stubs). `scripts/rpg2k_testbed_logic_check.rb` is the join of the two
kinds — a *real* game's `RPG_RT.ldb` driven through the *real*
`Game::Interpreter` — for rules that only genuine data violates: its first
subject is Nepheshel's companion swaps, where the party-roster bug of ADR 0030
passed every fixture check while breaking the actual game. It also asks the real
databases what the menus offer, which is how the empty battle skill menus of ADR
0031 were found — 306 and 134 skills, none of them reachable, with every fixture
check green.

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
  `scripts/rpg2k_render_check.rb`. **Replace Chipset Tiles** (Tile Substitution,
  11750) is implemented — the swap is recorded on the `Game::Map` so passability
  follows it, and the scene rebuilds both cached tile layers.
  **The screen tone reaches the map** now as well. A Tint Screen used to be
  approximated by a black overlay whose opacity tracked how far the channels
  averaged *below* neutral, which left three of the four things the command can
  ask for doing nothing at all: brightening (above neutral), the colour cast, and
  saturation. Every map sprite — the parallax, both tile layers, the hero, the
  vehicles and their shadow, and the battle-animation layer — now lives in one
  `Viewport`, and `Scene::Map#update_map_tone` sets that viewport's tone from
  `Game::Screen#tint`. A viewport is what carries a tone in RGSS, and it reaches
  the sprites inside it and nothing else, which is exactly the line the screen
  tone needs: the map is tinted while the pictures above it (which carry their
  own tone), the message window and the weather / flash / fade overlays are not.
  The channel conversion is the one the pictures already use
  (`Scene::Map.tone_channel`), saturation included — RPG2000 counts it *down*
  from 100 to mean less saturated, which inverts into RGSS's grey. The tone is
  pushed only when it changes, so an untinted map pays nothing.
  That this reaches the display rather than merely storing values is the point:
  the earlier attempt did store them and the screen never changed, which is why
  `RGSS.effect_probe` exists (`--rgss_effect_probe`, run under xvfb in CI) and
  measures a real frame before and after a viewport tone.
- ✅ Render parity with the genuine runtime —
  `scripts/compare-nepheshel-wine.bash` boots the real `RPG_RT.exe` under wine
  beside our engine on the same game and diffs the frames (ADR 0021). It first
  caught that the ported geometry was **not reachable at all** in the shipped
  binary (a bare `module_function` is a no-op in mruby), then pinned the title
  command window, the windowskin selection cursor, RPG_RT's shadow + colour-
  swatch text, the fixed 320×80 message panel, 60fps frame pacing, and the
  picture / camera-pan / chipset reset a map change performs. CI runs the cheap
  half (`--rpg2k_new_game` on the real Nepheshel data).
- ✅ Diff an in-game **map**, not just the title —
  `scripts/compare-nepheshel-save-wine.bash` resumes both runtimes from the same
  `Save01.lsd` (ours via `--rpg2k_continue`, RPG_RT via a fixed three-key
  Continue sequence), so they cannot drift the way the key-press-counting
  harness did through Nepheshel's timed opening.
  `scripts/gen-rpg2k-save.rb` moves the party in that save to any map. See the
  addendum in ADR 0021. Two gaps it uncovered, both still open:
  - ✅ **An ordinary map now diffs to zero.** Resuming the debug save landed
    back in the demo's timed cutscene (its choice lives in chunk 113, its
    backdrop in 103), and moving the party left RPG_RT drawing a different part
    of the map entirely — it **restores the camera from the save** rather than
    deriving it from the hero. Chunk 111's two leading ints, previously listed
    here as undecoded, are that camera in **1/16 pixel** (measured against
    RPG_RT: 5120/3840 puts its view at exactly (320, 240)).
    `gen-rpg2k-save.rb` now writes them and grew `--clear-scene` to drop chunks
    113/103. With both runtimes on the same tile the comparison found two real
    rendering bugs — CharSet/FaceSet/menu-windowskin graphics loaded without the
    colour key (a solid pink block over a wall) and lower-layer tile id 0 treated
    as empty when it is water set 0 (black holes in the sea) — after which the
    town, interior and open-water frames are **pixel-identical** to RPG_RT.
    The comparison is only meaningful on a map where nothing moves on its own:
    roaming events and parallel processes (needle traps, monsters) drift between
    the runtimes, and no Nepheshel map with events is fully static.
  - ✅ **Shown pictures are restored on load.** Resuming mid-cutscene, RPG_RT
    drew the saved background picture and we drew black. `Game::State` treated
    `@pictures` as transient — true for a HUD re-shown by parallel events, false
    for a save taken while a cutscene's picture is up, which the real runtime
    persists in chunk 103. `LCF::Schema::SAVE_PICTURE` recorded the position
    slots as doubles of unknown meaning; **31/32 are the centre position**,
    identified by rewriting each candidate pair in a real save and diffing the
    resumed frame against the unedited one (see the ADR 0021 table). The picture
    region of the resumed frame is now pixel-identical to RPG_RT. Zoom, opacity
    and tone have save fields but no sample where they are off their defaults,
    so they are still left at `Picture`'s defaults rather than guessed at.
  - ✅ **`Game::State#to_lsd` output is loadable by RPG_RT.** It round-tripped
    through our own parser (`scripts/lcf_save_roundtrip.rb`) but the genuine
    runtime left "Continue" dead, with no error anywhere. The assumed cause —
    that our five chunks against a real save's sixteen were too few — was
    **wrong**: a real save stripped to exactly those five chunks still loads.
    Swapping in one of our chunks at a time isolated the title chunk (100), and
    then the field: `to_lsd` wrote the file-screen date as `0.0`, and zero on
    the OLE-automation scale is 1899-12-30, which RPG_RT reads as an *empty
    slot*. It now defaults to the current time, and a from-scratch `to_lsd` save
    loads in the real runtime. A `to_lsd` save still carries no picture,
    map-event or vehicle state, so it resumes into a bare scene — enough to
    prove the file loads, not enough to compare rendering, which is why the
    comparison harness still edits a genuine save.
- ✅ Parallax background — `Scene::Map` draws the map's `Panorama/<name>`
  backdrop behind the tile layers (a sprite at z = -1). `Game::Parallax` ports
  EasyRPG's parallax model: a looping axis tiles the image and scrolls it at
  half the camera rate with optional time-based autoscroll (`parallax_sx/sy`),
  while a non-looping axis anchors it — fixed to the screen for the common
  full-screen backdrop, panned across its excess for a larger image. Grounded
  in the real Nepheshel data (all 45 parallax maps' images resolve and every
  offset stays in range across a camera sweep) and pinned by
  `scripts/rpg2k_render_check.rb`. The scroll *rate* mirrors EasyRPG's formulae
  but still wants a native/wine visual diff to confirm. The **Change Parallax
  Background** event command (11720) swaps this panorama at runtime — the
  interpreter records a `Game::State#parallax` override (name + loop / autoscroll
  settings, per EasyRPG's `SetParallax`) and flags a one-shot rebuild the scene
  polls; the override is dropped on the next map change so the destination map's
  own panorama returns.
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
  `scripts/rpg2k_scene_check.rb`. Vehicle sprites are drawn too: one sprite per
  vehicle from its System CharSet graphic, hidden unless the vehicle is placed on
  the current map, the ridden one following the party, and the airship floating
  above a shadow sprite that marks the ground tile it is over
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
  (scene integration under host Ruby).
  **Jumps really jump now.** `Begin Jump` / `End Jump` were both treated as
  waits, so the moves between them stepped one tile at a time — three route
  commands where RPG_RT runs one, testing every tile on the way when a jump is
  the thing that clears them. `Game::MoveRoute#do_jump` ports EasyRPG's
  `BeginMoveRouteJump`: the enclosed moves contribute a tile of offset each
  without stepping, faces and turns only steer what the next move contributes,
  and `Game::Character#jump` lands the character on the summed destination in
  one move, facing the jump's dominant axis (a tie going vertical) rather than
  its last move. Only the landing is tested — a new `can_land?` on the movement
  world (`Scene::Map#char_can_land?`), because the genuine runtime skips the
  "may I leave this tile" half of its check while jumping. Nepheshel has 625 jump
  blocks, every one enclosing a runtime-directed move (484 away from the hero,
  188 toward it, 133 forward) rather than a literal direction, and 141 enclose
  more than one, so those now clear the tile they hop over.
  **The hop is drawn as one now, too.** The move happened in a single step and
  the sprite went with it, so a jump — the move whose whole point is being
  airborne — was a blink from one tile to another. A jumping event slides across
  the *whole* hop (the one kind of move that does; anything else longer than a
  step still snaps rather than streaking) and is lifted along the way by
  `Scene::Map#event_jump_offset`, a port of EasyRPG's
  `Game_Character::GetJumpHeight`: the height tracks the remaining step, peaks at
  the midpoint and is then stretched — doubled while small, offset by 5 past 4 —
  which is what makes the hop leave the ground sharply and hang near the top. It
  peaks at 21px on a 16px tile, so a jumping sprite clearly leaves its row. The
  lift is applied where the sprite is **blitted**, not to its position, so the
  camera and the y-sorted draw order still see the character on the ground, as
  RPG_RT does. `Game::Character#jumped` is what tells the renderer which kind of
  move it is watching, since the distance cannot: a jump can land one tile away
  or on the tile it left, and every ordinary move (including being *placed* by
  Change Event Location) clears it.
  Drawing the arc turned up a hop that could never happen: `char_can_land?`
  refused a jump onto the character's **own** tile, because that tile is occupied
  — by the jumper. RPG2000 hops in place, so a character no longer blocks its own
  landing. It was invisible while there was nothing on screen to notice it by.
  Events are what jump in the real games: of Nepheshel's 634 Begin Jump blocks,
  **632 drive an event** (625 of them a page's own autonomous route) and two the
  player; mtf-meido-action's single block drives the player.
  **The player's forced routes interpolate now too**, which was the separate gap
  that left: `step_player_route` wrote the destination tile straight onto the
  state, so a cutscene walking the hero across a room teleported it a tile at a
  time while the same hero, walking on input, slid smoothly. It shares the
  machinery ordinary walking already had — `advance_player_slide` moves the party
  a frame at a time and lands it — so a forced **jump** arcs the hero through the
  same curve an event jumps through (`jump_offset_for`, one implementation for
  both, so a jumping party member and a jumping NPC cannot rise differently).
  Two rules fell out of it. A step in flight has to **land before the next
  begins**: the route character runs ahead of the party (it is what the route
  steps) and the party only catches up when the slide completes, so stepping
  again mid-slide would leave the two more than a tile apart and stretch one
  slide over the gap — which also caps a forced route at the walking pace it is
  drawn at. And **Proceed With Movement drives the slide itself**, because the
  normal movement step is skipped while the interpreter waits on it; without
  that the route starts a step and then waits forever for a landing nothing is
  advancing.
  **Vehicle move-routes: a Move Event / Set Move Route targeting a boat, ship
  or airship (10002-10004) now actually drives it**, previously a silent
  no-op in `Scene::Map#apply_move_request` / `#char_location` /
  `#set_char_location` (a literal `nil # vehicles are not modelled yet`,
  despite the interpreter always decoding the target id fine).
  `Game::Vehicle` (`mruby-rpg2k/mrblib/game.rb`) is plain save/render data —
  position, facing, graphic — not a `Game::Character`, so it cannot be handed
  to `Game::MoveRoute#step` directly; the fix mirrors the same "mirror a
  `Game::Character`, write the result back" idiom the player's own forced
  routes already use (`@player_char`/`start_player_route`): `#force_vehicle_route`
  lazily builds a `Game::Character` mirror per type (`@vehicle_chars`), and
  `#step_vehicle_routes` steps it each frame against a new `VehicleWorld`
  (`scene/base.rb`, the same small `world` protocol `MapWorld` implements for
  the hero/events, but routing passability through
  `Scene::Map#vehicle_passable?` instead of the on-foot `#char_passable?` —
  so a moving unboarded boat inherits the existing ship-specific Through-Mode
  event-blocking quirk automatically). Unlike the player/events, a moving
  vehicle is **not pixel-interpolated**: it snaps tile to tile at its route's
  pace, the same instant feel Set Vehicle Location already had (a deliberate
  scope choice, not an oversight — smooth sliding is a possible follow-up).
  A route targeting the **currently-ridden** vehicle is dropped outright
  (`force_vehicle_route`'s `@state.boarded == type` guard, checked again each
  step): the party's own `#follow_vehicle` already claims the ridden
  vehicle's position every frame, and no yado.tk source describes an
  intentional "pilot the vehicle you're standing on by event" interaction, so
  the simplest, safest reading is that boarding and a route on the same
  vehicle just don't mix (a deliberate first-cut scope decision, not
  something confirmed against real RPG_RT either way). A route's own
  **Change Graphic** sub-command lands on the mirror, not on the persisted
  `Game::Vehicle#charset_name`/`#charset_index` — `#vehicle_charset` /
  `#vehicle_charset_index` prefer a live mirror's override, exactly the
  not-persisted-like-the-dedicated-command shape `#player_draw_charset`
  already established for the hero — so it reverts on Transfer Player (and
  save/load, since Continue always builds a fresh `Scene::Map`) rather than
  sticking the way the dedicated Change Vehicle Graphic command's write does.
  Change / Trade Event Location targeting a vehicle now instantly repositions
  it too (`#move_vehicle_to`), keeping a live route mirror in sync the same
  way `#move_player_to` does for the hero. Proceed With Movement now also
  waits on a vehicle's forced route (`#step_forced_movement`/
  `#forced_movement_done?`), which would otherwise have resumed the
  interpreter while the vehicle was still mid-route. **Out of scope for this
  first cut, flagged as follow-ups**: smooth position interpolation for a
  moving unboarded vehicle; walk-cycle animation (vehicles already only ever
  draw one standing pattern regardless, even ridden, so this is a pre-existing
  gap, not a regression); hero/event collision with a moving unboarded
  vehicle (vehicles are not in the `@event_tiles` occupancy table); a vehicle
  parked on a map other than the one currently loaded (nothing simulates an
  unloaded map); autonomous move types for a vehicle (vehicles have no
  "pages," only the forced route path applies). Covered by six new
  `scripts/rpg2k_scene_check.rb` checks (driving an unboarded boat along a
  route respecting `vehicle_passable?`; terrain blocking it the same way
  ordinary sailing is blocked; a route on a ridden vehicle being dropped;
  Change Event Location repositioning a vehicle; Proceed With Movement
  waiting on a vehicle route; the Change Graphic override reverting on
  Transfer Player), each confirmed to fail against the pre-fix code.

#### Event system
- ✅ Event pages — page conditions (switch/variable/item/actor) are implemented
  (`Game::EventPage`) and **re-evaluated while the map runs**, not just when it
  loads. They were selected once in `build_events`, so an event kept whichever
  page it started the visit with however the state moved — talk to an NPC, set
  the switch meant to turn it into its page 2, and nothing happened until the
  party left and came back. `Scene::Map#refresh_event_pages` re-selects whenever
  anything a condition reads has changed, carrying each event's position and
  facing across (RPG_RT changes an event's page, not where it stands) and
  rebuilding the parallel processes, since a page change can add or remove one;
  an erased event stays erased for the visit. RPG_RT flags this per command
  (`Game_Map::SetNeedRefresh` from Control Switches / Variables, Change Items,
  Change Party Member) — this build instead gives `Game::Switches`,
  `Game::Variables` and `Game::Party` revision counters and watches those, which
  covers every writer including the ones that are not event commands, like the
  item menu. Writing a value already held does not count, so a parallel process
  setting the same flag every frame costs a sweep rather than a rebuild.
  All five start triggers run: **action button**
  (0), **player touch** (1, the party walking into the event), **event touch**
  (2, which fires from **either** side — the event walking into the party *or*
  the party walking into the event, because RPG_RT tests the two touch triggers
  as one set on every player-side path while the event side tests only trigger 2),
  **auto-start** (3) and **parallel** (4, a
  background interpreter per event, driven by `Scene::Map#step_parallels`). A
  page's autonomous move type / custom move route also drives the event at
  runtime (see Movement & collision). The interpreter's *Set Move Route* (Move
  Event) command is now wired up too: it decodes the route packed into the
  command's parameters and applies it as a forced route to the target — a map
  event (including "this event") or the player, overriding page movement until
  it finishes. ✅ **Vehicle targets (boat / ship / airship, 10002-10004) now
  drive the vehicle itself**, not just decode without effect as they used to
  (this line previously overstated it — the interpreter always decoded the
  target id fine, but `Scene::Map` silently no-opped it). See the "Vehicle
  move-routes" paragraph in the Movement & collision entry above for the
  implementation
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
  Event, Move Event, Change / Trade Event Location, Change Map Tileset,
  Change Parallax Background, Proceed
  With Movement, Halt All Movement,
  Erase Event, Return to Title, End Event) with a per-frame step cap so a bad
  loop can't hang. **Teleport** (10810) honours RPG2003's arrival-facing
  argument: it is 1-based over the editor's up / right / down / left, not the
  2/4/6/8 numpad the runtime speaks, and was being assigned raw — leaving two of
  the four values (the editor's *up* and *down*) as numbers that are not
  directions at all. The RPG2003 test-bed sets a facing on 25 of its 26
  teleports; an RPG2000 project writes 0 there, so Nepheshel's 2021 were
  unaffected. **Memorize Location** stores the player's current map id, x and y
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
  equipped item's bonuses into the effective stats). **Change Party Member**
  moves actors in and out of the party, and what it moves is an entry in a
  **permanent roster** (`Game::Actors`, RPG_RT's `Game_Actors`): one
  `Game::Actor` exists per database row for the whole session and the party is
  only an ordered list of ids into it. That is the difference between a
  companion who rejoins with the level, EXP, learned skills, equipment, statuses
  and renamed name they left with and one rebuilt from the database row — which
  is what used to happen, resetting a level-21 companion with 16682 EXP and nine
  skills back to level 1 with one. Nepheshel's entire companion mechanic runs on
  this command (**5205** of them: 2835 adds, 2370 removes, mostly the three
  summonable party members and their alternates), and driving its real 召還 /
  帰す common events through the interpreter is how both the break and the fix
  were measured; the other test bed issues the command zero times, which is why
  it hid for so long. The roster is what the **save** carries as well — the
  Marshal save and `Save<N>.lsd` chunk 108 both hold every actor the party has
  ever held, matching a genuine RPG_RT save, so a companion who is away when the
  game is saved comes back intact instead of being dropped on load. The roster is
  also what a command **naming one actor** resolves through — every command above
  that takes a fixed or variable-selected actor rather than the whole party, plus
  Change Actor Name / Title / Sprite / Face and Enter Hero Name — matching
  RPG_RT's `GetActors`, which reads the party only for the "whole party" scope
  and `Game_Actors::GetActor` otherwise. That too is the common case rather than
  a corner: all **7805** fixed-actor-id commands in Nepheshel name a companion it
  also dismisses (Change Skills on actor 1 alone is 2871), and 653 per companion
  silently did nothing while that companion was away. **Reading** an actor goes
  the same way, with one deliberate exception: Conditional Branch's "is this
  actor in the party" test really does ask the party, while its other six tests
  (name / level / HP / knows-skill / has-equipped / has-state) and Control
  Variables' actor-stat operand ask the actor — the split RPG_RT makes between
  `IsActorInParty` and `Game_Actors::GetActor`. Nepheshel writes 28 of the first
  and 243 of the second, and all **2436** of its actor-stat reads name a
  swappable companion, which is why its party status display used to list a
  dismissed member at level 0. See ADR 0030. **Control
  Variables** reads not just constants and other variables but also a **random**
  range, an **actor stat** (level / EXP / HP / MP / max HP-MP / attack / defence /
  spirit / agility, and the **id of the item in each of the five equipment
  slots**), an **item** count (number held, or number equipped across the
  party), **game quantities** (party gold, timer seconds, party size, and the
  **save / battle / win / defeat / escape counts** — running tallies bumped by
  Save and by each Enemy Encounter and its outcome, persisted in the save), a
  **character position** (the hero's or a map event's map id / x / y / facing /
  **screen x / y** — an event's map id reads 0, matching an RPG_RT 2000 quirk;
  the screen coordinates are measured against the live camera, which
  `Scene::Map#camera_position` now exposes, with RPG_RT's own asymmetric offsets:
  X from the tile's centre, Y from its bottom) and, in a fight, a **monster
  stat** (RPG2003's battle operand — HP / SP / max HP-SP / attack / defence /
  spirit / agility of a troop member). An operand this build does not know (the
  Maniac patch adds nine more) now reads **0 and logs**, where it used to return
  the operand's own *selector* — so a 2003 game's battle operand wrote the troop
  member index into the variable and looked like a plausible number.
  Conditional Branch covers switch / variable / **timer** / gold / item /
  **vehicle** (is the party aboard the boat / ship / airship) / **orientation**
  (is the hero or a map event facing a given direction) conditions and **all**
  the **actor** sub-conditions (in party, name, level ≥, HP ≥, item equipped,
  skill known, and **afflicted by a state**). Actors now
  carry a **status-condition (状態) set** (`Game::Actor#states` with
  `add_state` / `remove_state` / `state?`; **Full Recovery clears it**), which
  persists in both the Marshal save and the `.lsd` (chunk 108 fields 81/82,
  previously parsed-but-unused) and is restored by `from_lsd`, so a real save's
  status ailments survive. The **item menu cures states**: a medicine's `state_set`
  names the conditions it **cures**, and using it removes them from the target
  (unconditional, matching EasyRPG's item algorithm); such an item counts as
  usable when the target is afflicted even at full HP.
  That polarity was read backwards at first — curing only when
  `reverse_state_effect` was *set* — and **no item in either test bed sets it**,
  so every shipped curative item was inert, in the menu and in a fight alike.
  Nepheshel has thirteen medicines naming states without the flag
  (アンチドーテ and ユニコーンの角 name all fifteen states; 気付け薬 /
  ドラゴンブラッド / ドラゴンハート name 戦闘不能 alone, so they are revives)
  and mtf-meido-action four. `reverse_state_effect` is what flips a medicine into
  *inflicting*, exactly as it does for a skill. A fixture check cannot catch
  a polarity error — it is written to match whatever the code does, and four of
  them encoded the wrong reading quite happily — so
  `rpg2k_testbed_logic_check.rb` now asserts against the **real** item table that
  every curative medicine cures exactly the states it names.
  ✅ **The inflict half (`reverse_state_effect` set) is now built too**, not
  guessed at: `Game::Party#item_inflicted_states` mirrors `#item_cured_states`
  the same way `#skill_inflicted_states` already mirrors `#skill_cured_states`
  for a field skill — both port the identical EasyRPG `reverse_state_effect`
  branch (`Item::vExecute` for an item, `Game_Battler::UseSkill` for a skill),
  and the item side's own doc comment already named the skill side as the
  reference before this landed. `#use_medicine` inflicts a reverse item's
  listed states on each target not already carrying them (applying RPG_RT's
  state-crowding-out prune, `Game::States.prune`, exactly as `#cast_skill`
  does for a landed skill state) and `#item_effective?` offers such an item
  when the target lacks a state it would inflict, so the menu does not grey
  out a poison item on an unafflicted target. No item in either test bed sets
  the flag, so this is unexercised by `rpg2k_testbed_logic_check.rb`'s
  real-data sweep — covered instead by new `scripts/rpg2k_logic_check.rb`
  checks built the same way the mirrored skill-side inflict behaviour already
  was, confirmed to fail against the pre-fix code (a `NoMethodError` for the
  missing accessor, then a wrong-effective-flag failure) before the fix.
  The **death state (戦闘不能, id 1)** is **coupled to HP** (EasyRPG's
  `kDeathID`): lethal `change_hp` knocks the actor out and inflicts state 1
  (zeroing HP), a downed actor can't be healed by HP changes, and curing the
  death state (or Full Recovery) revives at 1 HP — `Game::Actor#dead?`/`alive?`
  report it, and the KO'd HP-0 + state-1 pair round-trips through the `.lsd`. The
  **Change Condition** event command (10480) inflicts / cures a state on the
  target actors, so events can poison, cure, KO, or revive. **Field skills change
  status too**: `cast_skill` applies a skill's `state_effects` deterministically
  (EasyRPG's field `Game_Battler::UseSkill` — no accuracy roll), curing them by
  default and inflicting them when `reverse_state_effect` is set (the opposite
  polarity to items); states apply before HP so a revive skill (curing 戦闘不能)
  stands the ally up and its recovery then lands, and a cure skill is usable even
  at full HP. A **party wipe now ends the game** (a game-over-mode battle defeat
  puts up the Game Over screen, then the title — see the Enemy Encounter
  entry), and **so does one an event causes**: the twelve commands that can
  knock the party out on the map — Change Party Member / EXP / Level /
  Parameters / Skills / Equipment / HP / MP / Condition, Full Heal, Simulated
  Attack and Change Class — each re-check afterwards, through
  `Game::Interpreter#check_game_over` (EasyRPG's `CheckGameOver`), and suspend on
  the same `:game_over` wait the Game Over command raises. Both of RPG_RT's
  guards come with it: a battle-event page leaves defeat to the fight's own
  `[Defeat]` handler, and an **empty** party is not a wipe. Without this a
  Simulated Attack damage floor — Nepheshel runs 850 of them — could kill the
  party and leave the player walking the map with it. Enemies inflict states
  too now, by casting the status skills in their action pattern (see the
  行動パターン entry below). ✅ The item polarity gap this line used to flag
  (items only cured, never inflicted) is closed — see the item `state_set`
  paragraph above.
  ✅ **A wipe an event's Parallel Process itself causes now reaches Game Over
  too**, matching the foreground half above. `check_game_over` raises the same
  `:game_over` wait regardless of which interpreter calls it, but only
  `Scene::Map#drive_event` (the foreground dispatch) ever answered it —
  `#drive_parallel_wait`, the equivalent dispatch for a Common Event Parallel
  Process's own interpreter, had no `:game_over` case at all, so the request
  fell into the generic "background: ignore message/choice/teleport requests"
  branch and was immediately `#resume`d: the wait was silently cleared and the
  process carried on, leaving a fully-dead party free to keep wandering the
  map with no Game Over screen ever shown — e.g. a Simulated Attack damage
  floor or a poison Change HP running from a background Parallel Process
  rather than a foreground event. Fixed with a new `:game_over` branch in
  `#drive_parallel_wait` that calls `#perform_game_over`, now generalized
  (`def perform_game_over(interp = @interpreter)`, the same
  take-the-waiting-interpreter-explicitly pattern the Show Battle Animation
  fix above already established for `#drive_map_animation`) to stop whichever
  interpreter actually raised the wait rather than always the foreground one.
  The still-open `016_ikinari_end` battle-context race (a Parallel Process's
  own game-over check beating a concurrent Battle "On Lose" recovery branch)
  is untouched — `check_game_over` already returns early while `@battle` is
  set, so this fix only reaches the field/non-battle path. Covered by a new
  `scripts/rpg2k_scene_check.rb` check (a Parallel Process's own lethal Change
  HP puts up the Game Over screen and stops the rest of that process from
  running), confirmed to fail against the pre-fix code before the fix.
  **Show / Move / Erase
  Picture** (11110/11120/11130) are implemented: a `Game::Picture` per shown id
  (centre position, zoom, opacity, tone and the scroll-with-map flag) held on
  `Game::State`, decoded with EasyRPG's parameter layout (literal or
  variable-sourced coordinates, transparency → opacity); Move eases every
  parameter to its target over the duration and its wait flag suspends the
  interpreter (`:picture`) until the move settles; `Scene::Map` composites the
  pictures (id-ordered, zoomed via `stretch_blt`, at their opacity) into a layer
  above the map and below the message window. Picture **tone** is **drawn** now:
  the source is toned through the native `Bitmap#tone_blt` before compositing,
  cached per image + tone so the software pass runs on a tint change rather than
  every frame, and skipped entirely for a neutral picture. The channel conversion
  truncates toward zero to match the reference's C++ integer arithmetic (Ruby's
  `/` would floor, putting a channel one unit out), and RPG2000's saturation —
  which counts *down* from 100 to mean less saturated — inverts into RGSS's grey,
  which counts up. Unlike the map-layer tint this rides the path pictures already
  draw through (a blit into the shared picture bitmap), not the per-frame
  `Sprite#bitmap=` swap that attempt found does not reach the display. The
  RPG2003 test-bed is what justifies it: 128 of its 315 Show Pictures and 17 of
  its 117 Move Pictures carry a non-default tone, against 1 in all of Nepheshel.
  **Weather
  Effects** (11070) records the map weather type (none / rain / snow) and strength
  on `Game::State`, and `Scene::Map` now draws it: a screen-sized overlay sprite
  (z 430, above the weather-less tint layer and below the animation layer) onto
  which `draw_weather` paints rain streaks (falling, wind-skewed 1×6 marks) or
  snow (drifting 2×2 flecks), the particle count scaling with strength and the
  positions advancing with the scene's animation frame so the field animates.
  **Set Teleport / Escape Target** (11810 / 11830) record their payloads on
  `Game::State` — a per-map teleport-target registry, a single escape target —
  and round-trip through the save; the field menu's Escape / Teleport skill
  types now consume them (see the field-skill-menu entry below) — an event can
  register a destination for a warp spell to use. **Change Encounter Rate**
  (11740) and **Change System BGM** (10660) record their payloads too — the
  encounter step rate and per-slot system music overrides — and round-trip
  through the save, but nothing consumes them yet (the encounter system and
  battle scene's use of a system BGM slot are not built), so they are modelled
  for save fidelity like the access flags. **Change System
  SFX** (10670) is now consumed on the map: the choice window plays the cursor
  sound as the selection moves and the decision sound on confirm, resolving a
  Change System SFX override on `Game::State` before the database default
  (`Scene::Map#system_se` / `play_system_se`).
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
  buy / sell menus. Picking an item opens a **quantity counter** rather than
  trading a single unit: UP / DOWN step by one and RIGHT / LEFT by ten (RPG_RT's
  horizontal axis, so a stack of 99 is a few presses rather than ninety-nine),
  the count is clamped to `Game::Shop#max_buy` / `#max_sell` — whichever of
  affordability, the 99-item cap and what the party holds binds first, with a
  price-0 good limited only by the cap rather than dividing by zero — and one
  confirm commits the whole stack through `buy(id, n)` / `sell(id, n)`. Those are
  **all-or-nothing**: a count beyond what is allowed trades nothing rather than
  quietly trading fewer, so no path can overspend, and a zero or negative count
  is not a transaction (it cannot mint gold). An item with no room at all —
  unaffordable, or already capped — does not open the counter, and cancelling it
  returns to the list having traded nothing. Nepheshel opens 10 shops, so this is
  exercised content rather than a hypothetical.
  **Enemy Encounter** (10710) starts the battle path: `Game::Enemy` / `Game::Troop`
  instantiate a database enemy group into live members and total its EXP / gold
  (and `Troop#drops` rolls each member's treasure item against its `drop_prob`,
  granted to the bag on a win),
  and the command decodes its troop id, escape / defeat modes and first-strike
  and routes the `[Victory]` / `[Escape]` / `[Defeat]` handler branches on the
  outcome (the "end event processing" escape mode abandons the event). The
  interpreter suspends on a `:battle` wait, and `Scene::Map` resolves it by
  running a **turn-stepped auto-battle** (`Game::Battle`): battlers act in agility
  order, each striking a random living opponent for `max(1, atk/2 − def/4)`
  damage until one side is wiped (`:victory` / `:defeat`), granting the troop's
  EXP / gold on a win. `#step` performs one action at a time and appends a `#log`
  entry (attacker / target / damage / defeated), so an on-screen battle can
  animate it action-by-action; `#run` steps to completion for the headless
  resolution. It runs on Combatant snapshots, and `Battle#apply_to_party` then
  **writes each survivor's final HP back to its actor** when the fight ends
  (`Scene::Map#finish_battle`), so damage taken **persists** and a combatant
  reduced to 0 comes out **knocked out** (戦闘不能, via `Actor#set_hp`) — a level-up
  on victory does not heal. `Scene::Map` traces the fight to the console from the
  log.
  Encounters now open a **battle screen** (driven by `Scene::Map` during the
  `:battle` wait, like the shop / inn): a status panel of the troop and each
  party member's HP, and **per-actor commands each round** — for every living
  member the player picks **Attack** (choosing a target) or **Defend** (half
  damage, no attack that round), then the round executes in agility order,
  repeating until a side falls. Cancelling on the first actor flees when escape
  is allowed. `Game::Battle` has the round-based API (`command_attack` /
  `command_defend` / `command_skill` / `command_item` / `run_round`) alongside
  the headless `run`. The round now **animates action by action** (agility order,
  one hit per `BATTLE_ANIM_FRAMES`, HP/SP ticking and each blow bannered); the
  per-actor menu is **Attack / Skill / Item / Defend** (single-target skills and
  battle medicines reuse the field formulas); the enemy troop is **drawn as
  battler sprites** (`Monster/<battler_name>`, placeholder block fallback, hidden
  on death) over a plain battle field. **Post-battle HP now persists to the
  party** — `Battle#apply_to_party` writes each survivor's final HP back through
  `Game::Actor#set_hp`, so damage sticks and a member reduced to 0 comes out
  戦闘不能 — and a **defeat ends the game** (the Game Over screen, then the title,
  via `perform_game_over`) when the encounter's defeat mode is "game over" (no
  `[Defeat]` handler) and the party is wiped (`Game::Party#all_dead?`). **Status
  conditions carry through a battle**: a `Combatant` seeds its state set from its
  actor, a **battle medicine cures** its `state_set` (an antidote used mid-fight),
  and `apply_to_party` writes the surviving states back — so an ailment walks into
  the fight, can be cured there, and the result persists out. **Afflicted
  battlers now act on their conditions each turn**: `Battle` takes the database
  `situation` (state) table, and at the start of a battler's turn `apply_turn_
  states` slips HP/SP (fixed val + a percentage of the max, per EasyRPG's
  `ApplyConditions`) and **skips the turn** for a "do nothing" restriction (asleep
  / paralysed). **Attack skills inflict states**: `battle_skill_command` carries a
  scope-enemy skill's `state_effects`, and `apply_command` rolls each against the
  skill's `hit` accuracy on a surviving target — so a Poison Sting / Sleep spell
  afflicts the foe, which then slips or skips via the per-turn processing above.
  A state also **auto-recovers**: a per-battler turn counter lets `apply_turn_
  states` roll `auto_release_prob` once the state has held past its `hold_turn`,
  so a temporary ailment wears off. Three more of the 状態 row's fields are read
  now, and they are the ones that give the genre's most familiar statuses their
  meaning (ADR 0032): **`reduce_hit_ratio`** scales the afflicted attacker's
  accuracy, the lowest ratio winning when several apply, so **Blind blinds** —
  mtf-meido-action's cuts a 90% base to 19.6%, and since Blind is that field and
  nothing else it used to be purely cosmetic; **`release_by_attack`** rolls after
  a normal attack the target survives, so **a blow wakes a sleeper** (Nepheshel's
  睡眠 on 80% of hits) — normal attacks only, as RPG_RT does it, so a skill never
  shakes a status loose; and **`restrict_skill` / `restrict_magic`** seal a skill
  whose physical / magical rate reaches the state's threshold, so **封印 /
  Silence silence** — a sealed actor's skills leave the battle menu and a sealed
  enemy's action entry stops firing. Nine of Nepheshel's 25 states and two of
  mtf's ten carry a reduced hit ratio, four and three a release chance, two and
  one a seal.
  **And a status the target already has is announced** rather than going silent,
  in the state row's own `message_already` (「はすでに毒に冒されている！」, 15 of
  Nepheshel's states and 7 of mtf's). RPG_RT counts an already-carried state as a
  *success* and settles that **before** rolling the skill's accuracy, so a Poison
  Sting on an already-poisoned foe always reports and a 0%-accuracy skill reports
  too — making the report depend on the roll would be the natural guess and it is
  wrong. `roll_inflict` returns the already-carried states beside the landed ones
  and the action banner prints the sentence, one wording for both sides.
  `message_affected` is deliberately still unread: EasyRPG defines its helper and
  never calls it from either battle scene, so nothing pins when RPG_RT prints it.
  **A condition drains the party on the map now, too** — RPG2000's field poison,
  the last of the 状態 row's simulation fields with a game behind it.
  `hp_change_map_steps` / `hp_change_map_val` (and the matching SP pair) say how
  many walked tiles pass between drains and how much each takes; nothing read
  them, so an ailment defined as wearing the party down between fights did
  nothing outside a fight. `Game::State` counts walked tiles, and
  `Game::Party#apply_map_step_damage` drains every afflicted member whenever the
  count reaches a multiple of that state's own interval — **summed** across two
  slipping states rather than the worse one winning, which is the opposite of how
  the battle side picks a single significant state. The drain **cannot kill**: it
  goes through `change_hp` with death disallowed and floors at 1 HP, which is why
  this is the one party-damaging path that needs no game-over re-check, and a
  member already down slips nothing. `Scene::Map` counts a step for the player's
  own movement **and** for a forced move route (an event that walks a poisoned
  party across a field should drain it), one per landing so a jump counts once,
  but **not** for a teleport — the party arrives without walking, and counting it
  would let an event chain drain the party by shuffling it about. A draining step
  flashes the screen red, because the map has no HP display for the loss to show
  up on otherwise. The counter persists in the Marshal save; the `.lsd` keeps its
  own in the inventory chunk (109), whose step / turn fields are still
  deliberately undecoded, so a resumed real save starts counting from 0.
  mtf-meido-action's Poison (1 HP every 4 steps) is the only state in either test
  bed that carries the field, and `rpg2k_testbed_logic_check.rb` walks the real
  party through the real interval against it. **`affect_type` stat
  halving/doubling is read now too**: a state's `affect_type` (0 halve / 1
  double / 2 no change, the schema default) plus its four independent
  `affect_attack` / `affect_defense` / `affect_spirit` / `affect_agility`
  flags say which stat(s) it touches. `Battle#effective_atk` / `#effective_def`
  / `#effective_spi` / `#effective_agi` (EasyRPG's `Game_Battler::AdjustParam`,
  minus its battle-only stat-`mod` term, which this runtime has no equivalent
  of) feed basic-attack and self-destruct damage, to-hit's agility term,
  average agility (so escape chance answers it too) and turn order — so a
  Weaken-style state that halves ATK now actually softens a hit, and two
  states that cancel out (one halving, one doubling the same stat) net to no
  change, exactly as `AdjustParam`'s own `dbl != half` guard reads. **A
  battle Skill's power formula reads it too now**: `Game::Party#skill_effect`
  / `#skill_defence_term` turned out not to need the state-definitions table
  threaded in from anywhere new after all — `Game::Party` already holds the
  whole database (`@db`), `.situation` is that table, so `Party` grew its own
  copy of the same `stat_mode` / `effective_atk` / `effective_def` /
  `effective_spi` shape `Battle` has (reading `@db.situation` instead of a
  `Battle`'s own `@states`), used by both the caster and the target. It
  applies to field/menu skill casting too, not just in-battle skills — a bare
  `Game::Actor` (no `Battle` behind it at all) still has `#states`, and
  EasyRPG's own `GetAtk()` / `GetSpi()` are the one accessor every context
  reads through, not a battle-only variant, so a Weaken picked up mid-fight
  blunts a Cure cast on the map afterwards too. Also still unread: the
  RPG2003-only `avoid_attacks` / `reflect_magic`,
  which no state in either test bed sets.
  **The ground drains it too** — RPG2000's 地形ダメージ, the 地形 row's `damage`
  field (ADR 0034). Stepping onto a tile whose terrain carries one takes that
  much HP off every member who is not already down and is not wearing gear
  flagged 地形ダメージ無効 (`Actor#prevents_terrain_damage?`, read through the
  same `equipment_flag?` helper as the combat flags, so any slot grants it —
  mtf's is a pair of boots, Nepheshel's four include a swimsuit). It shares the
  step counter, the "cannot kill, floors at 1 HP" rule and the one red flash with
  the status slip above, so a step drains at most once from each and a teleport
  drains nothing. Both test beds define damaging terrain — Nepheshel's ダメージ床
  １/２ at 1 and 10 HP, mtf's Poison Swamp and Damage Floor at 1 and 2 — but a
  sweep of all 543 and 13 shipped maps finds **no map that places one**, so this
  is the rare rule the real data proves by its definition rather than its use.
  The same work fixed the terrain **tag**, which the whole terrain table hangs
  off: RPG_RT omits a chipset's 162-entry terrain array when every tile of it is
  terrain 1, and 96 of Nepheshel's 100 chipsets and 92 of mtf's do exactly that.
  Reading the absence as terrain 0 left 414,993 of Nepheshel's lower-layer tiles
  (and 1,530 of mtf's) naming an id no row matches — Store Terrain ID stored 0,
  boats and ships fell back to on-foot passability instead of the terrain's
  `boat_pass` / `ship_pass`, and the terrain battle backdrop below never
  resolved. `ChipSet#terrain` answers 1 for a missing table now, and reads the
  first lower tile's terrain for an id the chip index cannot reach.
  **And characters sink into it** — the terrain row's `bush_depth`
  (下半身消去 / 半透明表示, ADR 0035). The bottom of a character's sprite draws at
  half opacity on such a tile, RPG_RT's divisor form: `4 - depth`, a divisor
  above 3 meaning no effect, so depths 1/2/3 sink the lower 10, 16 and all 32
  rows of a charset frame. The sunken rows take `(opacity + 1) / 2` rather than a
  fixed 128, so an already-translucent event wading in goes fainter still.
  `Scene::Map#blt_bushed` does it as a solid top plus a half-opacity bottom, with
  the two degenerate cases (nothing sinks, all of it sinks) staying single blits;
  the hero sinks unless jumping or boarded, an event only on the hero's own layer
  and not mid-jump, and a tile-graphic event scales its split to its own 16px
  frame. This is the terrain field the test bed really *uses*: Nepheshel names
  four terrains after the effect (下半身3/1消去, 下半身2/1消去, 半透明表示,
  全身半透明) and lays two of them across **9,687 tiles of 28 maps**, every one
  of which drew the hero fully opaque before. Vehicles are deliberately left out
  — RPG_RT exempts only the airship, but no water terrain in either test bed
  carries a depth, so there is nothing to measure a boat's wading against.
  **Forced-action restrictions** work too: a
  `restriction` of 2 (berserk) forces a basic attack on a random enemy even when
  the battler was told to defend, and 3 (confused) sends the attack at a random
  member of its own side. Basic attacks **and attack skills** apply RPG2000's
  **damage variance** (a `var` of 4 for attacks, each skill's own `variance` for
  skills, spread via `Algo::VarianceAdjustEffect`), enabled for the live game and
  off for seeded / headless fights. A basic attack can land a **3x critical hit**
  at the attacker's database 1-in-N chance (actor `critical_rate`, enemy
  `critical_hit_chance`); no crit on a same-side hit. Characters wearing gear with
  the **`prevent_critical`** flag can never be crit. Four more **equipment combat
  flags** are read now (ADR 0033), each of them previously parsed and used by
  nothing: **二刀流** (`dual_attack`) makes a basic attack swing **twice** — 13 of
  Nepheshel's weapons — skipping the second blow when the first fells the target;
  **必中** (`ignore_evasion`, 13 more weapons) drops the agility term from the
  to-hit roll so the weapon hits at its own rate (82% → 98% against an agi-999
  foe), while the wielder's own blindness still applies on top, since what the
  flag ignores is the *target's* evasion; **MP消費半分** (`half_sp_cost`, any
  slot) halves a skill's cost rounding up; and **強力防御** (`strong_defence`, an
  actor-row flag 7 of Nepheshel's 50 actors carry including its hero) halves
  damage a second time while defending — a quarter, not a half.
  A weapon's **会心必殺 rate** (`critical_hit`) is read now as well — the largest
  count in that audit at **75 items** — and it is the one that could not simply
  be read, because RPG_RT *adds* the weapon's percentage to the wielder's own
  1-in-N rate and no denominator says "1/30 and 20% more". So criticals moved to
  a **probability**: `Game::Actor#crit_chance` / `Game::Enemy#crit_chance` return
  basis points over `Game::CRIT_SCALE` (10000), `Combatant` carries
  `crit_chance`, and `Battle#critical?` rolls against it. Integer basis points
  rather than a float keeps the damage path on the arithmetic the rest of it
  uses; the cost is that a 1/30 row reads 333 bp (3.33% against 3.3333…%), one
  crit fewer in ~300,000 swings. Rounding was **not** the only cost, though, and
  the other one was three orders of magnitude larger: the roll draws through
  `Rng#scaled`, not `Rng#random`, because the generator's period is prime and
  `next_int % 10000` therefore leaves its lowest 5537 values over-represented —
  precisely the range a roll-under-a-small-threshold test reads. Measured through
  the real `Battle#critical?`, that paid **every** crit chance out about 7% more
  often than its number said (a 333 bp chance landing 3.56%, a 3333 bp chance
  35.6%). `#scaled` multiplies across the period instead of taking a modulus of
  it, which is monotonic and so spreads the unevenness rather than piling it
  under the threshold; the same measurement then reads 3.335% and 33.338%.
  `#random` is untouched — every other caller passes a small `n` where it is
  correct enough, and changing it would reshuffle every seeded result for no
  gain. Only a **weapon** grants the bonus — the best
  among those equipped, the same shape `attack_hit_rate` uses — and Nepheshel's
  own bytes are what settle that rather than an appeal to EasyRPG's structure:
  69 of the 75 are weapons with a spread of rates (2..100), while the other six
  are armour and accessories carrying **exactly 100 apiece** next to a `hit` of
  70, another weapon-only field. That is the editor leaving weapon fields
  untouched in the record every item type shares, not six pieces of armour that
  critical every swing. Unlike the four flags above this one is *meant* to move
  the simulation, and it does: over every troop in both beds, Nepheshel goes from
  124 wins in 157 fights to **130**, and from 1620 swings to **1442** — its
  starting party wields a +2% weapon, lifting its hero from 500 bp to 700.
  mtf-meido-action, which has no such weapon and puts every actor on the plain
  1-in-30, drifts by five swings with no change of outcome: that is the roll
  changing shape, not the bonus. **`attack_all`** (全体化, 7 of Nepheshel's
  weapons) and **`preemptive`** (先制攻撃) are read now too: `Game::Actor#attack_all?`
  / `#preemptive?` follow the same weapon-only `equipment_flag?` shape as
  `#ignores_evasion?`. `attack_all` spreads a basic Attack across every living
  member of the already-resolved target's side (`Battle#side_targets`,
  `#swing_side` / `#attack_side`) rather than just the one target — including
  under a forced attack-enemy/attack-ally restriction, and including the
  attacker itself when confusion turns the target's side into its own (EasyRPG's
  `Normal::vStart`: "attack all enemies regardless of original targeting", and
  `AddTargets` has no self-exclusion). `preemptive` jumps its wielder's basic
  Attack to the front of the round's turn order (`Battle#turn_order` /
  `#preemptive_boost?`) — only a basic Attack qualifies, a Skill/Item/Defend
  with the same weapon keeps its ordinary agility slot, matching EasyRPG's
  `CreateExecutionOrder`'s own `Type::Normal` guard (which adds 9999 to such a
  battler's computed order — this build sorts the flag ahead of agility
  instead of reproducing that literal offset, since the per-round agility
  jitter `CreateExecutionOrder` also rolls is not itself modelled here, and
  the offset's only observable effect is "always first"). Still unread:
  **`raise_evasion`**, which has nowhere to land until the to-hit formula
  grows an evasion term separate from agility. **Elemental attributes**
  scale damage too: a weapon's `attribute_set` / a skill's `attribute_effects`
  are matched against the target's per-attribute defence ranks (A..E, strongest
  element winning) — the rates come from each attribute's own `a_rate` .. `e_rate`
  in the database `property` table (RPG2000 defaults 300 / 200 / 100 / 50 / 0),
  and a status infliction likewise reads the `situation` table's per-state rates
  — so a foe is hurt more by a weakness and can fully nullify an element it is
  immune to. The party can also
  **flee**: `Battle#attempt_escape` rolls EasyRPG's agility-ratio chance
  (`150 - 100·enemyAgi/partyAgi`, clamped), a preemptive first strike always
  gets away, and a failed attempt forfeits the party's round (every member
  skips, the enemies still act) while raising the next try by 10 points. Basic
  attacks can also **miss**: `Battle#to_hit` takes the attacker's base hit rate
  (weapon / unarmed 90, a "miss"-flagged enemy 70) and applies EasyRPG's
  agility-ratio adjustment (`100 - (100 - base)*(srcAgi + tgtAgi)/(2*srcAgi)`),
  so a nimble target dodges more; a missed swing deals no damage. A skill's
  **status infliction** is scaled by the target's `state_ranks` susceptibility
  (RPG2000's A..E table 100/80/60/30/0 percent), so a resistant foe shrugs it
  off and an immune one never catches it.
  **Conditions are now visible, not merely simulated.** All of the above moved
  state ids around inside `Game::Battle` while the battle screen showed none of
  it: the status panel listed a name and HP/MP, the action banner reported damage
  and nothing else, so a poisoned hero and a healthy one looked identical.
  `Game::States` reads the display side of the database `situation` table and the
  screen uses it in three places. The **status panel** gained a condition column
  showing the *significant* state — death first, then the highest `priority`,
  ties going to the later id (EasyRPG's `State::GetSignificantState`) — drawn in
  the state's own palette colour through `draw_system_text`, or the database's
  `normal_status` term when the battler is clear. That tie rule is not academic
  for Nepheshel: **22 of its 25 states share priority 50**, so which one shows is
  decided by it. The **action banner** announces every condition an action landed
  or lifted, using the state row's own sentences — `message_actor` /
  `message_enemy` for one landing, `message_recovery` for one lifting — which are
  worded from the speaker's side and really do differ: Nepheshel's 恐怖 reads
  「ゼロは恐怖に陥った！」 of a party member and 「スライムは恐れおののいた！」
  of an enemy, and 封印 flips 「の魔法が封じられた！」 to 「の魔法を封じた！」.
  Being downed goes through the same path as state 1, so it reads
  「スライムを倒した！」 instead of the invented `— defeated!`; a database with
  no sentence (Nepheshel's own unnamed state 11, and English releases generally)
  falls back to a composed line rather than printing nothing. Finally, a battle
  page's **Change Monster Condition** (13130) writes straight to the live
  combatant instead of queueing a request, so nothing told the panel it was
  stale — `apply_battle_event_requests` now rebuilds it, and a page that poisons
  the boss changes the screen as well as the fight.
  **The action lines come from the 用語 table now too** (ADR 0036), which is the
  larger half of the same argument: every round prints an action, where only some
  print a state. The log used to invent its English ("Hero hits Slime for 42");
  a field-by-field audit (`ruby scripts/rpg2k_field_audit.rb`, see below) found
  both test beds filling in **126 of the 127 term
  fields** while the runtime read two of them. `Game::States::BattleText` composes
  them as the predicates they are, and `battle_action_body` prints what the
  battler did and then what it did to the target, the way RPG_RT splits it:
  「スライムの攻撃！」 then 「リトは 7 のダメージを受けた！」. The particle is the
  one part not in the database — に for one of theirs, は for one of yours,
  pairing with the two `enemy_damaged` / `actor_damaged` predicates (the CP932
  branch of EasyRPG's `GetDamagedMessage`, and this build decodes every string as
  CP932 so there is no other branch). Every basic action is covered — attack,
  Defend, Observe, Charge, self-destruct, flee, transform — plus both damage
  sides, no-damage and misses; a blank term drops the **whole** entry back to the
  composed English, because a half-translated line reads worse than an English
  one.
  **A skill says it in its own words**, which is why a spell reads differently
  from a sword swing: the row carries two sentences of its own, and they compose
  differently — `using_message1` follows the caster's name like every other
  predicate while `using_message2` **stands alone** as a second line, so a spell
  reads 「リトは炎を放った！」 then 「あたりが真っ赤に染まる！」, a caster and then a
  scene. 229 of Nepheshel's 306 skills and 122 of mtf's 134 set the first, 18 the
  second. A skill that achieved nothing — a miss, or a recovery that restored and
  cured nothing — takes its own failure sentence rather than a damage line, picked
  by the row's `failure_message` from the three 用語 failure lines plus the dodge
  line at index 3; all four values are in real use (255/7/1/43 and 116/8/4/6).
  This needed the skill's **id** on the log entry, which carried only its name, so
  `command_skill` / `command_skill_all` take a `skill_id:` and the enemy AI path
  sets it from its own action. A skill row with no sentence keeps the composed
  wording, as a blank term does.
  **And a potion says what it did**: an item borrows the `use_item` term rather
  than carrying a sentence of its own, and it is the one line RPG2000 builds from
  *two* names — 「リトはポーションを使った！」 is the caster, は, the item and the
  term. What a heal restored reads in the game's words too
  (「リトのＨＰが 30 回復した！」), which the skill sentences had left blank. The
  pool name comes from the 用語 `hp` / `mp` field rather than a literal —
  Nepheshel writes them full-width as ＨＰ / ＭＰ and mtf as HP / MP, so a
  hard-coded "HP" would be wrong in exactly one of the two test beds — and a heal
  filling both pools says so once per pool. An item that did nothing keeps the
  composed wording, since unlike a skill it has no `failure_message` to pick a
  sentence with.
  Still held back on purpose: the **critical** line is left alone
  because which side keys `actor_critical` / `enemy_critical` is genuinely
  unclear — EasyRPG picks `actor_critical` when the *target* is an ally, while
  会心 / 痛恨 read as the *attacker's* side, and both games fill both fields with
  the same two strings so the data cannot settle it.
  The **field windows show a condition too** — the menu party list, the item and
  skill target lists and the status screen (a labelled row of its own), which are
  the three RPG_RT draws one in (`Window_MenuStatus`, `Window_ActorTarget`,
  `Window_ActorInfo`). The target lists matter most: they are where a player
  picks who to use an antidote on, and until now a downed actor read only as
  `HP 0/120`. All four windows and the battle panel go through one
  `Scene::Base#state_display`, so the menu and the fight cannot disagree about
  which state a battler is showing.
  A **pre-emptive first strike** (the
  Enemy Encounter's first-strike flag) gives the party a free opening round —
  the ambushed enemies skip their turn in round 1 and rejoin from round 2.
  **All-target skills** work too: a scope-1 (all enemies) or scope-4 (all allies)
  skill resolves against every living target in one action — `command_skill_all`
  spends the SP once and `apply_command` produces one log entry per target,
  buffered so the screen animates the volley hit by hit — with attack damage
  still computed per target's defence. **All-party items** (medicine scope 1)
  work the same way through `command_item_all`, healing / curing every living
  ally and consuming a single item for the whole volley. The **RPG2000 Game Over
  screen** exists now: `Scene::GameOver` fills the screen with the database's
  `GameOver/<name>` picture over its game-over music and returns to the title on
  a button press, reached by both routes RPG_RT uses — the Game Over event
  command (12420) and a battle defeat whose encounter says "game over" rather
  than running a `[Defeat]` handler. A game that names no picture (or whose file
  is missing) still reaches the screen, on plain black, rather than the defeat
  failing.
  **The battle backdrop is chosen from the game's own data now** rather than
  always being the flat void. RPG2000 keeps it on the map-tree node, not the map:
  `Game::Backdrop.name_for` reads the node's `backdrop_type`, a tri-state the
  editor's map-properties dialog offers and liblcf spells
  BGMType_parent / _terrain / _specific — 親マップと同じ (inherit), 地形で指定
  (the terrain being fought on names it) or 指定する (this map pins one file) —
  and the scene resolves it against the terrain under the party
  (`Scene::Map#encounter_backdrop`, via the terrain row's `background_name`).
  The inheriting case has to walk the tree, and it is the common one: **491 of
  Nepheshel's 537 maps and 4 of mtf-meido-action's 13 are type 0** and answer only
  through a parent. Resolving every map in both games shows the walk earning its
  keep — 475 of Nepheshel's maps reach their "black" interior backdrop purely by
  inheritance (plus one pinned boss backdrop) where a naive reading would leave
  them all on the flat field, while all 13 of mtf-meido-action's maps vary with
  the terrain fought on (Grassland / Desert / Snow Field / ...), the branch
  Nepheshel never takes since it names no terrain backdrops at all. The walk is
  bounded and cycle-safe, so a tree that loops ends at the terrain instead of
  hanging the battle.
  **Enemies now run their 行動パターン** (action pattern, enemy chunk 42) rather
  than only ever attacking — the single biggest silent gap left in the battle
  system, since **510 of the 959 enemy actions across the two test beds are
  skills** that could never fire. `Game::EnemyAction` decodes the table and
  `Game::Battle#choose_enemy_action` picks from it each turn: a port of EasyRPG's
  rating-based algorithm, which keeps the entries whose condition currently
  holds, finds the highest `rating`, drops everything more than 10 below it
  (`rating - max + 10`, floored at 0) and picks from the rest weighted by that
  adjusted rating — so a monster's behaviour shifts through a fight as its
  preferred moves stop being valid. All eight condition types resolve (always,
  switch, turn, party size, own HP %, own SP %, party average level and party
  fatigue), the turn condition reusing `Game::BattlePage.check_turns` with the
  same base / multiple argument order, and an unknown type keeps the action out
  of the running rather than firing it unchecked. Every kind executes: a
  **skill** goes through the same command pipeline the party casts with (so an
  enemy's spell is costed against its SP, scaled by the target's elemental
  resistance, rolled for accuracy and **inflicts its states** — which is what
  finally lets a monster poison or sleep the party, the last enemy-cast gap), an
  ally-scoped skill **heals a fellow monster**, an all-scope skill hits every
  living target in one action; a **transformation** re-points the combatant at
  another database enemy (name, stats, ranks and its new pattern, HP/SP clamped
  to the new maxima); and the basic actions cover attack, **dual attack** (two
  swings, the second skipped if the first felled the target), **defend** (the
  guard halves the next blow and expires at that enemy's next turn), observe,
  **charge** (the next attack lands doubled — a critical takes precedence, per
  EasyRPG's `CalcNormalAttackEffect` — then the charge is spent),
  **self-destruction** (`atk - def/2` across the living party, killing the
  caster, per `CalcSelfDestructEffect`), **escape** (out of play without counting
  as a kill, like a page's Force Flee) and do-nothing. An action's post-run
  switch on / off is applied, so a monster's move can drive the troop's
  battle-event pages. `Game::Battle` stays database-free: it reaches the skill /
  enemy tables, the switches and the party's average level through a new
  `Game::EnemyAi` collaborator, and without one (the seeded harness fixtures) an
  enemy falls back to plain attacking exactly as before, so every existing
  result is unchanged. Exercised over real data: all 300 Nepheshel enemies and
  all 115 of mtf-meido-action's decode a pattern, and running every troop in both
  games (157 and 88 fights) completes without error with 1980 and 1193 skill
  casts landing where there were none. `ruby scripts/analyze_game.rb --enemies
  <game>` reports a game's patterns the way `--troops` reports its battle pages.
  A **transformed monster is redrawn** with the battler it turned into: the
  combatant carries its `battler_name`, and `Scene::Map#refresh_battle_sprites`
  rebuilds any sprite whose battler no longer matches the one it was drawn from
  (an unchanged battler is left alone, so the field does not churn every frame).
  **Every RPG2000 map / common-event command now has a handler.** The last gaps
  closed were Change Skills (10440), Simulated Attack (10500), Change Actor Face
  (10640), Enter/Exit Vehicle (10840), Flash Sprite (11320), Fade Out BGM
  (11520), Play Movie (11560), Tile Substitution (11750) and Open Save Menu /
  Open Main Menu (11910 / 11950), together with the last two Conditional Branch
  tests (the decision key started this event; the BGM has played through once).
  Three opcodes that never matched liblcf's `Code` enum were corrected in the
  same pass — Change Equipment is 10450 (10440 is Change Skills) and Game Over is
  12420 — so those commands are recognised in real game data at all.
  **Coverage is measured per opcode, though, not per parameter combination**, and
  the next pass closed two gaps a dispatched-but-partial handler was hiding —
  both found by tallying the *parameter* modes the real Nepheshel data uses
  against what each handler actually branches on:
  - **"This event" (0 / 10005) now resolves on the read side.** The write-side
    commands (Move Event, Change Event Location, Flash Sprite) queue their raw
    target for the scene, which knows which event it is stepping, so those always
    worked. The commands the interpreter answers itself did not: a **Conditional
    Branch** orientation test on this event was always false (223 of Nepheshel's
    233), the **Control Variables** character operand read its position as 0 (239
    of 246) and a **Call Event** naming another page of this event silently did
    nothing (17 of 33). `Game::Interpreter#event_id` now carries the running map
    event's id — set by `Scene::Map` beside `map_info`, and re-attached on every
    lap of a parallel process — and every character reference goes through
    `#character_ref`. It is nil for a common event and a battle page, which have
    no "this event" in RPG_RT either, so such a reference resolves to nothing.
  - **Show Choices honours its cancel setting.** param0 is the cancel behaviour
    as a 1-based option index: 0 forbids cancelling, 1..4 makes the cancel key
    pick that choice, 5 runs a dedicated **[Cancel] branch** — which the editor
    stores as a *fifth* option (index 4) with an empty label. It was being drawn
    as a blank extra row that shifted the routing of every option below it. Only
    options 0..3 are listed now (EasyRPG's `GetChoices(4)`), and `Scene::Map`
    backs out of a cancellable choice on the cancel key with the system cancel
    sound. 336 of Nepheshel's 349 choice blocks are cancellable; 27 carry a
    [Cancel] branch that could not be reached before.
  **The RPG2003-only commands are handled now as well** — the low opcodes the
  2003 editor emits for what RPG2000 never had, none of which had a handler
  while the opcode table stopped at the shared set. **Change Class** (1008)
  re-points an actor at a database class (職業, chunk 30 / `db.job`): equipment is
  stripped, the class row takes over the growth curve, the learn table and the
  EXP curve (`Game::Actor#curve_row`, mirroring how EasyRPG's `GetBaseMaxHp` /
  `LearnLevelSkills` / `CalculateExp` branch on `class_id > 0`), EXP resets to
  the new level's threshold, and the command's skill mode (keep / reset / add)
  and parameter mode (keep / halve / the class's level-1 or current-level values)
  both apply; an actor whose row names a class reads its curves from startup, and
  the change survives Save / Continue. **Change Battle Commands** (1009) edits
  the actor's 戦闘コマンド list with RPG_RT's six-plus-Row capacity rule.
  **Force Flee** (1006), **Enable Combo** (1007) and **Call Common Event** (1005)
  run inside a battle-event page — Force Flee either grants the party a
  guaranteed escape or hides the troop members that run (out of the fight, not
  killed), playing the database escape SE. **Open Load Menu** (5001) and **Exit
  Game** (5002) leave the map for the loader / quit; **Toggle Fullscreen** (5004)
  and **Open Video Options** (5005) are logged no-ops because this build's
  display backend has neither, the same answer EasyRPG gives on a platform whose
  window cannot change mode. Still open here: **Toggle ATB Mode** (5003), which
  needs the RPG2003 ATB battle system this runtime does not model, so it is
  deliberately left as a reported gap rather than a silent no-op; and the combo
  an Enable Combo arms is recorded on the actor but never spent, for the same
  reason. The opcodes were read out of liblcf's `EventCommand::Code` enum, which
  also corrected `analyze_game.rb` — it had Change Class / Change Battle Commands
  at 12610 / 12710, numbers the enum does not define at all.
  **Battle-event pages now run too**: a troop's pages (`enemy_group` chunk 11)
  are evaluated by `Game::BattlePage` at the start of every turn — switch,
  variable, turn, enemy-HP and actor-HP conditions — and each matching page runs
  through a `Game::Interpreter` carrying a `battle` context, so a page has the
  whole ordinary command set plus **Change Monster HP / MP / Condition**
  (13110 / 13120 / 13130), **Show Hidden Monster** (13150), **Change Battle
  Background** (13210), the battle **Show Battle Animation** (13260),
  **Conditional Branch** (13310 with its `_B` markers) and **Terminate Battle**
  (13410). Messages from a page are shown in a battle panel. The flag bits are
  **validated against real bytes** — `ruby scripts/analyze_game.rb --troops
  <game>` reports a game's troop pages, and Nepheshel's 2819 conditional pages
  confirm the `switch_a` / `switch_b` / `turn` / `enemy_hp` bits and show that
  every battle-only command it uses has a handler (see the comment on
  `Game::BattlePage` for what each bit is confirmed by). The **RPG2003
  conditions resolve now too**: each `Combatant` carries its own `battle_turn`,
  bumped as that battler's turn begins (EasyRPG's `Scene_Battle::NextTurn`), so
  `turn_enemy` / `turn_actor` read real per-battler counters through the same
  base/multiple arithmetic; and `fatigue` is `Game_Party::GetFatigue`'s formula —
  HP two thirds of the weight, SP the other third, an SP-less party dividing by
  1 rather than 0. A page whose condition box is **entirely unticked never runs**,
  which is RPG_RT's reading of "no trigger" and the opposite of how every other
  RPG2000 page kind treats vacuous conditions; both test beds carry such pages
  (446 of Nepheshel's 3265, all 88 of mtf-meido-action's) and every one is empty,
  so no real game changes behaviour. **The `command_actor` (chosen battle
  command) condition never firing is confirmed correct, not a gap**: it needs
  the battler whose action triggered the check, and EasyRPG's
  `AreConditionsMet` only evaluates it when handed one (`if (!source) return
  false;`) — but `Scene_Battle_Rpg2k::CheckBattleEndAndScheduleEvents`, the
  *only* page-scheduling call site RPG2000's own battle scene has, always
  calls `ScheduleNextPage(nullptr)`. A real `source` only ever exists in
  `Scene_Battle_Rpg2k3`, the separate ATB battle scene this runtime does not
  model (see Toggle ATB Mode below), so a page gated on `command_actor` is
  *never satisfiable* under RPG2000's own battle system — not a once-per-turn
  evaluation standing in for a future per-actor one. Still open: video
  playback for Play Movie (no decoder is linked in; the request is logged). **Show Battle Animation** (11210) now plays on the map — the
  scene composites the animation's cells from its `Battle/<name>` sheet over the
  target frame by frame and fires its screen flashes, holding the event with the
  wait flag (per-cell zoom / tone and target-only flashes are approximations for
  now). **Set Vehicle Location** (10850) and **Change Vehicle Graphic** (10650)
  place a boat / ship / airship and set its CharSet (persisted via
  `Game::Vehicle`), and the party can now **board and pilot** a placed vehicle on
  the map (`Game::State#boarded`; the airship flies over any tile whose terrain
  allows it — the database terrain's `airship_pass` flag, default true — and
  lands only where `airship_land` allows, touching down **in place** rather
  than stepping onto the tile ahead the way a boat / ship disembarks onto the
  shore; boat / ship follow their terrain's `boat_pass` / `ship_pass`).
  Placed vehicles are **drawn on the map** from their CharSet, the
  ridden one following the party under the hero, and the **airship floats above a
  ground shadow**. Boarding **plays the vehicle's own BGM** (the database System
  boat / ship / airship music) and disembarking restores the map BGM. **Enter Hero Name**
  (10740) opens a character-entry widget that renames a
  party actor; **Change Level** (10420) / **Change EXP** (10410) honour their
  "show message" flag — a level-up queues one message per level gained, shown
  through the message window before the event continues (a small reusable
  pending-message queue on the interpreter); **Change System Graphics** (10680)
  overrides the windowskin / font (save chunks 15 / 17; the scene reloads the
  skin); **Change Screen Transitions** (10690) sets the six teleport / battle
  transition styles (save chunks 111–116), which an Erase / Show Screen's "use
  the configured transition" now reads; and **Game
  Over** (12520) returns to the title — all handled. **Vehicle locations** (boat /
  ship / airship) also persist in the save (`Game::Vehicle`, `.lsd` chunks
  105–107 / the Marshal save).
- 🚧 Message window — renders text lines and a choice cursor and expands the
  common message control codes (`\v[n]` variable, `\n[n]` actor name, `\\`,
  `\_` space). `\n[n]` names the **live** actor out of the roster rather than the
  database row, so a hero the player named through Enter Hero Name is called what
  they chose — Nepheshel renames actor 1 and then writes `\N[1]` in 34 messages —
  and `\n[0]` is the **party leader** (actor ids are 1-based, so it used to
  expand to nothing and left the boss line `\n[0]よ…` without its subject). An
  actor the game has never instantiated still falls back to the database name.
  Text now **reveals gradually** (a `Game::TextReveal` typewriter
  driven by `Scene::Map`, with a button press completing the reveal before
  dismissing), and the **pacing codes act**: `Game::Message.scan` surfaces
  `\!` (wait for a button), `\.` / `\|` (¼ / 1-second holds), `\^` (close the
  window without a keypress) and `\>` / `\<` (an **instant span** that reveals in
  one frame) in revealed-character coordinates; the reveal halts at each pause
  until released and collapses each instant span (still stopping at a pause that
  falls inside it). `\$` opens a small **gold window** (the party's money)
  alongside the message, closed with it. `\c[n]` **colour codes** are
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
  only when no windowskin loaded or for an out-of-range index. When the message
  is **not pinned** (`position_fixed` off, the RPG2000 default) the window now
  relocates to keep clear of the hero — top when the hero sits in the lower half
  of the screen, bottom otherwise — so talking to something at a map's bottom
  edge shows the text up top; the exact zone boundary is approximate pending a
  wine diff, but the direction matches RPG_RT. ✅ **The mirrored-face flag is
  now honoured too.** Change Face Graphic's param2 (`cfg.face_flipped`) was
  already read, stored on `Game::MessageConfig` and persisted through the
  save, but `Scene::Map#draw_message_face` never looked at it — the flag was
  wired end to end except for the one place that would have made it visible.
  `RGSS::Bitmap#blt` has no flip primitive of its own (`mruby-rgss`'s own
  `Sprite#mirror=` resorts to the same per-pixel software pass, for the same
  reason), so a new `#build_face_cell` crops the selected 48x48 cell out of
  the FaceSet sheet once, at message-open time, into a small dedicated
  bitmap: a single blit normally, or 48 single-column blits in
  source-column-reversed order when mirrored — done once per message rather
  than re-deriving the crop rect from the raw sheet on every reveal frame,
  since `#draw_message_face` runs every frame the typewriter is still
  revealing. Covered by two new `scripts/rpg2k_scene_check.rb` checks (an
  unmirrored face crops in a single blit from the right cell; a mirrored one
  crops in 48, with the sheet's leftmost/rightmost source columns landing on
  the destination's rightmost/leftmost columns), both confirmed to fail
  against the pre-fix code before the fix.
- ✅ Common events — auto-start common events run once on the map, and parallel
  common events now run **continuously** in the background alongside the player
  via their own looping interpreter (`Scene::Map#step_parallels`), each gated by
  its switch when `need_flag` is set (re-checked every frame, so toggling the
  switch starts/stops it). Background processes honour `Wait` but do not drive
  the message/choice UI (those requests are skipped) — full parallel UI is a
  later refinement
- 🚧 Screen effects — the game **timer** works (Timer Operation command +
  `Game::Timer`) and is **drawn**: the start operation's "show timer" flag makes
  `Scene::Map` show a small window counting down as `M:SS`. There are **two**
  timers — RPG2003 adds a second, selected by the command's sixth parameter, read
  back by Control Variables selector 9 and by Conditional Branch type 10, and
  drawn in its own window to the right of the first (RPG_RT parks the pair at the
  screen's left and right edges as digit sprites off the System graphic; drawing
  them that way is a rendering-parity job of its own). The start operation's
  second flag — **keep running in battle** — is honoured: without it a timer
  pauses *and* hides for the duration of a fight rather than being stopped. Two
  RPG_RT details this used to get wrong are fixed from EasyRPG's
  `Game_Party` timer block: **set** seeds `seconds * 60 + 59` (so a freshly-set
  timer holds the number it was given for a whole second instead of dropping one
  after a single frame), and **stop hides it** — the countdown reaching zero goes
  through that same stop, which is how a finished timer leaves the screen instead
  of sitting at `0:00`. Both timers persist in the save, and a save written
  before the second one existed still loads. The **Tint Screen**
  (11030) command now drives a
  `Game::Screen` tint state machine on `Game::State`: it interpolates the four
  RPG2000 channels (red/green/blue/saturation, 0..200) toward their target over
  the command's duration (advanced each frame by `Scene::Map`), and the wait
  flag pauses the interpreter until the effect settles (a `:screen` wait,
  resumed by the scene once `Game::Screen#busy?` clears). The **darkening** half
  of the tint now draws: `Scene::Map` overlays a black screen sprite (below the
  flash / fade overlays) whose opacity approximates how far the tone averages
  below neutral, so a night / cave tint dims the map. A full tone — the colour
  cast, brightening above neutral and saturation — still needs an
  `RGSS::Viewport` tone in C++. **Shake Screen**
  (11050) also drives `Game::Screen`: a timed, float-free triangle-wave
  horizontal offset (amplitude from power, rate from speed) that `Scene::Map`
  subtracts from the camera, so — unlike the tint — the shake **is** visible
  with the current renderer. **Flash Screen** (11040) drives `Game::Screen` too:
  a colour + strength that fades to zero over the duration, and it **is** drawn:
  a screen-sized colour sprite above everything, shown at the flash's strength
  through `Sprite#opacity`. **Pan Screen** (11060) drives
  `Game::Screen` as well: lock / unlock freeze or resume the camera's hero
  follow, and pan / reset scroll a pixel offset toward a target that `Scene::Map`
  adds to the camera (so — like the shake — the pan **is** visible; while locked
  the view holds where locking began). **Erase Screen** (11010) / **Show Screen**
  (11020) drive `Game::Screen` too: a fade level (0 visible .. 255 black) held
  erased until a Show, drawn by the same screen-sized sprite mechanism as the
  flash. All share the `:screen` wait, so event timing around them is correct.
  **Show Picture** now renders (see the interpreter bullet above).

  Those two commands now run their **actual transition style** rather than one
  fixed fade. `Game::Transition` ports EasyRPG's transition model: the two
  parameter → style tables (the same index means the "out" style to an erase and
  the "in" style to a show), each style's own length — 35 frames for a fade, 41
  for the shaped ones, 1 for a cut, 0 for "no transition" — and the frame-by-frame
  geometry. Parameter **-1**, "use the configured transition", is by far the most
  common value in real data (2124 of Nepheshel's 2146 Erase Screens) and used to
  fall through unresolved; it now reads the Change Screen Transitions slot, which
  `Game::State#seed_screen_transitions` fills in from the database's System
  settings (chunks 61–66) at New Game and after a load — including a `.lsd` slot
  the save left un-overridden, which comes back out of range rather than as a
  setting. `Scene::Map` draws a shaped transition as a **mask**: the erase overlay
  goes fully opaque and the regions of the map still showing through are punched
  back out of it with `fill_rect`, which is exactly how RPG_RT composites the
  screen being left against the screen being arrived at (one of the two is always
  solid black). That draws the blinds, the vertical / horizontal stripes and the
  border-to-centre / centre-to-border windows for real. Remaining: the styles a
  black mask cannot express — the scrolls and the combine / division pairs slide
  the live scene itself, zoom / mosaic / wave resample it, and random blocks wants
  thousands of block blits a frame — which run as a fade of the right length and
  the right end state for now.

  **That remainder was written up as blocked on a screen capture the renderer
  does not have. It is not: `RGSS::Graphics.snap_to_bitmap` exists, is tested
  (`mruby-rgss/test/test.rb`), is enabled on the builds that draw
  (`LV_USE_SNAPSHOT` in `include/lv_conf.h`; the Wio/PSP builds compile it out
  and it answers nil there), and the **RPG Maker XP scene already uses it**
  (`mruby-rpgxp/mrblib/scene.rb`) for exactly this — its own transitions.** The
  same mistake as the fade/flash note below: a capability assumed missing that
  was already there. What was left per style (scroll and combine / division are
  now done — see below):

  - ✅ **Scroll (settings 9–12)** and **combine / division (13–15)**: capture the
    outgoing screen once when the transition starts, then each frame paint the
    overlay as the full composite — black plus the capture blitted at the
    sliding offset — rather than as a mask. `Bitmap#blt` is enough; no native
    work. The overlay is opaque and above everything, so painting the whole
    frame into it is what lets the scene appear to move, which a mask cannot do.
  - **Zoom (16)**: the same, with `stretch_blt` instead of `blt`.
  - **Mosaic (17) / wave (18)**: per-pixel resampling. `get_pixel`/`set_pixel`
    exist but a full-screen loop per frame in Ruby is far too slow, so these are
    the only two that genuinely want a native pass.
  - **Random blocks (1–3)**: expressible as a mask already; it needs the
    *incremental* paint RPG_RT uses (only the newly-covered blocks each frame,
    ~120 of 4800) rather than repainting every block, which is why it was left.

  One wrinkle a Show Screen has and an Erase does not: its capture is of the
  screen being arrived at, and `snap_to_bitmap` grabs the rendered screen
  *including* the erase overlay that is currently hiding it. RPG_RT's equivalent
  draws everything below the transition layer only
  (`Graphics::LocalDraw(..., GetZ() - 1)`); here that means hiding the fade
  sprite around the snapshot. Worth confirming in the real binary before
  building on it — the RPG2003 test-bed uses zoom / mosaic / wave twelve times,
  which is what makes the family worth finishing (`ruby scripts/analyze_game.rb
  --params --code 11010 data/mtf-meido-action/Debug`).

  **Scroll and combine / division are done.** `Game::Transition#capture_ops`
  computes, per style, where each piece of a captured screen goes this frame
  (a plain offset for the four scroll directions; two sliding pieces for
  vertical/horizontal combine and division; four for cross), staying pure
  logic exactly like `#visible_rects` above — no `Graphics` access, so it is
  unit-testable without a renderer. `Scene::Map#draw_captured_transition`
  snapshots the screen once (on the frame a captured `Game::Transition`
  instance first appears, by object identity, so a same-style transition
  right after it still re-snapshots) and blits the pieces over a black fill
  every frame after, disposing the snapshot once the transition ends. The
  wrinkle above did not end up mattering in practice: a shaped transition still
  runs a plain fade at the moment a captured one starts (the two families
  never chain outside a hand-built sequence), so there was no erase overlay
  hiding the scene to worry about excluding — worth revisiting if that
  assumption stops holding. Cross combine/division's exact quadrant motion
  (diagonal from each screen corner) is this build's own reading, not
  confirmed against RPG_RT — neither test bed exercises that specific style,
  so the vertical/horizontal pair's confirmed-by-name motion was extended
  rather than guessed from nothing. Covered by new checks in
  `scripts/rpg2k_scene_check.rb`. Zoom, mosaic/wave and random blocks are
  still unbuilt, per the per-style breakdown above.

  The fade and flash overlays were listed here as blocked on `RGSS::Viewport`
  tone/alpha support in C++. **They were not**: `RGSS::Sprite#opacity` already
  maps onto LVGL's per-object alpha at blit time, so a screen-sized sprite of
  solid colour shown at the effect's strength is the entire mechanism, in Ruby.
  Confirmed in the real binary before the code was written — forcing the fade
  layer to opacity 128 halves the rendered frame's mean brightness (31.9 → 15.2).

  Both the **weather** particle overlay and the **tint** (Tint Screen) layer are
  now composited by `Scene::Map` alongside the fade and flash. The tint really
  does need native work, unlike the fade and flash — a tone rescales what is
  already drawn rather than laying a colour over it. That native half now
  exists: `RGSS::Bitmap#tone_blt(src, tone)` copies a bitmap applying an
  RGSS `Tone` (desaturate toward luminance by `gray`, then add the per-channel
  offsets), covered by `mruby-rgss/test/test.rb`. It writes to a separate
  destination on purpose — the map layers are redrawn only when they change, so
  an in-place tone would re-tint an already-tinted layer every frame and walk it
  to black.

  **Nothing calls it yet.** A first attempt at wiring it through `Scene::Map`
  (tone each scene-owned layer into a shadow bitmap, point the sprite at the
  shadow) was written and then dropped rather than shipped: instrumentation
  confirms the code runs and finds its four layers, but the rendered frame is
  unchanged — a forced full-strength green tint moved the frame's mean green by
  0.09/255. So the remaining work is not the tone maths but finding why a
  per-frame `Sprite#bitmap=` swap does not reach the display; suspects are the
  sprite's cached canvas source and the dirty-flag sweep in
  `mruby-rgss/src/lib.cxx`. Note the obvious probe is misleading: the Nepheshel
  opening is nearly black (frame mean ~32/255), where a *subtractive* tint
  changes almost nothing even when it is working — use an additive one
- ✅ Random ("wandering monster") encounters — until now the only way to start
  a fight was a scripted Enemy Encounter event command; the map tree's own
  encounter list (`map_properties` field 41 `enemy_groups`, field 44
  `encount_steps`, 25 by default) went unread. `Scene::Map#check_random_encounter`
  ports EasyRPG's `Game_Player::UpdateEncounterSteps`: every ordinary
  (non-forced) step adds the stepped-on tile's terrain `encounter_rate`
  (database terrain field 3, 100 by default) to a running total, whose ratio to
  the map's step count is looked up in RPG_RT's own encounter table
  (`ENCOUNTER_TABLE`) to scale that step's chance of a fight — the chance rises
  the longer a walk goes without one, rather than staying flat. A hit picks a
  uniform-random troop from the current map's own list, filtered by each
  troop's `terrain_set` (enemy_group field 5; an entry too short to reach the
  tile's terrain tag defaults to allowed, the same rule this runtime's other
  bit tables already follow), and opens the battle through a new
  `Game::Interpreter#start_random_battle` — the same request shape and
  `:battle` wait an Enemy Encounter command builds, minus the
  [Victory]/[Escape]/[Defeat] handler routing (a random encounter is not a
  command in any list, so there is nothing to route back into): escape is
  always allowed and a wipe is always game over. First strike rolls RPG2000's
  own 1-in-32 chance (EasyRPG's `Rand::ChanceOf(1, 32)` under
  `Feature::HasRpg2kBattleSystem`; 2003's back-attack / pincer terrain rolls
  are a different battle system this runtime does not model). Flying (the
  airship) is RPG_RT's one blanket exemption, matched here via
  `Game::Party#flying?`; a forced move route (a Move Event on the player, or
  Proceed With Movement) never rolls either, tracked by a new
  `@player_forced_step` flag set at the two places a player slide can start —
  matching EasyRPG's own gate on ordinary input-driven movement only.
  `Change Encounter Rate` (11740) overrides the map's own step count for the
  rest of the visit; the running total persists across a save
  (`Game::State#encounter_total`, matching EasyRPG's own
  `total_encounter_rate`), while the encounter-table row it last reached does
  not, matching EasyRPG's own unsaved `last_encounter_idx`. Covered by new
  `scripts/rpg2k_scene_check.rb` checks (a guaranteed roll opening the right
  troop, an empty list never firing, `terrain_set` filtering, the airship
  exemption, a forced route never rolling despite a guaranteed-roll setup, and
  the step-count lookup / override / default / disable cases)

#### Menus, save, battle
- 🚧 Menu scene — opens over the map (cancel button); shows party status and a
  command list. Save, End Game, **Item**, **Skill**, **Equip** and **Status** all
  work — the full main-menu set. The **Item** command opens
  `Scene::ItemMenu`: it lists the party's usable **medicines** (database item type
  6), **skill books** (type 7) and **seeds** (type 8) with their held counts. A
  medicine heals its target — a single-target item a chosen ally, an all-ally item
  (scope 1) the whole party — restoring HP/SP (flat + percentage of max, clamped);
  a skill book teaches its skill (item field 53) to a chosen ally who does not
  already know it; a seed permanently raises a chosen ally's base stats (the
  item's `max_hp_points` / `max_sp_points` and the `*_points2` stat set, applied
  through `Actor#change_param` so the stat caps hold). Each consumes one on a use
  that had any effect, and greys out / reports a use with no effect (a full
  target, an actor who already knows the skill, or a seed with no boost). The
  **Equip** command
  opens `Scene::EquipMenu`: it shows a party member's five equipment slots and
  stats (LEFT/RIGHT cycle members), and for a chosen slot lists the bag's fitting
  items (plus Remove); equipping swaps the previously-worn item back into the bag
  and recomputes stats. The **Status** command opens `Scene::StatusMenu`: a
  read-only per-member detail (name/title, level, EXP and EXP-to-next, HP/MP, the
  six stats and the equipped items; LEFT/RIGHT cycle members). The **Skill**
  command opens `Scene::SkillMenu`: it lists a caster's known field-usable normal
  skills (LEFT/RIGHT cycle casters) with their SP cost; casting a self / all-ally
  skill applies at once and a single-ally skill asks who to target, spending SP
  and restoring HP/SP by the RPG2000 effect formula (`power +
  physical_rate*atk/20 + magical_rate*spirit/40`, deterministic in the field —
  battle adds variance). The decision logic is on `Game::Party` (`field_items` /
  `item_recovery` / `item_effective?` / `use_item` for items; `equip_candidates` /
  `equip_from_bag` / `unequip_to_bag` for equip; `field_skills` / `skill_cost` /
  `can_cast?` / `skill_effect` / `cast_skill` for skills) and `Game::Actor`
  (`next_level_exp` / `exp_to_next` for status), covered by
  `scripts/rpg2k_logic_check.rb`; the RGSS windows are the untestable-here UI.
  A **switch item** (type **10**, not 9 — see below) is field-usable too:
  `Game::Party#use_switch_item` consumes one and returns the game switch it turns
  on, which the item menu then sets (matching EasyRPG, where the scene owns the
  switch table). A **special item** (type 9, 特殊) invokes the skill named in its
  `skill_id`, with the item standing in for the SP cost — the user pays nothing
  and need not have learnt it, which is what Nepheshel's whole thrown-bomb line
  is. **Switch skills** (type 3) flip their switch: that is how a Nepheshel
  player summons and dismisses a companion.

  What decides usability is the **type**, not the occasion flags, and getting
  that wrong used to leave the battle skill menu **empty in both test beds** —
  306 skills and 134 skills, none offered. `occasion_field` / `occasion_battle`
  gate **switch skills only** (RPG_RT reads them in one arm of
  `Algo::IsSkillUsable`, and the editor only offers the checkboxes there); an
  RPG2003 **subskill category** (type >= 4) is an ordinary skill filed under a
  custom battle command, which is 57 of mtf-meido-action's 134 including all its
  healing; and an item's occasion flags are `occasion_field1` (bars battle use),
  `occasion_field2` and `occasion_battle` (a switch item's own pair) — this build
  asked for `occasion_field`, a name no real row carries, so the gate silently
  never fired. An earlier version of this list claimed that gate worked; it did
  not, on any genuine item. See ADR 0031. **Escape and Teleport skill types now
  warp the party.** Both were declared unbuilt here — Escape wanting nothing
  more than its one registered target and Teleport wanting "a destination
  picker this build has no screen for" — and both gaps are closed the same way
  EasyRPG's own `Scene_Skill` closes them: `Algo::IsSkillUsable`'s
  `Type_escape` / `Type_teleport` arms (not in battle — already true, since
  `#battle_skill?` excludes both types unconditionally; the party's access
  flag; a registered target; not flying) became
  `Game::Party#escape_skill_available?` / `#teleport_skill_available?`, read by
  `#field_skill?` given the `Game::State` the field menu now passes it (every
  older caller, including the fixture checks, still omits it and gets the old
  "unsupported" reading). Casting spends SP through the same `#can_cast?` gate
  every other field skill uses and returns the destination for
  `Scene::SkillMenu` to queue on `Game::State#pending_teleport` rather than
  jumping directly — the menu is not `Scene::Map` and has none of its map-load
  machinery, so the actual jump happens back there, the way the interpreter's
  own Teleport command already does, just queued from a different source and
  picked up (then rendered immediately, not left a frame stale) the moment
  `Scene::Map` is next on top of the scene stack. Escape warps straight to its
  one target with no prompt, matching `Scene_Skill`'s own "no picker" branch;
  Teleport opens a third list beside the skill/target ones, built from every
  `Game::State#teleport_targets` entry and named through the map tree's own
  `map_properties` (`Game_Map::GetMapName`), the same source the battle
  backdrop's terrain walk already reads. A registered target's own `switch_id`
  is round-tripped through the save but — like EasyRPG's `Window_Teleport`,
  `Game_Targets` and `Scene_Teleport`, none of which read it back — still left
  unconsumed here too; nothing in the reference implementation gates the list
  by it, so filtering here would be a guess the real binary does not make.
  Casting either skill also forces the party off a ridden boat or ship first
  (mirroring `Game_Player::ForceGetOffVehicle`), leaving the vehicle parked
  where it was boarded; the airship is not forced off because it is not
  boarded off at all — `#flying?` (`state.boarded == :airship`) bars both
  skills outright, the one vehicle RPG_RT excludes them from. `Party#unsupported_field_skill?`
  stays (renamed in spirit, not in name): the testbed harness builds a party
  with no map or interpreter behind it, so it still cannot tell "this skill is
  legitimately state-gated" from "no menu reaches this skill" on its own, and
  keeps deferring those two types to this note instead of flagging them as
  unreachable. Left unbuilt still: the battle-time skill variance, and a
  **special item** (type 9) invoking an Escape/Teleport skill —
  `#field_usable?` does not thread `Game::State` through to `#field_skill?`
  the way the field menu does, so such an item (neither test bed has one)
  would still read as unusable rather than warping.
  **Dual-wield equipping is done too, the opposite rule to two-handed.** A
  weapon's own *combat* effect (a 二刀流 weapon swinging twice) was read
  already (ADR 0033); what remained was the *actor*-row 二刀流 (`double_hand`,
  4 of Nepheshel's actors and 1 of mtf's), which turns the shield slot into a
  second weapon slot — ADR 0040 named this as the item its own two-handed-gear
  rule left alone. `Game::Party#equip_candidates(slot, actor)` retargets the
  shield slot to weapon-only candidates for such an actor, ported from
  EasyRPG's `Window_EquipItem` (which does the identical retarget before
  filtering, and rejects a shield there outright with no exception); a new
  `#equip_candidate_for?` guards `#equip_from_bag` against the reverse. Placing
  the result needed `Actor#equip_item` to take an explicit slot — its old
  always-by-type mapping would put any weapon in slot 0, which is exactly
  wrong for a second one — while the Change Equipment event command's own call
  stays untouched (no notion of "the second weapon slot" there either,
  matching `Game_Actor::ChangeEquipment`). Combat needed nothing: the weapon-
  only scans behind `#attack_hit_rate` / `#weapon_crit_bonus` /
  `#equipment_flag?` and the plain sum behind `#equip_bonus` already read every
  equipped slot by the item's own *type*, not by slot index, so a second
  weapon in the shield slot is picked up — the better of the two, for hit and
  crit — the moment it is worn. See ADR 0040's addendum.
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
  name is in the title chunk). Both save paths carry the **whole actor roster**,
  not just the current party: chunk 108 holds one entry per actor the party has
  ever held (which is what a genuine RPG_RT save holds), so a companion who is
  out of the party when the game is saved is written out and read back rather
  than being silently dropped — `.from_lsd` used to skip exactly those rows. See
  ADR 0030
- Battle system — enemy groups, battle scene, actions/damage/states,
  animations (large; Nepheshel uses the default RPG2000 battle). Needs real
  assets + the native build to develop against. The game-over scene is done
- ✅ Menu screens — the Item, Skill, Equip and Status screens all exist now (see
  Menu scene above). The Skill screen's recovery formula (`power +
  physical_rate*atk/20 + magical_rate*spirit/40`) is the same one the battle
  system will reuse for skills; battle adds the +/- variance the field path omits

#### Assets & infrastructure
- ✅ Audio playback — `RGSS::Audio` now plays real BGM/BGS/ME/SE through an
  SDL_mixer backend (`src/sdl_audio.cxx`), resolving names under
  `Music/`/`Sound/`/`Audio/*`
- ✅ MIDI music — `scripts/download-freepats.bash` installs the FreePats patch
  set into `assets/timidity` (git-ignored, ~32 MiB), which drives SDL_mixer's
  built-in TiMidity synthesiser, so the `.mid` BGM that RPG2000 projects ship is
  audible (ADR 0026). `TIMIDITY_CFG` overrides the patch set;
  `Audio.midi_available?` reports whether one was found. Remaining polish:
  pitch/tempo control (SDL_mixer exposes none), MIDI for SE/BGS (they play as
  samples, which are never synthesised). The browser build plays MIDI too: the
  Emscripten SDL2_mixer port is asked for `-sSDL2_MIXER_FORMATS=ogg,mid` (it
  defaults to OGG-only, so it had no MIDI decoder at all) and the patch set is
  mounted at `/timidity`, at ~32 MiB of `index.data`. `-DWASM_MIDI_PATCHES`
  defaults to `AUTO`, packaging the patches once they have been downloaded, so
  a page built the documented way plays MIDI rather than failing every `.mid`
  load; CI passes `ON` because its download races the configure
- ✅ RTP resolution / `FullPackageFlag` (issue #40) — `RPG_RT.ini`'s
  `FullPackageFlag=1` clears `RTP_DIR`, and `Bitmap` lookup already falls back
  from the game directory to the RTP (with `.png`/`.xyz`/`.bmp` extensions)
- ✅ Default UI font — `scripts/download-default-font.bash` installs M PLUS 1p
  Regular into `assets/fonts` (git-ignored, ~1.7 MiB, SIL OFL), which the
  XP/VX/MV/MZ runtimes fall back to when a project ships no font of its own,
  instead of drawing every window with the 12px shinonome bitmap font (ADR
  0028). `RPG_DEFAULT_FONT` overrides it; the `default_font` ctest
  (`scripts/check_default_font.rb`) validates what was installed and skips when
  nothing was. RPG2000 deliberately keeps shinonome — its metrics are what the
  RPG_RT parity comparisons measure — so the fallback is opt-in per maker via
  `RGSS::Font.default_path`. The browser build mounts the font at `/fonts` with
  `-DWASM_DEFAULT_FONT=ON`, at ~1.7 MiB of `index.data`
- ✅ **Battle animations** — every skill and every item in both test beds names
  one (306/306 and 1200/1200 in Nepheshel against a 500-row table, 134/134 and
  100/100 in mtf against 150) and none of them played: a fight was a status
  panel, a line of text and an HP number going down. The animation was top of
  `scripts/rpg2k_field_audit.rb` by a wide margin. The frame-by-frame player the
  map's Show Battle Animation command (11210) already used is now shared —
  `build_animation(id, tx, ty, battle)` takes an explicit id and target pixel,
  and `battle` means the two things that differ: the pixel is a screen position
  rather than a map one (so the draw skips the camera) and nothing is waiting on
  it (so the step skips `@interpreter.resume`). `drive_battle_animate` paces the
  round by the animation in place of the fixed banner timer, and reads the id off
  the skill / item row the entry's `skill_id` / `item_id` names — plumbing ADR
  0036 already put there. It plays centred on the targeted enemy's sprite, found
  by the target's **index** so two monsters sharing a name cannot be confused, or
  over the middle of the screen for an action aimed at a party member, since
  RPG2000's first-person battle draws no ally sprite. Left for their own changes:
  a **plain attack's** animation (RPG2000 takes it from the equipped weapon,
  which the entry does not carry), the `position` field (whole screen / target /
  above / below — carried but not acted on, so everything draws centred), and
  per-cell tone and scale, which the map path has never had either. See ADR 0037.
- ✅ **Which fields the games set that the runtime never reads** —
  `ruby scripts/rpg2k_field_audit.rb`. A survey, not a check (it asserts nothing
  and always exits 0): for every scalar database field it counts the rows of the
  real test beds that set it away from its schema default, and reports the ones
  whose name appears nowhere in `mruby-rpg2k/mrblib`. A field the schema parses
  and the runtime never mentions is a feature the author paid for and the player
  does not get, and the row count is a decent proxy for how much of the game that
  is. Six of this runtime's RPG2000 decisions came out of asking that question
  (ADRs 0031-0036), and none of them was visible to the fixture suites: in every
  case the fixtures encoded the same assumption as the code, because they were
  written to match it. Only a real game's tables disagree. The name search is
  crude in one direction on purpose — a field named only in a comment counts as
  read, so the list under-reports and never over-reports. A row is a question,
  not a defect: the script carries a `NOT_OURS` table of fields checked against
  EasyRPG and deliberately left alone (`levitate` and `state_chance` are RPG2003
  only, `message_affected` has no known trigger, and the two critical-hit terms
  are side-keying-unresolved, ADR 0036), so nobody re-derives them.
- ✅ **Drain skills** (吸収, the skill row's `absorb_damage`) — 13 of Nepheshel's
  306 skills and 5 of mtf's 134 set it and nothing read it, so every drain spell
  in both games was an ordinary attack spell, and the two 用語 sentences that
  report one (`enemy_hp_absorbed` 「奪った！」 / `actor_hp_absorbed` 「奪われた！」,
  filled in in both) had nothing to report. The rule that matters is the **clamp
  order**: RPG_RT limits the effect to the target's current HP *before* applying
  it ("Only absorb the hp that were left"), so a 200-damage drain on a 30 HP foe
  **deals 30 and returns 30** — the drain is weaker against a nearly-dead target,
  not merely capped in what it gives back, and reading it the other way round
  (full damage, capped healing) is the natural implementation and the wrong one.
  The caster still stops at its maximum. Only offensive skills drain, as RPG_RT
  gates it, so a healing skill that sets the flag drains nothing. The log line is
  close to the recovery line and differs in three places — の / は by side where
  recovery always takes の, を rather than が after the pool name, and a separate
  predicate per side — and it is **additive**: a database with no drain wording
  drops that sentence rather than the whole entry, since the damage line above it
  still reads. SP drain is left out: an RPG2000 skill has one flag rather than a
  pair and neither test bed has a negative-SP skill to measure it against, and the
  stat drains EasyRPG also supports are RPG2003. See ADR 0038.
- ✅ **蘇生専用 items** (the item row's `ko_only`) — unread, and all four items
  that set it across the test beds are revives that cure 戦闘不能 **and** restore
  a percentage of max HP (Nepheshel's ドラゴンブラッド 25%, ドラゴンハート 100%,
  気付け薬 3%; mtf's Stimulant 25%). That shape is what made the field matter:
  reading it as nothing did not merely let the *cure* fire pointlessly on a
  living ally — the cure is a no-op there anyway — it let the **HP restore**
  fire, so all four were wastable as percentage heals and ドラゴンハート was a
  full heal that way, with the field menu offering them as effective. RPG_RT
  returns from the item algorithm **before both** the HP and the state effects
  (EasyRPG's `Item::vExecute` puts the `ko_only && !IsDead()` return ahead of the
  state loop, with the HP block further down), so the answer is "does nothing at
  all". `Party#ko_only_blocked?` gates `item_effective?` (the menu greys it out)
  and `use_medicine` **per target**, so an all-party revive passes over the
  members who never fell rather than topping them up — the case that reading
  actually decides, since a single target would be hidden by the menu gate. See
  ADR 0039.
- ✅ **The skill damage defence term** (ADR 0041) — an enemy-scope skill's damage
  was `skill_effect - target.def / 4`. The effect half was already RPG_RT's; the
  defence half was invented here. RPG_RT blunts the skill with the **same two
  rates that built the effect**: `physical_rate * def / 40 + magical_rate * spi /
  80`, so a physical skill is stopped by armour and a magical one by the target's
  spirit (and the divisors differ — spirit is worth half as much per point in
  defence as in offence). The flat term coincides with that only for a purely
  physical skill at rate 10: **211 of Nepheshel's 276 enemy-scope skills and 112
  of mtf's 116** differ from it against a def-40/spirit-40 target. The column that
  matters most is the **222 purely magical** skills across the two games — every
  one was being blunted by the target's *armour*, a stat RPG_RT does not let them
  see, so a plated knight resisted fire with his plate. `ignore_defense` (防御無視,
  13 and 7 skills) is read at the same time and skips the **whole** subtraction,
  not just the physical half. A missing stat absorbs nothing rather than raising,
  and a skill costed against no target takes the full effect. Left alone: the
  `dmg = 1 if dmg < 1` floor, where RPG_RT floors the effect at 0 and lets a 0
  land as a "no damage" line — a separate divergence, visible in the log rather
  than the formula, and folding it in would have hidden this change inside it.
- ✅ **両手持ち weapons** (the item row's `two_handed`) — unread, so a claymore
  and a shield could be worn together and both bonuses counted. Not a rare flag:
  **35 of Nepheshel's 104 weapons** and **14 of mtf's 26**, more than half that
  game's arsenal. ADR 0033 audited the equipment *combat* flags and did not reach
  this one, because it is not a modifier but a constraint on what may be worn at
  once. The weapon and shield slots are now mutually exclusive whenever **either**
  holds a two-handed weapon — both slots are tested, so equipping a shield over a
  claymore drops the claymore just as the claymore drops the shield; reading only
  the incoming item would let the shield win by going second. The flag counts
  only on a weapon, as RPG_RT tests the type alongside it (and no non-weapon in
  either game carries it, which the test-bed check asserts). The emptied hand
  returns its item to the bag rather than vanishing, since the equip menu swaps
  through the inventory. A bulk `equip` — loading a save, initial equipment —
  does **not** enforce it: RPG_RT stores what it stores, and enforcing on load
  would silently drop a shield the save really held. Left for its own change:
  `double_hand` (二刀流 on the *actor* row, 4 Nepheshel actors and 1 of mtf's),
  which turns the shield slot into a second weapon slot — the same pair and the
  opposite rule, and the menu's candidate list for slot 1 has to change with it.
  See ADR 0040.
- ✅ **使用可能キャラ item restriction** (`actor_set` / `actor_set_size`, item
  field 62/61) — parsed by the schema but never consulted, so an item or piece
  of gear reserved for one named character (a signature weapon, a class-locked
  scroll) could be equipped or used by anyone. `Party#item_usable_by?(it,
  actor_id)` reads the bit at `actor_id - 1`, defaulting an entry the array is
  too short to reach to allowed — the same "missing = the field's default"
  reading every other bit-array field here follows (EasyRPG's
  `Game_Actor::IsItemUsable`). Wired into every path that reaches an item:
  `item_effective?` (menu grey-out) and `use_medicine` / `use_skill_book` /
  `use_seed` / `use_special_item` (the effect itself — `use_medicine` checks it
  **per target** the same way `ko_only_blocked?` already had to, so a
  restricted member is skipped even under an all-party scope rather than only
  being caught by the single-target menu gate); `equip_candidates` /
  `equip_candidate_for?` (the equip menu's own candidate list and
  `equip_from_bag`'s validation); and the **Change Equipment** event command
  (10450, `do_change_equipment` in `interpreter.rb`), which EasyRPG's
  `ChangeEquipment` gates through the identical `IsItemUsable` call — checked
  per target there too, since a command can target the whole party at once.
  Covered by new `scripts/rpg2k_logic_check.rb` checks (the read itself, the
  all-party-scope per-target skip, menu greying-out, equip-menu filtering,
  and the event command). **The previously-left-open half is now fixed
  too**: the battle screen's own ally-target picker
  (`Scene::Map#draw_battle_ally_target` / `#drive_battle_ally_target`) used
  to read straight off `#living_allies` with no `actor_set` awareness at
  all, so a restricted medicine/item could still be picked — and its effect
  actually applied — against a party member the field menu already refused
  to let it touch. Fixed with a new `Scene::Map#battle_ally_targets`, which
  narrows the candidate list by `item_usable_by?` whenever the pending
  action is a Battle Item (a pending skill is untouched, since `actor_set`
  never gates skills); `Game::Party#battle_item_command` itself stays pure
  arithmetic, unchanged — the gate is about which target may be *offered* at
  all, not what the formula computes once one legitimately is. Covered by a
  new `scripts/rpg2k_scene_check.rb` check (a two-actor party where the item
  excludes the second actor: the picker offers only the first, and moving
  the cursor has nowhere to go), confirmed to fail against the pre-fix code
  before the fix.
- ✅ **物理回避率アップ** (the item row's `raise_evasion`, field 26) — unread, so
  a shield/armour/helmet/accessory bought specifically for its evasion bonus
  was purely a stat stick against a normal attack. `ruby
  scripts/rpg2k_field_audit.rb` against a freshly re-downloaded Nepheshel
  flags it with 12 rows once `two_handed`/`actor_set`/the rest above stopped
  crowding it out. EasyRPG's `Game_Actor::HasPhysicalEvasionUp` scans every
  equipped **non-weapon** slot for the flag (`ForEachEquipment<false, true>`,
  weapons excluded by item type, not slot index — the same rule
  `#equip_bonus` already follows for stat sums, so a 二刀流 actor's second
  weapon in the shield slot is correctly excluded too), and
  `Algo::CalcNormalAttackToHit` subtracts a flat 25 from the already
  agility-adjusted hit chance for such a target, right after the AGI term
  and never reached at all when the attacker's own weapon is 必中 (that
  branch already returns before either term). Ported as
  `Game::Actor#physical_evasion_up?` and a new `Combatant#evasion_up` field
  (`Battle.from_actor` wires it, an enemy Combatant leaves it nil/false —
  monsters equip nothing) consulted by `Game::Battle#to_hit` in the same spot.
  Covered by new `scripts/rpg2k_logic_check.rb` checks (the flat -25, the
  0..100 floor, 必中 skipping the term entirely, weapon-slot exclusion, and
  an end-to-end `Battle.from_actor` wiring check), confirmed to fail against
  the pre-fix code before the fix.

### yado.tk quirks backlog

[yado.tk](http://yado.tk/) is a Japanese fan reference cataloguing specific,
undocumented-elsewhere behavioural quirks of the genuine RPG_RT.exe (RPG
Maker 2000/2003 runtime). Unlike the rest of this file, the section below is
a **raw backlog to triage**, not a record of shipped work — items move up
into "Fixed" or "Confirmed already correct" as they're checked against the
codebase and, where needed, against real RPG_RT. **Every one of the 471 distinct subpages linked from the front page has now
been read** (plus the site's own update history, `page/reki.htm`), across
two passes: an initial manual pass (the front page, `011_siyou/`'s ~140
quirks, and 13 `09_bug/` pages) and a full sweep of the remaining ~457
pages in 34 parallel-agent batches covering every category — 初心者
(beginner), 主人公・パーティー・乗り物 (hero/party/vehicles), イベントコ
マンド (event commands, 110 pages), スイッチ・変数 (switches/variables),
マップイベント (map events), 特殊技能・アイテム (skills/items), 自作メ
ニュー (custom menus), 自作戦闘 (custom battle, 44 pages), デフォルト戦闘
(default battle), バグ・エラー (remaining bug pages), データベース
(database, 48 findings alone), 画像加工 (image processing), その他 (misc),
and 演出 (presentation/effects, 59 pages). The consolidated, deduplicated
findings from that full sweep are in the **"Full-site sweep"** subsection
below; the earlier hand-picked findings stay in the sections immediately
following this paragraph as the original record.

#### Fixed
- ✅ Event **priority type** (page `layer`: below/same/above characters) now
  gates collision (`passable?`/`char_passable?`/`char_can_land?`/
  `vehicle_passable?`), not just draw order — only "same as characters"
  blocks movement.
- ✅ The **decision key** only answers a below/above-characters action event
  (trigger 0) by tile overlap, never by facing it from an adjacent tile —
  only "same as characters" answers by facing (yado.tk: 決定キーを押しても
  マップイベントが実行しない, `2k/09_bug/025_ibento_kettei_huka/`).
- ✅ Set Move Route **Change Graphic** targeting the hero now actually
  changes the on-screen sprite (it applied to `@player_char` but the
  renderer never read it), and reverts on Transfer Player like real RPG_RT
  (not persistent like the dedicated Change Hero Graphic command).
- ✅ **"Has item X" now counts an equipped copy, not just the bag**
  (`Game::Party#has_item?`, behind Conditional Branch's item condition and an
  event page's item appearance condition). Equipping an item removes it from
  `item_count`'s bag tally, and RPG_RT's possession test still reads it as
  held; the numeric "item possession count" operand (Control Variables) stays
  bag-only, matching RPG_RT's own split between the two reads. Covered by new
  `scripts/rpg2k_logic_check.rb` checks.
- ✅ **Move route continuation across a page switch.** `build_event` used to
  always build a fresh `Game::MoveRoute` on every page (re)selection, so a
  custom route in progress restarted from the top on *any* page switch, even
  one that changed nothing about the route. `Game::MoveRoute.same_route?`
  compares two pages' raw `move_route` fields (commands, repeat, skippable)
  byte-for-byte, and `Scene::Map#rebuild_events_preserving_positions` now
  carries the **old route object** — index and done-ness included — across
  the rebuild when both the old and new page are on a custom route and the
  two describe the identical route; anything else (a different route, or no
  custom route on one side) still restarts, matching RPG_RT. Covered by two
  new `scripts/rpg2k_scene_check.rb` checks (identical route keeps its place;
  a changed route restarts).
- ✅ **The page-level "doesn't overlap another event" flag now gates
  collision** (`overlap_forbidden`, LCF page field 35 — parsed since it was
  added to the schema but never read). It is a *fourth*, independent
  collision axis on top of priority type: a blocker with it set collides
  regardless of the mover's layer (a below-characters "pen gate" still blocks
  a same-layer NPC wandering through it), and a mover with it set likewise
  collides with a blocker of any layer — wired into all five call sites that
  already gated on layer (`passable?`, `char_passable?`, `char_can_land?`,
  `vehicle_passable?`, `airship_landable?`), the same set the priority-type
  fix above touches. `Game::Character` gained a matching `overlap_forbidden`
  accessor, set from the active page in `build_event` alongside `layer`.
  Covered by two new `scripts/rpg2k_scene_check.rb` checks (a below-characters
  blocker with the flag set still stops the hero; two events on different
  layers no longer pass through each other when the blocker sets it).
- ✅ **The active party caps at four members.** `Game::Party#add_actor` had no
  size check at all, so a Change Party Member "Add" past the fourth slot grew
  `@actors` unbounded instead of no-op'ing the way RPG_RT does (the editor
  never offers a fifth party slot). `Game::Party::MAX_SIZE` (4) now guards the
  join; leaving and rejoining once a slot frees up still works, and nothing
  about `remove_actor` or the roster's rejoin-with-preserved-state changed.
  Covered by a new `scripts/rpg2k_logic_check.rb` check.
- ✅ **A batch (range) Control Variables random-assign now rolls
  independently per variable**, not once for the whole group.
  `Game::Interpreter#do_control_vars` computed its operand value a single
  time before the range loop and applied that one value to every id in the
  range — harmless for a constant or a variable/item/actor read, but wrong
  for a random operand (type 3), where `Var[1..5] = random 1~6` must be five
  separate dice, not one roll broadcast to all five. The random case is now
  re-evaluated per id inside the loop; every other operand type keeps its
  existing once-up-front evaluation, since nothing establishes RPG_RT
  re-reads a *non-random* source per id (a self-referential range reading a
  variable inside its own write range is a different, unverified question).
  Covered by a new `scripts/rpg2k_logic_check.rb` check (a wide-range batch
  assign must not produce the same value in every variable).
- ✅ **Indirect ("pointer") target addressing now no-ops on a resolved id
  ≤0**, instead of writing switch/variable slot 0 or a negative one.
  `Game::Interpreter#range`'s mode-2 (indirect) branch resolves the pointer
  variable's value with no bounds check at all, and `Switches`/`Variables`
  are plain Hash-backed with no guard in their write path either — so a
  `Control Variables`/`Control Switches` command addressed indirectly
  through a pointer variable holding 0 or a negative number was writing to
  that bogus key rather than doing nothing, the way RPG_RT's target-role
  indirect addressing does (the **operand**-role read side already handled
  this correctly, via `Variables`/`Switches`' own missing-key default).
  `range` now returns an already-empty range for a ≤0 resolved index,
  reusing the same "does nothing" mechanism a descending batch range
  already relies on. Covered by a new `scripts/rpg2k_logic_check.rb` check,
  confirmed to fail against the pre-fix code before the fix.
- ✅ **A Common Event's Parallel Process now survives a Transfer Player and a
  save/load**, instead of always restarting from the top. Within one map
  visit this was already modelled correctly — `step_parallel`'s
  `gate_switch` resumes the same interpreter, so a process paused by its own
  gate switch turning off mid-run genuinely freezes at that exact command —
  but `perform_teleport` and `Scene::Map#initialize` unconditionally rebuilt
  *every* parallel process from scratch via `build_parallels`, and
  `Game::State#to_h`/`to_lsd` had no field at all for an interpreter's
  position. Fixed in two parts, matching the two ways this codebase's
  `Scene::Map` is (re)built: `build_parallels` now keys its previous
  `@parallels` entries by common-event id and, across a Transfer Player
  (which mutates `@map`/`@state` on the *same* `Scene::Map` instance rather
  than building a fresh one), reuses the still-running `Game::Interpreter`
  entry outright — full fidelity (call stack, in-flight Wait countdown,
  everything), since nothing is actually serialised. A genuine save/load
  builds a brand-new `Scene::Map`, so there is no live object to reuse;
  `Game::Interpreter#resumable_index` returns the interpreter's current
  index whenever it is safely capturable (not paused inside a nested Call
  Event, whose frames nothing tracks how to re-resolve — `@call_stack` must
  be empty), `Scene::Map#step_parallel` records it on the new
  `Game::State#common_event_progress` (id → index) every tick, and
  `Scene::Map#new_parallel` seeds a fresh interpreter from it via the new
  `Game::Interpreter#start_at` on the very first `build_parallels` for a
  scene. A tick caught mid a nested call simply leaves the last known-good
  checkpoint in place rather than clearing it, so a save taken there resumes
  at the last clean position, not the top. A Map Event's own parallel
  process is untouched — it has no common-event id to key either mechanism
  off, and keeps restarting fresh on every visit, exactly as before. The
  `.lsd` export still does not carry this: LCF save chunks 113
  (`SAVE_FOREGROUND_EVENT`) and 114 (`SAVE_COMMON_EVENT`) are known to hold
  exactly this kind of execution state (a real save taken from an on-screen
  choice keeps that choice's option strings inside chunk 113's blob) but
  their internal byte grammar is undocumented and stays an opaque
  `int8_array`, so only the portable Marshal save persists a Common Event's
  parallel-process position — decoding that grammar against a real save
  taken mid a Parallel Process is a still-open follow-up. See ADR 0044.
  Covered by new `scripts/rpg2k_logic_check.rb` checks (the plain
  `#resumable_index`/`#start_at` contract, including the nested-call-stack
  and finished-process nil cases, and `common_event_progress` round-tripping
  through `#to_h`/`.load`) and new `scripts/rpg2k_scene_check.rb` checks (an
  end-to-end Transfer Player check proving both the command index and the
  in-flight Wait countdown survive untouched; an end-to-end save/load check
  built around this section's own example — a gate switch turning off
  mid-run, then a save/load, then the switch turning back on; and a check
  pinning that a map event's own parallel process still gets a brand-new
  interpreter, restarting at index 0, on every visit), all confirmed to fail
  against the pre-fix code before the fix.

#### Confirmed already correct (no action needed)
- Wait 0.0 seconds already costs exactly one frame (not a no-op) —
  `do_wait`/`drive_wait` in interpreter.rb / map.rb.
- Battle Event page selection already differs correctly from Map/Common
  event selection: `Game::BattlePage.select_all` runs **every** satisfied
  page once per turn, lower page number first, vs. `Game::EventPage.select`
  picking only the single highest-numbered page for map/common events.
- **Call Event has no indirect mode for a common-event id, matching
  RPG2000's own editor.** `Game::Interpreter#resolve_call`'s mode 0 (common
  event) arm always reads `cmd.param(1)` literally; only mode 2 (map event)
  reads its ids out of variables (`map_event_call(variables[cmd.param(1)],
  variables[cmd.param(2)])`). RPG2000's Call Event dialog genuinely offers
  no "select the common event indirectly" option, so a designer wanting a
  variable-selected common event has to build an if/elsif dispatcher chain
  of literal Call Events — this codebase's command format already mirrors
  that constraint rather than working around it. Covered by two new
  `scripts/rpg2k_logic_check.rb` checks (a variable holding a different id
  never steers mode 0's target; mode 2 genuinely does resolve both the event
  and the page indirectly, making the asymmetry explicit).
- **A Parallel Process that reaches its own end already costs exactly one
  frame before its next lap starts.** `Scene::Map#step_parallel` only
  restarts a finished process (`it.start` + `it.update`) the *next* time it
  is called — one real game frame later than the frame whose `#update` made
  `it.running?` go false — rather than restarting within the same call, so
  there is always exactly one idle frame between a lap ending and the next
  one's first command. Already covered by the existing `scripts/
  rpg2k_scene_check.rb` checks `'parallel (trigger 4): a background event
  runs every frame'` and `'Wait 0.0 sec doubles a parallel process lap gap
  to two frames'` (the latter's own comment names this exact one-frame gap);
  this bullet only records that the yado.tk claim is the same fact, not a
  new one.
- **Jump to Label already matches the three documented yado.tk facts.**
  `Game::Interpreter#do_jump_label` does a linear scan of `@list` (the
  current page/common-event's own flat command array) from index 0 and
  returns on the first `Label` command whose id matches, which is all three
  claims at once: it can only ever land inside the *same* block since
  nothing else is searched (no cross-page/event list exists to jump into);
  it works from any position because the scan always restarts at 0
  regardless of where `@index` currently sits, so a jump issued before,
  after, or anywhere around the target label finds it the same way; and a
  duplicate label id always resolves to the first (topmost) occurrence
  because `each_with_index` returns on its first match. Covered by two new
  `scripts/rpg2k_logic_check.rb` checks (a duplicate-label jump lands on the
  earlier one, not the later one; a jump issued mid-block, not as the first
  command, still finds its target and skips the commands in between).
- **Change Menu Prohibit already persists across map transfers; Change Save
  Prohibit and Teleport/Escape Prohibit already do not** (yado.tk: a real,
  asymmetric rule across three similar-sounding commands). Confirmed by
  reading `Scene::Map#apply_map_access`, which re-derives `save_access` /
  `teleport_access` / `escape_access` from the map tree's own per-map
  tri-states (LMT `map_properties` fields 33/31/32) on the initial map load
  and on every Teleport, while `menu_access` is untouched there — and the map
  tree schema (`mruby-lcf/mrblib/schema.rb`) confirms *why*: RPG2000 never
  offers a per-map Menu setting at all, only Save/Teleport/Escape, so there
  is nothing for Menu access to be re-derived from. A `Control Menu/Save/
  Teleport/Escape Access` event command can still override any of the four
  for the rest of the current visit; only the next map load or Teleport
  recomputes the three that have a map-tree setting. Regression-covered by
  extending an existing `scripts/rpg2k_scene_check.rb` check to also assert
  Save access resets with Teleport/Escape and Menu access does not.

#### Untriaged backlog, from `2k/09_bug/` (bugs/errors pages read so far)
- `016_ikinari_end/` — a Parallel Process can observe an all-KO'd party and
  fire Game Over *before* a concurrent Battle "On Lose" recovery branch gets
  to run its full-heal, even though the recovery would have prevented it.
  Ordering/race between the game-over check and parallel-process ticking.
- `017_heiretu_totyu_end/hei_mukou.htm` — (a) a Parallel Process's appearance
  condition going false mid-execution isn't observed until the process
  naturally hits a Wait/yield point, not instantly (may already follow from
  how `step_parallel` is structured — unverified); (b) Set Move Route +
  "wait for completion" targeting a permanently-impassable tile without
  "Ignore if can't move" stalls a parallel process forever.
- `015_shujinkou_idou_huka/` — catalogue of hero-can't-move causes; most
  already covered by existing passability/move-route logic, but **"Force
  Move All" targeting a currently-hidden (appearance-conditions-unmet) map
  event causes a hard freeze in real RPG_RT** is a distinct crash-class quirk
  not cross-checked yet.
- `037_zen_tuukou_kanou/` — passability is the AND of lower+upper chip
  passability (probably already correct, unverified); only the chipset's
  literal top-left upper tile is the canonical "no tile" transparent chip,
  any other blank-looking one carries its own (possibly impassable)
  identity — content-authoring nuance, likely nothing to fix engine-side.
- ✅ `028_tokushu_huka/` — a skill whose Attack/Defense Attribute is configured
  as a **weapon** attribute (vs. a **magic** attribute) can only be used
  while a weapon carrying that same attribute is equipped; armour with the
  same attribute does not satisfy it. Skill usability modelled no
  attribute-based equip-gating at all before this — see the "Database field
  semantics" entry below, now implemented as `Game::Party#can_cast?` /
  `#weapon_attribute_ready?`.
- `033_load/` — editing a map in the *editor* after a save exists resets
  that save's event positions to default on load, and database edits (e.g.
  reordering Items) desync old saves since items are referenced by
  index/id. Narrow/likely not applicable — this reimplementation has no
  "map data changed since this save" concept to model.
- `027_tokushu_suicchi/` — a Skill Type "Switch" becoming unselectable in
  battle until its attributes are reset appears to be an *editor* bug that
  produces malformed authored data, not runtime engine behaviour — probably
  nothing to reproduce here.
- `001_bug_taisaku/`, `014_shift/`, `024_shori_ochi/`, `032_bgm_naranai/`,
  `040_siro_bubun/` — debugging-technique guide, Windows StickyKeys dialog,
  frame-rate-drop authoring advice, and two Windows/graphics-import issues,
  respectively. Not engine game-logic; skip.

#### Untriaged backlog, from `2k/01_shoshin/011_siyou/` (ツクールの仕様)
Full page read; ~140 distinct quirks catalogued, grouped by the page's own
section headers (English). Items already Fixed/Confirmed above are omitted.
Everything below is unverified against the codebase.

- **Items & equipment** — counts silently cap at 99 (not clamped, just
  ignored past it); Change Equipment creates/returns inventory copies
  implicitly; item list always sorts by database id, never acquisition
  order; "equipped item No." reads 0 when empty, and the 2nd weapon slot
  reads through the *Shield* No. operand for dual-wield; "item possession
  count" excludes equipped copies (must sum both for the true total —
  already true of the Control Variables item operand); no inventory is
  per-hero, always party-shared. ("hero equips X" — the Conditional Branch
  actor sub-condition — already reads `actor.equipped?` directly and was
  fine; "has item X" was the actual gap, now fixed, see above.)
- **Call Event** — doesn't move the target event, ignores its appearance
  conditions, can't cross maps, continues the *caller* right after itself
  once the callee finishes/cancels; calling a bad event/page id raises
  specific distinct error dialogs; nesting caps at 1000; under heavy
  nested-Call-Event + multi-parallel-process load, processing can freeze
  (workaround: a Wait:0.0s before the call). Battle Events can't use Call
  Event through the normal editor at all. ("A variable can't pick the
  called common-event id directly" is confirmed already correct — see
  below.)
- **Wait** — an inline "(W)" wait option is identical to a separate Wait
  command; Wait 0.0s is one frame, not zero (**confirmed correct**, see
  above).
- **Encounter** — ✅ **standing on a "hero touches event" tile suppresses
  random encounters there.** `Scene::Map#check_random_encounter` rolled for
  a wandering-monster fight on every ordinary step regardless of what stood
  on the landed tile; a Hero Touch (trigger 1) event's own tile answers
  random encounters too (multiply corroborated — see the fuller writeup
  under "Full-site sweep" below), which this codebase did not implement at
  all. Fixed by adding an early-out, right after the existing flying
  exemption: `event_at(@state.x, @state.y)` (the same tile lookup
  `#try_action_trigger`/`#passable?` already use) and, if that tile holds an
  event whose currently active page's trigger is `TRIGGER_PLAYER_TOUCH`,
  the roll (and the encounter_total accumulation for that step) is skipped
  entirely, exactly like flying or a forced-route step. A same-tile *Event
  Touch* (trigger 2) event does **not** suppress it — only Hero Touch does —
  covered by a new control case in `scripts/rpg2k_scene_check.rb`. ✅ Ctrl
  during test play disabling encounters (a separate fact from this one) is
  now also implemented — see `Scene::Map#debug_through?`, which the same
  `#check_random_encounter` early-outs on.
- **Screen Flash / Character Flash** — only one of each can be active at
  once (a second supersedes, doesn't stack); both are capped to 1/30s
  display while a Battle Animation plays concurrently (the animation's own
  per-frame flash occupies the effect).
- **Set Move Route / Character movement** — route commands don't apply
  until Move-All/Show-Text/Wait/event-end; only one pending route per
  character (issuing two back-to-back discards the first entirely, not
  just supersedes visually); moving onto an impassable tile without
  "Ignore If Can't Move" hangs at that command until unblocked; Through
  Mode must be explicitly ended or it never turns back off; "Face
  Direction" always overrides Fixed Direction/Animation Type; "One Step
  Forward" after Fixed-Direction movement uses the last direction actually
  moved, not the displayed facing; Jump needs both Begin/End (no move
  between = vertical hop in place), speed/direction fixed for its duration;
  hero-targeted Set Move Route suppresses random encounters during the
  move; running it from a Parallel Process during a hero/event tile overlap
  can suppress that event's touch trigger; targeting a currently-hidden map
  event with Move-All freezes (same family as the `015_shujinkou_idou_huka`
  item above).
- **Repeat/Loop** — loops forever without an explicit Break Loop.
- **Common Event** — can't display map graphics or use touch-style
  triggers, can't run during battle or with the menu open; "This Event" as
  a target inside a Common Event (no map-event context) raises the invalid-
  event error; **interrupting a Common Event's Parallel Process (its switch
  turns off mid-run) and re-enabling it resumes exactly where it left off**
  — ✅ the same fact as the fixed "A Common Event's Parallel Process now
  survives a Transfer Player and a save/load" item above, restated.
- **Move All / Force Complete Move** — blocks Event Content at that command
  until every targeted character's route finishes; same freeze conditions
  as Set Move Route above.
- **Autorun** — blocks hero control (unlike Parallel Process); runs to
  completion even if its own appearance condition goes false mid-run,
  *including across a map transfer*; only one Autorun engine-wide at a time,
  and none can start while any non-parallel event is already running; a
  self-targeted Set Move Route with a real movement command can let hero
  control through during an Autorun. **Bug**: an "event touches hero" event
  approaching via "Approach Hero" that simultaneously triggers a Common
  Event Autorun can permanently freeze that map event (fixes: touch it
  again, toggle its appearance switch, or issue any move-route command at it
  — "Cancel Move Route" alone does not clear it). Related to the
  already-fixed priority-type/touch-trigger work but distinct and unverified.
  ✅ **It also blocks other events too, unless "move other events during
  message wait" is on — now wired up.** `Game::MessageConfig#continue_events`
  (LCF field 44, `message_continue_events`) was already parsed from the
  database/save and settable via the Message Options event command, but
  `Scene::Map` never once read it: `#step_events` (autonomous move types and
  forced/custom routes for every non-parallel map event) only ever ran from
  `#update`'s not-busy branch, so a bystander event held still for the whole
  time any message window stayed open regardless of this flag. Fixed by
  calling `#step_events(allow_trigger: false)` a second way, from inside the
  busy branch, whenever a new `#events_move_during_message?` (a message
  window is open **and** `continue_events` is set) answers true — scoped to
  an open message window specifically, not `#event_busy?` in general, so an
  Autorun grinding through non-blocking commands with no message shown still
  freezes the map either way, unaffected. `allow_trigger: false` (threaded
  through `#step_event`/`#move_autonomous`) still lets a bystander walk,
  turn and finish its route, but never lets one start a *new* event over the
  player's — there is only one foreground `@interpreter`, already busy with
  the open message, and RPG2000 never shows two message windows at once, so
  an event-touch (trigger 2) bystander reaching the player's tile during
  this window still stops adjacent to it without starting its own commands,
  the same as the ordinary nothing-else-running case. Covered by three new
  `scripts/rpg2k_scene_check.rb` checks (a bystander holds still with the
  flag off, the existing default; a bystander keeps walking with the flag
  on; an approaching trigger-2 bystander still never starts its own event
  while the flag is on), two confirmed to fail against the pre-fix code
  before the fix.
- **Hero & party** — removing a hero preserves their equipment/level/EXP/HP/
  status; the field sprite is always party member 1's; only the front member
  draws on the field at all; a hero's name can't be copied to another via any
  built-in command. (Party caps at 4, Change Party Member no-ops past that —
  now fixed, see above.)
- **Processing order** — map/common events process in ascending id order;
  only one event/parallel-process advances per tick engine-wide (round
  robin, not true concurrency) — a process that hits Wait/Show-Text yields
  to the others that tick. **"Get Event ID at coordinates" on overlapping
  events resolving to the highest id is confirmed already correct**:
  `Scene::Map#build_events` walks the map's event table (`LCF::Array2D`,
  always ascending id — a plain Ruby Array iterated low to high) into
  `@events` in that order, and `#rebuild_event_tiles` writes
  `@event_tiles[[x, y]]` once per event in that same order, so the *last*
  write — the highest id — is what ends up on a shared tile and what
  `event_id_at` reads back; nothing sorts by draw order or picks the
  lowest/topmost. Covered by a new `scripts/rpg2k_scene_check.rb` check
  (two events sharing a tile, `Store Event ID` resolves to the higher one).
- **Battle Animation** — only one can display at once (second supersedes);
  each frame is exactly 1/30s; ✅ **targeting a Vehicle position now reads
  that vehicle's live x/y even from a different map than the one shown** —
  see the fuller writeup under "Full-site sweep" below.
- **Material data** — an imported asset takes priority over a same-named RTP
  one; dropping files directly into asset folders bypasses size/transparent-
  colour-index validation.
- **Parallel Process** — yields to others during its own Wait/Show-Text
  pause; appearance condition going false mid-run only stops at the next
  yield point, not instantly (same fact as the `09_bug` item above); a
  Transfer Player command inside one lets subsequent commands run while the
  new map is still loading (needs a Wait:0.0s after it) — for a **map**
  event specifically, a Wait right there instead ends that event outright
  since its context is gone post-transfer; "On Loss: Handle Separately" +
  an immediate recovery branch can still lose to Game Over if *any*
  Parallel Process is still running (must stop them all first) — same
  family as the `016_ikinari_end` race above; **setting a map event's
  trigger to Parallel Process also fires it on hero contact** — instantly
  on overlap for below/above-characters priority, repeatedly while a
  direction key is held against a same-as-characters (blocking) one. Worth
  checking against `step_parallel`/touch-trigger dispatch.
- **Vehicles** — an unset vehicle defaults to map id 0, (0,0); Small/Large
  Ship aren't hardcoded to water, their passability follows the terrain
  table's boat/ship-pass flags like any other vehicle rule; ✅ an airship
  can't land on a tile a map event currently occupies (now fixed — see the
  "Party / Actor / Vehicle" section under "Full-site sweep" below); airships
  get no random encounters by default (**confirmed already correct**, same
  section); hero-targeted Set Move Route commands (Dash,
  Jump, etc.) still run normally while mounted and must be manually guarded
  off; **setting a map event's trigger to Parallel Process and running "Set
  Vehicle Position" from it crashes RPG_RT** (any other trigger type does
  not) — an authentic engine crash, probably not worth reproducing; ✅ a
  vehicle's x/y/screen-x/y can be read via variable ops from a different map
  than it currently occupies — `Game::Interpreter#event_operand`'s Control
  Variables "character position" operand (type 6) recognised the hero (ref
  10001) and map event ids, but a vehicle ref (10002-10004, boat/ship/
  airship) fell through to the same "no match" branch a nonexistent map
  event does, always reading 0. A new `#vehicle_operand` reads the target
  `Game::Vehicle` straight off `Game::State` — map id, x, y, facing — which
  needs no scene hook at all, since a vehicle (unlike a map event) is
  tracked independently of whichever map is currently loaded, and
  `Scene::Map#follow_vehicle` already keeps a ridden vehicle's stored
  position live every step. A vehicle's map id operand returns its real
  value rather than the map-event quirk's hardcoded 0, the same way the
  hero's own map id read already does. Covered by a new
  `scripts/rpg2k_logic_check.rb` check (a boat and an airship's map id/x/y/
  facing read correctly from an interpreter positioned on an unrelated map;
  an unplaced vehicle reads its (0,0) default), confirmed to fail against
  the pre-fix code before the fix. ✅ **Screen x/y (attr 4/5) are now covered
  too** — the one deliberately-scoped-out half of the fix above, since it
  needs a live camera that only the currently-loaded map's own scene has.
  `Scene::Map#character_screen_position` (the method
  `Interpreter#screen_operand` calls through the `@map_info` hook) only
  recognised the hero (10001) and map-event ids, so a vehicle ref
  (10002-10004) fell through to its "nothing to place" branch and read 0
  the same way an unresolvable map event does — not the vehicle's actual
  on-screen position. A new `#vehicle_pixel(type)` reads `Game::State`'s
  `Game::Vehicle` and returns the ridden vehicle's own interpolated pixel
  position (`#player_pixel`, so it reads in lockstep with the hero mid-step)
  or a parked one's tile position — the exact same rule `#draw_vehicles`
  already renders a vehicle's sprite by — and nil when the vehicle isn't
  placed on the currently loaded map at all (unplaced, or parked on a
  different one), which `#character_screen_position` treats the same as an
  unresolvable map event: falls back to 0 one level up in
  `#screen_operand`. `#character_screen_position` dispatches to it for refs
  10002-10004 before falling through to the map-event lookup, reusing the
  same `MOVE_TARGET_BOAT`/`MOVE_TARGET_AIRSHIP` range Set Move Route's own
  vehicle-target resolution already uses. Covered by a new
  `scripts/rpg2k_scene_check.rb` check (an unplaced boat reads nil; a parked
  one reads the same tile-centre/tile-bottom position a map event at that
  tile would; one parked on a different map reads nil again; a boarded one
  reports the identical screen position the hero riding it does), confirmed
  to fail against the pre-fix code before the fix.
- **Battle Event** — separate command set from Map/Common events entirely;
  ✅ no Pictures on the battle screen (see the fuller writeup under the
  **Picture** bullet directly below — the same fix); Parallel Process can't
  run in battle; no further pages run once battle ends.
- **Picture** — ✅ **none show on Menu/Battle screens — the Menu half was
  already correct, the Battle half was a real gap, now fixed.**
  `Scene::Base#build_field_background` already paints an opaque panel above
  the picture layer (`@picture_sprite`, z 250) the instant `Scene::Menu`
  opens, and `Scene::Map#update` — and with it `#render`, the one place
  `@picture_sprite` is drawn — simply is not called while a menu scene sits
  on top of it, so the picture layer never gets a chance to draw over the
  menu in the first place. The battle screen has no equivalent scene push:
  RPG2000's front-view battle runs inline on the very same `Scene::Map`,
  gated only by `@battle_ui`, so `#render` kept calling `#draw_pictures`
  every frame regardless — and the battle backdrop
  (`@battle_ui[:back_sprite]`) sits at a much lower z than the picture
  layer, so nothing painted over it. A picture shown before the encounter
  (a field HUD element, say) or by a Parallel Process still running during
  the fight (per the "parallel processes were paused too broadly" fix
  above, one keeps ticking through a battle-adjacent message window, though
  not through the battle itself — `#parallels_paused?` does gate on
  `@battle_ui`) drew straight over the battle UI. Fixed by gating
  `#render`'s picture step on `@battle_ui`: `@picture_sprite.visible = false`
  and `#draw_pictures` is skipped entirely for as long as a fight is running
  (not merely hidden with a stale composited frame underneath), and the
  sprite un-hides and resumes drawing on the very first frame after
  `@battle_ui` clears. Covered by a new `scripts/rpg2k_scene_check.rb`
  check (a shown picture draws normally before the encounter, is hidden and
  stops compositing the instant the battle screen is up, and reappears the
  instant the fight ends), confirmed to fail against the pre-fix code
  before the fix. Still open: halted entirely while a text window is up
  (separate from the battle/menu case — a message window is not a scene
  push, so a different mechanism would be needed, and this project's own
  "Picture commands... suppressed while a message window is open" fix above
  only stops new Show/Move/Erase Picture *commands* from taking effect, not
  an already-shown picture's own visibility); **changing maps clears all
  Pictures — except via Teleport or Escape (skill/item), which don't clear
  them**; semi-transparent (1-99%) opacity costs noticeably more than fully
  opaque/transparent; Erase Picture is instant (no fade) — a gradual fade
  needs Move Picture to the same spot at 0% opacity instead. (50 slots with
  the higher id always drawing on top, independent of show order, is
  confirmed already correct — see below.)
- **Map Event** — "hero touches event" does *not* fire in three specific
  cases: (a) ✅ the event has already logically started moving into its next
  tile (hit-test uses the target tile, even if the sprite still visually
  overlaps the old one) — **already correctly modelled**. `Scene::Map
  #reoccupy` rewrites `@event_tiles` (what a touch trigger / the player's own
  passability check reads) to the destination tile the instant a step
  commits, in the same call that starts the pixel slide (`#start_event_slide`)
  toward it — the vacated tile's hit-test clears immediately, well before
  `#event_sliding?` (`disp_x`/`disp_y` catching up to the logical tile) says
  the sprite has visually arrived. No code change; covered by a new
  `scripts/rpg2k_scene_check.rb` check pinning that exact gap between the
  logical and display position mid-step. (b) the event moved onto the hero's
  own tile
  (event-initiated contact doesn't count for this trigger — **already
  correctly modelled**, `move_autonomous` only checks trigger 2 for that
  case); (c) hero and event simultaneously swap tiles by crossing paths —
  this "pass-through" also fails to register (looked at this one already —
  genuinely tricky to verify without a real RPG_RT reference, see prior
  session notes); if a multi-page event's move route is mid-execution when
  its page switches, the route restarts *unless* the two pages' move-route
  settings are byte-identical (**same fact as the "confirmed gap" above**).
- **Menu screen** — Call Menu Screen bypasses "Prohibit Menu" (only the
  player's own Cancel-key shortcut respects it); no sub-part of the menu
  can be called except the dedicated Save-screen command; can't open during
  battle; opening it pauses *all* event processing including active
  timers/parallel processes; Erase Screen's black-out is undone if the
  player opens and closes the menu (✅ implemented — see the "Screen
  effects" bullet below, same fact from a different site page).
- **Load** — resuming mid-Autorun/mid-Parallel-Process picks up exactly
  where it left off, *unless* the map was edited/re-saved since, in which
  case that event restarts from the top (edge case, likely not applicable
  here — no "map data changed since save" concept). **A runtime Change
  Tileset override not surviving save/load is confirmed already correct**:
  `@tileset_id` is a `Scene::Map` instance variable, not a `Game::State`
  field — `to_h`/`to_lsd` have nothing named `tileset`/`chipset` at all — and
  `RPG2k#continue_game` always builds a **fresh** `Scene::Map` from the
  loaded state, so the override cannot follow it even though nothing
  explicitly clears it the way `perform_teleport` does. Regression-covered
  by a new `scripts/rpg2k_scene_check.rb` check.

#### Full-site sweep (all remaining ~457 pages, 34 batches)

Deduplicated findings from every category not covered above. Grouped by
subsystem; each bullet compresses what were often 3-8 independent
corroborating sources into one statement. **Nothing below has been checked
against the codebase yet** — this is raw reference material for future
triage, the same as the rest of this backlog.

**Flagged for priority triage** — these look most likely to be genuine,
actionable gaps based on this session's own reading of the current code,
not yet verified:
- ✅ **Parallel processes were paused too broadly.** `Scene::Map#step_parallels`
  used to only run when `!event_busy?`, and `event_busy?` is true for any
  foreground interpreter activity including an ordinary Show Text window.
  Multiple independent yado.tk pages state real RPG_RT parallel processes
  keep advancing during a message window / ordinary foreground event and are
  suspended only by the **Menu screen and the Battle screen** — a message
  box is not one of the pause conditions. Fixed: `#step_parallels` is now
  called unconditionally every frame (before the foreground gets a chance to
  start anything, matching a separately-documented "if both fire the same
  frame, parallel process goes first"), gated by a new, narrower
  `#parallels_paused?` instead of `event_busy?` — true only while a battle is
  in progress (`@battle_ui`, the Menu screen's pause is already structural:
  `Scene::Map#update` simply is not called while `Scene::Menu` sits on top)
  or the foreground interpreter is actively grinding through non-blocking
  commands ("parallel processes keep running during an Autorun's *blocking*
  waits (Show Text/Wait) but are blocked while the Autorun executes
  non-blocking commands" — `Game::Interpreter#running?` stays true for a
  foreground event's *entire* lifetime including while parked waiting, so
  `!waiting?` is what actually isolates the still-bursting case, in practice
  a command list heavy enough to spill past one frame's `MAX_STEPS` budget
  without reaching a wait). (Picture commands specifically *are* suppressed
  during a message window per several other pages, which is a narrower,
  separate rule from whether the parallel process's own non-picture commands
  keep ticking, and was **not** addressed by this change — now fixed
  separately, see the "Pictures" bullet under "Full-site sweep" below.)
- ✅ **Timer max 99:59 (5999s), clamped not wrapped when set higher via a
  variable.** `Game::Timer#set` (`mruby-rpg2k/mrblib/game.rb`) computed
  `@frames = seconds * FPS + (FPS - 1)` with no upper bound at all, and
  `Game::Interpreter#do_timer`'s Timer Operation "set" command can source
  `seconds` from an arbitrary Control-Variables value
  (`variables[cmd.param(2)]`), so an out-of-range variable reached the frame
  counter unclamped. Real RPG_RT's timer display never grows past two minute
  digits, so it caps the loaded value at 99:59 (5999 s) rather than wrapping
  or overflowing. Fixed by adding `Game::Timer::MAX_SECONDS = 5999` and
  clamping in `#set` (`seconds = MAX_SECONDS if seconds > MAX_SECONDS`)
  before the frame math runs; 5999 s is confirmed to land exactly on 99:59
  via `#seconds`/`#display_text` (5999 / 60 = 99 minutes remainder 59
  seconds). Regression coverage added to `scripts/rpg2k_logic_check.rb`:
  a direct `Game::Timer#set(9999)` clamps to 5999 s / "99:59", a Timer
  Operation "set" sourced from a Control Variable holding 9999 clamps the
  same way through the interpreter, and an ordinary in-range variable-sourced
  set (30 s) is left untouched. The other numeric constants originally
  bundled with this bullet (battle damage cap, HP recovery cap, switch/
  variable caps and ranges, recursion ceiling, party/stack/picture caps, move
  speed, transparency steps) remain unverified — see below.
- ✅ **Special-skill HP recovery is capped at 999 per use** — the same
  fixed-3-digit-popup reasoning as the battle damage cap above, for the
  opposite direction. `Game::Battle#apply_skill_hit`'s recovery branch
  (`mruby-rpg2k/mrblib/game.rb`) clamped the healed amount only by the
  target's `max_hp`, never by any fixed digit cap — since `max_hp` and a
  skill/item's `recover_hp_rate`-of-`max_hp` can both exceed 999, a single
  heal could legitimately compute (and apply) well past what RPG_RT's
  heal popup — the same fixed 3-digit widget as the damage one — could ever
  display. Fixed by adding `Game::Battle::RECOVER_CAP = 999` next to the
  existing `DAMAGE_CAP` and clamping the recovery amount to it before it's
  added to `target.hp`, in the one method (shared by single- and all-target
  commands) that applies it — the field-menu item-use path
  (`Game::Party#item_recovery`) doesn't show the same fixed-width popup and
  is a separate, unconfirmed question left open. Regression coverage added
  to `scripts/rpg2k_logic_check.rb`: a recovery skill computing a raw 5000
  HP heal against a high-max-HP target clamps at 999, confirmed to fail
  against the pre-fix code.
- ✅ **A variable's stored value now clamps to RPG_RT's ±999999 range**
  (RPG2000; RPG2003 widens it to ±9999999, per `LCF.var_min`/`var_max`) instead
  of overflowing. `Game::Variables#[]=` had no bound at all, so a Control
  Variables assign/add sourced from a large constant, an Input Number, or an
  expression like the standard `×1.5` = `×15÷10` workaround (which can
  legitimately overshoot mid-computation, per the "Variables & Switches"
  bullet above) landed outside the range the real engine ever lets a variable
  hold. Fixed with a local `Game::Variables::MAX`/`MIN` pair rather than a
  reference to `LCF.var_max`/`var_min` directly — this file deliberately
  touches neither RGSS nor the native LCF parser at load time (see
  `scripts/rpg2k_logic_check.rb`'s header), so the bound is its own constant,
  matching the existing `EXP_MAX`/`DAMAGE_CAP`/`RECOVER_CAP` pattern rather
  than a cross-gem call. Covered by a new `scripts/rpg2k_logic_check.rb`
  check (an over/under-range constant assign clamps at the boundary; an
  in-range add that would overflow clamps too), confirmed to fail against the
  pre-fix code. **Other numeric constants in this same bullet are already
  confirmed correct, no code change needed**: Call Event / Event Call
  recursion ceiling of 1000 (`MAX_CALL_DEPTH`, `interpreter.rb`); party cap of
  4 (`Game::Party::MAX_SIZE`); item/equipment stack cap 99 and gold cap
  999999 (`Party#add_item`/`#gain_gold`); move speed 1-6 via `SPEED_UP`/
  `SPEED_DOWN` clamping to `[1, 6]`; character transparency 8 discrete steps
  (`TRANSP_UP`/`TRANSP_DOWN` clamping to `[0, 7]`). **Still open**:
  switches/variables capping at 5000 (configurable in the editor, so this may
  be a non-issue rather than a gap — nothing here enforces a count ceiling on
  how many distinct ids get used, which is a different question from a single
  variable's *value* range, now fixed). Picture id range 1-50 is now fixed
  too, see the "Pictures" bullet under "Full-site sweep" below.
- **Runtime per-map overrides that reset on leaving-and-returning to the
  map**, not just on Transfer Player/save-load: Chipset Change, Panorama/
  parallax Change, Encounter Steps Change, Tile Replacement, and — per one
  source — Save/Teleport/Escape Prohibition changes. `perform_teleport`
  resets tileset/parallax/pan on a *map change*, and Save/Teleport/Escape
  Prohibition are confirmed correct above (`apply_map_access`). **Tile
  Replacement is confirmed correct too**, for a different reason than the
  other three: a Tile Substitution is recorded directly on the live
  `Game::Map` object (`Game::Map#substitute_tile`), and `perform_teleport`
  always rebuilds `@map` from scratch (`@parent.load_map`, which re-parses
  the destination's `.lmu` fresh) rather than reusing or caching one — so
  a substitution cannot survive a Teleport, including one back to the same
  map, without any explicit reset code needed. Regression-covered by a new
  `scripts/rpg2k_scene_check.rb` check. ✅ **Encounter Steps Change is now
  fixed too** — it had stopped being the "not actionable, no reader exists"
  case this bullet originally described the moment the wandering-monster
  system landed (`Scene::Map#current_encounter_steps` reads
  `@state.encounter_rate` when set), but nothing then reset the override on
  a map change the way the tileset/parallax/pan resets already did a few
  lines up in the same method. `perform_teleport` now sets
  `@state.encounter_rate = nil` alongside those, so a Change Encounter Rate
  command's effect ends the moment the party leaves the map, matching this
  bullet's other three confirmed members. Covered by a new
  `scripts/rpg2k_scene_check.rb` check (an override recorded via Change
  Encounter Rate, then a Teleport back to the same map id, falls back to
  the map tree node's own `encount_steps`), confirmed to fail against the
  pre-fix code before the fix.

**Event triggers & page selection**
- Map/common event page selection: only the single **highest-numbered**
  page whose conditions are satisfied runs (already implemented, `Game::
  EventPage.select`). Battle events are the opposite: **every** satisfied
  page runs once per turn, lower page number first (already implemented,
  `Game::BattlePage.select_all` — confirmed correct earlier this session).
- **Autorun (auto-start) and any other non-parallel-process trigger are
  mutually exclusive engine-wide**: an Autorun can't start while any other
  foreground event (action-key, touch) is executing, and per one source
  this exclusion is **global, not per-map** — a second map's Autorun won't
  fire while a first map's Autorun (or another foreground event) is still
  mid-script, even after a Transfer Player took you to that second map.
  Also: Autorun and parallel process are independent — parallel processes
  keep running during an Autorun's *blocking* waits (Show Text/Wait) but
  are blocked while the Autorun executes non-blocking commands; if both
  are set to fire the same frame, parallel process goes first.
- An Autorun/parallel event whose appearance condition goes false
  mid-execution **keeps running to completion** rather than aborting —
  confirmed by many independent sources, including across a map transfer
  for Autorun specifically. ✅ **The map event Parallel Process half is now
  fixed too.** A foreground Autorun's own command list already kept
  running unaffected regardless of `@events` (it steps its own captured
  `commands` array via `@interpreter`, independent of whether its owning
  event still has a live `Game::Character`), but a **map event's own
  Parallel Process** was a real, reachable gap: `#build_events`
  (`mruby-rpg2k/mrblib/scene/map.rb`) already skips an event outright once
  no page's conditions are satisfied — dropping it from `@events`/
  `@event_tiles` entirely, the same "no `Game::Character` built at all"
  fact already recorded for `event_id_at` above — but
  `#build_parallels`'s bystander-preservation pass (`preserve_map_events:`,
  see "A Map Event's own Parallel Process no longer restarts..." just
  below) only ever looked for a still-running interpreter among the events
  that survived into the freshly-rebuilt `@events`, so one whose *own*
  page just stopped matching (e.g. its own script turning off its one
  gating switch) fell out of `@parallels` on the very next page-reselection
  sweep and was silently garbage-collected mid-script, instead of finishing
  out its remaining commands the way this bullet's own claim describes.
  Fixed by carrying forward any bystander-preserved entry whose event id
  did *not* end up live this rebuild, under its now-stale event/character
  reference (unreachable from `@events`/`@event_tiles`, so harmless) — it
  keeps ticking exactly like an ordinary Parallel Process, indefinitely,
  until something else stops it (an Erase Event still finds and removes it
  by object identity) or its conditions later pick the very same page
  again, in which case the existing same-page reuse check just reattaches
  this same interpreter rather than starting a fresh one. Whether RPG_RT
  lets such a hidden process loop forever versus refusing to start a new
  lap once its script naturally reaches the end is not resolved by this
  fix — only "does not get torn down mid-script" is confirmed by the
  source material, so the simpler, more literal reading (treat it exactly
  like a live one) is what's implemented; only scoped to `preserve_map_events:`
  rebuilds (an in-place, same-map page reselection), matching every other
  bystander-preservation rule in `#build_parallels` — a genuine map change
  still discards it, unaffected. Covered by a new
  `scripts/rpg2k_scene_check.rb` check (a single-page event's own Parallel
  Process runs a marker, waits, turns off its own gating switch — making
  the event vanish from `@events` — waits again, then runs a second marker,
  confirmed to still fire once the event is gone), confirmed to fail
  against the pre-fix code before the fix.
- A **Common Event's** parallel-process state (its interpreter position)
  **resumes exactly where it left off** when re-enabled, indefinitely,
  persisting in every future save even after the condition goes false — ✅
  fixed, see "A Common Event's Parallel Process now survives a Transfer
  Player and a save/load" above. A **Map Event's** parallel process always
  restarts from the top on every re-trigger (matches this codebase's
  current — correct — per-visit behavior).
- ✅ **A Map Event's own Parallel Process no longer restarts from the top
  when a *different* event's page flips.** `Scene::Map#pages_changed?` (see
  above) is a map-wide check — any Control Switch/Variable/item/party write
  that flips *any* event's active page runs
  `#rebuild_events_preserving_positions`, which rebuilds every event's
  `Game::Character` and, via `#build_parallels`, every parallel-process
  interpreter, an unrelated bystander event's parallel process included even
  though that event's own page never changed. `#build_parallels` had no
  reuse mechanism for a Map Event's own parallel process at all — only a
  Common Event's, keyed by common-event id, already survived this kind of
  rebuild (see the already-fixed Common Event bullet just above) — so the
  bystander's Parallel Process silently lost its entire in-flight state
  (call stack, a paused Wait's countdown, everything) and restarted at index
  0 on every unrelated page flip anywhere on the map — a stricter, more
  frequent reset than "restarts from the top on every re-trigger" describes,
  since nothing about *this* event was re-triggered at all. Fixed with a new
  `preserve_map_events:` keyword on `#build_parallels`, passed only by
  `#rebuild_events_preserving_positions` (a same-map, in-place page
  reselection, where a map event's own id still means the same thing before
  and after) and left off at the other two call sites — the initial build
  and a genuine Transfer Player — where a map event's parallel-process id
  means nothing carried over from a different map/visit and a fresh restart
  stays correct (unchanged, still pinned by the existing "a map event's
  parallel process still gets a brand-new interpreter every visit" check).
  When set, a still-running Parallel Process whose own page selection did
  not move (the same `commands` array, compared by object identity) keeps
  its interpreter across the rebuild; one whose own page *did* just change
  still gets a fresh interpreter either way, so "always restarts from the
  top on every re-trigger" (the bullet just above) is untouched. Covered by
  a new `scripts/rpg2k_scene_check.rb` check (a bystander event's Parallel
  Process — mid-Wait — keeps its command position and in-flight countdown
  intact across an unrelated event's switch-triggered page change),
  confirmed to fail against the pre-fix code (the bystander's first command
  re-running) before the fix.
- Multiple simultaneous parallel processes are **not concurrent** — the
  engine advances one command block at a time, round-robin, yielding at a
  blocking command (Wait/Show Text/Show Picture), in definition/event-ID
  order.
- A parallel process reaching its own loop end and restarting always costs
  ~1/60s (an implicit one-frame gap), independent of any explicit Wait.
- "Hero Touch" (trigger 1) does **not** fire in three specific cases
  (documented on the specs page, already tracked above): the touched
  event has already logically begun moving into its next tile; the event
  moved onto the hero's own tile (event-initiated, not hero-initiated
  contact); hero and event simultaneously swap tiles. Also newly found
  this pass: touch triggers only fire on **forward** movement onto the
  tile, not on a "move backward" move-route step reaching the same tile.
- Setting a page's trigger to **Parallel Process** *also* answers hero
  contact: fires instantly on overlap for a below/above-characters page,
  or repeatedly while a direction key is held against a same-as-characters
  (blocking) one.
- ✅ **Standing on a "Hero Touch" trigger's tile suppresses random
  encounters there** (multiply corroborated) — see the fuller writeup under
  "Untriaged backlog, from `2k/01_shoshin/011_siyou/`" above (the
  `**Encounter**` bullet). Moving via Set Move Route or Jump already
  suppressed encounters before this pass (the `@player_forced_step` /
  random-encounters fix above); ✅ holding Ctrl in test-play doing the same
  is now also implemented (`Scene::Map#debug_through?`).

**Move Route / Character Movement command**
- Only **one pending move route per character** — issuing a second while
  the first is still running **discards the first outright** (not queued,
  not layered).
- Move-route commands are asynchronous/fire-and-forget by default: the
  interpreter advances immediately while the character keeps sliding in
  the background; only "Proceed With Movement"/"Run All Designated Moves"
  blocks until every pending route finishes. ✅ **An implicit auto-run now
  also happens whenever the event hits a Wait or a Show Text** — "Run All"
  is only needed to force it mid-list otherwise. This was a genuine gap:
  `Game::Interpreter#do_show_message`/`#do_wait` (`mruby-rpg2k/mrblib/
  interpreter.rb`) set their `:message`/`:wait` wait-kind unconditionally,
  and `Scene::Map#drive_event`'s dispatch for both
  (`mruby-rpg2k/mrblib/scene/map.rb`) opened the message window / started
  the wait countdown immediately, with no awareness of a still-running
  forced route (set by an earlier fire-and-forget Move Event in the same
  script) at all — since a forced route only ever advances via
  `#step_events` (skipped whenever `#event_busy?` is true, which it always
  is while the triggering event's own interpreter is still running or
  waiting) or the explicit `:movement` wait's `#step_forced_movement`, a
  route left pending going into a Wait/Show Text sat completely frozen,
  with zero progress, until the *whole* event's command list finished —
  not "auto-running to completion" the way an inserted Proceed With
  Movement would. Fixed by routing both branches through the same
  `#step_forced_movement`/`#forced_movement_done?` machinery
  `:movement` already uses: `:message` now only calls `#open_message` once
  `#step_forced_movement` reports every forced route (player, every map
  event, every vehicle — the same map-wide scope Proceed With Movement
  itself already covers) done, driving it one frame further otherwise; `:wait`
  gates `#drive_wait` the same way, so the wait timer does not even start
  counting down until then. The "list ends" half of the original claim
  needed no change: once the triggering event's own command list is
  genuinely exhausted, `#event_busy?` already goes false on its own and
  `#step_events` resumes driving the route at its normal pace — the same
  outcome Proceed With Movement produces, just via the ordinary per-frame
  path instead of the `:movement` wait, so nothing was actually broken
  there. **Still open**: a fire-and-forget route sitting between two
  *non-blocking* commands (e.g. a Move Event followed by several Control
  Variables commands with no Wait/Show Text/Proceed before the list ends)
  genuinely does not animate frame-by-frame while those commands run — it
  stays frozen until one of the three trigger points above is reached,
  same as before this fix; true concurrent background sliding while
  arbitrary non-blocking commands keep executing is a larger,
  unaddressed change. Covered by two new `scripts/rpg2k_scene_check.rb`
  checks (a 3-tile forced route on a bystander event, immediately followed
  by a Show Text with no Proceed With Movement, only opens the window once
  the route lands; the same setup with a Wait in place of the Show Text
  only starts that Wait's countdown once the route lands), both confirmed
  to fail against the pre-fix code before the fix.
- Moving onto an impassable tile without "Ignore If Can't Move" **hangs**
  at that command until the obstruction clears (not a skip) — a full
  control-lock freeze if the hero is the target. The same freeze class
  applies to Move-All/jump-landing targeting a currently-hidden
  (appearance-condition-unmet) map event.
- ✅ **"Through Mode: Begin" without a matching "End" leaves the character
  *permanently* able to pass through walls — including across an unrelated
  event's page change**, which used to silently turn it back off.
  `Scene::Map#pages_changed?` is a map-wide check (see the "Event triggers &
  page selection" section below), so any Control Switch/Variable/item/party
  write that flips *any* event's active page runs
  `#rebuild_events_preserving_positions`, which rebuilds **every** event's
  `Game::Character` from scratch via `#build_events` — including events whose
  own page never changed. The old-to-new copy loop only carried `x`/`y`/
  `direction` (and, conditionally, an in-progress custom route) across that
  rebuild; `through`, `facing_locked`, `animation_stopped` and `transparency`
  were left at `Game::Character#initialize`'s defaults (Through Mode off,
  Direction Fix off, animation running, fully opaque) on the fresh object,
  silently undoing whatever a Move Route's Through Mode/Direction Fix/Stop
  Animation/Transparency Up-Down sub-commands had set on an event that was
  never touched by whatever triggered the rebuild — the opposite of "must be
  explicitly ended or it never turns back off". Fixed by carrying those four
  fields across the rebuild the same way position/direction already are.
  Covered by a new `scripts/rpg2k_scene_check.rb` check (a bystander event's
  Through Mode, Direction Fix, Stop Animation and Transparency all survive a
  *different* event's switch-triggered page change), confirmed to fail
  against the pre-fix code before the fix.
- ✅ **A move-route "Face Direction" sub-command always overrides an earlier
  "Direction Fix ON" (Lock Facing) in the same route.** Direction Fix only
  ever suppresses the facing change an *ordinary move* would otherwise cause
  (matching "Through Mode"'s and "Change Graphic"'s own don't-touch-explicit-
  overrides pattern above) — it does not also swallow a later *explicit*
  turn. `Game::MoveRoute#apply_command`'s Turn Right/Left/180/Random
  sub-commands (`Character#turn_right`/`#turn_left`/`#turn_around`) already
  wrote `@direction` directly, bypassing `facing_locked` entirely, but the
  Face Up/Right/Down/Left/Random/Hero/Away-from-Hero sub-commands all routed
  through `Character#face`, which *does* respect the lock
  (`@direction = dir unless @facing_locked || dir.nil?`) — the same method
  ordinary movement uses to update facing as a side effect, and correctly
  should keep respecting it. Fixed by giving `Character` a second method,
  `#face!` (lock-ignoring, mirrors the Turn commands' direct-write), and
  routing the seven Face Direction sub-commands through it instead of
  `#face`; `#move`/`#jump`/`#move_diagonal`'s own movement-driven facing
  still goes through the original `#face` and still respects the lock,
  unchanged. Covered by a new `scripts/rpg2k_logic_check.rb` check (Direction
  Fix ON, then a Move Right that keeps the facing frozen, then a Face Up that
  turns north despite the still-active lock), confirmed to fail against the
  pre-fix code (asserting direction 8, getting 2) before the fix. ✅ **The
  related, separate "One Step Forward" question this fix scoped out is now
  fixed too**: a move-route "One Step Forward" is documented to continue in
  the *last direction actually moved* rather than the displayed facing, which
  a Direction Fix lock or an explicit Face command can leave pointing
  somewhere else entirely (a locked `Move Right` steps east without turning
  the sprite; a `Face Up` right after turns the sprite north without moving).
  `Game::Character` had only the one `@direction` field for both, and
  `Game::MoveRoute`'s `MOVE_FORWARD` handler read it — the sprite's facing,
  not the walked direction. Fixed by adding a second `Character#last_move_direction`
  reader, updated by `#move`/`#jump`/`#move_diagonal` alongside (but
  independently of) `#direction` — a blocked `#do_move` still turns to face
  the obstruction without setting it, matching "actually moved" — and
  `MOVE_FORWARD` now reads that instead of `#direction`. A jump that lands
  where it started (`dx == 0 && dy == 0`) updates neither field, since there
  is no axis to be dominant when nothing moved. Covered by a new
  `scripts/rpg2k_logic_check.rb` check (Direction Fix ON, a locked Move
  Right, an explicit Face Up, then One Step Forward continues east, not
  north), confirmed to fail against the pre-fix code before the fix. The
  "Animation Type" half of the original claim (whether an Animation Type
  setting is also overridden by a Face Direction command) is unverified
  either way.
- Jump needs paired Begin/End; movement commands between them sum into a
  net displacement vector (opposite-axis moves cancel); only the *landing*
  tile's passability is tested, tiles crossed are ignored; speed/direction
  can't change mid-jump.
- A move-route "Change Graphic" sub-command (hero, event, or vehicle) is
  **not persistent** — it reverts to the base graphic on save-load or map
  transfer, unlike the dedicated Change Graphic event commands. ✅ **All three
  targets are now confirmed correct.** The hero was fixed earlier this
  session (`@player_char` reset on Transfer Player, see the "Fixed" section
  above). A vehicle's own override was already correct by construction: the
  Set Move Route vehicle work (see the "Full-site sweep" Event system section
  below) landed its Change Graphic on a `Game::Character` mirror
  (`@vehicle_chars`), never on the persisted `Game::Vehicle#charset_name`/
  `#charset_index`, and `perform_teleport` clears `@vehicle_chars` outright —
  reverting it on Transfer Player and save/load (`Scene::Map#initialize`
  always builds a fresh `Scene::Map`) exactly like the hero, no code change
  needed. **A map event's own override had a real, narrower gap**: it did
  correctly revert on an actual map transfer (`build_events` derives
  `graphic_name`/`graphic_index` fresh from the page every time, and a
  Transfer Player never preserves anything), but
  `Scene::Map#rebuild_events_preserving_positions` — the same in-place,
  same-map rebuild that carries position/direction/Through Mode/Direction
  Fix/Stop Animation/Transparency across an *unrelated* event's page change
  (see the "Move Route / Character Movement command" fixes above) — had no
  such carry-over for the graphic override, so any other event's Control
  Switch/Variable write anywhere on the map silently snapped a bystander's
  overridden sprite back to its page's own base graphic, well before any
  genuine map transfer. Fixed by carrying `graphic_name`/`graphic_index`
  across that rebuild too, but — unlike the four flags, which no page ever
  sets — only for a bystander whose own page selection did not move
  (`old[:page].equal?(e[:page])`, the same page-identity test
  `#pages_changed?` and the move-route-continuation check already use): an
  event whose own page genuinely changes to a different base sprite still
  gets that new page's graphic, not a stale override painted back over it.
  Covered by a new `scripts/rpg2k_scene_check.rb` check (a bystander's
  override survives an unrelated event's switch-triggered page change, while
  a third event's own page change to a different base sprite still wins),
  confirmed to fail against the pre-fix code before the fix.
- ✅ **Move Frequency set via a page now reasserts itself once a forced Move
  Route finishes** — the page's own frequency wins going forward, not
  whatever a Frequency Up/Down sub-command left it at. `Scene::Map#step_event`
  set an event's `move_frequency` from its page only when the page was
  (re)built, so a Move Event's route bumping frequency via `Frequency Up`/
  `Frequency Down` leaked into whatever paced the event afterwards — an
  autonomous move type, or a later route with no explicit override. The
  moment a forced route finishes (`e[:forced_route] = nil`, already the
  "revert to page movement" point), `move_frequency` is now reset from the
  page too. Scoped to a forced route only — a page's *own* custom route
  (`move_type: CUSTOM`) reasserting nothing is a different, unverified
  question, since there is no separate "page movement" for it to revert to.
  Covered by a new `scripts/rpg2k_scene_check.rb` check, confirmed to fail
  against the pre-fix code before the fix.
- ✅ **"Cancel All Designated Moves" aborts in-progress routes without
  unwinding side effects.** Its jump half was already correct by
  construction: `Game::MoveRoute#do_jump` resolves an entire Begin/End Jump
  block inside one `step()` call (character.move lands it immediately; the
  visual arc that follows is presentation only), so there is no frame at
  which a halt can catch a jump "mid-flight" — a cancel issued right after
  landing drops only the route's still-queued trailing steps, never the jump
  itself. A map event's Through Mode was already correct too, for the same
  reason as the rest of its collision state: it lives on `e[:char]`, the same
  `Game::Character` the event's page movement uses afterward, and
  `apply_halt_request` never touches it. The **player** side was genuinely
  broken, though: a forced player route steps a disposable mirror character
  (`@player_char`, "the player has no Game::Character") that Through Mode
  lived on and nothing else did, so it vanished the moment the route ended —
  by halting *or* by finishing normally, since a fresh route always started a
  brand new mirror at `through = false`. `@player_through` is now a standing
  flag on the scene: `start_player_route` seeds a new mirror from it rather
  than always false, `step_player_route` mirrors the flag out every step (not
  just at the end, so a halt mid-route still sees it), ordinary input-driven
  walking (`step_movement`) now checks it the same way `char_passable?`
  checks an event's `through`, and it resets only on Transfer Player (where
  RPG_RT drops it too), never on Halt All Movement. Covered by new
  `scripts/rpg2k_scene_check.rb` checks — one for each half, the jump one
  confirming it already passed before any code changed, the Through Mode one
  confirmed to fail against the pre-fix code (stuck at the tile the route
  left it on) before the fix.
- Moving a **map event** (not the hero) via Set Move Route bypasses that
  event's own occupied-tile membership tests the normal way a page-driven
  move does — no distinct finding beyond what's already covered by the
  priority-type/collision work.
- Running a hero-targeted Parallel-Process Set Move Route while the hero
  is mid-transition onto an event's tile can suppress that event's "Hero
  Touch" trigger for that step.
- Display stat clamping (e.g. displayed max HP capped 1-999) is **cosmetic
  only** — the underlying stored value is not clamped, so it can go
  negative or over 999 internally and a later +/- operates on the real
  (unclamped) value, producing results that look wrong if you assume the
  displayed number was the true one.

**Variables & Switches**
- Switches/variables cap at 5000 each (configurable up to that hard max),
  all start OFF/0. Variables are **integer-only, truncating** on
  division/modulo (no fractional values ever) — the standard workaround
  for `×1.5` etc. is `×15÷10` in that order, since multiplying first can
  silently overflow the ±999999 range with no error (wrong output, not a
  crash).
- **Indirect ("pointer") addressing** — `V[n]`, where the *value* of
  variable n becomes the actual target/operand variable's index — is a
  distinct third addressing mode from a literal variable number or a
  direct-copy-of-another-variable's-value, and it can reach indices well
  past the configured max (used deliberately, though the site warns large
  indices measurably slow opening the Save screen — corroborated by an
  entire `09_bug/` page on the topic). Indirect addressing's failure mode
  on an index ≤0 differs by role: the **operand** form already resolved to
  0 (`Variables`/`Switches`' own default for a missing key); the **target**
  form is fixed now too, see below.
- ✅ **Batch (range) operations requiring ascending order or silently no-op is
  confirmed already correct.** `Game::Interpreter#range` returns a batch's
  two ends verbatim with no ordering check, and Ruby's `(a..b).each` on a
  descending range already iterates zero times — so a `Control Switches` or
  `Control Variables` batch whose high end is below its low end does nothing
  at all, matching RPG_RT, with no dedicated guard needed. Covered by a new
  `scripts/rpg2k_logic_check.rb` check. (A batch **random-assign** rolling
  independently per variable, not once for the whole group, used to be a
  real gap here — now fixed, see below.)
- The built-in random-number operand is a genuine non-seeded RNG (two New
  Games produce different sequences) and accepts negative ranges.
- ✅ **`\N[]`/`\V[]` control codes now accept a nested `\V[n]` as their own
  argument** (`\N[\V[1]]` names the actor whose id is variable 1's *value*;
  `\V[\V[1]]` displays variable 1's value indirectly) — this build has no
  notion of the "post-VALUE!" engine-version gate the site names, so the
  behaviour is implemented unconditionally, matching every real-world game
  this codebase's test beds are drawn from. `Game::Message.read_bracket`
  (`mruby-rpg2k/mrblib/game.rb`) used to stop at the first `]`, so
  `\N[\V[1]]`'s argument read as the literal text `"\V[1"` (`.to_i` = 0, the
  wrong actor) with the outer `]` left behind as stray text in the message;
  it now balances nested `[`/`]` pairs, and a new `Game::Message.resolve_arg`
  recursively unwraps a `\v[]`/`\V[]` argument to the variable's value before
  the actor-name/variable lookup runs, leaving a plain numeric argument
  (`\N[5]`, `\V[1]`) resolved exactly as before. `\C[]`/`\S[]` are untouched
  — the site's wording doesn't name them as nesting-capable, only as
  degrading gracefully out of range, which they already do (`\C[]` falls
  back to a flat colour for an out-of-range index, already implemented;
  `\S[]` is dropped outright today, a separate open question tracked in the
  Message window doc above). An out-of-range `\N[]` argument crashing real
  RPG_RT is a genuine engine crash, not reproduced here. Covered by a new
  `scripts/rpg2k_logic_check.rb` check, confirmed to fail against the
  pre-fix code.

**Pictures**
- ✅ **50 concurrent picture slots; higher id always draws on top,
  independent of show order — confirmed already correct.**
  `Scene::Map#draw_pictures` composites `@state.pictures.keys.sort`, so the
  lowest id is always drawn first and the highest id lands on top of it
  regardless of the order Show Picture commands ran in; nothing sorts by
  show/insertion order. The text window sits above the picture layer too
  (`@picture_sprite.z = 250`, the message window's `z = 300`), already
  covered by an existing check. Covered by a new
  `scripts/rpg2k_scene_check.rb` check (two pictures shown out of id order,
  asserting the composite draws the lower id first). Still open: Battle
  Animation drawing above the picture layer specifically, and "map/
  characters always draw below all pictures" as its own assertion. (Not the
  same question as "no Pictures on the battle screen" — ✅ fixed, see the
  **Picture** bullet under "Untriaged backlog, from `2k/01_shoshin/
  011_siyou/`" above — which is about the picture layer being hidden
  outright while a fight is running, not about its z-order relative to the
  battle animation sprite while both are visible on the map.)
- ✅ **Show Picture now no-ops on a picture id outside 1..50** — the "Still
  open: picture id range 1-50" gap left by the numeric-constants bullet
  above. RPG2000's editor caps the Show Picture id field at 50 (a
  fixed-size internal slot array, the same fact the "50 concurrent picture
  slots" confirmation just above already relies on), so an id past it is
  not a real picture and RPG_RT does nothing with it.
  `Game::State#show_picture` (`mruby-rpg2k/mrblib/game.rb`) only ever
  rejected `id <= 0`, so an out-of-range high id was tracked, drawn and
  addressable by Move/Erase Picture like any other. Fixed with a new
  `Game::State::MAX_PICTURE_ID = 50` and an upper bound alongside the
  existing `id > 0` check on `#show_picture`; `#move_picture`/
  `#erase_picture` need no matching guard of their own, since neither can
  ever find such an id shown in the first place once `#show_picture`
  refuses to create one. Covered by a new `scripts/rpg2k_logic_check.rb`
  check (id 51 is silently dropped; the boundary id 50 still works),
  confirmed to fail against the pre-fix code before the fix.
- Changing maps **auto-clears every picture** — except when the transfer
  was via Teleport or Escape, which is an explicit, deliberate exception
  (multiply corroborated). ✅ **The Teleport/Escape skill/item half of this
  is now implemented.** `Scene::Map#perform_teleport` (the one method both
  an ordinary map change and a Teleport/Escape field skill's warp route
  through — the latter via `@state.pending_teleport`, queued by
  `Game::Party#cast_teleport_skill`/`#cast_escape_skill` and applied in
  `Scene::Map#update`, see the "a pending teleport queued by the field
  skill menu is applied" check) called `@state.erase_all_pictures`
  unconditionally, so a Teleport/Escape warp wrongly dropped the party's
  pictures the same way an ordinary Transfer Player does. `perform_teleport`
  now takes a `keep_pictures:` keyword, `false` by default (the interpreter's
  own `:teleport` wait — Transfer Player, Recall to Location — still clears
  pictures, matching the already-covered "a teleport clears every shown
  picture" check) and `true` at the `pending_teleport` call site. Covered by
  a new `scripts/rpg2k_scene_check.rb` check ("a Teleport/Escape field skill
  warp does not clear shown pictures"), confirmed to fail against the
  pre-fix code before the fix.
- ✅ **Picture commands (Show/Move/Erase) are now fully suppressed while any
  message window or choice list is open**, anywhere, including inside an
  already-running parallel process — an unconditional engine limitation with
  no workaround. This was a real, reachable gap: `Game::Interpreter#
  do_show_picture`/`#do_move_picture`/`#do_erase_picture` called straight
  into `Game::State#show_picture`/`#move_picture`/`#erase_picture` with no
  gating at all, and the sibling "parallel processes were paused too
  broadly" fix above (`Scene::Map#step_parallels`/`#parallels_paused?`)
  means a parallel process keeps executing commands — including these three
  — while the foreground (or another interpreter) has a message window or
  choice list open. Fixed with a new `Scene::Map#message_window_open?`
  predicate (`!!(@message || @number_input)`, true for a plain message, a
  choice list, and a standalone or embedded Input Number widget, all of
  which set one of those two ivars) queried by the interpreter through the
  existing `map_info` hook — the same `@map_info.respond_to?(:x) &&
  @map_info.x` pattern `#event_operand`/`#screen_operand` already use for
  `#event_position`/`#character_screen_position` — so a headless interpreter
  (no `map_info`, or a battle page) is unaffected. All three picture
  commands now return immediately when it answers true; a suppressed Move
  Picture's wait flag is not honoured either (nothing moved, so there is
  nothing to wait for), matching "no workaround". Covered by four new
  `scripts/rpg2k_scene_check.rb` checks, confirmed to fail against the
  pre-fix code: a direct interpreter poke while its own message window is
  open, the same poke against an open choice list, and a full scene
  simulation proving a parallel process's Show/Move/Erase Picture attempts
  are dropped while a message window (opened via `#open_message`, sidestepping
  the `#step_parallels`-before-`#start_autostart` ordering that would
  otherwise let the parallel process's first lap land before the window is
  actually open) is up and take effect on the very next lap once it closes —
  while confirming the same process's non-picture commands (`Control
  Variables`) keep advancing throughout, so the sibling fix stays intact.
- Re-issuing **Show Picture** every tick (rather than reusing an
  already-shown picture via Move Picture) is expensive enough to cause
  real frame drops; Move Picture, even at 0.0s duration, is cheap and can
  update position/opacity/tone/zoom all in the same call — this is why
  the standard idiom across dozens of tutorials is "Show once at 0%
  opacity, then only ever Move Picture."
- A picture's source image can be up to 640×480 (vs. the 320×240 screen);
  rendering off the visible edge is simple clipping, but packing multiple
  animation frames into one oversized image and under-spacing them (less
  than a full screen width/height apart) bleeds a neighboring frame's
  content onto the opposite screen edge — implying non-clamped/toroidal
  sampling at the image's own bounds, not just clipping the final
  viewport.
- Erase Picture is instant; a fade needs Move Picture to the same
  position at 0% opacity over a duration instead.
- "Hero's screen X/Y" is the **feet position**, not center, and is a
  one-shot snapshot at read time, not a live binding — tracking the hero
  with a picture (spotlight, flashlight) requires re-reading and
  re-issuing Move Picture every tick.

**Screen effects (Flash / Shake / Tone / Erase Screen / Weather)**
- Screen Flash and Character Flash: only one of each active at a time
  (second supersedes, doesn't stack, doesn't queue); both are capped to
  1/30s display while a Battle Animation is playing, because the
  animation continuously re-asserts its own per-frame flash state for its
  whole duration — corroborated by many independent sources as one of the
  most commonly-hit surprises on the site.
- Change Screen Tone affects **only** the map tile+character layer —
  pictures, screen/character flash, battle animations, and message text
  are all completely unaffected even at a maximal dark tone; Erase Screen,
  by contrast, hides literally everything. Screen tone **persists across
  map transfers** with no auto-reset (unlike most per-map overrides).
  **The pictures / flash / message-text halves were already correct**:
  `Scene::Map#setup_sprites` (`mruby-rpg2k/mrblib/scene/map.rb`) always built
  `@picture_sprite`/`@flash_sprite`/`@fade_sprite`/`@weather_sprite` and every
  message window as plain top-level sprites, never children of the toned
  `@map_viewport`, so `#update_map_tone`'s viewport tone never reached them —
  no code change needed. ✅ **Battle animations were the one genuine gap, now
  fixed.** `@animation_sprite` — the single shared renderer both a field/
  parallel-process Show Battle Animation (11210) and an in-battle attack's own
  animation play through (`#step_map_animation`) — was a child of
  `@map_viewport` too, so an active Tint Screen wrongly darkened/tinted every
  animation play along with the tiles and hero. Fixed by making it a
  top-level sprite (outside any toned viewport) and splitting the upper
  (above-character) chip layer into its own `@upper_viewport`, tinted in
  lockstep with `@map_viewport` by `#update_map_tone` — needed only so
  `@animation_sprite` keeps drawing in its original slot (over the hero,
  under the upper chip layer; gfx_update's per-parent z sort compares a
  Viewport as one block against its siblings, so pulling one sprite out of a
  shared viewport changes only whether that viewport's tone reaches it, not
  where it draws relative to the layers around it) without itself living
  inside either toned viewport. Covered by two new
  `scripts/rpg2k_scene_check.rb` checks (the upper chip layer still takes the
  identical tone `@map_viewport` does; the animation sprite's viewport is
  neither of the two tinted ones, and it still draws between the player and
  upper-layer sprites), both confirmed to fail against the pre-fix code
  before the fix.
- ✅ **Erase Screen's blackout is auto-cancelled by opening and closing the
  Menu or Save screen**, even though no "Show Screen" ran. `Scene::Menu`
  (Save is one of its commands, not a scene of its own — see the Menu screen
  bullet above) now calls `@state.screen.show(Game::Transition::CUT_IN, 0)`
  in its `#initialize`, the instant the menu opens: an explicit `frames: 0`
  forces a same-frame settle to fully visible regardless of the style's own
  length, and `Game::Transition::CUT_IN` (rather than `NONE`, which is a
  true no-op) so an already-visible screen is left alone. `Game::Screen` is
  shared off `Game::State` between `Scene::Map` and `Scene::Menu`, so
  nothing re-erases it on return — matching RPG_RT never restoring the
  black-out once the menu has been opened and closed.
- Shake strength increases in fixed 2px increments per level; duration 0
  or flash intensity 0 both produce no visible effect (too brief to
  render, not merely "instant").
- Weather Effects "None" while rain/snow is active interrupts and stops
  the running effect.

**BGM / SE**
- 🚧 BGM has a **single channel** — a new Play BGM force-stops whatever's
  playing; re-triggering the exact same file that's already playing does
  **not** restart it (applies new vol/tempo/pan without a break); field
  and battle BGM sharing the same file continue seamlessly across the
  transition. Memorize/Play-Memorized BGM only remembers the *filename*,
  never playback position — replaying always restarts from the top, and
  uses the vol/tempo/pan settings active **at memorize time**, not replay
  time. **The no-restart half is now implemented**:
  `Game::Interpreter#play_audio`'s `:bgm` branch (`mruby-rpg2k/mrblib/
  interpreter.rb`) compares the command's filename against
  `@state.current_bgm[:name]` and skips the `RGSS::Audio.bgm_play` call
  (and the `bgm_looped` reset) when they match, so a same-file re-trigger
  leaves the still-playing track alone. `@state.current_bgm` is still
  updated unconditionally to the command's latest vol/tempo, so Memorize
  BGM continues to stash whatever was most recently requested. **The
  vol/tempo/pan-without-restart half is not addressed**: this build's
  `RGSS::Audio` exposes no primitive to adjust an already-playing BGM's
  volume, pitch, or pan in place — `bgm_play` (`mruby-rgss/src/audio.cxx`,
  backed by `SDL_mixer`) is the only entry point that takes those
  parameters, and it always starts playback from the top. Implementing
  this half would need a new native backend primitive (e.g. an
  `Mix_VolumeMusic`-style setter) that does not exist today.
- SE is truly polyphonic (unlike BGM); ✅ **SE "OFF" now stops all playing
  SEs at once**, instead of silently doing nothing. `Game::Interpreter
  #play_audio` (`mruby-rpg2k/mrblib/interpreter.rb`) returned immediately on
  a blank filename for both Play BGM and Play SE alike, which is correct for
  a blank Play BGM (nothing establishes RPG_RT treats that as anything but a
  no-op) but wrong for Play SE: the editor's "(OFF)" choice is encoded the
  same way, as an empty filename, and since SE is truly polyphonic (no
  single "current" track the way BGM has one), a blank Play SE genuinely
  halts every in-flight sound effect rather than leaving one alone. The
  blank-name branch now calls `RGSS::Audio.se_stop` (already defined as an
  `Audio` module wrapper in `mruby-rgss`, previously unused from this
  codebase) when the command is a Play SE; Play BGM's own blank-name case is
  untouched. Covered by two new `scripts/rpg2k_logic_check.rb` checks (a
  blank-name Play SE reaches the stop-all backend call and plays nothing; an
  ordinary named Play SE still plays normally, not a stop-all), confirmed to
  fail against the pre-fix code before the fix. SE never loops natively
  (unverified, separate claim).
- SE files must be WAVE; BGM accepts MIDI/WAVE/MP3 — an asymmetric format
  restriction.

**Message window / Show Choices / control characters**
- Two message windows can never be shown simultaneously — a hard engine
  limit.
- ✅ **A Face Graphic setting persists through the rest of the current event's
  execution content (not just the next message) and is auto-cleared when
  the event ends, but not before** — it must be explicitly "erased" to stop
  mid-event, unlike Message Options (transparency/position/etc.), which are
  genuinely sticky game-wide with no such reset. `Game::Interpreter`
  (`mruby-rpg2k/mrblib/interpreter.rb`) modelled both the same way: plain
  shared state on `Game::MessageConfig`, set by Change Face Graphic (10130)
  and Message Options (10120) alike, with nothing anywhere clearing the face
  once the event that set it finished — so it silently carried over into
  every later event's own messages too. `#do_change_face` now marks the
  interpreter as owning the shared face state whenever it sets a real
  (non-empty) face (dropping the claim on an explicit empty clear, as
  before), and `#update` drops that claim — clearing `message_config`'s face
  — the instant its own command list genuinely finishes (`finished?`, the
  same point that already flips `@running` false), Call Event nesting
  included since a call shares the same interpreter and call stack; an
  unrelated interpreter finishing elsewhere (a different parallel process,
  say) never touches a face it didn't itself set. Message Options are
  untouched by this — nothing resets them, matching RPG_RT's asymmetry
  between the two commands. Covered by three new `scripts/
  rpg2k_logic_check.rb` checks (the face applies across multiple messages
  within one event but auto-clears once the event ends, while Message
  Options set in the same event stay sticky afterward; a face set inside a
  Call Event survives back into the caller and clears only once the whole
  call — caller and callee — finishes), confirmed to fail against the
  pre-fix code before the fix. It also shrinks the per-line text capacity
  vs. no portrait — unverified, a separate open question.
- 🚧 \c[]/\s[] (color/speed) control codes set inside Show Text **bleed into
  an attached Show Choices list** when the two merge into one window
  (≤4 combined lines) — an explicit `\c[0]` reset is needed to stop
  choices inheriting the preceding text's color. **The colour half is now
  implemented**: `Game::Message.scan` takes an optional `start_color` and
  reports the colour still in effect at the end of the line as `:end_color`
  (`mruby-rpg2k/mrblib/game.rb`), and `Scene::Map#open_message` records a
  Show Text's trailing colour on `@message`, which `#append_choice_lines`
  now seeds its own scans with instead of always starting at 0 — chained
  across the choice labels themselves too, so the whole merged window (text
  then choices) reads as one continuous colour stream that an explicit
  `\c[0]` breaks, matching the finding. **The speed half is not addressed**:
  this codebase drops `\s[]` outright today (see the Message window doc
  above, "the remaining display code (`\s` speed) is dropped") rather than
  varying the reveal rate at all, so there is no speed *state* yet for
  anything to bleed — implementing the bleed would first need `\s[]` itself,
  a larger, separate feature.
- `\>` (instant display) only affects the current line — must be repeated
  per line for a fully-instant multi-line message.
- ✅ **`\<`, `\$`, `\^` each cost one character's worth of display time even
  though they render nothing; `\c[]`/`\s[]` cost none.** `Game::Message.scan`
  (`mruby-rpg2k/mrblib/game.rb`) now advances its `count` reveal-coordinate by
  one for the closing `\<` of an instant span, `\$` (show gold) and `\^`
  (auto-close) — the same coordinate space `\!`/`\./`\|` pauses and `\>`…`\<`
  instant spans are recorded in — while leaving `\>` (span open) and
  `\c[]`/`\s[]` untouched, matching the yado.tk finding that only those three
  are "free". The instant span itself still only covers its literal
  characters (the `\<` tick lands just after the span closes, not inside it),
  so a pause or more text right after one of these three codes now reveals
  one frame later than it would with the code removed — previously they were
  pure no-ops in the reveal counter.
- `\^` doesn't work inside Show Choices even though other codes do.
- Message Options (window transparency/position) are **sticky global
  state** — once set, they apply to every subsequent message window for
  the rest of the game (or until reset), not scoped to the current event.
- Text beyond the display-limit line is silently truncated, not wrapped —
  and because `\V[]`/`\N[]` substitute a runtime value, a message that
  fits in the editor can still overflow and truncate at runtime if the
  substituted value/name is long.

**Battle system (default)**
- ✅ **Battle pages are checked far more often than once per turn** — the
  yado.tk phrasing above ("right after hero action is decided but before the
  turn resolves") undersold it, and so did this runtime: EasyRPG's
  `Scene_Battle_Rpg2k::CheckBattleEndAndScheduleEvents` is called from two
  places, `State_SelectOption` (before the round-start Fight/Auto/Escape menu
  — the "before action-select" case this runtime already had) **and**, per
  its own comment, from `ProcessSceneActionBattle`'s `ePreAction` substate,
  which "happens before each battler acts and also right after the last
  battler acts" — i.e. checked again before *every individual battler's*
  action within the round, not just once at the start. A page whose
  condition turns true mid-round (an enemy's HP crossing a threshold from an
  earlier attacker's hit, say) used to sit until the *next* round's check;
  real RPG_RT would run it immediately, before the next battler in the same
  round even acts. `Scene::Map#drive_battle_animate` now checks between every
  acting battler: a `battler_boundary` flag (set once `Game::Battle#step_action`
  has drained the last buffered hit of one battler's action — a dual-wield
  swing or an all-target Skill/Item queues several from the *same* battler,
  and the check belongs between battlers, not between hits) triggers
  `#run_battle_events` before the next `step_action` call, threading a new
  `return_phase` (`:command` for the pre-existing between-rounds check,
  `:animate` for this one) through to `#leave_battle_event_phase` so a page
  started mid-round resumes the animation loop afterward instead of jumping
  to the command menu partway through a round. **Every** satisfied page still
  fires exactly once per turn regardless of how many times it is checked
  (`pages_run`, unlike map/common events, already confirmed correct above) —
  never before action-select (the original claim's other half already held),
  never after the battle ends. Covered by a new `scripts/rpg2k_scene_check.rb`
  check (an enemy-HP-conditioned page firing before the round settles back to
  `:command`), confirmed to fail against the pre-fix code.
- ✅ **Damage is hard-capped below 1000 (999) by engine spec.** RPG_RT's
  battle damage popup is a fixed three digits, so no single hit — however
  the underlying ATK/DEF/attribute/variance math computes it — can ever
  apply more than 999 to a target's HP in one go. `Game::Battle`
  (`mruby-rpg2k/mrblib/game.rb`) had no such ceiling anywhere on its damage
  path: a normal attack (`#deal_attack`, including a critical's ×3 or a
  charged hit's ×2), an attack skill/item (`#apply_skill_hit`'s negative-HP
  branch, both single- and all-target), an enemy's self-destruct
  (`#enemy_autodestruct`), and per-turn state slip damage
  (`#apply_turn_states`) all subtracted whatever they computed straight from
  `target.hp` with no upper bound — a high enough ATK/attack-power stat
  could one-shot for thousands, something the original engine's fixed-width
  damage display could never even show. Fixed by adding
  `Game::Battle::DAMAGE_CAP = 999` and clamping the final per-hit damage
  value (after variance/attribute scaling and the crit/charge/defend
  multipliers, so the *displayed* number is what's capped) at each of the
  four sites above, right before it's subtracted from HP. Special-skill HP
  recovery's own 999-per-use cap — bundled into this same bullet
  originally — is now ✅ too, its own bullet above (`RECOVER_CAP`); the
  item drop rate's 1% floor remains open (see the "Numeric constants worth
  asserting directly" bullet above, which has had both of these removed now
  that they're covered).
  Regression coverage added to `scripts/rpg2k_logic_check.rb`: a
  high-ATK, always-critical normal attack against a defenceless target
  clamps at 999 rather than the uncapped 6000 (2000 base × 3 crit), and an
  attack skill computing a raw 5000 HP hit likewise clamps at 999.
  **A fifth site was missed by this fix and is now covered too: Simulated
  Attack (10500, "Damage Processing" in the yado.tk write-up), the raw
  event command that hurts a target with no attacker at all.**
  `Game::Interpreter#do_simulated_attack` (`mruby-rpg2k/mrblib/
  interpreter.rb`) computes its own damage independently of `Game::Battle` —
  `atk - def * p_def / 400 - int * p_spi / 800`, matching the yado.tk
  finding that this command's defence/spirit "effectiveness" percentages
  divide by 4 and 8 respectively rather than the normal attack's own
  `ATK÷2 − DEF÷4` formula (**confirmed already correct**, no change needed
  for the formula itself) — and had no ceiling on the result, so a large
  enough Attack Power parameter could apply (and report through the
  command's store-in-variable option) far more than 999 in one hit. Fixed
  by clamping to the same `Game::Battle::DAMAGE_CAP` before it reaches
  `Actor#change_hp` or the result variable. Covered by a new
  `scripts/rpg2k_logic_check.rb` check (a 5000-power Simulated Attack
  against a defenceless, high-max-HP target clamps at 999, both in the HP
  change and the stored variable), confirmed to fail against the pre-fix
  code.
- ✅ **Turn-order tie-break on equal Agility: an ally acts before an
  equal-agility enemy; among tied allies, the lower actor id acts first.**
  The ally-before-enemy half was already correct by construction —
  `Game::Battle#turn_order`'s `sort_by` tie-broke on each battler's index in
  `(@allies + @enemies).reject(&:out_of_play?).each_with_index`, and since
  `@allies` is concatenated first, every surviving ally always carried a
  lower index than every surviving enemy — but the **among-tied-allies**
  half was a genuine gap: that same index reflects party **seat/join
  order**, not actor id. `Game::Party#add_actor` (`mruby-rpg2k/mrblib/
  game.rb`) appends to `@actors` on join, so seat order only matches id
  order until a member has left and rejoined behind a different one (the
  same seat-vs-id split already documented in the "Hero X is in the party"
  bullet above) — at that point two same-agility allies would tie-break by
  whichever happened to occupy the earlier seat, not by the lower id RPG_RT
  actually uses. Fixed by widening `turn_order`'s sort key: a new
  `b.actor ? 0 : 1` term ranks any battler carrying a source `Game::Actor`
  (i.e. an ally — `Game::Battle.from_actor` always sets `Combatant#actor`,
  and an enemy `Combatant` never does) ahead of one that doesn't,
  independent of array position, making the ally-before-enemy rule
  structural rather than incidental; the final tie key is `b.actor.id` for
  an ally instead of the old positional `i`. An enemy tie has no documented
  ordering rule and keeps its prior troop-definition-order tie-break via
  `i`, unchanged. Covered by a new `scripts/rpg2k_logic_check.rb` check (two
  allies seated out of id order, plus an equally-fast enemy, resolve
  ally-id-1 → ally-id-2 → enemy), confirmed to fail against the pre-fix
  code.
- The party "exhaustion %" battle-event condition is computed as
  `100 − 100×((ΣHP/ΣMaxHP×2 + ΣMP/ΣMaxMP)÷3)` — HP weighted twice MP's
  weight.
- No built-in hero double-action; enemies have a native "Attack Twice"
  action-pattern option as the only built-in double-action mechanism.
  Enemy action-pattern selection: candidates are patterns whose condition
  is currently true; the engine looks from the highest priority tier down
  to priority−9, computes a per-pattern weighted "importance" from battle
  state, then rolls RNG against those weights. A turn-condition shorthand
  like "3×?+5" means: first candidate on turn 5, then every 3 turns
  after.
- ✅ **An HP-increase cannot revive a downed (0 HP) combatant**, checked
  across all three paths that can raise HP. The **field actor** path
  (`Game::Actor#change_hp`, `mruby-rpg2k/mrblib/game.rb`) was already
  correct: it returns early with `return @hp if dead?`, so no HP change
  (heal or further damage) touches a downed party member until Change
  State or Full Recovery clears the death state. The **enemy/battle-event**
  path was the actual gap: `Game::Interpreter#do_change_monster_hp` (Change
  Monster HP, code 13110, `mruby-rpg2k/mrblib/interpreter.rb`) applied its
  delta straight to the `Game::Battle::Combatant` with no such guard, so a
  positive amount on a 0 HP enemy (`dead?` is `hp <= 0` for a Combatant)
  unconditionally raised it back above 0, silently reviving it — fixed by
  making a positive amount a no-op once the target is already dead,
  mirroring `Actor#change_hp`; a further (negative) hit on an already-dead
  enemy is untouched by the guard and simply re-clamps to the command's
  existing lethal-flag floor as before. The **in-battle Skill/Item
  command** path (a heal spell/item cast mid-fight) was checked too and
  found already correct: `Game::Battle#apply_command` / `#apply_command_all`
  gate every Skill/Item command — single- and all-target alike — on
  `target.dead?` *before* ever calling `#apply_skill_hit`, so a command
  aimed at a downed combatant fizzles outright (no SP spent, no log entry,
  HP untouched) rather than reaching the HP-raising branch at all. An
  explicit state-cure (Full Recovery, a revive item/skill) remains the only
  modelled way to stand a downed combatant back up, writing HP directly
  rather than through any of these three paths. Regression coverage in
  `scripts/rpg2k_logic_check.rb`: the Change Monster HP fix is confirmed to
  fail against its pre-fix code, and an all-ally heal aimed at both a downed
  member and a wounded one confirms the Skill/Item path skips the downed
  member entirely while still healing the wounded member normally (true
  both before and after, since that path was never broken).
- ✅ Damage Processing (the raw event command, Simulated Attack 10500) uses a
  **different formula** from the built-in normal attack: normal attack =
  `(ATK÷2) − (DEF÷4)`, but this command computes `AttackPower − (DEF÷4)`
  with **no automatic halving** of the given Attack Power — replicating a
  normal attack requires manually halving the parameter first.
  Defense-effectiveness 100% = DEF/4 (not full DEF); Spirit-effectiveness
  100% = Mind/8. **Confirmed already correct** —
  `Game::Interpreter#do_simulated_attack` already implements exactly this
  formula — but the command was missing the same 999 damage cap every other
  damage path has, which is now fixed; see the fuller writeup under the
  "Damage is hard-capped below 1000 (999)" bullet above.
- ✅ Multiple active states: only the highest-priority one is **displayed**
  (`Game::States.significant`, unchanged), but all active states still
  mechanically apply (a hidden poison keeps ticking under a displayed
  confusion — already true, since the map/battle slip-damage and
  turn-restriction passes walk the whole `states` array, not just the
  significant one). **A state ≥10 priority below the current highest is now
  auto-removed** (`Game::States.prune`, called the instant a *new* state
  lands — a state may itself immediately push an existing one out, or be
  pushed out itself by one already held that outranks it by the gap).
  Unlike `#significant`, ties don't matter for pruning — only the *value* of
  the top priority does, so several states sharing it all survive; "ties go
  to the higher state ID" is about which one **displays**, not which ones
  live. State #1 (Knockout) is exempt on both sides — it is never pruned and
  its own priority is never consulted as "the current highest" either,
  matching `#significant`'s existing death special-case; knockout is tracked
  through HP/`Actor#dead?`, not through this ranking. Wired into every
  infliction path: `Game::Actor#add_state` callers (`Change Condition`, field
  `cast_skill`) via a new `Game::Party#state_table` accessor, and
  `Game::Battle#roll_inflict` via the battle's own state table. One
  simplification, not confirmed against real RPG_RT: a state's accuracy-roll
  "landed" report is unconditional even where pruning removes it again the
  same instant — no test bed exercises two states with a large enough
  priority gap to say whether the real messaging differs. Covered by new
  `scripts/rpg2k_logic_check.rb` checks (the pure `States.prune` rule, and
  one per infliction path), confirmed to fail against the pre-fix code.
- ✅ A weapon-type Attribute (as opposed to a magic-type one) gates skill
  usability on having a matching-attribute **weapon** equipped — armor
  with the same attribute does not satisfy it (already flagged as a
  09_bug finding above; corroborated independently via the Attribute
  database page too). `Game::Party#weapon_attribute_ready?` reads each of a
  skill's `attribute_effects` ids, checks the database `property` table's
  `type` field (0 weapon / 1 magic) for each, and — for the weapon-type ones
  only — requires `Actor#weapon_attributes` (the union of the *equipped
  weapon slot's* item(s) own `attribute_set`, already used for battle damage
  scaling) to cover every one of them; a magic-type attribute, or a skill
  with none at all, gates nothing. Wired into `#can_cast?`, the single choke
  point every cast path (field, battle, escape/teleport/switch skills) already
  runs through. A skill naming more than one weapon-type attribute needs all
  of them covered (one weapon or several via dual-wield) — the literal reading
  of "a weapon carrying **that** attribute", not confirmed against a
  multi-attribute skill since neither test bed ships one. Covered by a new
  `scripts/rpg2k_logic_check.rb` check, confirmed to fail against the pre-fix
  code. **Weapon-type × magic-type attribute stacking is built now too** — a
  separate question from equip gating, in the damage formula rather than
  usability. EasyRPG's `Attribute::ApplyAttributeMultiplier` keeps the
  *strongest* rate within each type (physical/weapon and magical/magic
  tracked independently) and, when an attack carries both at once,
  **multiplies** the two as successive percentage scalings of the damage
  (200%×50% nets 100%, not an average and not just the single strongest
  rate across every attribute regardless of type). `Game::Battle#apply_attr_multiplier`
  (renamed from `#attr_multiplier`, which returned a percentage rather than
  the scaled damage — the truncation order between the two isn't always the
  same, so it now takes and returns the actual damage figure, matching
  `ApplyAttributeMultiplier`'s own signature) reads each attribute's type
  off the same `@attributes` (`property`) table `#attr_rate` already uses.
  RPG2000 attribute rates never go negative, so EasyRPG's "one side
  negative" fallback branch (a 2003 `attribute.type` add-on) never applies
  here. Covered by new `scripts/rpg2k_logic_check.rb` checks (both types at
  once multiplying, and two attributes of the *same* type still keeping the
  strongest rather than multiplying against each other).
- Battle Animation: only one on screen at a time (a second forcibly cuts
  off the first); 1 frame = 1/30s, but a "Wait" frame is internally
  **two** consecutive 0.0s-wait frames, not one; chaining two Show Battle
  Animation calls back-to-back produces a visible one-frame stutter.
  ✅ **A Common Event Parallel Process's own Show Battle Animation (11210)
  now actually plays**, rather than its "wait until it finishes" flag being
  silently ignored. `Scene::Map#drive_parallel_wait`'s wait-kind dispatch had
  no `:animation` case at all, so a parallel process that issued one fell
  into the generic "background: ignore message/choice/teleport requests"
  branch and was `#resume`d on the very next frame — the animation was never
  built, drawn, or waited on, only the foreground `@interpreter`'s own
  requests ever reached `#drive_map_animation`. Fixed by generalizing
  `#drive_map_animation`/`#init_map_animation`/`#start_map_animation` to take
  the waiting interpreter explicitly — a new `@map_animation_interp` tracks
  which one currently owns the single `@map_animation`/`@anim_wait` slot, so
  `#step_map_animation`/`#step_animation_wait` resume the right one instead of
  always the foreground `@interpreter` — and adding a `:animation` branch to
  `#drive_parallel_wait` that drives the same shared renderer. This only
  covers making a parallel process's request render and block that process at
  all; the "only one at a time, second forcibly cuts off the first" precedence
  rule between two *concurrent* requests (which interpreter, if any, gets
  bumped) is intentionally left unmodelled — a request arriving while the slot
  is held simply waits its turn — since resolving it needs a real RPG_RT
  comparison this environment cannot run. The "Wait frame is two 0.0s frames"
  and "back-to-back calls stutter" claims are likewise still open. Covered by
  two new `scripts/rpg2k_scene_check.rb` checks (a parallel process's Show
  Battle Animation holds it, then resumes once the animation finishes; the
  animation actually renders — sprite shown, screen flash fired — for a
  parallel-process request, not just a foreground one), both confirmed to
  fail against the pre-fix code before the fix.
- ✅ **Show Battle Animation (11210) targeting a vehicle now plays over that
  vehicle's own live position**, instead of silently defaulting to the
  player's. `Scene::Map#animation_target_pixel` (`mruby-rpg2k/mrblib/
  scene/map.rb`) resolved a Move-Event-style target id to the player, "this
  event," or a map event by id — but had no case at all for a vehicle slot
  (10002-10004, boat/ship/airship): a vehicle id never matches a real map
  event id, so it fell straight through to the "map event by id, defaulting
  to the player" branch and silently drew the animation over the player
  instead. Fixed with a new `#vehicle_pixel`, reading the target `Game::
  Vehicle`'s live `x`/`y` straight off `Game::State` — the same source
  `#event_operand`'s Control Variables "character position" vehicle fix
  reads (see the "Vehicles" bullet under "Party / Actor / Vehicle" above) —
  which needs no scene-side camera hook and, matching that fix's own
  quirk, does not check whether the vehicle is actually on the map this
  scene has loaded before reading its position: a vehicle target reads its
  real x/y even when a different map is on screen, exactly as yado.tk
  describes. Covered by a new `scripts/rpg2k_scene_check.rb` check (a Show
  Battle Animation targeting the boat lands at the boat's own tile, not the
  player's or the triggering event's), confirmed to fail against the
  pre-fix code before the fix.
- ✅ **A Battle Animation's per-frame target-scope flash (flash_scope 1) now
  actually flashes its target**, instead of being silently dropped. The LCF
  `animation_timing` schema (`mruby-lcf/mrblib/schema.rb`) documents
  flash_scope as a three-way field — 0 none / 1 target / 2 screen — but
  `Scene::Map#fire_animation_flashes` (`mruby-rpg2k/mrblib/scene/map.rb`)
  only ever checked for `== 2`, so a very common animation idiom (flash the
  hit enemy red on a damage frame) silently did nothing. Scoped to the
  battle-round path: a skill/item log entry already carries a
  `target_index` (`Game::Battle#apply_skill_hit`, `@enemies.index(target)`)
  that `#battle_animation_pixel` already uses to centre the animation on the
  right `@battle_ui[:enemy_sprites]` entry, and the new `#fire_target_flash`
  reuses the same index to flash that sprite — nil (an ally target) is a
  silent no-op, since RPG2000's front-view battle draws no sprite for a
  party member to flash (the same fact `#battle_animation_pixel`'s own
  comment already documents) — nothing here invents ally-side behaviour. A
  map-triggered Show Battle Animation (11210) aimed at a map character is a
  different target class entirely (the CharSet-based Flash Sprite mechanism
  already models flashing one) and is not addressed by this fix;
  `#build_animation`'s map-triggered call site never sets `target_index`, so
  a flash_scope-1 timing there stays a no-op too, same as before. The flash
  itself uses the RGSS `Sprite#flash`/`#update` primitive
  (`mruby-rgss/src/lib.cxx`) — already ported natively but unused anywhere
  else in this codebase — decayed one frame at a time by a new
  `#update_enemy_flashes`, driven every frame `@battle_ui` is up from
  `#drive_battle`, the same way `#update_map_tone` already drives
  `@map_viewport`/`@upper_viewport`'s tone per frame. Colour/strength scale
  from the LCF's 0..31 fields the identical `*8` way the screen-flash branch
  already does. Covered by two new `scripts/rpg2k_scene_check.rb` checks (a
  target-scope timing flashes the targeted enemy sprite with the scaled LCF
  colour for `ANIM_FLASH_FRAMES`, leaves the screen flash and an untargeted
  bystander sprite untouched, and fades back to nothing once driven for its
  full duration; a target-scope timing with no resolvable target sprite is a
  silent no-op, not a crash), the first confirmed to fail against the
  pre-fix code before the fix.
- ✅ **A Timer with "valid during battle" checked force-ends the battle**
  the instant it reaches 0:00, regardless of encounter source (default or
  scripted) — an easy accidental trap if the same Timer is reused for a
  non-combat countdown. `Game::Timer#tick` (`mruby-rpg2k/mrblib/game.rb`)
  already returned `true` on exactly that frame — it only ever does so for a
  timer carrying the battle flag while a fight is running, since one without
  it is held frozen (never reaching zero) for the duration — but
  `Scene::Map#update` threw the `Game::State#tick_timer` return value away.
  Now, when it reports a finish while `@battle_ui` is present, the scene
  calls `#finish_battle(:abort)` directly, the same outcome Terminate
  Battle's own `#finish_terminated_battle` produces, just reachable from any
  battle phase (command/target/event/result) rather than only from a running
  battle-event page. Matches Terminate Battle in satisfying neither the
  Win/Escape/Defeat handler branch — an unlabeled third outcome the event
  resumes past.
- Common events (including Parallel Process ones) **never run during
  battle**, even if their trigger switch flips mid-battle — execution is
  deferred until control returns to the map.
- ✅ **Bare-hand attacks carry no elemental attribute by default; an
  element's effect-rate at 0% deals exactly zero damage (not healing).**
  Confirmed already correct rather than left as an open claim:
  `Actor#weapon_attributes` (`mruby-rpg2k/mrblib/game.rb`) only scans the
  *weapon*-slot item(s) for an `attribute_set`, so an unarmed actor's loop
  finds nothing and returns `[]` — no attribute at all, matching the site.
  `Battle#apply_attr_multiplier` never flips a 0% rate into recovery: a
  matched (non-nil) rate of exactly 0 takes the `elsif physical` /
  `elsif magical` branch and computes `0 * dmg / 100 = 0`, not a sign flip —
  so a full immunity zeroes the hit rather than healing the target. No code
  change; the claim already held.
- ✅ **Battle Interrupt (Terminate Battle, 13410) already satisfies neither
  the Win nor Lose branch of the enclosing Enemy Encounter command, and
  already leaves the win/escape/defeat tallies alone — confirmed rather
  than an open claim, and the regression coverage that looked like it
  already proved this was actually vacuous.** `Game::Interpreter#resume_battle`
  (`mruby-rpg2k/mrblib/interpreter.rb`) only bumps `win_count`/`defeat_count`/
  `escape_count` inside a `case result when :victory/:defeat/:escape` block
  with no `:abort` arm, and `#find_battle_option`'s `BATTLE_HANDLERS` lookup
  table has no `:abort` key either, so an unmatched lookup (`want = nil`)
  never finds a `[Victory]`/`[Escape]`/`[Defeat]` marker and instead lands on
  the encounter's own `END_BATTLE` — resuming the event right after Branch
  End, exactly as the site describes. `battle_count` (the "a battle was
  entered" tally the site's "battle-count stat" bullet half refers to) is
  bumped once at `do_enemy_encounter`, independent of any outcome, so it is
  untouched by this path either way. No code change was needed for the game
  logic — but the existing `scripts/rpg2k_scene_check.rb` check that looked
  like it already covered this (`'Terminate Battle from a page ends the
  fight and resumes the event'`) had a loop bug: `12.times { scene.update;
  break if @battle_ui.nil? }` breaks on the very first frame, before the
  battle has even opened, since `@battle_ui` reads as `nil` then too —
  identical to how it reads once the fight has genuinely closed (the
  Timer-force-end check right after it, which this bullet cites for the
  "no Win/Escape/Defeat handler matched" half, avoided the trap already, by
  explicitly waiting for `@battle_ui` to appear before ever expecting it to
  clear). Confirmed by re-running the *original* (pre-fix) check against an
  injected `:abort → win_count` bug: all 344 checks still "passed". Fixed by
  a new `open_then_close_battle` helper that first asserts `@battle_ui`
  actually appears, then asserts it disappears again, and by a new check
  built on it (`'Terminate Battle matches neither Win/Escape/Defeat and only
  bumps the battle-entry count'`) that asserts `battle_count == 1` with
  `win_count`/`escape_count`/`defeat_count` all `0` and neither handler
  switch set — confirmed to fail against both an injected win-count bug and
  an injected `BATTLE_HANDLERS[:abort]` mapping.
- ✅ **Enemy Appearance (Show Hidden Monster) already gets both halves of this
  right.** Targeting an already-appeared enemy is a silent no-op:
  `Scene::Map#reveal_battle_monster` (`mruby-rpg2k/mrblib/scene/map.rb`)
  returns immediately once `member.hidden` is already false, before touching
  the sprite or the combatant. The "reinforcement never spawns" half looked
  like a real gap on paper — `Game::Battle::Combatant#out_of_play?` treats a
  still-hidden troop member as not-alive
  (`dead? || hidden`), so `#finished?` would read a fight as won the instant
  the only *visible* enemy died, if a scripted reinforcement's own Show
  Hidden Monster hadn't cleared its `hidden` flag yet — but it already has to
  have, by construction: this is exactly the race the "Battle pages are
  checked far more often" fix above (`@battle_ui[:battler_boundary]`) closes.
  A battle page conditioned on the dying enemy's HP gets to run — and, via
  `#apply_battle_event_requests`, have its Show Hidden Monster command take
  effect — at the battler boundary right after the killing blow, strictly
  before `#drive_battle_animate`'s next `step_action` call (finding nothing
  left pending for the round) reaches `#finish_round_animation`'s own
  `battle.finished?` check; the two are sequential states in the same phase
  machine (`:event` must finish and return to `:animate` before `:animate`
  can ever reach that check again), not a race that can land either way.
  Covered by a new `scripts/rpg2k_scene_check.rb` check (a reinforcement
  hidden behind an Enemy-HP-conditioned page is revealed while the battle is
  still running, never after it has already settled into `:result`; a second
  reveal of an already-visible member is confirmed to be a sprite-rebuild
  no-op), confirmed to fail if the battler-boundary check is disabled.
- **Documented race condition**: a Battle Processing "Lose: Branch"
  that revives the party can still lose to an erroneous instant Game Over
  if a Parallel Process is running concurrently — the parallel process's
  own game-over check can fire before the Lose-branch's revive commands
  execute. Corroborated by many independent sources as one of the site's
  most emphasized gotchas; the documented mitigation is manually stopping
  all parallel processes immediately before entering such a battle and
  restarting them from both the Win and Lose branches.
- A **map event with Parallel Process trigger** executing "Set Vehicle
  Location" **crashes RPG_RT** with a module-address access-violation
  error; the identical command from any other trigger type, or from a
  Parallel-Process **common** event, does not crash. (An authentic engine
  crash — flagged for awareness, not necessarily something to reproduce.)

**Party / Actor / Vehicle**
- Party is hard-capped at 4; adding a 5th via Change Party Member is a
  silent no-op. Removing a member preserves equipment/level/EXP/HP/status;
  re-adding a KO'd member keeps them KO'd. Only the party **leader's**
  sprite is ever drawn on the field, regardless of party size.
- Empty party doesn't itself Game Over, but battling with one is instant
  defeat; all-KO'd (or an unrecoverable input-blocking state across the
  whole party) is instant Game Over the same way.
- "Hero X is in the party" always evaluates in **database ID order**, not
  current seat/slot order — there is no built-in way to read a member's
  current seat position.
- Vehicles: an un-placed vehicle defaults to Map ID 0, (0,0) — **confirmed
  already correct**, `Game::Vehicle#initialize`'s own defaults
  (`mruby-rpg2k/mrblib/game.rb`). An airship's *initial* position can be set
  on unlandable terrain and boarded there without issue (the landability
  check is skipped only for the starting placement) — already true here too,
  since nothing validates a vehicle's position outside of `#disembark_vehicle`
  — and Set Vehicle Location has **no** landability validation at all (will
  happily place it somewhere unlandable) — likewise already correct,
  `Game::Interpreter#do_set_vehicle_location` writes the given map/x/y
  straight through with no passability check of any kind. Random encounters
  stay active on ships (governed by terrain settings) but are **hard-disabled**
  on airships with no database toggle — already correct too,
  `Scene::Map#check_random_encounter`'s `return if @state.party.flying?(@state)`
  early-out (`Game::Party#flying?` — true only while `boarded == :airship`)
  skips the roll entirely regardless of terrain, with no equivalent early-out
  for a boarded boat/ship. ("It can never land on a tile a map event occupies
  regardless of terrain" was the one genuine gap in this bullet — now fixed,
  see below.)
- ✅ **Small/large ships can never overlap an event's tile even with a
  passable graphic + below-characters priority** (which *does* let the
  walking hero overlap it fine via the already-implemented priority-type
  gating) — a ship needs the *blocking event's own* move route to have
  Through Mode on instead; ships ignore priority-type/`overlap_forbidden`
  gating for this purpose entirely and just check the blocked event's own
  Through Mode flag. `Scene::Map#vehicle_passable?`'s boat/ship branch
  (`mruby-rpg2k/mrblib/scene/map.rb`) used to reuse the exact same
  `blocker[:layer] == LAYER_SAME || blocker[:overlap_forbidden]` occupancy
  test the hero's own `passable?`/`char_passable?` use, so a below-
  characters event never blocked a ship at all — the opposite of RPG_RT,
  which always blocks a ship on such a tile unless that specific event has
  Through Mode enabled. The blocker check is now `blocker &&
  !blocker[:char].through`, reading the same `Game::Character#through`
  accessor (`attr_accessor :through`, toggled by the Set Move Route
  Through Mode ON/OFF commands) that the hero's own Through Mode already
  uses — this is a one-line, ship-specific divergence from the hero's rule,
  not a change to the hero's passability or to the airship branch (which
  ignores events entirely and flies over everything, unaffected). Covered
  by a new `scripts/rpg2k_scene_check.rb` check (a boarded boat is stopped
  by a below-characters event on an otherwise boat-passable tile; setting
  that event's own Through Mode on lets the boat sail through it).
- ✅ **An airship can never land on a tile a map event occupies, regardless
  of terrain** — the same vehicle-specific Through-Mode rule as the boat/ship
  fix directly above, applied to landing rather than sailing. Flying itself
  already ignored events entirely (`#vehicle_passable?`'s airship branch
  never reads `@event_tiles`, so an airship can cruise directly over a
  below-characters event a walking hero would just as happily overlap), but
  `Scene::Map#airship_landable?` — the one place events reach it at all, via
  `#disembark_vehicle`'s airship branch — was gating its own blocker check on
  the hero's priority-type occupancy test
  (`blocker[:layer] == LAYER_SAME || blocker[:overlap_forbidden]`), the exact
  same reused-hero-rule mistake the boat/ship fix above already corrected for
  sailing: a below-characters event was silently landable on instead of
  refusing the landing. The blocker check is now `blocker &&
  !blocker[:char].through`, textually identical to `#vehicle_passable?`'s
  boat/ship branch; the terrain's own `airship_land` flag and flight itself
  are untouched. Covered by a new `scripts/rpg2k_scene_check.rb` check (an
  airship boarded directly over a below-characters event cannot land there
  despite `airship_land: true`; turning that event's own Through Mode on lets
  it land), confirmed to fail against the pre-fix code before the fix.

**Save / Load persistence — consolidated master list**
Runtime state that does **not** survive a map re-visit (leave and return,
no save/load needed): map event positions (reset to their default page-1
placement), Chipset Change, Panorama/parallax Change, Encounter Steps
Change, Tile Replacement, a move-route "Change Graphic" on any character,
Screen Scroll offset (snaps back instantly on return rather than
animating), a map event's own parallel-process running state.

State that does **not** survive a save/load specifically (distinct from
mere map-revisit): screen-shake offset (never saved, always resets);
BGM/SE playback position (always restarts a track from the beginning even
though the *filename* is remembered); Screen Scroll offset (saved but
documented as broken/buggy after resuming — the site explicitly
recommends never saving mid-scroll). A **Common Event's** parallel-process
position **does** survive save/load (✅ fixed for the portable Marshal save,
see "A Common Event's Parallel Process now survives a Transfer Player and a
save/load" above; the `.lsd` export still does not, chunks 113/114 remain
opaque) — the asymmetry with map events is the point.

State that persists across **both** map-revisit and save/load: a
Common Event's parallel-process interpreter position (until explicitly
completed); a map event's move route/execution point if paused mid-way
(survives save/load, but a map-file update force-terminates it and a
database update force-terminates an in-progress common event instead);
Change Menu Prohibit (unlike Change Save/Teleport/Escape Prohibit, which
are scoped to the current map only).

Editor-side database changes vs. old saves: reordering database entries
(Actors/Skills/Items) reassigns old-save data **positionally**, not by a
stable id — swapping two items' order in the editor makes an old save's
stored count for one silently read as the other's. Lowering a max
HP/MP does not retroactively clamp an old save's current value (silently
allows current-above-max to stand). A "learn skill at level X" change made after a
character already passed that level does not retroactively grant it, even
if the new requirement is now lower than the character's saved level.
Editing and re-saving the **map file itself** resets that map's event
positions to default on the next load of an old save against the new map
data (already tracked above as a narrow, likely-inapplicable edge case for
this reimplementation, since it has no notion of "the map data changed
since this save was written").

**Concrete runtime error catalog** (from the `09_bug/` remainder sweep) —
useful as a checklist for what a from-scratch reimplementation should
itself detect and fail loudly on, rather than silently misbehave:
invalid event ID (four distinct causes: stale Variable-Op/Move-Route
target, common event referencing a map-event ID absent on the *current*
map, "This Event" inside a common event, a variable-driven Call Event
resolving to no match); invalid event *page* (event exists, page number
doesn't — a **separate** error from invalid event, i.e. RPG_RT validates
event-id-existence and page-existence as two distinct checks); invalid
map (Transfer Player / Teleport-to-Remembered-Location targeting a
nonexistent map id — error text includes the literal missing filename);
invalid hero, skill, item, enemy, enemy group, battle animation, terrain,
chipset, common event (all: a database shrink leaves a dangling id
reference somewhere, shown as "?" in the editor); event-call recursion
past 1000. Several of these errors are **deferred** until the stale
reference is actually exercised at runtime rather than raised at load
time — e.g. invalid terrain only errors when the player steps onto the
specific stale tile, invalid battle animation only when it would actually
display, invalid skill only when a skill-select screen opens (or, if the
dangling ref is in a hero's learned-skill list, at the moment of
level-up).

**Map/Event ID assignment & tile occupancy**
- Event IDs (and separately, Map IDs) are assigned by **creation order**
  and are **reused** — deleting one frees its number for the *next*
  created entity to reuse (not append-only). A **copy-pasted** map event
  specifically takes the **lowest currently-unused** id on that map, not
  the next-highest — so cut+paste (vs. drag) can silently renumber an
  event and break other commands' hardcoded numeric references. Only
  drag-and-drop reordering in the map tree preserves ids.
- ✅ **"Get Event ID at Location" now still resolves a temporarily-erased
  event at the tile it occupied when it was erased**, instead of reading
  back 0 there for the rest of the visit — matching yado.tk's claim that
  RPG_RT keeps answering even though the erased event no longer draws,
  moves or blocks. `Scene::Map#erase_event` (`mruby-rpg2k/mrblib/
  scene/map.rb`) used to drop the event from `@event_tiles` — the same
  table `#event_id_at` (the Store Event ID query) reads — unconditionally
  on erasure; it now also freezes the tile in a new
  `@erased_event_positions` hash (an erased event cannot move any further,
  so one snapshot taken at erasure time is enough) that `#event_id_at`
  falls back to. The pre-existing "highest id among several events sharing
  a tile" rule (confirmed already correct — see the "Processing order"
  bullet above) now spans live and erased events together: several ids on
  one tile, in any live/erased mix, still resolve to the highest of them.
  **The other half of this same claim — an event whose current page
  conditions simply aren't met — is separate and still open**: such an
  event never gets a `Game::Character` built at all (`#build_events` skips
  it outright whenever no page's conditions are satisfied), so there is no
  position to answer from without first deciding what "its" position even
  means while hidden, which would need a real RPG_RT comparison to pin
  down rather than a guess. The "id-lookup position snaps to an event's
  destination tile the instant it begins moving" half of the original
  bullet was already confirmed correct earlier, under the `Map Event`
  "hero touches event" bullet above (`#reoccupy` rewrites this same
  `@event_tiles` table the instant a step commits, well before the visual
  slide catches up) — `#event_id_at` reads that same table, so the same
  fact already covered it. Covered by three new
  `scripts/rpg2k_scene_check.rb` checks (an erased event alone on a tile
  still answers with its id; an erased event still outranks a lower-id
  live event sharing its tile; a live event still outranks a lower-id
  erased one), two confirmed to fail against the pre-fix code before the
  fix.

**Database field semantics** (from the `11_db/` sweep, 48 findings — the
single densest source in this pass; only the ones not already listed
above are repeated here)
- **Sell price = `floor(list price / 2)`; price 0 = unsellable in a shop
  but free if placed in a shop's own buy list — confirmed already
  correct**, all three facts, no code change needed. `Game::Shop#sell_price`
  (`mruby-rpg2k/mrblib/game.rb`) is `price(id) / 2`, plain Integer division
  which truncates toward zero the same as `floor` for the non-negative
  prices a database ever stores. `#sellable?` requires `price(id) > 0`
  (alongside actually holding the item), so a price-0 item — RPG2000's own
  way of marking a key item unsellable — can never be sold back regardless
  of how it entered the party's bag. That price-0 exemption is scoped to
  *selling*: `#max_buy` short-circuits to the 99-item stack cap alone
  (`return room if cost <= 0`) rather than dividing the affordable count by
  a zero price, so a shop that deliberately stocks a price-0 good in its
  own buy list still lets the party take it for free, matching the second
  half of the claim exactly. Already covered by existing
  `scripts/rpg2k_logic_check.rb` checks predating this entry — `'Shop sell
  refuses unowned, price-0 (key), or in a buy-only shop'`, `'Shop max_buy of
  a free item is limited only by the cap'` (its own comment: "a price-0
  good does not divide by zero") and `'Shop sellable_items lists only held,
  priced goods in id order'` — none of them vacuous; each asserts a concrete
  gold/item-count/list outcome.
- State resistance rank A-E only gates **susceptibility** — the actual
  proc chance is entirely the *skill's own* occurrence-rate field (0%
  occurrence never applies regardless of rank) — **confirmed already
  correct**: `Game::Battle#roll_inflict` (`mruby-rpg2k/mrblib/game.rb`)
  computes `prob = chance * state_susceptibility(target, sid) / 100`, so a
  0% `chance` (the skill's own occurrence-rate operand) always yields
  `prob = 0` regardless of what `state_susceptibility` scales it by.
  Attribute resistance rank A-E already maps to the Attribute database's own
  per-rank effect-% table too (`Game::Battle#attr_rate`, `a_rate`..`e_rate`
  with a `[300, 200, 100, 50, 0]` fallback — **confirmed already correct**,
  no change needed). ✅ **Death/Knockout is now exempt from rank scaling and
  always lands at the skill's own occurrence rate.** RPG2000 has no separate
  instant-death mechanic — an "instant death" spell is just a skill whose
  state-effect list names Knockout (state id 1, `Game::Actor::DEATH_STATE`)
  directly — but `state_susceptibility` scaled it through the target's
  ordinary `state_ranks` lookup exactly like any other status, so a rank-E
  ("immune") target silently blocked Knockout too, the opposite of the
  yado.tk finding. Fixed with an early `return 100 if sid ==
  Game::Actor::DEATH_STATE` before `state_susceptibility` ever consults
  `state_ranks`, leaving `roll_inflict`'s already-carried/"already" handling
  and every other state's rank scaling untouched. Covered by two new
  `scripts/rpg2k_logic_check.rb` checks (a rank-E target still catches
  Knockout; the same rank on an ordinary state — the control case — still
  resists it, pinning the exemption to state id 1 specifically), the first
  confirmed to fail against the pre-fix code before the fix.
- ✅ A skill flagged "attribute defense up/down" (field 45,
  `affect_attr_defence`) now shifts the target's rank for each attribute in
  its `attribute_effects` list by **exactly one step**, capped at ±1 from the
  rank the battle started at (`Game::Battle::Combatant#attr_base_ranks`), for
  every attack (scope enemy) *and* buff/recovery-style (scope self/ally)
  skill alike — `Game::Party#battle_skill_command` computes the shift on both
  branches, `Game::Battle#apply_attr_shift` applies and caps it. It
  **resets automatically at battle end** for free rather than needing an
  explicit reset: `attr_ranks` is a fresh `Hash` built from the database row
  on every `Combatant#attr_ranks_of` call (`Game::Actor#attribute_ranks`
  caches nothing), and `Battle#apply_to_party` never writes it back to the
  actor — so a shift dies with the Combatant along with everything else the
  fight didn't ask to persist. **The direction is this build's own reading,
  not confirmed against RPG_RT or either test bed**: it reuses
  `reverse_state_effect` (unset = up/better, set = down/worse), the same
  polarity flag a skill's state effects already use, on the assumption
  RPG2000's skill editor drives one shared "raise/lower" toggle for both the
  state-effect list and the attribute-defence list rather than a separate
  field of its own — neither Nepheshel nor mtf-meido-action ships a skill
  with the flag set, so there is nothing to check it against. Attribute
  ranks must be configured strictly `A>B>C>D>E` for the ±1-step logic to make
  sense. Covered by a new `scripts/rpg2k_logic_check.rb` check (both
  directions, and that repeat casts don't stack past the cap).
- Enemy group members are numbered by add-order. ✅ **The lower-numbered
  member renders in front (closer to camera)**: `Scene::Map#build_battle_sprites`
  / `#rebuild_battler_sprite` / `#reveal_battle_monster`
  (`mruby-rpg2k/mrblib/scene/map.rb`) previously all set a battler sprite's
  `z` to `100 + i` for add-order index `i`, but the native renderer draws the
  *highest*-z sprite on top (`gfx_update`'s own "leaving the greatest z on
  top") — so the code had it backwards, putting the *last*-added member in
  front instead of the first. Now routed through a shared `#battler_z(i)`
  that inverts the index (`100 + (members.size - 1 - i)`), so member 0 gets
  the highest z of the group. Covered by a new assertion on the existing
  `scripts/rpg2k_scene_check.rb` two-Slime battler-sprite check, confirmed to
  fail against the pre-fix code. **Still open**: whether deleting a middle
  member shifts every later member's number down by one (and whether a
  battle-event command naming a member by number gets silently repointed by
  it) is unverified — a separate question about troop-member identity/
  numbering, not the render-order this PR fixes.
- The "airborne" enemy display flag **only** changes its Y position on
  screen — it has no accuracy/hit-related effect. **Still open**: the
  monster schema's `levitate` field (LCF enemy field 28,
  `mruby-lcf/mrblib/schema.rb`) is parsed but read nowhere in
  `mruby-rpg2k`, so this codebase draws every enemy at its plain
  centred position regardless — but yado.tk's own text names no pixel
  offset or animation shape for the raise, and both the yado.tk and
  viprpg-dev wiki mirrors were unreachable this session (`yado.tk`
  itself 503'd; the viprpg-dev wiki 403'd WebFetch), so implementing this
  would mean guessing a magnitude with no way to check it — left for a
  session that can compare against real RPG_RT. ✅ **The "frequent miss"
  enemy option is confirmed already correct: a hardcoded 90%→70% drop to
  *normal-attack* accuracy only, skills unaffected.** `Game::Enemy#attack_hit_rate`
  (`mruby-rpg2k/mrblib/game.rb`) already reads the schema's `miss` field
  (LCF enemy field 26) exactly this way — `@miss ? 70 : 90` — and
  `Game::Battle.hit_rate_of` dispatches to it polymorphically the same
  way it reads an actor's own `attack_hit_rate`, feeding
  `Game::Battle#to_hit`'s `base` term, the **one and only** call site
  (`Battle#strike`'s basic-attack path). A skill's own hit chance
  (`Game::Party#skill_hit`) reads the skill row's `hit` field directly and
  never touches an attacker's `attack_hit_rate` at all, structurally
  confirming the "skills unaffected" half — there is no code path between
  the two. No change was needed; the claim only lacked its own regression
  coverage, now added: a new `scripts/rpg2k_logic_check.rb` check
  (`Game::Enemy#attack_hit_rate: the 'miss' flag...`) pins the bare
  reader (70 flagged / 90 not), the polymorphic `Battle.hit_rate_of`
  reader agreeing, and an end-to-end `Battle#to_hit` roll against a
  same-agility target (so the agi-adjustment term drops out and the
  result is the bare base) for both a flagged and an unflagged enemy in
  the same fight — confirmed to fail (`expected 70, got 90`) against a
  temporarily-neutered `attack_hit_rate` that always returned 90, then
  restored.
- Chipset passability: an upper-layer "passable" flag **overrides** a
  lower-layer "impassable" one (passable overall); an upper "impassable"
  flag **always** blocks regardless of the lower layer. The simplified
  ○/×/★/□ icon shown per-tile in the editor only means "at least one of
  the 4 directions is passable" — a tile can show ○ and still block the
  specific direction actually being attempted.
- ✅ **The equip-menu comparison arrow (Up/Same/Down) is computed from the
  sum of all four stat deltas between the currently-equipped and candidate
  item, not evaluated per-stat.** (The bullet's own wording says "shop", but
  RPG2000 shops never compare equipment stats — only the field Equip screen's
  own candidate list does; `01_shoshin`/`11_db` both describe this same
  indicator on that screen.) `Scene::EquipMenu#build_cand_window`
  (`mruby-rpg2k/mrblib/scene/equip_menu.rb`) drew each candidate as a bare
  name + bag count, with no comparison of any kind. Fixed by summing each
  side's `atk_points1`/`def_points1`/`spi_points1`/`agi_points1` fields (the
  combat quarter of `Game::Actor::EQUIP_BONUS_FIELD`'s five, max HP/SP
  excluded) via a new `#item_stat_sum`, and drawing a third column between
  the name and count holding the *sign* of `candidate_sum - equipped_sum`
  only — `^`/`v`/`-` for the whole combined delta, never a per-stat verdict,
  which is the actual yado.tk claim (a candidate trading `-2` Atk for `+3`
  Def still draws a single Up arrow). RPG_RT draws small triangle icons here;
  this build has no icon-cell blit for them yet, so a plain glyph stands in
  — a later, purely-visual refinement, not a behaviour gap. The "Remove"
  entry draws no arrow (nothing to compare an empty slot's combined points
  against is confirmed either way). Covered by a new
  `scripts/rpg2k_scene_check.rb` check (a strictly-better, a strictly-worse
  and an exactly-equal candidate against a fixed worn item each draw the
  right glyph), confirmed to fail against the pre-fix code before the fix.
- Text color slots 1-4 have hardcoded semantic roles (stat label /
  value-increase / value-decrease / low-HP-MP warning), and a State's own
  configured display-color field is a pointer into that **same** shared
  palette.
- **Call Event invoked from an Auto-Start parent runs the called content
  under Auto-Start semantics (blocks input) even if the called common
  event's own configured trigger is Parallel Process; Call Event always
  bypasses the target's own condition-switch state entirely — confirmed
  already correct**, both halves, no code change needed.
  `Game::Interpreter#do_call_event`/`#resolve_call`
  (`mruby-rpg2k/mrblib/interpreter.rb`) never reads a trigger or a gate
  switch at all — it just splices the target's raw command list onto the
  *calling* interpreter's own `@call_stack` and keeps running it inline, so
  whatever is already true of the caller (an Auto-Start's foreground,
  input-blocking execution included) mechanically stays true for the whole
  call, with no separate scheduling path a Parallel Process's trigger could
  route through instead. The condition-switch bypass is even more
  structural: `Scene::Map#build_resolver` hands the Call Event resolver a
  plain `id => commands` hash built from `@common`
  (`common[c[:id]] = c[:commands]`), discarding each common event's
  `:trigger`/`:need_flag`/`:switch_id` in that same line — the resolver
  `do_call_event` reads from has no gate to consult in the first place, so a
  Call Event cannot observe the callee's switch state even if a future
  change tried to add such a check without separately plumbing the gate
  through this hash. `interpreter.rb` has no trigger/switch-related constant
  or read anywhere, corroborating the same conclusion from the other
  direction. Covered by a new `scripts/rpg2k_scene_check.rb` check (an
  Auto-Start event Call-Events a Parallel-Process common event whose gate
  switch is off for the whole run; its content still executes), confirmed to
  fail when `build_resolver` is temporarily made to honour the gate switch,
  restored before finalizing since nothing here needed to change.

**Asset / graphics format notes** (lower priority — content-authoring
constraints more than runtime-correctness gaps, but recorded for
completeness): all game graphics are indexed/paletted ≤256 colors;
transparent color defaults to palette index 0, chosen at import time (a
plain BMP dropped directly into the asset folder without going through
the importer skips this step, so its own index-0 must already be
correct); standard chipset = 480×256px, charset = 288×256px, FaceSet =
192×192px, System graphic = 160×80px, Title/GameOver = 320×240px; the
engine renders at 16-bit color internally so on-screen RGB differs
slightly from a 24-bit source image's values (RPG Maker's own documented
conversion table, already tracked/implemented per the render-parity work
above — worth double-checking the exact conversion table against this
list if channel values are ever revisited); importing the same asset as
both PNG and XYZ leaves both on disk, and the engine may pick either
(documented source of "wrong graphic shows up" bugs).

### viprpg-dev wiki backlog (2000 category)

Findings from <https://wikiwiki.jp/viprpg-dev/2000> (VIPRPG@総合制作技術 Wiki's
RPGツクール2000 category) and the `200X共通` pages it transcludes
(`基本的な仕様`, `バグ`), plus `2000/デフォ戦/デフォ戦botまとめ`. A different
source from the yado.tk backlog above — corroborates it in places (the
parallel-process-goes-first-if-both-fire-the-same-frame rule, the 999 damage
cap) but adds new specifics, especially around per-frame event step
accounting and a documented RPG_RT loop-exit bug (Break Loop's own nesting
bug — now reproduced, see the "Fixed" bullet below).

**Flagged for priority triage** — checked against the current code this
session (reading + documenting only, not fixed — see below):
- ✅ **Break Loop now reproduces RPG_RT's own nesting bug.**
  `Game::Interpreter#do_break_loop` (`mruby-rpg2k/mrblib/interpreter.rb:1008`)
  used to scan forward for the first `End Loop` whose `indent < cmd.indent`,
  i.e. it deliberately skipped any `End Loop` at the break command's own
  nesting depth or deeper and landed exactly on the *enclosing* loop's own
  end — which is the behaviourally "correct" outcome, but not what real
  RPG_RT does. The wiki's worked example: a Loop containing (in order) a
  Break Loop, then a second, empty, more-deeply-nested Loop/End Loop pair,
  then a Show Text, before the outer loop's own End Loop and a final Show
  Text after it. Real RPG_RT's Break Loop searches downward for the
  **next** `End Loop` line with no regard for nesting depth at all, so it
  lands on the *inner* loop's End Loop (the first one it meets) instead of
  the outer one — control falls into the inner loop's body (the first Show
  Text) and then loops back via the *outer* End Loop forever, so the
  second Show Text after the outer loop is never reached and the first one
  repeats indefinitely. This codebase's old `indent`-aware scan meant that
  exact repro would have correctly exited here instead of hanging — a
  compatibility gap for any game whose logic (deliberately or not) depends
  on this specific bug. Fixed by dropping the indent comparison entirely:
  `do_break_loop` now jumps past whichever `End Loop` command it meets first
  scanning forward by list position alone, matching RPG_RT's own scan and
  reproducing the bug rather than "fixing" it into the sane behaviour a
  literal reading of "break the loop" would suggest — consistent with this
  project's general stance of modelling RPG_RT's own quirks over a
  better-behaved reading of the spec. The common case (nothing but the
  enclosing loop's own `End Loop` between the break and it) is unaffected,
  since an indent-blind scan finds the same command an indent-aware one
  would. Covered by two new `scripts/rpg2k_logic_check.rb` checks (the
  common, unaffected case; and the wiki's own worked nested-loop example,
  asserting the command after the outer loop is never reached), the second
  confirmed to fail against the pre-fix code before the fix.
- **Autorun (auto-start) events run at most once per map visit, not once
  per frame.** `Scene::Map#start_autostart` (`mruby-rpg2k/mrblib/scene/
  map.rb:919`) picks the single lowest-id not-yet-started eligible
  auto-start map event or common event, flips `@started_auto[id]` /
  `@started_common[id]` and never considers that id again this visit —
  already marked ✅ "done" above (`docs/TODO.md`'s "Common events" bullet)
  with the explicit rationale "so an ungated process cannot hard-loop."
  Per `200X共通/基本的な仕様`'s "マップイベントの挙動"/"コモンイベントの挙動"
  sections, real RPG_RT instead re-triggers an eligible Autorun event from
  its first line on **every subsequent frame** for as long as its page's
  appearance condition keeps holding (not once ever) — an Autorun with no
  wait-including command is the well-known "spams every frame" beginner
  mistake, and a Common Event Autorun goes one step further: absent a wait
  command it re-executes from the top **within the same frame**, up to the
  10000-step-per-frame budget (worked example given: a one-line
  `[0001] += 1` auto-start common event advances the variable by 5000
  *every single frame*, not once ever, because each iteration costs 2 steps
  — the operation plus the implicit blank terminator line — and
  10000 / 2 = 5000). The current one-shot design is a deliberate,
  documented simplification to keep the simulation from spinning forever
  on an unthrottled Autorun, but it means a real game's every-frame
  Autorun screen-effect/counter idiom (the exact pattern the wiki's own
  worked example describes as ordinary usage, not an edge case) will only
  ever run once here. Needs a real decision — re-trigger every frame and
  rely on `MAX_STEPS`/the existing per-command step cost to bound it the
  way real RPG_RT does, or keep the one-shot behaviour and record the
  divergence as accepted scope — rather than staying marked ✅ as-is.

**Untriaged backlog** (raw reference material, not checked against the
codebase yet):
- **Autorun cascading within one frame.** If the lowest-id eligible Autorun
  map event's content contains no wait-including command, real RPG_RT lets
  the next-lowest-id eligible Autorun event start immediately in the same
  frame (potentially chaining through several before one of them blocks on
  a wait). `#start_autostart` only ever starts one event per frame
  regardless — entangled with the run-once-per-visit item above, since
  fixing that one changes how this needs to be tested too.
- **A body-less command block still spends a step.** The wiki's own
  worked example: a `◆繰り返し処理` / (blank inner line) / `：以上繰り返し`
  loop, and the empty branches of a `◆条件分岐`, each spend 1 step per
  visit to their blank line, in addition to whatever `End Loop`/`End
  Branch` itself costs. Worth confirming the LCF-parsed command list
  actually carries a real entry for an empty loop/branch body (rather than
  the parser collapsing/omitting it) and that `Interpreter#step_cost`
  charges for it — `mruby-rpg2k/mrblib/interpreter.rb:495` already
  differentiates `END_LOOP`/`CALL_EVENT`/`CALL_COMMON_EVENT`/`END_BRANCH`
  (cost 2) and a taken/untaken `CONDITIONAL` (1 or 2), which lines up with
  the wiki's "most commands cost 1, a few vary," but the empty-line case
  specifically wasn't checked this session.
- **Party wipe during "Show Text" freezes or crashes real RPG_RT** (also
  reachable via "Damage Processing," not just "HP change"). Worked repros
  given for both a blocking Autorun HP-drain-to-0-during-a-message and a
  Parallel Process doing the same. Since this project already deliberately
  does *not* reproduce other native RPG_RT crashes, this is presumably a
  "leave it be" — the interesting question is only whether this codebase's
  own game-over/party-wipe handling already behaves sanely in this exact
  scenario (HP hits 0 while a message window from the same or a parallel
  event is open) or has some other gap the freeze happened to have masked
  in the original. ✅ **Part of that question is answered now**: a Parallel
  Process's own wipe reaching Game Over at all was a real, separate gap
  (`Scene::Map#drive_parallel_wait` had no `:game_over` case — see the "Event
  system" entry near the top of this file for the full writeup), now fixed
  and regression-covered. **Still open**: this fix says nothing about the
  specific "while a message window is open" timing the repro asks about — a
  Parallel Process keeps advancing non-blocking commands during a message
  window per the "parallel processes were paused too broadly" fix above, so a
  lethal Change HP there would reach `check_game_over` and now correctly
  raises Game Over, but whether the message window itself is torn down
  cleanly (rather than leaking a disposed sprite reference, say) is
  unverified — no test bed or session note here exercises that exact
  interleaving yet.
- **Save data location fallback.** If `RPG_RT.exe` itself is read-only,
  real RPG_RT reads/writes save files from `My Documents\<GameName>\`
  instead of the game folder, and stops listing game-folder saves (even
  ones shipped with the game) while that's active — presumably to support
  running straight off read-only media. Not applicable to this project's
  own portable `Marshal` save format today; relevant only if/when `.lsd`
  save compatibility is targeted.
- RTP graphic asset mistakes (`FaceSet/モンスター.png` has the Dark Elf's
  face bleeding into the Grim Reaper's portrait next to it; `CharSet/
  主人公3.png`'s female ninja sideways sprite has a transparency mistake in
  her hair; two `ChipSet` off-by-one-pixel errors in `基本.png`'s castle
  turret and `外観.png`'s roof tiling) are mistakes in Enterbrain's own
  official RTP art assets, fixable by an official patch — not applicable
  unless this project ever ships or tests against the stock RTP bitmaps
  directly.
- `2000/デフォ戦/デフォ戦botまとめ` is a large (~140-item), fine-grained
  community trivia dump for default-battle-system fidelity, sourced from
  the `@2000_battle_bot` Twitter account — worth a dedicated read-through
  once battle-system work resumes rather than transcribing it piecemeal
  now. A few structurally-significant points worth flagging early so
  they're not missed later: ✅ **displayed ability-value changes clamp to
  1–999 but the *underlying* unclamped total is still tracked internally
  and can un-clamp back into view after a later change** (e.g. lower Attack
  by more than the display can show, then raise it partway back — the
  displayed value stays pinned at its old clamp until the raise actually
  pushes the real total back above it) — now fixed, see below; a special
  skill's ability-value *decrease* rounds up on ÷2, a status effect's own
  halving rounds *down*; dual-wielding's off-hand attack animation is
  offset by a few frames from the main hand's. **Change Parameters' hidden
  unclamped total is now tracked.** `Game::Actor#change_param`
  (`mruby-rpg2k/mrblib/game.rb`) clamped and overwrote `@base[type]` on
  every call, permanently discarding how far past the 1..999 (1..9999 for
  max HP/MP) limit the real total had gone — lowering Attack by 2000 off a
  base of 3, then raising it back by 1000, landed at the clamp ceiling
  (999) instead of staying floored, even though the real total
  (3 − 2000 + 1000 = −997) is still deep underwater. Fixed with a parallel
  `@base_raw` shadow that `#change_param` accumulates the signed delta on
  before clamping the result into `@base` — the value `#recompute_stats`
  and every other reader still uses, so nothing outside `#change_param`
  itself changed. `@base_raw` is reset alongside every wholesale
  replacement of `@base` (`#set_level`, and all three branches of
  `#change_class`'s param-mode handling), since a level-up or class change
  establishes a fresh baseline rather than carrying stale drift across it
  — the same reasoning `#set_level`'s own existing HP/MP re-clamp already
  follows for vitals. This build has no existing notion of a "raw" vs.
  "effective" stat elsewhere, so `@base_raw` is new state, not a rename;
  save/load persistence of `@base` itself is a separate, pre-existing gap
  (`Game::Party#load_state` re-derives `@base` purely from saved EXP via
  `#set_level`, so a live Change Parameters adjustment — clamped or not —
  does not currently survive a save at all) left untouched here. Covered
  by a new `scripts/rpg2k_logic_check.rb` check (a large drop floors the
  stat; a partial raise that doesn't cross back over 1 stays floored; a
  further raise that does cross back over unclamps to the real total; an
  ordinary never-clamped sequence is unaffected), confirmed to fail against
  the pre-fix code before the fix. ✅ **"Party wipe" for game-over purposes is now "every
  member is both unable to act and does not recover naturally," not
  literally "every member's HP is 0"** — why Stone status can wipe a party
  without zeroing anyone's HP. `Game::Battle#alive?` (`mruby-rpg2k/mrblib/
  game.rb`) only ever asked `!b.out_of_play?` (dead or hidden), so a fully
  restricted-but-undamaged party (every ally afflicted by a "do nothing"
  state, RESTRICTION_DO_NOTHING, that never wears off on its own) read as
  still fighting: `#finished?`/`#run` kept calling `#step`, which itself
  never reaches an action for any of them (`apply_turn_states` returns
  `can_act = false` for every one, `#step`'s inner loop just cycles to the
  next battler), so the fight silently ground all the way to the
  `MAX_ROUNDS` safety net before finally reading as a loss, rather than
  ending the instant the last ally is afflicted. Fixed with a new
  `#incapacitated?(b)`, used by `#alive?` in place of the bare
  `!out_of_play?` check: true for a dead/hidden battler as before, or for
  one carrying a state whose `restriction` is `RESTRICTION_DO_NOTHING` *and*
  whose `auto_release_prob` is 0 — deliberately narrower than "any do-nothing
  state," since a do-nothing state that *can* still shake itself off on its
  own (Sleep, Paralysis with a nonzero `auto_release_prob`) does not count
  towards a wipe, matching "does not recover naturally": the fight keeps
  running, the same roll `#recovers_from_state?` would eventually use to
  stand that battler back up. Applies symmetrically to both sides (an
  all-Stoned enemy troop ends the fight in victory too), since nothing in
  the source material suggests the rule is ally-only and `#alive?` was
  already shared by both `@allies`/`@enemies` call sites. Covered by three
  new `scripts/rpg2k_logic_check.rb` checks (a fully-Stoned party is a loss
  with no HP ever moving, confirmed to fail against the pre-fix code before
  the fix; a party-wide do-nothing state with a nonzero `auto_release_prob`
  does *not* end the fight; one incapacitated ally among others is not a
  wipe). ✅ **Berserk/Confusion override target selection but still
  honour "hits twice"/"ignores evasion," while Berserk additionally
  collapses an "attack all" weapon down to a single target and disables
  "always acts first."** `Game::Battle#strike`'s forced-restriction branch
  (shared by both, `RESTRICTION_ATTACK_ENEMY`/`_ALLY`) called a bare
  `#deal_attack` instead of the `#swing` an ordinary Attack uses, so
  dual-wield's extra hit never landed under either restriction (必中 already
  worked either way, since `#to_hit` reads `attacker.ignores_evasion`
  regardless of which method calls it); attack-all spread across the whole
  opposing side under Berserk exactly as it does under Confusion, with no
  single-target collapse; and `#preemptive_boost?` granted the "always acts
  first" turn-order jump to both restrictions alike. Fixed by routing the
  restricted branch through `#swing` (dual-wield restored for both), scoping
  the attack-all spread to `RESTRICTION_ATTACK_ALLY` only (Berserk now always
  hits its single forced target via `#swing` directly, so the now-redundant
  `#attack_side` helper was removed in favour of the existing `#swing_side`),
  and returning `false` from `#preemptive_boost?` for `RESTRICTION_ATTACK_ENEMY`
  before the existing `RESTRICTION_ATTACK_ALLY` case. Covered by four new
  `scripts/rpg2k_logic_check.rb` checks (Berserk plus attack-all hits one
  target; a preemptive weapon's jump is dropped under Berserk; Berserk still
  swings a dual-wield weapon twice; a confused, attack-all, dual-wield
  attacker swings twice per target), all four confirmed to fail against the
  pre-fix code. **Confirmed already correct, no change needed**: hit rate's
  floor/ceiling relative to a skill's configured rate by relative Agility (a
  90%-accuracy skill can't exceed 95% actual hit even against a much slower
  target; an 80% one caps at 90%). `Game::Battle#to_hit`'s existing
  `100 - (100 - base) * (src + tgt) / (2 * src)` (EasyRPG's
  `CalcToHitAgiAdjustment`, already ported for the "hit rate has both a
  floor and a ceiling" claim above) already produces exactly this: as the
  target's agility shrinks toward 0 relative to the attacker's, the ratio
  term approaches 1/2, so hit approaches `50 + base/2` — 95 for a 90-rate
  skill, 90 for an 80-rate one, matching both cited numbers as an emergent
  property of the formula rather than a separate clamp. The reverse-skew
  half (a much *faster* target) already floors at the existing `Game.clamp(…,
  0, 100)`, unverified against a specific nonzero floor since neither test
  bed's own accuracy math suggests RPG_RT keeps one there.

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
  loads the start map and enters a walkable `Scene::Map`. The three tile layers
  now render through the native `RGSS::Tilemap` — the project's real tileset
  graphic, the seven autotiles assembled from their quads and animated, and
  priority tiles routed above the characters — exactly the objects RMXP's
  `Spriteset_Map` builds. Every event draws from its active page's graphic (a
  `Graphics/Characters` sheet, or the tile id a page uses instead); an event with
  an empty graphic draws nothing, as in RMXP. Characters stack by the screen row
  they stand on (`Sprite_Character#update`'s `screen_z`), with `always_on_top`
  pages above the priority layer. Movement is grid-based with tileset passability
  and a follow camera. Remaining: per-row priority interleaving rather than one
  flat above-layer (ADR 0022), and the character effects the sprites ignore —
  opacity, blend mode, hue and step animation.
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
  trigger fires when an event walks into the player. An event **glides** between
  tiles the way RGSS moves a character: taking a step claims the destination
  tile at once (that is what collision sees) and the drawn position closes the
  128-unit gap at `2 ** move_speed` a frame, while the walk row cycles off the
  same animation counter and falls back to the page's own frame once the event
  comes to rest. The wait between autonomous steps is RMXP's
  `(40 - frequency * 2) * (6 - frequency)` frames. The interpreter's *Set Move
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
  and Control Variables also reads the **"other" game quantities** — map id,
  party size and gold (operand type 7). A **per-actor model** (`Game::Actor`)
  now wraps each `RPG::Actor` record and its class: level-derived stats read
  straight from the actor's `parameters` table (max HP/SP, str/dex/agi/int), the
  known skills from the class's learnings up to the current level, and the
  equipment from the actor's weapon / four armor slots; `State#actor(id)`
  memoises one live actor per id (like RMXP's `$game_actors`). It powers the full
  **actor Conditional Branch** (type 4): *is in the party* (0), *name is* (1),
  *skill learned* (2), *weapon equipped* (3) and *armor equipped* (4), matched to
  RMXP's `command_111`. The model's **Change Actor** commands mutate it: **Change
  HP** (311, with the allow-knockout floor), **Change SP** (312), **Recover All**
  (314), **Change EXP** (315) and **Change Level** (316) — both routed through the
  RMXP EXP curve (`make_exp_list`: `Integer(exp_basis*(L+3)**pow / 5**pow)`,
  `pow = 2.4 + exp_inflation/100`, ported from the editor's `Game_Actor`), so
  levelling learns each level's class skills on the way up and keeps them on the
  way down — **Change Skills** (318 learn / forget) and **Change Equipment** (319,
  weapon + four armor slots), each targeting a fixed or variable-held actor id;
  the mutated per-actor state (level, EXP, HP/SP, skills, equipment) now persists
  through the Marshal save. **Battle Processing** (301) navigates its result
  branches — If Win (601), If Escape (602), If Lose (603), branch end (604) —
  running only the branch that matches the resolved outcome (a win by default,
  configurable via the interpreter's `battle_outcome`, since there is no battle
  system yet); the real `OpenGame.exe` XP test bed uses this structure. Covered
  by `mruby-rpgxp/test` and driven over the real test bed by
  `scripts/rpgxp_testbed_check.rb` (which now builds a `Game::Actor` for every
  database actor). Still to come: **Change Parameters** (317, permanent stat deltas
  on top of the table, via a per-actor `*_plus` set); the actor *state* (5) and
  enemy / character conditional sub-conditions; vehicle move-route targets; and
  the many screen-effect / picture commands, plus the battle system itself that
  Battle Processing would drive (skipped for now).
- ✅ **Encrypted archives** — a packed release that ships only a `Game.rgssad`
  (RPG Maker XP; VX's same-format `Game.rgss2a`) or a VX Ace `Game.rgss3a` loads:
  `RPGXP::RGSSAD` (`mruby-rpgxp/mrblib/rgssad.rb`) decrypts **both** the version-1
  format (rolling 0xDEADCAFE key) and the version-3 format (a plaintext header
  seed → base key, a fixed-key entry table with per-file data keys) and
  `RPGXP::RGSSData` falls back to whichever archive is present when a `.rxdata` is
  not loose on disk. Covered by `mruby-rpgxp/test` (v1 and v3 round-trips) and by
  `scripts/rpgxp_testbed_check.rb` (packs the real test bed as both `.rgssad` and
  `.rgss3a` and reloads the whole DB through each). **Graphics come out of the
  archive too**: the boot shell registers its opened archive as
  `RGSS.asset_archive`, and `Bitmap#initialize` consults it after the loose-file
  search misses, trying the same extension candidates — an asset is asked for by
  name from deep inside a game's own scripts, so there is no handle to thread
  down and the registry is what closes that. The bytes go through the same
  decoder a loose file does (`_init_file` and `_init_memory` share
  `bmp_decode_into`), so the stb / XYZ / tolerant-PNG fallbacks a real project
  needs are not quietly missing from the packed path. Checked end to end in the
  real binary by `scripts/rgssad_asset_check.bash`, which packs the test bed
  twice — with and without a title graphic in the archive — and asserts the
  engine finds it only when it is there; a single run would pass just as well if
  the archive were never consulted. **Audio comes out of the archive too**: each
  entry point of the backend's C function table (`include/rgss_audio.hxx`) has
  grown a `*_play_mem` twin taking the encoded bytes, fed to SDL_mixer through an
  `SDL_RWops`, with the Ruby side crossing the four kinds' archive folders with
  the same extensions the disk search uses. The lifetime is the subtle part —
  `Mix_LoadMUS_RW` *streams* from the RWops, and RGSS replays the BGM after a
  music effect, which for an archived track means replaying from bytes that must
  still be there — so the backend owns both buffers and frees them only with the
  stream they feed. Measured by the `audio_probe` ctest under
  `SDL_AUDIODRIVER=dummy` (decodes and mixes with no sound card): loose plays,
  stop reads 0, packed plays.
- ✅ **Run the bundled RGSS scripts** — the largest direction: an `eval`-based
  host that runs `Data/Scripts.rxdata` unmodified against the RGSS class library
  (the equivalent of the MV "embed the real engine" choice), which also runs
  community scripts. Built by ADR 0017: a native `RGSS.zlib_inflate` decompresses
  the script sections, `RPGXP::RGSSData` exposes
  `read_object`/`save_object`/`scripts`, and `RPGXP::ScriptHost` installs the
  Kernel `load_data`/`save_data` built-ins and evaluates every section at the top
  level (mruby-eval) so "Main" drives the game. **It is now the only boot path**
  (ADR 0029 made it the default, ADR 0030 deleted the reimplemented title/map/
  interpreter it used to fall back to — ~4,600 lines that could only ever
  reproduce the *default* scripts). What made that possible: the
  `mruby-rgss` class library the stock scripts call is complete enough — `Font`,
  `Graphics` timing, `Input`, `Audio`, `Sprite`'s extended properties and the
  `Window`/`Tilemap`/`Plane` widgets all render, plus `Kernel#sprintf` and
  `exit`; the scripts' blocking main loop is reconciled with the emscripten
  frame loop by the per-frame Fiber driver (ADR 0023), rather than Asyncify; and
  the **RGSS standard library** — `RPG::Sprite`, `RPG::Weather`, `RPG::Cache`,
  the Ruby classes `RGSS104E.dll` supplies and no project ships — is now
  supplied by `mruby-rpgxp/mrblib/rgss_library.rb`, without which a game stopped
  21 sections in on `class Sprite_Character < RPG::Sprite`. The
  remaining polish is tracked in
  [`docs/rpgxp-rgss-api-gap.md`](rpgxp-rgss-api-gap.md). Decoding, the built-ins
  and top-level evaluation of real script source are covered by
  `mruby-rpgxp/test` and `scripts/rpgxp_script_host_check.rb`; CI boots both XP
  beds natively (`scripts/rpgxp_boot_check.bash`), taps confirm on each game's own
  title screen and walks the party on the editor bed's map. Still unverified: the
  frame driver in a real **browser**. (Graphics and audio both come out of the encrypted
  archive now — see Encrypted archives above.)
- ✅ **Cross-runtime testing** — an XP project is booted natively and against the
  genuine runtime: `scripts/rpgxp_boot_check.bash` runs the game's own scripts in
  the built binary (the guard against mruby/CRuby divergence the CRuby-hosted
  checks cannot see) and `scripts/compare-rpgxp-wine.bash` diffs our frames
  against the genuine `Game.exe` + `RGSS104E.dll` under wine, driving both with
  the same keys — so since ADR 0030 it compares the game's own engine against the
  genuine one. See
  [`docs/adr/0025-rpgxp-cross-runtime-testing.md`](adr/0025-rpgxp-cross-runtime-testing.md);
  a third check played the project in the **browser build** and found (and this
  fixed) an XP project rendering on a 320x240 screen in the page and the loader
  panel covering the running game, and the wine pass found four more (the XP RTP
  key was never read, `.jpg` was missing from the asset search, truecolour images
  were red/blue-swapped, and an RGBA image loaded opaque drew garbage).
- **Re-test the browser build without a heavyweight dependency.**
  `scripts/rpgxp_browser_check.py` drove the emscripten page in headless Chromium
  over the DevTools protocol, but the `chromium` it needed was the largest
  download in the dev shell — paid for by every `nix develop`, in every job, for
  one non-blocking check — so both were removed (ADR 0025, amended). The page's
  loader, DOM input path and frame loop are untested again. Bringing it back
  wants a browser that is *found* rather than *fetched* (a system chromium, skip
  when absent) or a browser-only CI job. Still open with it: running the **script
  host** in the browser (the ADR 0023 frame driver has never been verified in a
  real browser), loading a **packed** release (`Game.ini` + `Game.rgssad`) through
  the shell, and a way to pass engine flags to the page so a browser check can use
  `--rgss_host_new_game` instead of pressing keys.
- ✅ **A released game as a test bed** — every XP check above also runs on
  *Pray for You* (`scripts/download-prayforyou.bash`): a packed release
  (`Game.ini` + `Game.rgssad`, nothing loose), 69 maps, 1107 event pages, 15,797
  event commands, Japanese `RGSS103J.dll`. The data check went from 1 map / 2
  event pages / 15 commands to 70 / 1109 / 15,812 and the script host from 90 to
  193 sections; both games boot in CI. It found a Transfer Player leaving the
  old map's ground on screen, an ignored Change Screen Color Tone (223) and a
  message box laid out the RPG2000 way instead of RMXP's inset 480x160 — with
  those fixed a map frame differs from the genuine runtime in 25% of its pixels,
  down from 97%, the rest being the reference's own font-less message box. See
  [`docs/adr/0027-rpgxp-released-game-parity.md`](adr/0027-rpgxp-released-game-parity.md).
  Playing it further added **Wait for Move's Completion (210)**, **Set Event
  Location (202)** and **Change Transparent Flag (208)** — 210 first, because
  without it a list ran straight on and an event delivered its line before it
  had walked over — and found that ten of the game's music tracks were
  unplayable, its `Audio/BGM` mixing `.MID` with `.mid` where the search only
  tried lower case. The **picture commands** (231–235, 471 uses) and the message
  **pause arrow** followed, with a `STEPS_SPEC` override on the comparison so a
  game's opening cutscene can be driven rather than only its start map. The screen effects
  followed — Prepare / Execute Transition (221/222) and Screen Flash / Shake
  (224/225), 871 uses — with 222 suspending the interpreter and the scene fading
  the frozen still per frame rather than calling the blocking
  `Graphics.transition`. **Scroll Map (203)**, **Show Animation
  (207)** and **Script (355)** followed, leaving the map scene with a handler for
  **every** event command a real XP game uses. The script design question — what
  a game's inline Ruby is evaluated against — the game answered itself: 22 of its
  23 blocks assign globals of its own invention, one reads `$game_variables[1]`,
  so scripts evaluate at the top level with `$game_switches` / `$game_variables`
  bound to the runtime state and nothing else provided.
- Reference for the RGSS game library:
  https://www.rpgmaker.fixato.org/Manual/RPGVXAce/rgss/

### VX (RGSS2) and VX Ace (RGSS3)

The two makers between XP and MV keep XP's shape — `Game.ini`, a `Data/` folder
of Ruby `Marshal` dumps, a bundled script bundle that *is* the engine — and
change the data extension (`.rvdata` / `.rvdata2`), the record schema and the
screen (544×416). Full rationale:
[`docs/adr/0024-rpgvx-rgss2-rgss3-data-layer.md`](adr/0024-rpgvx-rgss2-rgss3-data-layer.md).

- ✅ **Data layer** — `mruby-rpgvx/mrblib/rgss2_data.rb` declares the RGSS2 and
  RGSS3 `RPG::*` schema (VX Ace's `BaseItem#features`, `damage`/`effects`
  usables, `Class#params`, per-map `Tilesets` and the fourth region layer; VX's
  `Actor#parameters`, `Areas` and game-wide `System#passages`) so every
  `Data/*.rvdata(2)` loads through `Marshal.load`, and `RPGVX::RGSSData` exposes
  them as an edition-aware database (extension, table set, maps on demand,
  script-bundle decoding). Both editions share the one `RPG::` namespace with
  the XP schema, which is why the RGSS3 superclass chain is carried by
  `*Fields` modules rather than real superclasses — see the ADR.
- ✅ **Detection & dispatch** — VX Ace is `Data/System.rvdata2` or
  `Game.rgss3a`, VX is `Data/System.rvdata` or `Game.rgss2a` (a packed release
  ships no loose `Data/`, so the archive is the only marker). `src/main.cxx`
  checks this **before** the XP branch — a VX project has a `Game.ini` too, so
  it used to be handed to the XP runtime and fail on the missing
  `Data/System.rxdata` — and sizes the window to 544×416.
- ✅ **Encrypted archives** — `Game.rgss2a` (v1) and `Game.rgss3a` (v3) load
  through the XP reader (`RPGXP::RGSSAD`) unchanged, so a single-archive release
  boots with no loose files, and — like XP, through the same shared
  `RGSS.asset_archive` the VX boot shell registers — finds its **graphics and
  audio** in there as well, so a packed release needs nothing loose at all.
- 🚧 **Run the bundled scripts** — a VX/VX Ace game's engine is its script
  bundle, so this is *the* path rather than a later refinement. The host runs
  (`RPGXP::ScriptHost`, ADR 0017) with the per-frame Fiber driver shared by both
  shells (`ScriptHost.build_driver`, ADR 0023), and the RGSS2/RGSS3 class
  library is now measured, not guessed: the gap is tracked in
  [`docs/rpgvx-rgss-api-gap.md`](rpgvx-rgss-api-gap.md), counted across the
  stock VX Ace script set (109 sections, ~19.9k lines).
  - ✅ The built-ins a bundle needs before it can draw anything: **symbol input
    keys** (`Input.trigger?(:C)` — VX/VX Ace use nothing else, and the same key
    table now serves all three makers), **`Graphics.width`/`height`** (declared
    per maker via `resize_screen`; ~82 uses), **`Graphics.wait`/`fadeout`/
    `fadein`/`brightness`**, **`Audio.setup_midi`**, the **`Window` RGSS2/RGSS3
    surface** (`openness` + `open?`/`close?`, `padding`/`padding_bottom`,
    `arrows_visible`, `tone`, and the `Window.new(x, y, w, h)` constructor),
    **`RPG::BGM`/`BGS`/`ME`/`SE` playing themselves** (`#play`/`#replay`/
    `#fade`, the class-side `last`/`stop`/`fade`), and the RGSS3 Kernel methods
    **`rgss_main`** (the whole `Main` section of every VX Ace project),
    `rgss_stop`, `msgbox`/`msgbox_p`.
  - ✅ **`Viewport#color` / `#flash`** — VX does every screen effect through the
    viewport (`@viewport3.color.set(0, 0, 0, 255 - brightness)` is the fade,
    `@viewport2.color` the flash, `viewport.flash` the animation flashes), so
    these are now native: a colour overlay canvas the size of the viewport,
    above its content layer, repainted from `#update` — which is what makes the
    scripts' in-place `color.set(...)` visible. Same mechanism ADR 0021 measured
    working for the RPG2000 fade, moved into the viewport so it clips and
    scrolls with it.
  - ✅ **VX/VX Ace `Tilemap`** — `bitmaps` (the nine A1–A5/B–E sheets, assigned
    by index the way the scripts do), `flags=`, and the VX tile-id decode: a
    tile id carries both the autotile and which of its 48 (16 for walls, 4 for
    waterfalls) edge shapes to assemble from four quarter-tiles, per family.
    Ported from the MIT MV corescript, which inherited VX Ace's tile system
    unchanged, and **differentially tested against it** — all 8300 ids × a full
    animation cycle × the table flag (66,400 cases) match byte for byte. The
    decode is exposed as `Tilemap.vx_tile_quads` so `mruby-rgss/test` pins it
    without a display, as sample cases plus a checksum over the whole sweep.
    Left as polish: the flat "above the characters" layer (the same
    approximation ADR 0022 describes for XP) and the A2 table-edge tile.
  - ✅ **`Viewport#tone`** — the screen tint. Unlike `color` a tone rescales
    what is already drawn, so it cannot be a layer: every display object in the
    viewport folds the viewport's tone into its own composite as its last step
    (`Sprite`/`Plane` already baked their own; the `Tilemap` gets a pass over its
    composed canvases), and the viewport re-composites its children when the
    value changes — checked from `#update` too, since the scripts mutate the Tone
    in place, and skipped when it did not move. **This is the per-pixel tone pass
    the RPG2000 screen tint has been waiting on** (see the Screen effects section
    above): `apply_tone_px` is shared by all three composites, so the RPG2000
    side can adopt it instead of growing its own.
  - ✅ **`Graphics.snap_to_bitmap` / `freeze` / `transition`** — scene
    transitions. `snap_to_bitmap` is `lv_snapshot_take` into a `Bitmap`, the one
    capture that works on every backend (the SDL window, the terminal
    framebuffer and the wasm canvas all buffer differently, and two of them
    render partially). `freeze` keeps the snapshot; `transition` shows it on a
    full-screen sprite above everything and steps its opacity to zero, so the
    next scene builds behind a fading still of the last — RGSS's default
    dissolve. The `filename`/`vague` form runs as a plain fade and says so once.
  - ✅ **A render probe that can see the screen.** The three items above are
    native rendering that no unit test could reach: `mruby-rgss/test` has no
    display, so a `Viewport` cannot even be constructed there, and the failure
    mode that leaves is the one that hid the RPG2000 screen tint — the code
    runs, the values are stored, and nothing changes. `RGSS.frame_mean` (the
    frame's mean R/G/B, sampled on an 8px grid via `snap_to_bitmap`) and
    `RGSS.effect_probe` close it: `rpg_maker_clone --rgss_effect_probe` drives a
    grey screen, a red `Viewport#color`, an additive-blue `Viewport#tone` and a
    freeze/transition round trip on a real display and measures each. It runs as
    the `render_probe` ctest under xvfb (display 98) and needs no game. Verified
    to have teeth by neutering `vp_refresh_overlay` and the transition in turn —
    each broke exactly the assertion it should.
  - ✅ **`Window#openness` and `Window#tone`** — the VX open/close animation and
    the windowskin tint. The window unrolls from its horizontal centre line: the
    frame is composited at `height * openness / 255` and shifted down by half of
    what it lost, with the 9-slice's corner height clamped to half the drawn
    height so a part-open window keeps a frame; contents, cursor and pause arrow
    stay hidden until it is fully open. The tone goes on the *background* only —
    applied right after the background tile and before anything on top — through
    the shared `apply_tone_px`, and is re-checked from `#update` because the
    scripts mutate the Tone in place. Both native, and deliberately not
    redefined in mrblib (which loads after the C init and would shadow them).
    Measured by `RGSS.window_probe`: `drawn=[0,0,86] half=[0,0,43]
    closed=[0,0,0] toned=[86,0,86]`.
  - ✅ **`Bitmap#blur` / `#radial_blur`** — the title background and the
    animation effects. `blur` is a 3x3 box blur over a snapshot of the bitmap,
    so each output pixel reads the original neighbourhood instead of feeding
    already-blurred pixels back in; `radial_blur(angle, division)` averages
    `division` rotated copies spread over `angle` degrees and centred on the
    original. Both average premultiplied by alpha, so a transparent neighbour
    contributes weight but no colour. Pure pixel work, so unlike the rest of
    this section they are pinned in `mruby-rgss/test` rather than measured on a
    display — down to the exact seam values (170/85 either side of a
    white/black edge) and the mirror symmetry of the swept arc, which is what
    actually pins the centre of rotation.
  - Remaining, all native `mruby-rgss` work: `Viewport#tone` on `Window`
    contents (a different composite path; RGSS keeps windows in their own
    viewport, so a map tint does not tint the message window anyway).
- ~~**Built-in title/map flow**~~ — dropped, not deferred: a VX/VX Ace game *is*
  its script bundle, and ADR 0030 removed the XP side's reimplementation for the
  same reason. A project that ships no scripts reports that instead of showing a
  blank window.
- **A real test bed.** Neither editor nor its RTP is redistributable and no
  open-source VX/VX Ace project ships a genuine `Data/*.rvdata(2)` tree, so
  `scripts/rpgvx_testbed_check.rb` builds a full project per edition instead and
  drives the loader over it (loose, then repacked into the real archive
  formats). A generated bed cannot prove a *field name* — the names are
  transcribed from the RGSS2/RGSS3 references — so the check also audits that
  every field in the data has an accessor, which is what makes running it
  against a user's real game (`ruby scripts/rpgvx_testbed_check.rb path/to/Game`)
  worthwhile. Finding a redistributable bed for CI remains open.

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
  - ✅ M6.2 host reuse (to the WebGL wall): `MZ#boot_probe`
    (`mruby-mvjs/mrblib/mz.rb`) runs the `rmmz_*` scripts on the shared quickjs
    host and calls `SceneManager.run(Scene_Boot)`, which reaches the renderer
    boundary and stops — everything up to pixels works. There is **no fetchable
    MZ test bed** (MZ's engine ships only with the paid editor, no open-source
    release like MV's MIT `rpgtkoolmv`), so this path is verified against a
    user-supplied project, not CI; the pure logic it leans on
    (`MZ.runnable_scripts`, `MZ.host_globals_js`) is covered by
    `mruby-mvjs/test/mz_test.rb`. The measured boot map (correcting the earlier
    source-read guesses): PIXI v5.2.4 loads under quickjs; `rmmz_managers.js`
    needs `HTMLVideoElement`/`HTMLImageElement` host globals (empty-constructor
    stubs suffice); the Effekseer WASM init is **not** on the boot path (it
    lives in the bypassed `main.js`, and `effekseer.min.js` loads without WASM),
    so the only WASM-gated script is the audio-only `vorbisdecoder.js`, which is
    skipped; the sole remaining blocker is WebGL (M6.3).
  - 🚧 M6.3 WebGL rendering: the WebGL-subset backend behind PIXI v5 (the bulk
    of the work — MZ dropped the Canvas2D renderer the MV bridge targets). The
    exact gate is `SceneManager.run` → `Utils.canUseWebGL()` throwing at
    `rmmz_managers.js:1890` unless `canvas.getContext("webgl")` returns a real
    (LVGL-backed) context.
    - ✅ M6.3a EGL GLES2 backend foundation: `mruby-mvjs/src/mvgl.cxx`
      (`MV::GL`) drives an off-screen surfaceless-EGL/GLES2 context (llvmpipe
      into an FBO). `flake.nix` adds `libglvnd` (EGL/GLES2 headers + dispatch)
      and `mesa.llvmpipeHook` (headless software-GL runtime), so
      `MV::GL.smoke_test` — compile the PIXI-style GLSL ES 1.00 shaders, draw
      and read back a green triangle — runs as a check in CI, not just the apt
      dev build. (Started on OSMesa; Mesa removed that frontend, so this moved
      to surfaceless EGL, its supported replacement.)
    - ✅ M6.3b WebGL method wrapper: `mruby-mvjs/src/mvwebgl.cxx` maps the
      `WebGLRenderingContext` surface (the `__mv_gl*` natives + JS prototype)
      onto the native GLES2 backend, so `getContext("webgl")` returns a real
      context and `Utils.canUseWebGL()` is true. `gl_test.rb` renders a green
      triangle end to end through the wrapper. Stubs cleanly (getContext →
      `null`) where the EGL backend is absent.
    - 🚧 M6.3c PIXI v5 boots to a frame:
      - ✅ MZ reaches `Scene_Boot` through the renderer: `data/mz-sample` commits
        a minimal authored database and fetches the rmmz engine
        (`scripts/download-mz-corescript.bash`, community mirror, CI-only); `MZ`
        adds the one host global MZ's boot needs (`indexedDB`), and
        `MZ#boot_probe` drives `SceneManager.run(Scene_Boot)` + a few frames past
        the old `Utils.canUseWebGL()` wall. `scripts/mz_boot_check.bash` asserts
        the `[MZ-BOOT] booted to <scene>` marker in CI. Discovered/validated by
        booting PIXI v5.2.4 + rmmz under Node against the wrapper's surface.
      - ✅ On-screen present: `MZ.runtime_available?` tracks `MV::GL.available?`,
        so `MZ#start` boots once and then runs a per-frame loop like MV — PIXI
        renders the scene into the WebGL canvas, `MZ#present` reads that FBO back
        (`MV::JS.present_gl` / `mv_webgl_pixels`) onto a full-screen
        `RGSS::Sprite`/`Bitmap`, and `RGSS::Graphics.update` draws it.
        `mz_boot_check.bash` runs the loop headless (SDL `dummy` video driver, no
        X — Mesa rejects a GLX make-current whenever an X server is reachable)
        and logs `presenting frames on-screen (webgl handle N)`.
        `MV::JS.present_gl` is covered by `gl_test`.
      - ✅ Input: `MZ#main_loop` feeds `RGSS::Input`/mouse into rmmz's
        `Input._currentState` / `TouchInput` each frame (`sync_input` /
        `sync_touch`), reusing MV's shared key map and touch bridge (rmmz and
        rmmv share the button names and state shape).
      - ✅ **Title and a walkable map.** MZ boots past the loading scene into
        `Scene_Title` and, on New Game, into its start map with the player
        walking. Five things were in the way. The first three were found by
        booting PIXI v5.2.4 + rmmz under Node against the host's semantics; the
        last two only surfaced on the real engine in CI, because the Node harness
        stubbed *every* Canvas2D/WebGL method and so could not see a gap in the
        native surface at all. The harness now mirrors `Ctx.prototype` and
        `mvwebgl.cxx`'s `P.*` list exactly — **keep it that way**, or it will go
        on hiding this whole class of bug:
        - **The frame loop never pumped the host.** `MZ#main_loop` called
          `SceneManager.update` itself, but MZ drives itself from PIXI's ticker:
          `SceneManager.run` hands over to `Graphics.startGameLoop`, and it is
          `Graphics._onTick` — reached only through `requestAnimationFrame` —
          that both updates the scene *and* calls `_app.render()`. Calling
          `update` directly therefore rendered nothing and, worse, left every
          promise microtask and rAF callback queued forever, so `Scene_Boot` —
          a *loading* scene that polls `ImageManager`/`FontManager`/
          `ConfigManager`/`StorageManager` readiness across frames — could never
          become ready. `MZ#pump_frame` now advances the host once per frame like
          MV, and `#boot_probe` pumps until the boot scene hands over instead of
          spinning a fixed count.
        - **`HTMLImageElement` was a separate empty constructor.** PIXI v5 wraps
          a texture source by `source instanceof HTMLImageElement`; with the shim
          distinct from the host's `Image`, it built a *fresh* image and assigned
          the object to its `src`, so every loaded bitmap became a broken
          texture. `MZ::HOST_GLOBALS_JS` now aliases the two.
        - **The native Canvas2D context had no `strokeRect`.** MV never calls it,
          so it was never implemented; MZ calls it on a hot path —
          `Window_Selectable.drawBackgroundRect` strokes the frame of *every*
          item in *every* selectable window — so building the title's command
          window threw `TypeError: not a function` at `rmmz_core.js:1587`
          (`Bitmap.prototype.strokeRect`) on the first drawn frame. This one is
          invisible to a permissive JS harness and only showed up on the real
          engine (measured in CI on the diagnostic branch of PR #333, whose
          `[MZ-DIAG]` line reported `Scene_Title` with every readiness gate
          true — the boot was no longer waiting on anything, it was dying inside
          the title's drawing). `mvcanvas.cxx` now implements it as four
          `lineWidth`-thick bars through the same native fill, so the transform,
          alpha and composite mode behave exactly as for a filled rect.
        - **The bed was too thin to leave the loading scene.** `data/mz-sample`
          is now authored by `scripts/gen-mz-sample.py` (like MV's bed): real
          terms, a tileset + `MapInfos` entry, a walled 17×13 room, a party
          sprite, and the system art MZ *requires* — `img/system/ButtonSet.png`
          at ≥ 11×48 px wide, because `Sprite_Button.checkBitmap` throws
          ("ButtonSet image is too small") on anything smaller and MZ's touch UI
          puts those buttons in every scrollable window. The tileset's `flags[0]`
          carries `0x10` ("no effect on passage"): `Game_Map.checkPassage` reads
          the four layers top-down and the first tile not marked so decides, so a
          plain `0` there makes the empty upper layers report every cell passable
          and no wall blocks (checked against a real editor-written tileset).
        - **`gl.clearStencil` was missing from the WebGL wrapper.**
          `WindowLayer.render` calls it on every frame that draws a window, so
          the first rendered frame threw `TypeError: not a function` — and that
          is *fatal*, not transient: PIXI v5 re-arms its `requestAnimationFrame`
          only after `update()` returns, so one throw inside the ticker stops the
          game loop for good. It pinned MZ at `Scene_Title` with New Game already
          requested. Added as a no-op beside the existing `stencilFunc`/`Op`/
          `Mask` stubs, together with `polygonOffset` and the `uniform3i`/
          `uniform4i` setters PIXI generates for `ivec3`/`ivec4`. Note the
          stencil *buffer* is not the gap — the FBO carries a packed
          DEPTH24_STENCIL8 renderbuffer already; it is the wrapper's
          `stencilFunc`/`Op`/`Mask` that are still no-ops, so the per-window
          clipping does not clip.
        - **The render target stayed 1x1.** The WebGL context is taken from a
          canvas that is still 0x0 (clamped to 1x1) and MZ only sizes it later,
          in `Scene_Boot.resizeScreen` → `Graphics.resize` → PIXI's
          `renderer.resize`, which assigns `canvas.width/height`. Nothing
          followed that, so the entire game rendered into one pixel — the CI
          screenshot came back `1x1` and the on-screen present copied a single
          pixel. `mvgl::resize` now re-specifies the colour and depth/stencil
          renderbuffers, `__mv_glResize` exposes it, and the canvas' size setters
          drive it. `gl_test` covers the order that matters (context first, size
          second), which the older tests did not.
        - Validation: `--mz_new_game` / `--mz_move_test` / `--mz_screenshot`
          drive it in CI (`scripts/mz_boot_check.bash` asserts `[MZ-BOOT]` is not
          the loading scene, `[MZ-MAP]` was reached and `[MZ-MOVE] moved=true`),
          and the blocking `scripts/mz_testbed_check.rb` guards the bed's data
          and art under plain CRuby — including the two rules above, which a JSON
          shape check cannot see. It is equally useful against a real MZ project.
          Note the smoke is still `continue-on-error`, so **read its log** rather
          than the job's conclusion: a `FAILED:` line there is a real regression
          even though the job stays green.
      - ✅ **Window clipping.** `WindowLayer.render` masks each window to its own
        shape with the stencil buffer — draw where the buffer is 0, stamp the
        shape with `REPLACE`, so a window behind cannot paint over the one in
        front. The wrapper accepted `stencilFunc`/`stencilOp`/`stencilMask` and
        threw them away, so every window overpainted its neighbours; the FBO's
        packed DEPTH24_STENCIL8 buffer had been there since M6.3a, just never
        programmed. All three now map onto GL, as does `clearStencil`. `gl_test`
        proves it at the pixel level on the real backend: stamp the left half,
        draw a full-screen quad, and assert only the right half survives — which
        is the same shape the window masking uses, and which came out green on
        both halves with the stubs.
      - ✅ **Audio.** rmmz's `AudioManager` exposes the same high-level surface
        MV's bridge overrides, so MZ installs `MV::AUDIO_BRIDGE_JS` verbatim and
        drains the same op queue into `RGSS::Audio` (`MZ#pump_audio`); the whole
        reason MZ was silent was that nobody installed it. One MZ-only addition
        was needed on top (`MZ::AUDIO_BRIDGE_EXTRA_JS`): `Scene_Boot.start` calls
        `SoundManager.preloadImportantSounds`, which loads the system SEs through
        `AudioManager.loadStaticSe` -> `createBuffer` -> `new WebAudio`, and MZ's
        `WebAudio` fetches with **`fetch`** (MV used XMLHttpRequest) — a global
        this host does not provide, so the boot died in `Scene_Boot.start` the
        moment the bed named a system sound. Both entry points are now inert;
        playback still rides the bridged `playSe`. The bed ships an authored
        `audio/se/Beep.wav` wired to the UI sounds, and `--mz_audio_test` plays
        one SE on the map, which `mz_boot_check.bash` asserts as `[MZ-AUDIO]`.
        (Worth noting the engine queues its own ops too — New Game's fade-out
        emits `bgm_fade`/`bgs_fade`/`me_fade` — so the path is exercised even
        without the probe.)
      - ✅ **VAO / `vertexAttribDivisor` fast path.** `getExtension` returned
        `null` unconditionally, so PIXI's `GeometrySystem.contextChange`
        always fell back to its own no-VAO/no-instancing path — correct but
        slower. `OES_vertex_array_object` and `ANGLE_instanced_arrays` (the
        two PIXI actually asks for) are now real, working extension objects:
        the GLES 3.0 core functions they wrap (absent from the GLES2 header
        this builds against) are loaded via `eglGetProcAddress`, core name
        first — `eglGetProcAddress` resolves the legacy `ANGLE`-suffixed names
        to a non-null pointer too, but llvmpipe does not actually implement
        that (non-Khronos) extension namespace and calling it silently drew
        nothing; the OES-suffixed VAO names happened to work, so this only
        surfaced once instancing was tested end to end, not just checked for
        non-null. Covered by `gl_test.rb`: the extension objects are
        advertised with working methods and cached per call, a VAO round-trips
        real vertex-attribute state (two VAOs, one with a bound attribute and
        one without, draw differently through the same program), and
        `drawArraysInstancedANGLE` paints one primitive per instance at its
        own per-instance offset.
      - ✅ **`UNPACK_PREMULTIPLY_ALPHA_WEBGL`.** Grouped with Y-flip above as
        one deferred "pixel-store polish" item, but unlike Y-flip (never set
        `true` by a stock PIXI v5 build) this one already fires on every
        ordinary texture upload — `BaseTexture`'s default `alphaMode` is
        `UNPACK` (premultiply-on-upload), and PIXI's `NORMAL` blend mode
        (`[ONE, ONE_MINUS_SRC_ALPHA]`) assumes the GPU did it. Silently
        swallowing the enum (GLES has no equivalent) left every texture
        uploaded with straight alpha blended as if premultiplied — every
        partially-transparent pixel (window corners, any anti-aliased sprite
        edge) rendered over-bright. Now premultiplied on the CPU before the
        real `glTexImage2D`/`glTexSubImage2D` call, on all four upload paths
        (raw `ArrayBufferView` and canvas-source, both `texImage2D` and
        `texSubImage2D`). Covered by `gl_test.rb`: a raw upload and a
        canvas-source upload each come back scaled by their own alpha with
        the flag on, and untouched with it off (the default).
      - 🚧 Remaining: `UNPACK_FLIP_Y_WEBGL` (genuinely inert against a stock
        PIXI v5 build — never set `true`, only reset to `false`) and
        uniform-introspection polish, as real content exercises them.
      - ✅ **`.woff` fonts.** The canvas text loader looked only for `.ttf`/`.otf`
        under a game's `fonts/`, but **MZ projects ship `.woff`**
        (`mplus-1m-regular.woff` and friends), so it found nothing and every real
        MZ game drew blank windows — `data/mz-sample` hid this by shipping no
        font at all and setting `mainFontFilename` to "". `mvcanvas.cxx` now
        unpacks WOFF 1.0 to the sfnt inside it (a table-by-table container whose
        tables are stored raw or zlib-deflated; the zlib decoder stb_image
        already provides does the work, so no new dependency) and hands that to
        stb_truetype. WOFF2 is a different format (Brotli + a transformed
        `glyf`) and is reported rather than half-parsed into garbage, as are a
        malformed WOFF and a font stb_truetype rejects — silent blank text is
        exactly what let this hide.
      - ✅ CI coverage for the unpacker: it needed a redistributable font and the
        bed ships none, and its result sits behind `game_font()`'s
        process-lifetime cache, invisible to a font dropped in after another
        test has already drawn text. `MV::Font.unpack_woff`/`smoke_test`
        (test-only mrb bindings) reach `woff_to_sfnt` and a fresh
        `stb_truetype` rasterisation directly; `mz_test.rb` hand-authors the
        smallest font that can prove the pipeline (one glyph mapped from
        `'A'`, the way the MV image fixtures are built) and checks the
        unpacked sfnt comes back byte-for-byte identical and rasterises the
        same real ink as the bare original.
