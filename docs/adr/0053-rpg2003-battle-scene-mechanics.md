# 53. RPG2003 battle scene mechanics — ATB/gauge timing and rows

Date: 2026-08-16

## Status

Accepted — Phase 1 (rows), the Phase 2 gauge model (fill + ready + turn cycle),
the Phase 2 scene integration and Phase 3 (boot-to-battle) all implemented
2026-08-16. The active-time turn cycle itself — the per-frame picker that
consumes a full gauge — is implemented as the follow-on ADR 0054.

## Context

The runtime boots and plays **RPG2000** battles end to end (turn-based,
`Scene::Battle` extracted from `Scene::Map` per ADR 0052, every RPG_RT battle
command and menu path ported). RPG2003 reuses that same turn-based skeleton
but layers three mechanics on top that this engine does not model yet:

1. **Battle timing.** RPG2003 offers three `battle_type` presentations
   (database chunk 0x1D field 7, already decoded into the schema): 0
   traditional (RPG2000-style), 1 alternative (actor sprites, no ATB), 2
   **gauge** (an active-time / charge gauge per combatant that fills and
   triggers turns). The gauge (and the implicit ATB of presentation 1 for
   enemy turns) is a per-frame time system the current turn-based phase
   machine has no concept of.
2. **Rows.** RPG2003 actors / enemies can sit in a front or back row
   (`battlecommands.placement`, chunk 0x1D field 2 — 0 manual via the actor's
   `battle_x`/`battle_y`, 1 automatic) and the row changes hit / evade /
   attack-reach: back-row actors are harder to hit and cannot reach front-row
   melee. The current combat model has no row attribute and no row-adjusted
   accuracy.
3. **Battle-command customization** — the one 2003 battle piece that *is*
   already done. ADR 0048 covers it: the database-wide Battle Commands table
   (chunk 0x1D), per-actor / per-class `battle_commands` (chunk 11/30 field
   80), `change_battle_commands` (event 1009), and `Scene::Battle` resolving
   Row (0) / empty (-1) / Attack / (sub)Skill / Defense / Item / Escape /
   Special into the menu. The data path is complete and exercised by
   `mruby-rpg2k/mrblib/scene/battle.rb` and `game.rb`.

So the gap is purely the *scene mechanics* — a time system for presentations 1
and 2, and a row model for accuracy/reach — on top of the battle-command data
path that already works. None of it is reachable today because the engine does
not yet boot an RPG2003 project to a battle (the title/boot path still assumes
RPG2000), so every piece below is unverifiable against real gameplay until a
2003 project can be driven into a fight; verification will rely on
`scripts/rpg2k_*_check.rb`-style unit harnesses over the mtf-meido-action 2003
test bed plus a hand-built battle-state fixture.

## Decision

Scope the 2003 battle work as three independent, separately-landable phases,
each behind its own PR, so none blocks the others and each is reviewable on
its own:

- **Phase 1 — rows (smallest, no time system).** Add a row attribute to
  `Game::Battle::Combatant` (front/back, default from
  `battlecommands.placement` for manual placement), thread it through
  `Game::Battle`'s hit/evade rolls and melee-reach check, and adjust accuracy
  the way RPG_RT / EasyRPG (`Game_Battler::GetHitChance`,
  `src/game_battler.cpp`) does. No scene timing change; still turn-based.
- **Phase 2 — active-time / gauge timing.** Introduce a per-combatant time /
  charge gauge advanced every frame by `Scene::Battle#update`, gated on
  `battle_type` (presentation 2 always, presentation 1 for enemy turns), and
  replace "whose turn is it" with "whose gauge is full." Keep the turn-based
  branch intact for `battle_type` 0 so RPG2000 is untouched.
- **Phase 3 — 2003 boot-to-battle.** Make the project boot path (title → New
  Game / Continue) honour the 2003 edition and drive an actual 2003 project
  into `Scene::Battle`, so Phases 1–2 become verifiable against real gameplay
  rather than only against fixtures.

Each phase lands behind a `scene/check.rb` / `logic_check.rb` harness entry
over mtf-meido-action before merge, following the existing RPG2k verification
convention.

## Phase 1 — implementation notes (2026-08-16)

Landed in `mruby-rpg2k/mrblib/game.rb`:

- `Game::Battle::Combatant` gained a `:row` field (nil → front; `ROW_FRONT` /
  `ROW_BACK` constants on `Game::Battle`). A back-row battler reports
  `back_row?`. `Game::Battle.from_actor` seeds it to the front row by default
  (the RPG2000-only row); per-battler row derivation from
  `battlecommands.placement` (field 2) + the actor's `battle_x`/`battle_y` is
  the remaining data step and is intentionally **not** guessed here — the
  placement→row mapping is an RPG_RT 2003 presentation rule that needs the spec.
