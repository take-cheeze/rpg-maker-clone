- **A state's per-turn battle slip damage can no longer knock a battler out
  by itself, and `hp_change_type`/`sp_change_type` (RPG2003 fields 45/46) are
  now honoured on both the map and battle slip paths.** Ported from a
  reference implementation, not independently confirmed against genuine
  RPG_RT under wine: its slip-damage application floors at 1 HP regardless
  of the computed slip — the same non-lethal rule
  this codebase's map-side field-poison drain already followed, but
  `Game::Battle#apply_turn_states` never did, so a large enough
  `hp_change_max` (a boss's own poison-percent-of-max attack, say) could end
  a battler's turn in death from status alone. Both that battle-side logic
  and its map-step counterpart also branch on a state's own
  lose/gain/nothing change-type,
  which neither `Game::Battle#apply_turn_states` nor `Game::States.drain`
  (the map-step helper) read at all — every state was treated as an
  unconditional loss. Fixed with a new `Game::States::CHANGE_TYPE_LOSE`/
  `GAIN`/`NOTHING` trio, a shared `Battle#slip_stat` (floor 1 for HP, 0 for
  SP) that `apply_turn_states` now routes through instead of a bare `-=`, and
  a signed `Game::States.drain` that `Party#apply_map_step_damage` sums and
  applies through the existing `change_hp`/`change_mp` calls. Every existing
  loss-only state (every state in both shipped test beds, since the field is
  a 2003 addition neither database sets) is unaffected beyond the corrected
  HP floor. Covered by new `scripts/rpg2k_logic_check.rb` checks, including
  one confirmed to fail against the pre-fix code (`expected 1, got 0`) before
  the fix.
