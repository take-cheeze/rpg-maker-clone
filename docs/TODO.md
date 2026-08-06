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
  advancing

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
  it finishes. Vehicle targets (boat / ship / airship, 10002-10004) resolve as
  well, so a route can drive one
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
  *inflicting*, exactly as it does for a skill; nothing in either bed sets it, so
  that half is left unbuilt rather than guessed at. A fixture check cannot catch
  a polarity error — it is written to match whatever the code does, and four of
  them encoded the wrong reading quite happily — so
  `rpg2k_testbed_logic_check.rb` now asserts against the **real** item table that
  every curative medicine cures exactly the states it names.
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
  行動パターン entry below). Still remaining here: the non-reverse item case.
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
  **Set Teleport / Escape Target** (11810 / 11830), **Change Encounter Rate**
  (11740) and **Change System BGM** (10660) record their payloads
  on `Game::State` — a per-map teleport-target registry, a single escape target,
  the encounter step rate and per-slot system music overrides — and
  round-trip through the save, but nothing consumes them yet (the Teleport /
  Escape skills, encounter system and battle scene are not built), so
  they are modelled for save fidelity like the access flags. **Change System
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
  party through the real interval against it. Still unread: `affect_type` stat
  halving / doubling plus the RPG2003-only `avoid_attacks` / `reflect_magic`,
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
  changing shape, not the bonus. Still unread:
  **`attack_all`** (7 weapons), whose handling is not in EasyRPG's `algo.cpp`
  with the others and is left declared rather than guessed; and **`preemptive`**
  / **`raise_evasion`**, the latter having nowhere to land until the to-hit
  formula grows an evasion term separate from agility. **Elemental attributes**
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
  a field-by-field audit found both test beds filling in **126 of the 127 term
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
  so no real game changes behaviour. Still TODO here: the `command_actor`
  (chosen battle command) condition, which RPG_RT only answers for the battler
  whose action triggered the check — this runtime evaluates pages once per turn
  with no acting battler, the same null-`source` case EasyRPG bails on, so such a
  page deliberately does not fire rather than firing unchecked; and video
  playback for Play Movie (no decoder is linked in; the request is logged). **Show Battle Animation** (11210) now plays on the map — the
  scene composites the animation's cells from its `Battle/<name>` sheet over the
  target frame by frame and fires its screen flashes, holding the event with the
  wait flag (per-cell zoom / tone and target-only flashes are approximations for
  now). **Set Vehicle Location** (10850) and **Change Vehicle Graphic** (10650)
  place a boat / ship / airship and set its CharSet (persisted via
  `Game::Vehicle`), and the party can now **board and pilot** a placed vehicle on
  the map (`Game::State#boarded`; airship flies over any tile, boat / ship follow
  their terrain). Placed vehicles are **drawn on the map** from their CharSet, the
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
  wine diff, but the direction matches RPG_RT. The mirrored-face flag is a
  later refinement
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
  was already there. What is actually left per style:

  - **Scroll (settings 9–12)** and **combine / division (13–15)**: capture the
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
  not, on any genuine item. See ADR 0031. Remaining: **teleport / escape** skill
  types (one of each across both test beds; teleport wants a destination picker
  this build has no screen for, so `Party#unsupported_field_skill?` declares the
  gap), the battle-time skill variance, and two-handed / dual-wield **equipping**
  (the equip screen's slot rules — a 二刀流 weapon's *combat* effect is read now,
  see ADR 0033).
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
      - 🚧 Remaining: optional VAO / `vertexAttribDivisor` fast path (PIXI falls
        back without it, and `getExtension` returns null so the fallback is what
        runs); and texture Y-flip and uniform-introspection polish as real
        content exercises them.
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
      - 🚧 Remaining for fonts: no CI test covers the unpacker, because it
        needs a redistributable font and the bed ships none. Verified locally
        instead, against two real TTFs repacked as WOFF: the unpacked sfnt comes
        back byte-for-byte the size of the original, stb_truetype accepts it, the
        vertical metrics and every A-Z advance/lsb match the original exactly,
        and a glyph rasterises with real ink. Authoring a tiny TTF we own (the
        way the bed's PNGs are authored) would let the smoke render text and
        close this.
