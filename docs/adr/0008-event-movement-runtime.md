# 8. Event movement runtime (move routes and autonomous walk)

Date: 2026-08-02

## Status

Accepted

## Context

The LCF loaders already decode move routes (`LCF.parse_move_commands` /
`LCF::MoveCommand`) and the movement fields on an event page (`move_type`,
`move_frequency`, `move_speed`, `move_route`), but nothing consumed them: map
events were static markers at a fixed tile. Getting a real game such as
Nepheshel to feel alive needs events that actually roam — guards that pace,
NPCs that wander, objects that approach the hero, and events scripted with a
custom move route.

Two constraints shape the design:

- **The SDL/mruby binary cannot be built or run in CI's cheap path.** The pure
  gameplay logic therefore has to be verifiable under host CRuby, the same way
  `scripts/lcf_testbed_check.rb` verifies the loaders. That pushes the movement
  logic out of the drawing/scene layer and into plain `Game::` objects that
  touch neither RGSS nor the native parser.
- **mruby is built here without `mruby-random`** (see `build_config.rb`), so
  `Kernel#rand` is unavailable and random movement needs its own generator that
  stays within a 32-bit `mrb_int`.

## Decision

Model event movement as pure `Game::` logic driven by the scene through a small
adapter:

- `Game::Character` — a movable entity (tile position, facing, and the flags a
  move route can toggle: speed, frequency, through, facing lock, animation,
  transparency, graphic). It knows only geometry (`move`, `face`, turns,
  `direction_toward`/`direction_away`), never how to draw.
- `Game::MoveRoute` — a cursor over a decoded `LCF::MoveCommand` list. `step`
  runs one command against a `Character`, using a `world` collaborator for
  passability, hero position, switch/sound side effects and randomness. It
  implements every RPG2000 move-route opcode and honours the route's `repeat`
  and `skippable` flags; a blocked non-skippable move turns to face the obstacle
  and retries on the next step.
- `Game::MoveType` — the autonomous (non-custom) walk types: random,
  vertical/horizontal bounce, and approach/flee the hero.
- `Game::Rng` — a tiny LCG (multiplier 75, prime modulus 65537) whose arithmetic
  never reaches 2**31, so it needs no bigint promotion on this target.

`Scene::Map` owns the glue: it builds one `Character` per active event page,
steps each event every frame (paced by its move frequency) either along its
custom `MoveRoute` or per its `MoveType`, and exposes itself to the engine via a
`MapWorld` adapter implementing the `world` protocol. Occupancy is updated
eagerly as each event moves, so an event that has already moved this frame
blocks the next one — events never stack on a tile, the player or impassable
terrain.

The logic is covered by `scripts/rpg2k_logic_check.rb` (pure engine) and
`scripts/rpg2k_scene_check.rb` (the real `Scene::Map` behind RGSS stubs), both
run in CI.

## Consequences

- Events now move at runtime, closing the "driving events from move routes"
  gap and the move-route part of the event-page work in `docs/TODO.md`.
- The `world` protocol keeps the engine testable and decoupled: the same
  `MoveRoute`/`MoveType` code runs under a fake grid world in tests and the real
  map in the game, so most movement behaviour is validated without the native
  build.
- Event sprites are still drawn as markers, so movement currently snaps tile to
  tile with no per-step pixel interpolation (unlike the player). Smooth event
  interpolation and real charset rendering are follow-up work.
- The interpreter's *Set Move Route* (Move Event) event command is now wired up.
  Its route is packed inline in the command's parameters (a different layout from
  the page/common-event `move_route` chunk — the ids are the same, but the
  strings for change-graphic / play-sound live in the command's string field,
  prefixed by their length in the parameter list). `Game::Interpreter` decodes it
  into `Game::MoveCommand`s and queues a non-blocking request; `Scene::Map`
  applies it as a *forced route* to the target (a map event, "this event" or the
  player) that overrides page movement until it finishes, reusing the same
  `MoveRoute` executor and `world` protocol. The player, which has no
  `Game::Character`, is mirrored by one for the duration and input movement is
  suppressed while the route runs. Vehicle targets remain unmodelled.
