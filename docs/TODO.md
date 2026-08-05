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
  spirit / agility), an **item** count (number held, or number equipped across the
  party), **game quantities** (party gold, timer seconds, party size) and a
  **character position** (the hero's or a map event's map id / x / y / facing —
  an event's map id reads 0, matching an RPG_RT 2000 quirk; screen coordinates
  are not modelled).
  Conditional Branch covers switch / variable / **timer** / gold / item /
  **vehicle** (is the party aboard the boat / ship / airship) / **orientation**
  (is the hero or a map event facing a given direction) conditions and **all**
  the **actor** sub-conditions (in party, name, level ≥, HP ≥, item equipped,
  skill known, and **afflicted by a state**). Actors now
  carry a **status-condition (状態) set** (`Game::Actor#states` with
  `add_state` / `remove_state` / `state?`; **Full Recovery clears it**), which
  persists in both the Marshal save and the `.lsd` (chunk 108 fields 81/82,
  previously parsed-but-unused) and is restored by `from_lsd`, so a real save's
  status ailments survive. The **item menu cures states**: a medicine with
  `reverse_state_effect` set removes its `state_set` conditions from the target
  (an antidote / herb — unconditional, matching EasyRPG's item algorithm), and
  such an item now counts as usable when the target is afflicted even at full HP.
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
  returns to the title — see the Enemy Encounter entry). Still remaining:
  inflicting states from **battle** (rolling `state_chance` / to-hit, the
  non-reverse item case, enemy attacks).
  **Show / Move / Erase
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
  buy / sell menus (one unit per confirm — the quantity selector is a later
  refinement).
  **Enemy Encounter** (10710) starts the battle path: `Game::Enemy` / `Game::Troop`
  instantiate a database enemy group into live members and total its EXP / gold,
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
  戦闘不能 — and a **defeat ends the game** (return to title via
  `perform_game_over`) when the encounter's defeat mode is "game over" (no
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
  so a temporary ailment wears off. **Forced-action restrictions** work too: a
  `restriction` of 2 (berserk) forces a basic attack on a random enemy even when
  the battler was told to defend, and 3 (confused) sends the attack at a random
  member of its own side. Basic attacks **and attack skills** apply RPG2000's
  **damage variance** (a `var` of 4 for attacks, each skill's own `variance` for
  skills, spread via `Algo::VarianceAdjustEffect`), enabled for the live game and
  off for seeded / headless fights. Still to come: enemy-cast infliction,
  criticals / attributes, all-target skill/item scopes, the per-terrain backdrop
  and the RPG2000 Game Over graphic.
  The remaining event commands (tile substitution and other native-render
  effects) are TODO. **Show Battle Animation** (11210) now plays on the map — the
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
  skin); **Change Screen Transitions** (10690) records the six teleport / battle
  transition styles (save chunks 111–116; modelled for save fidelity); and **Game
  Over** (12520) returns to the title — all handled. **Vehicle locations** (boat /
  ship / airship) also persist in the save (`Game::Vehicle`, `.lsd` chunks
  105–107 / the Marshal save).
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
  (11020) drive `Game::Screen` too: a fade level (0 visible .. 255 black) that
  eases like the tint over a fixed transition and is held erased until a Show,
  recording the requested transition style (fade / block / stripe / scroll) for
  fidelity while modelling only the fade — and the fade **is** drawn, by the
  same screen-sized sprite mechanism as the flash. All share the `:screen` wait,
  so event timing around them is correct. **Show Picture** now renders (see the
  interpreter bullet above).

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
  Switch (type 9) item use, teleport/escape/switch skill types, the battle-time
  skill variance, the item usable-occasion gate, and two-handed / dual-wield
  equipping are later refinements.
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
- ✅ Menu screens — the Item, Skill, Equip and Status screens all exist now (see
  Menu scene above). The Skill screen's recovery formula (`power +
  physical_rate*atk/20 + magical_rate*spirit/40`) is the same one the battle
  system will reuse for skills; battle adds the +/- variance the field path omits

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
  boots with no loose files. Same remaining gap as XP: graphics/audio are still
  read from loose files only.
- 🚧 **Run the bundled scripts** — a VX/VX Ace game's engine is its script
  bundle, so this is *the* path rather than a later refinement. The host already
  runs (`RPGXP::ScriptHost`, ADR 0017) with the per-frame Fiber driver now
  shared by both shells (`ScriptHost.build_driver`, ADR 0023); what is missing is
  the RGSS2/RGSS3 halves of the `mruby-rgss` class library the stock scripts call
  (the RGSS1 gap is tracked in
  [`docs/rpgxp-rgss-api-gap.md`](rpgxp-rgss-api-gap.md); RGSS2 added
  `Graphics.wait/fadeout`, `Window#openness`, `Cache`, and RGSS3 the `rgss_main`
  wrapper and `Bitmap#draw_text` sizing the VX windows rely on).
- **Built-in title/map flow** — the reimplemented scene stack the RPG2000 and XP
  runtimes have (title → New Game → walkable map). Not written yet; a boot
  without the script host reports that instead of showing a blank window.
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
      - 🚧 Remaining: present the GL frame on-screen each frame + resize the FBO
        to the canvas (continuous play, not just the boot probe); optional VAO /
        `vertexAttribDivisor` fast path (PIXI falls back without it); texture
        Y-flip + image uploads and uniform-introspection polish as real content
        (a user-supplied MZ project) exercises them.
