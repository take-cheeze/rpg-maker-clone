- `scripts/rpg2k3_battle_command_check.rb` no longer treats an absent
  `battlecommands` chunk field 9/24 as a decode failure. It read the two
  fields by poking the `Array1D`'s raw `@data` bytes directly (to stay
  independent of whatever name `schema.rb` gives them), which assumed the
  chunk is always physically written — true of mtf-meido-action, the only
  2003 bed this check had ever run against, but not a general LCF guarantee:
  a field matching its schema default (0 for both) can be omitted from the
  file like any other chunk, and a second real 2003 game (kk1.12) does
  exactly that for field 24. It now reads both through `bc[fid]` — the same
  defaulting path every other field in this file already goes through — and
  only requires the *decoded* value to be an Integer, `bc.key?(fid)` noted
  alongside it for whether the chunk was actually on disk.
