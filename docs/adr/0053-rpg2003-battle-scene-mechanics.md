# 53. RPG2003 battle scene mechanics — ATB/gauge timing and rows

Date: 2026-08-16

## Status

Proposed

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

## Consequences

- RPG2003 battles become progressively implementable without disturbing the
  already-working RPG2000 battle: Phases 1–2 are additive and gated on
  `battle_type` / row data that RPG2000 never writes.
- The 2003 boot path (Phase 3) is the only piece that makes the work
  end-to-end verifiable; until then Phases 1–2 are fixture-only.
- Row and timing are modelled as data on `Game::Battle::Combatant` so they are
  reusable by both the turn-based and gauge phase machines and by enemy AI.
- Follow-up work (battle-event pages already parsed; 2003-specific battle
  commands beyond the four this engine drives; the Special command handler)
  stays out of scope for these three phases and is tracked separately.
