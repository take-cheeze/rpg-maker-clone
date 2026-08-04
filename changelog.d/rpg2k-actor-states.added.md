- RPG Maker 2000: actor **status conditions (状態)** are now modelled and saved.
  `Game::Actor` carries a state-id set (`states`, with `add_state` / `remove_state`
  / `state?`), and **Full Recovery** clears it. The set persists both ways: the
  portable Marshal save round-trips it, and `Game::State#to_lsd` now writes chunk
  108's per-actor state fields (81 `state_size` / 82 `states`) — previously parsed
  but never populated — with `from_lsd` restoring them, so an actor's ailments in
  a real `Save<N>.lsd` survive Continue instead of being dropped. The Conditional
  Branch **actor "afflicted by state"** sub-condition (type 5, sub 6) is wired up,
  where it used to always read false. Covered by new `scripts/rpg2k_logic_check.rb`
  checks (the state model, the conditional, and a Marshal round-trip) and by
  `scripts/rpg2k_save_load_check.rb` (the `.lsd` `to_lsd -> from_lsd` round-trip
  now asserts states survive, against the real Nepheshel / mtf-meido saves).
  Inflicting states from battle / items / skills (the item `state_set` /
  `reverse_state_effect` fields) remains a follow-up.
