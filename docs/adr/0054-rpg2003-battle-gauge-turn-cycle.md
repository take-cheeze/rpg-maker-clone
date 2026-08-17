# 54. RPG2003 gauge battle — the active-time turn cycle

Date: 2026-08-16

## Status

Accepted

## Context

ADR 0053 scoped the RPG2003 battle work in three phases and landed them: the
row mechanic (Phase 1), the per-combatant gauge model — `advance_gauges` /
`ready_combatants` / `pop_ready` / `reset_gauge` on `Game::Battle` (Phase 2) —
and the boot path that drives a real 2003 project into the battle scene (Phase
3). The scene integration that routes 2003 fights to `RPG2k3::Scene::Battle`
(Phase 2's final slice) advanced every combatant's gauge every frame, but the
**turn picker was never wired**: the battle still decided *whose turn it is*
with the 2000 sequential round machine (`begin_round` / `step_action` /
`end_round` over an agility-ordered queue), so a gauge battle charged gauges
that nothing consumed. The remaining piece, called out as "the next step (ADR
0054)" in `battle_rpg2k3.rb`, is the active-time turn cycle itself.

RPG_RT 2003's gauge presentation (EasyRPG's `Scene_Battle_Rpg2k3`) replaces
"whose turn is it" with "whose gauge is full": every combatant's gauge fills
every frame at a rate proportional to its AGI; the instant one is full it
acts — a controllable party member opens the command menu, everyone else
(enemy AI included) fires automatically — and acting resets the gauge so it
must refill. Turns are thus per-combatant and continuous rather than
all-combatants-per-round.

## Decision

Drive the gauge battle's turns from gauge readiness in `RPG2k3::Scene::Battle`,
on top of the unchanged action-resolution machinery:

- **A new idle phase `:atb`** is the gauge battle's "whose turn" loop.
  `drive_battle_atb` runs the troop battle-event page check, settles a decided
  fight, then polls `Game::Battle#ready_combatants` (the full-gauge
  combatants, highest gauge first). A living, in-play party member free to be
  handed a manual command — `controllable?`: an ally, not
  `command_restricted?`, not Forced-AI — opens the command menu with its gauge
  held full; anyone else's ready gauge fires its action automatically.
- **`Game::Battle#begin_gauge_turn(b)`** is the model-side counterpart to
  `begin_round`: it queues `b` as the sole battler of the coming action, resets
  its gauge, locks in its round-level do-nothing restriction, and bumps its
  per-battler turn counter (the RPG2003 `turn_enemy`/`turn_actor` page
  condition count). It deliberately does **not** touch `@rounds` — a gauge
  battle has no RPG2000-style rounds, so the global turn number stays 0 and the
  pages read per-battler counters. From there the existing `step_action` /
  `strike` / `@pending` machinery runs the action unchanged.
- **The round-flow method overrides are all gated on `battle_type == 2`**
  (`gauge_battle?`): `enter_command_phase` and `open_battle_options` route to
  the idle loop instead of the once-per-fight Fight/Auto/Escape window,
  `prev_commandable_actor_index` returns nil (canceling a ready actor's menu
  returns it to the idle loop, its gauge still full), `advance_actor` starts
  the committing actor's action instead of the next actor's menu, and
  `finish_round_animation` returns to the idle loop instead of opening the next
  round. The traditional (0) and alternative (1) presentations inherit the
  untouched 2000 machine.
- **`update`** advances the gauges and dispatches the phases itself for a gauge
  battle (adding the `:atb` case); everything else delegates to `super`.

Behavioral notes and deliberate simplifications:

- The command menu **pauses the fight** while it is open — RPG2003's Wait-mode
  behaviour — so other ready combatants queue behind the committing actor
  rather than acting mid-deliberation. The active-during-menu (Wait-off)
  presentation, and the database's wait toggle itself (a Battle Commands field
  the schema does not decode yet), are follow-ups.
