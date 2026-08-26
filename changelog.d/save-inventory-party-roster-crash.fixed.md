- `Game::State#to_lsd` no longer writes a save file that crashes a genuine
  `RPG_RT.exe` on load. `SAVE_INVENTORY` (chunk 109) field 1 was modelled as a
  self-contained `int8_array` holding the party roster directly, and `#to_lsd`
  wrote the roster there and nothing else — but liblcf's own
  `generator/csv/fields.csv` documents field 1 as the roster
  `Vector<Int16>`'s *count* and field 2 as its *data*, the identical
  count-then-data split `item_count`/`item_ids` (fields 11/12) already use.
  A save missing field 2 that a genuine RPG_RT.exe itself always writes
  crashes the real engine outright on load with a null-pointer read
  (confirmed live under wine), regardless of what field 1's count says. A
  solo party's field 1 byte happens to read identically under either
  schema (count 1 and "array `[1]`" are the same one byte), which is
  exactly why every prior real-game save this engine has loaded never
  exposed it; a multi-actor party (kk1.12, a real RPG2003 game) does not
  share that coincidence. This also resolves a crash a prior session's own
  investigation had already run into and worked around without diagnosing
  (see the "Methodology note" in `Actor#use_skill_book`'s comment,
  `mruby-rpg2k/mrblib/game.rb`). Covered by a new fixture check in
  `rpg2k_logic_check.rb`.
