- **Change EXP** (10410) and **Change Level** (10420) event commands are now
  handled. `Game::Actor` gains an RPG2000 experience curve — `exp_for_level`
  computes it from the actor row's exp_basic / exp_increase / exp_correction
  fields (ported from a reference implementation, not independently confirmed
  against genuine RPG_RT under wine) — plus `gain_exp` / `change_level_by`, which re-derive the level
  from the EXP thresholds (or the reverse), recompute the base stats from the
  level's growth curve via `set_level`, and keep EXP and level consistent
  (current HP/MP are not refilled on level up, matching RPG_RT); EXP caps at
  999999. Both commands target a fixed actor, a variable-selected actor or the
  whole party. Actor EXP is now persisted in the save (the level is re-derived on
  load) and is readable via **Control Variables** (actor-stat operand,
  attribute 1). Covered by new checks in `scripts/rpg2k_logic_check.rb`.
