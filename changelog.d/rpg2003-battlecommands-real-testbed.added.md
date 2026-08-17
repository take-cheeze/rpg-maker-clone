- The RPG2003 battle-command schema is now **validated against a real 2003
  database the way the rest of the 2003-specific table is**, closing the ADR 0048
  follow-up: `scripts/lcf_testbed_check.rb` gains a `check_battlecommands` pass
  (alongside its existing chunk-30 Classes check) that proves a 2003 database's
  database-wide Battle Commands list (chunk 29) is present with a non-empty
  `commands` table, that every positive reference in each actor's and class's
  own `battle_commands` list names one of those commands, and that an RPG2000
  database never carries the list at all (its editor has no such tab). Verified
  against mtf-meido-action (12 commands covering every type value 0–6, with all
  of its 12 actors' and 18 classes' positive references resolving) alongside the
  RPG2000 Nepheshel data.