- A gauge battle shows **no Fight/Auto/Escape options window**: the first ready
  actor's menu opens on its own. The gauge fill runs on EasyRPG's real RPG_RT
  2003 curve — `GAUGE_MAX` 300000, per-frame increment
  `GAUGE_MAX / (sum_agi / (agi + 1))` over every non-hidden battler's AGI, so
  the field charges together and a do-nothing-restricted ally never charges —
  replacing the earlier placeholder constants.
- The **battle combo** (Enable Combo / 1007) is spent: the scene records the
  chosen battle command onto the Combatant (`last_battle_action`), and
  `Game::Battle#combo_hits` multiplies the hits of an attack or skill command
  when an armed combo names that exact command — never a Defend/Item/Escape.
  The combo stays armed for the fight (no decrement), matching EasyRPG.
- A `command_actor`-gated battle page now fires: the battle tracks the acting
  battler (`Combatant#acting_battler`, set as each turn resolves), the
  boundary page check passes it as the per-battler `source` the way EasyRPG's
  `ScheduleNextPage(flags, source)` does, and `Game::Battle#actor_command`
  answers that battler's recorded command (`Combatant#last_battle_action`) —
  so the condition tests the acting battler's choice, and only its own. The
  same source also gates the `turn_enemy`/`turn_actor` conditions (`source !=
  enemy/actor` fails the page), so a per-battler check never fires off a
  *different* battler's counter. A no-source round-boundary check leaves
  those ungated (turn_* read the named battler's counter, command_actor
  fails), matching EasyRPG's RPG2000 scene.

## Consequences

- The gauge presentation's core timing — per-combatant, AGI-paced turns instead
  of rounds — is now playable, and a real 2003 gauge project (mtf-meido-action
  via `--rpg2k_battle_troop`) boots into it and runs stably.
- The existing round machine, the row mechanic and the traditional/alternative
  presentations are untouched: every override is gated on `battle_type == 2`,
  and the model addition is additive.
- Verification is fixture-driven: `rpg2k3_battle_gauge_check.rb` pins
  `begin_gauge_turn` (single-battler queue, gauge consumption, per-battler turn
  bump, silent no-op turn for a restricted battler) and the real fill curve
  (exact increments, faster-fills-first, full-and-stays, a dead or
  do-nothing-restricted ally never charging) and `rpg2k_scene_check.rb`
  drives real gauge battles through the 2003 scene (menu-on-own, commit →
  action → idle, ready enemy auto-fires, restricted member's silent turn, a
  battle_type 0 fight never entering the gauge loop, and a `command_actor`
  troop page firing at the acting battler's turn). The combo's model math and
  the per-battler page-condition gating (command_actor satisfiable only for
  the acting battler who chose the command; turn_enemy/turn_actor gated on
  the source) are pinned by `rpg2k_logic_check.rb`, and the command-id
  recording by the scene checks.
  The native boot check keeps the real 2003 battle green.
- The **automatic battler placement** (`battlecommands.placement == 1`) is
  implemented: each party member's battle sprite sits on the grid slot from
  EasyRPG's `CalculateBaseGridPosition` / `Calculate2k3BattlePosition`
  (src/game_battle.cpp), keyed by party index/size and the encounter terrain's
  grid fields (terrain chunks 46-48), replacing the manual battle_x/battle_y —
  ported with the reference's own grid table 0 and its no-terrain defaults
  (112 / 392 / 16000). Only the ordinary front-row actor path is done (the
  back-row `row_x_offset` and the pincer/surround enemy tables need the row
  derivation and battle conditions this runtime does not model); `mtf-
  meido-action` uses placement 1, so its real gauge battle exercises it.
- Follow-ups: Wait-off (active) mode and the database wait toggle; the
  Special command handler. The attacker-side row adjustment (a front-row actor
  dealing +25% damage and the flat-25 back-row defender hit penalty) landed
  with ADR 0053 Phase 1's reference-aligned row model (2026-08-17).
