- RPG Maker **XP**: the **Change Actor** event commands now mutate the per-actor
  model (`RPGXP::Game::Actor`). Implemented: **Change HP** (311, honouring the
  "allow knockout" floor of 0 vs 1), **Change SP** (312), **Recover All** (314),
  **Change Level** (316 — which learns any newly-reached class skills and regrows
  the level-derived stats), **Change Skills** (318, learn / forget) and **Change
  Equipment** (319, the weapon and four armor slots, an id of 0 emptying a slot).
  Each resolves its target through RMXP's `iterate_actor` (a fixed actor id, or
  one held in a variable) and the value commands through `operate_value`
  (increase / decrease, constant or variable operand), matching RGSS's
  Interpreter. The mutated per-actor state (level, HP/SP, skills, equipment) now
  round-trips through the Marshal save. Covered by new `mruby-rpgxp/test` cases
  for each command plus the save round-trip; the `rpgxp_testbed_check` /
  `rpgxp_script_host_check` harnesses stay green. Change EXP (315), the exp-curve
  alignment of Change Level, and Change Parameters (317) — which need the RMXP EXP
  curve and per-actor stat deltas — are the remaining follow-ups.
