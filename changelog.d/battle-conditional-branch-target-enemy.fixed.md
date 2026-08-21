- **Events:** the RPG2003 battle-event Conditional Branch's "troop member
  is the current target" test (13310, test type 4) is now implemented,
  matching RPG_RT's `target_enemy_index`/`targets_single_enemy` -- it
  previously always took the else branch regardless of actual battle
  state.
