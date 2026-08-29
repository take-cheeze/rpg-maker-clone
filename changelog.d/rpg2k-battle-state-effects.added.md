- RPG Maker 2000: **afflicted battlers now act on their status conditions each
  turn** in battle. `Game::Battle` accepts the database `situation` (state) table,
  and at the start of a battler's turn `apply_turn_states` applies each afflicting
  state's per-turn effect: **slip damage** — HP (and SP) loss of `hp_change_val +
  max * hp_change_max / 100`, grounded on a reference implementation's
  condition-application logic, not independently confirmed against genuine
  RPG_RT under wine — which can
  knock the battler out, and a **"do nothing" restriction** (`restriction == 1`,
  asleep / paralysed) that **skips its turn**. `Scene::Map` passes `db.situation`,
  so real poison / sleep states take effect; a battle built without a state table
  (the 3-argument form) stays inert, so existing call sites are unchanged.
  Covered by new `scripts/rpg2k_logic_check.rb` checks (fixed + percent slip, a
  poison KO, an SP slip, a restriction skipping a commanded attack, and the inert
  no-lookup case). State **auto-recovery** (`hold_turn` / `auto_release_prob`),
  forced-attack restrictions, and in-battle state **infliction** (rolling
  `state_chance`) remain follow-ups.
