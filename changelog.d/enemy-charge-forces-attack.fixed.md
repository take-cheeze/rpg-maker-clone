- **Battle:** a charged enemy still runs its ordinary AI pattern instead of
  being forced into a plain Attack, confirmed against a genuine RPG_RT.exe
  under wine: a charged enemy whose only pattern action was Defend showed
  a Defend message, not a forced attack. A prior revision of this fragment
  claimed the opposite (a charged enemy is "guaranteed a single doubled
  Attack... skips pattern selection outright"), based on reading a
  reference implementation's source as forcing the attack unconditionally;
  that reading was not itself checked against genuine RPG_RT, and this
  cycle's wine capture contradicts it. `Game::Battle#strike` now runs
  `#choose_enemy_action` unconditionally regardless of charge, and only
  substitutes the forced-single-swing fallback when the *drawn* action is
  itself a plain Attack or Dual Attack — matching a second wine capture
  showing a charged Dual Attack pattern pick still capped at one swing.
  Covered by rewriting the existing `scripts/rpg2k_logic_check.rb` check in
  place.