- **Row adjustments are ported from EasyRPG's `Algo` (src/algo.cpp)**, once
  that source became reachable, which resolved the earlier guesses. The row
  mechanic is richer than "back-row is hard to hit": `Algo::IsRowAdjusted`
  decides whether a battler's row matters at all, by *battle condition* and
  *role*. This engine models no battle conditions, so only the normal (`none`)
  branch holds, and `Game::Battle#row_adjusted?(battler, offense)` is that
  branch: an actor standing on the offense row is row-adjusted (a **front-row
  attacker deals +25% damage** — the deferred attacker-side piece; an *enemy*
  attacker is never row-adjusted, `allow_enemy=false`), and a **back-row
  defender is 25 harder to hit and takes -25% damage**. This replaces the
  pre-reference `row_hit_modifier` guess of a flat **50% multiplier**: the
  reference's `CalcNormalAttackToHit` subtracts a flat 25 (`to_hit -= 25`,
  `ROW_HIT_PENALTY`), and `CalcNormalAttackEffect` scales damage by 125/100
  (attacker, before the weapon's elemental multiplier) and 75/100 (defender,
  after it). RPG2000 never sets a row, so every term is a no-op there.
- **Skills are deliberately not row-adjusted.** EasyRPG's `CalcSkillToHit` /
  `CalcSkillEffect` gate their row terms behind `skill.easyrpg_affected_by_row_
  modifiers`, an EasyRPG-only field the RPG Maker 2003 editor cannot set
  (absent from every real 2003 file), so vanilla skills are untouched by rows;
  the earlier `Party#skill_to_hit` row penalty is removed to match.

Verification: `scripts/rpg2k3_battle_row_check.rb` (13 checks) exercises the
row model, `#row_adjusted?` (front-row ally attacker adjusted, back-row / enemy
attacker not, back-row defender adjusted), the flat 25 hit reduction in
`Battle#to_hit`, the 125/75 damage adjustments in `Battle#deal_attack` in the
reference's order, that a physical skill is *not* row-adjusted, and `from_actor`
front-row default; wired into the `ruby-checks` CI job. The existing
`rpg2k_logic_check.rb` and `rpg2k_scene_check.rb` suites stay green because no
fixture sets a back row.

## Phase 2 — implementation notes (2026-08-16)

The active-time (gauge) model is in place in `mruby-rpg2k/mrblib/game.rb`;
the per-frame `Scene::Battle` integration that actually drives turns off it is
**deferred to Phase 3** (the 2003 boot path), because the gauge only matters
once a 2003 project reaches a fight.

- `Game::Battle::Combatant` gained a `:gauge` field (0..`GAUGE_MAX`, default
  empty) with `gauge` / `gauge_full?` readers.
- `Game::Battle` gained `battle_type` (0 traditional / 1 alternative / 2
  gauge; defaults to 0) and the gauge engine:
  - `advance_gauges(ticks)` fills every charging battler's gauge, clamped to
    `GAUGE_MAX`. The exact curve was settled later, in the ADR 0054 follow-on,
    as EasyRPG's `Game_Battle::UpdateAtbGauges` port (`GAUGE_MAX` 300000,
    per-frame increment `GAUGE_MAX / (sum_agi / (agi + 1))` over every
    non-hidden battler's AGI) — the original placeholder (`effective_agi *
    GAUGE_AGI_RATE * ticks`, max 100) is gone. It is a
    **no-op unless `battle_type == 2`**, so RPG2000 and the 2003 traditional
    presentation keep running the turn-based machine untouched.
  - `ready_combatants` returns the full-gauge battlers in descending gauge
    order — the pool the active-time turn picker draws from. `all_combatants`
    joins allies + enemies for bookkeeping.
  - The active-time turn cycle is modelled too: `reset_gauge(c)` empties a
    combatant's gauge after it acts, and `pop_ready` returns the highest-gauge
    ready combatant and resets it — the "fill → ready → act → refill" loop the
    per-frame `Scene::Battle` picker will drive (Phase 3). Both are nil / no-op
    for a turn-based battle.
- The database's battle-setup `battle_type` (Battle Setup chunk 0x1D field 7,
  already decoded into the schema) is now plumbed into `Game::Battle` at
  construction: `Game::Battle.new` takes a `battle_type:` keyword (default 0),
  and `Scene::Battle` passes `db.battlecommands.battle_type` (0 when the
  database has no Battle Commands table, i.e. every RPG2000 project). This is
  the first Phase-3 (boot) slice — it makes the gauge engine actually select
  for a 2003 gauge battle the moment one is reached — without touching the
  turn-based path.
- **Open within Phase 2:** the turn picker that consumes a ready combatant and
  resets its gauge (replacing "whose turn is it" in the round machine) is
  intentionally **not** wired yet — doing so requires the per-frame
  `Scene::Battle#update` loop and a 2003 project to run it (Phase 3). The
  exact fill curve was also deferred — the ADR 0054 follow-on resolved it
  against EasyRPG's own RPG_RT 2003 port once that source was reachable.

