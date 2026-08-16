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
  actor's menu opens on its own. The `GAUGE_MAX` / `GAUGE_AGI_RATE` fill curve
  remains ADR 0053's flagged-placeholder constants.
- The **battle combo** (Enable Combo / 1007) is spent: the scene records the
  chosen battle command onto the Combatant (`last_battle_action`), and
  `Game::Battle#combo_hits` multiplies the hits of an attack or skill command
  when an armed combo names that exact command — never a Defend/Item/Escape.
  The combo stays armed for the fight (no decrement), matching EasyRPG.
- A `command_actor`-gated battle page still never fires: the scene now records
  which command the battler chose (`Combatant#last_battle_action`), but the
  source-threading that lets the page test *the acting battler's* command at
  its action boundary — EasyRPG's `ScheduleNextPage(flags, source)` — is not
  wired, so `Game::Battle#actor_command` stays nil (never satisfiable, the
  same answer RPG_RT's RPG2000 scene gives).

## Consequences

- The gauge presentation's core timing — per-combatant, AGI-paced turns instead
  of rounds — is now playable, and a real 2003 gauge project (mtf-meido-action
  via `--rpg2k_battle_troop`) boots into it and runs stably.
- The existing round machine, the row mechanic and the traditional/alternative
  presentations are untouched: every override is gated on `battle_type == 2`,
  and the model addition is additive.
- Verification is fixture-driven: `rpg2k3_battle_gauge_check.rb` pins
  `begin_gauge_turn` (single-battler queue, gauge consumption, per-battler turn
  bump, silent no-op turn for a restricted battler) and `rpg2k_scene_check.rb`
  drives real gauge battles through the 2003 scene (menu-on-own, commit →
  action → idle, ready enemy auto-fires, restricted member's silent turn, and a
  battle_type 0 fight never entering the gauge loop). The combo's model math is
  pinned by `rpg2k_logic_check.rb` (armed Attack combos to its full count,
  wrong-command and Item combos never apply, a combo'd skill repeats with SP
  spent once, all-target too) and the command-id recording by the scene checks.
  The native boot check keeps the real 2003 battle green.
- Follow-ups: Wait-off (active) mode and the database wait toggle; the
  source-threading that makes `command_actor` pages satisfiable; the Special
  command handler;
  the attacker-side back-row reach penalty; the exact RPG_RT 2003 fill curve.
