- RPG Maker 2000: **battle status conditions now wear off on their own**. Each
  `Game::Battle::Combatant` keeps a per-state turn counter; at the start of a
  battler's turn `apply_turn_states` first rolls each afflicting state for
  auto-recovery — once the counter has passed the state's `hold_turn`, an
  `auto_release_prob`% roll (0 = never) cures it — before applying that turn's
  slip damage / restriction to whatever remains. So a temporary poison or sleep
  fades after a few turns instead of lasting the whole fight, while a permanent
  ailment (0% release) stays. Grounded on a reference implementation's
  state-recovery logic, not independently confirmed against genuine RPG_RT
  under wine. Covered by
  new `scripts/rpg2k_logic_check.rb` checks (a state cures only after it has held
  past `hold_turn`, and a 0%-release state never wears off on its own). Enemy-cast
  infliction and forced-attack restrictions remain follow-ups.