Verification: `scripts/rpg2k3_battle_gauge_check.rb` (14 checks) exercises the
inert turn-based path, the real relative fill curve, full/ready selection,
ordering, that a dead battler neither charges nor becomes ready, and that a
do-nothing-restricted ally never charges; wired into the
`ruby-checks` CI job.

## Phase 2 — scene integration notes (2026-08-16)

The per-frame gauge advance is now driven from the battle scene rather than
left as a fixture-only model. A new `RPG2k::Scene.battle_scene_class(db)`
factory (`mruby-rpg2k/mrblib/scene/base.rb`) selects the scene class for a
fight: `RPG2k3::Scene::Battle` (a new `mruby-rpg2k/mrblib/scene/battle_rpg2k3.rb`)
when the database was authored in 2003 (`db.rpg2003?`), else the plain
`RPG2k::Scene::Battle`. `Scene::Map#drive_battle` now constructs the battle
through this factory instead of `Scene::Battle.new` directly, so the 2003 scene
is reached the moment a 2003 project opens a fight.

- `RPG2k3::Scene::Battle` subclasses the 2000 scene and overrides `#update` to
  call `Game::Battle#advance_gauges` once per frame **before** `#super`, gated on
  `battle_type == 2`. `advance_gauges` is itself a no-op for `battle_type != 2`,
  so the traditional (0) and alternative (1) presentations run the unchanged
  turn-based machine — routing every 2003 fight through this scene is safe and
  future-proof for the 2003-specific presentation work.
- The factory is referenced at call time (not load time), and `RPG2k3::Scene::Battle`
  only needs to exist when the method runs, so scene-file load order does not
  matter for correctness. `battle_rpg2k3.rb` sorts after `battle.rb` in the
  mrblib glob, so its superclass is defined before it is parsed.

Verification: `scripts/rpg2k_scene_check.rb` adds checks that `battle_scene_class`
returns `RPG2k3::Scene::Battle` for a 2003 database, `RPG2k::Scene::Battle` for
an RPG2000 database, and the 2000 scene for a database that implements no
`#rpg2003?` at all (a bare fixture) — keeping the gauge engine dark for every
fixture-driven check. The existing 660-check scene harness stays green.

## Phase 3 — boot-to-battle notes (2026-08-16)

The 2003 boot path is the piece that makes Phases 1–2 end-to-end verifiable
against real gameplay, and it is what turned out to be blocking: the 2003 test
beds (mtf-meido-action) ship **no encounters at all** — no Enemy Encounter
commands, no random-encounter tables on any map — so a bare boot only ever
reached the map, and no 2003 fight could be driven from real data.

- A new `--rpg2k_battle_troop <id>` flag (RPG Maker 2000/2003, `src/main.cxx`
  `DEFINE_int32` → the `RPG2K_BATTLE_TROOP` constant) opens a battle against the
  named database troop right after New Game: `RPG2k#start_new_game`
  (`mruby-rpg2k/mrblib/main.rb`) calls the map's new `Scene::Map#headless_battle`
  once the map scene is built, which arms the fight on the map's own foreground
  interpreter through `Game::Interpreter#start_random_battle(..., headless: true)`
  — the same `:battle` wait a wandering encounter uses, so `#drive_battle` picks
  it up on the map's next frame and the fight runs through the ordinary battle
  machinery (including the `battle_scene_class` routing from the Phase 2 scene
  integration). The battle then waits for input until the run times out.
- The request carries a `headless: true` marker so `Scene::Battle#start` logs
  `[RPG2k-BATTLE] troop=<id>` once the fight's whole UI — backdrop, troop
  sprites, actor sprites, the status panel — is actually on screen. A real
  encounter never sets the marker, so the line never appears for ordinary play.
- `scripts/rpg2k_boot_check.bash` now runs a battle pass (mtf-meido-action,
  troop 14, a single Behemoth) alongside the map boot, asserting the marker
  appears and that no `[RPG2k] battle failed` line does.
