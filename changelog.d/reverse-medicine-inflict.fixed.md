- **RPG2000 medicines with `reverse_state_effect` set now inflict their
  listed states instead of doing nothing.** `Game::Party#item_cured_states`
  only ever handled the cure polarity (the flag unset); the inflict polarity
  was read backwards at first and then left unbuilt when that got fixed,
  even though the identical mechanism was already built and tested on the
  field-skill side (`#skill_inflicted_states`/`#cast_skill`, mirroring the
  same EasyRPG `reverse_state_effect` branch). `#item_inflicted_states` now
  mirrors `#item_cured_states` the same way, `#use_medicine` applies it
  (with RPG_RT's state-crowding-out prune on a landed state, matching
  `#cast_skill`), and `#item_effective?` offers such an item when the target
  lacks a state it would inflict. Covered by new
  `scripts/rpg2k_logic_check.rb` checks, confirmed to fail against the
  pre-fix code before the fix.
