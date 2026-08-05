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
  Event, Move Event, Change / Trade Event Location, Change Map Tileset,
  Change Parallax Background, Proceed
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
  off for seeded / headless fights. A basic attack can land a **3x critical hit**
  at the attacker's database 1-in-N chance (actor `critical_rate`, enemy
  `critical_hit_chance`); no crit on a same-side hit. Characters wearing gear with
  the **`prevent_critical`** flag can never be crit. **Elemental attributes**
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
  off and an immune one never catches it. A **pre-emptive first strike** (the
  Enemy Encounter's first-strike flag) gives the party a free opening round —
  the ambushed enemies skip their turn in round 1 and rejoin from round 2.
  **All-target skills** work too: a scope-1 (all enemies) or scope-4 (all allies)
  skill resolves against every living target in one action — `command_skill_all`
  spends the SP once and `apply_command` produces one log entry per target,
  buffered so the screen animates the volley hit by hit — with attack damage
  still computed per target's defence. **All-party items** (medicine scope 1)
  work the same way through `command_item_all`, healing / curing every living
  ally and consuming a single item for the whole volley. Still to come:
  enemy-cast infliction, the per-terrain backdrop and the RPG2000 Game Over
  graphic.
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
  skin); **Change Screen Transitions** (10690) records the six teleport / battle
  transition styles (save chunks 111–116; modelled for save fidelity); and **Game
  Over** (12520) returns to the title — all handled. **Vehicle locations** (boat /
  ship / airship) also persist in the save (`Game::Vehicle`, `.lsd` chunks
  105–107 / the Marshal save).
- 🚧 Message window — renders text lines and a choice cursor and expands the
  common message control codes (`\v[n]` variable, `\n[n]` actor name, `\\`,
  `\_` space). Text now **reveals gradually** (a `Game::TextReveal` typewriter
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
  `Game::State` countdown) and is now **drawn**: the start operation's
  "show timer" flag sets a `timer_visible` state (persisted in the save), and
  while set `Scene::Map` shows a small top-centre window counting down as
  `M:SS`, independent of whether the timer is still running. The **Tint Screen**
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
  A **switch item** (type 9) is field-usable too: `Game::Party#use_switch_item`
  consumes one and returns the game switch it turns on, which the item menu then
  sets (matching EasyRPG, where the scene owns the switch table). The **usable
  occasion** is honoured on both sides: a medicine / switch item flagged
  battle-only (`occasion_field` off) is hidden from the field menu, and one
  flagged field-only is hidden from the battle item list (books / seeds stay
  field-only). Teleport/escape/switch skill types, the battle-time skill
  variance, and two-handed / dual-wield equipping are later refinements.
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
  `Music/`/`Sound/`/`Audio/*`
- ✅ MIDI music — `scripts/download-freepats.bash` installs the FreePats patch
  set into `assets/timidity` (git-ignored, ~32 MiB), which drives SDL_mixer's
  built-in TiMidity synthesiser, so the `.mid` BGM that RPG2000 projects ship is
  audible (ADR 0026). `TIMIDITY_CFG` overrides the patch set;
  `Audio.midi_available?` reports whether one was found. Remaining polish:
  pitch/tempo control (SDL_mixer exposes none), MIDI for SE/BGS (they play as
  samples, which are never synthesised). The browser build plays MIDI too: the
  Emscripten SDL2_mixer port is asked for `-sSDL2_MIXER_FORMATS=ogg,mid` (it
  defaults to OGG-only, so it had no MIDI decoder at all) and CI mounts the
  patch set with `-DWASM_MIDI_PATCHES=ON`, at ~32 MiB of `index.data`
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
  widgets, plus `Kernel#sprintf`. (`Graphics.freeze`/`transition` now draw, on
  the native `Graphics.snap_to_bitmap` — see the VX section below.)
  Also reconcile the scripts' blocking main loop with the emscripten frame loop
  (Asyncify or a per-frame driver). (Graphics and audio both come out of the
  encrypted archive now — see Encrypted archives above.)
- ✅ **Cross-runtime testing** — an XP project is booted natively and against the
  genuine runtime, both asserting the same `[RPGXP-MAP]` marker
  (`--rpgxp_new_game` picks New Game without input):
  `scripts/rpgxp_boot_check.bash` (the native binary, in CI — the guard against
  mruby/CRuby divergence the CRuby-hosted checks cannot see) and
  `scripts/compare-rpgxp-wine.bash`, which diffs our frames against the genuine
  `Game.exe` + `RGSS104E.dll` under wine, the XP twin of
  `compare-nepheshel-wine.bash`. That comparison is the harness the remaining
  render work below is meant to be driven by. See
  [`docs/adr/0025-rpgxp-cross-runtime-testing.md`](adr/0025-rpgxp-cross-runtime-testing.md);
  a third check played the project in the **browser build** and found (and this
  fixed) an XP project rendering on a 320x240 screen in the page and the loader
  panel covering the running game, and the wine pass found four more (the XP RTP
  key was never read, `.jpg` was missing from the asset search, truecolour images
  were red/blue-swapped, and an RGBA image loaded opaque drew garbage) — the XP
  title screen now differs from the genuine runtime in 15% of its pixels, down
  from 74%, the rest being the windowskin's opacity and the reference's font-less
  text.
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
  `--rpgxp_new_game` instead of pressing keys.
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
  `Graphics.transition`. What a real XP game uses that we still skip: `203`
  (scroll map), `207` (show animation) and `355` (script).
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
        runs); texture Y-flip and uniform-introspection polish as real content
        exercises them; and a `.woff` font path — the canvas text loader finds
        only `.ttf`/`.otf` in a game's `fonts/` and MZ games ship `.woff`, so a
        real MZ game's text draws blank. That is the biggest visible gap left.