- **Latent native-only bug this exposed and fixed:** the fight's backdrop is
  seeded from `Scene::Map#current_map_tone` behind a `respond_to?` guard. CRuby
  excludes private methods from `respond_to?`, so the CRuby harnesses skipped
  the call and passed; mruby's `respond_to?` ignores visibility, so **every**
  native battle raised `NoMethodError: private method 'current_map_tone'`
  at `Scene::Battle#build_battle_back` — the battle "failed" gracefully (logged
  and resumed as a victory), meaning no real fight ever opened on the binary
  since the tint commit. `current_map_tone` is now public, the way its own
  comment and the "services the battle scene calls back into" list already
  intended (covered by a scene check asserting the plain-call works).

Verification: the battle drive reaches `[RPG2k-BATTLE]` against the real 2003
database and stays stable (no repeated errors) for the whole run, exercising
the 2003 scene routing, troop/actor sprites, the gauge-card status layout
(System2 missing on the test bed degrades to the text rows it always did, and
the missing Monster graphic to its placeholder block — both logged, never
fatal). Scene checks pin the `headless_battle_troop` flag plumbing and
`Scene::Map#headless_battle`'s request shape; `rpg2k_logic_check.rb` pins the
`headless:` marker on the request.

## Consequences

- RPG2003 battles become progressively implementable without disturbing the
  already-working RPG2000 battle: Phases 1–2 are additive and gated on
  `battle_type` / row data that RPG2000 never writes.
- The 2003 boot path (Phase 3) is what makes the work end-to-end verifiable;
  its first real drive already caught a latent crash that only the native
  binary could hit (the `current_map_tone` visibility bug above), the exact
  mruby/CRuby divergence class the CRuby harnesses cannot see.
- Row and timing are modelled as data on `Game::Battle::Combatant` so they are
  reusable by both the turn-based and gauge phase machines and by enemy AI.
- The active-time turn cycle — the gauge-readiness-driven picker that consumes
  a full gauge with a command/AI action and resets it — is implemented as the
  follow-on ADR 0054, on top of the Phase 2 scene integration and Phase 3 boot
  path: a gauge fight now runs on per-combatant gauges instead of the 2000
  sequential round machine, with every other 2003 fight untouched.
- Follow-up work (battle-event pages already parsed; 2003-specific battle
  commands beyond the five this engine drives) stays out of scope for these
  three phases and is tracked separately. The Special command handler landed
  with the command-customization follow-up (2026-08-17), and the attacker-side
  row adjustment is implemented (ADR 0053 Phase 1 notes, 2026-08-17); the
  condition-gated `IsRowAdjusted` branches (back-attack / surround) remain
  open until the battle conditions are modelled.
- **The in-battle Row command landed (2026-08-18).** The earlier framing above
  ("per-battler row derivation from `battlecommands.placement`") turned out to
  be the wrong model once EasyRPG's actual `Game_Actor` source was reachable:
  row is not derived from the placement table or the actor's manual
  `battle_x`/`battle_y` at all -- it is its own persisted field
  (`data.row`/`GetBattleRow`/`SetBattleRow`, liblcf's `SaveActor` field
  `0x5B`), defaulting to the front row and changed only by the player, via the
  Row battle-menu command. `Game::Actor#battle_row`/`#battle_row=` now carry
  that state (schema.rb's `SAVE_PARTY_ACTOR` field 91, both the LCF `.lsd`
  round-trip and the portable Marshal save), `Combatant.from_actor` seeds a
  fight's row from it, and `Scene::Battle`'s command window appends a fixed
  Row entry (`#row_command_available?`, gated on `battle.rpg2003?` since the
  EasyRPG-only `easyrpg_disable_row_feature` opt-out this mirrors has no real
  LCF field for a vanilla database to set) that flips it via the new
  `Game::Battle#toggle_row`, a `DoNothing` turn like the Special command,
  refusing a toggle that would empty the front row
  (`#can_leave_front_row?`, ported from EasyRPG's `RowSelected` guard) with
  the reference's own Buzzer SE. `scripts/rpg2k3_battle_row_check.rb` and
  `rpg2k_scene_check.rb` stay green. Still open: the field menu's own Row
  screen (id 6 of `RPG2K3_COMMAND_IDS`, a pre-battle per-actor row picker,
  EasyRPG's `Scene_Row`) and the automatic-placement `row_x_offset` /
  pincer-surround grid tables, both noted in `scene/menu.rb` and ADR 0054
  respectively.
