- `Game::State#to_lsd` now writes chunk 108 (SAVE_PARTY_ACTOR) fields 92-95
  (`two_weapon`/`lock_equipment`/`auto_battle`/`super_guard`, liblcf's own
  generator/csv/fields.csv names, right after field 91's own row) as a live
  mirror of `Game::Actor#double_hand?`/`#equipment_fixed?`/`#force_ai?`/
  `#strong_defence?`. Confirmed against a genuine kk1.12 save under wine:
  several roster slots carried one or more of these fields, each present
  only when the underlying actor/class trait was actually on — `#to_lsd`
  never wrote any of the four before. `.from_lsd` has nothing new to
  restore: this engine already derives all four live from the actor's own
  class/database row, so they're written for byte parity only.
