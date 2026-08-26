- `Game::State#to_lsd` now writes chunk 108 fields 33/34 (hp_mod/sp_mod) and
  80 (battle_commands) unconditionally, matching a genuine kk1.12 save under
  wine: every actor's own untouched hp_mod/sp_mod is present as an explicit
  `0` (distinct from liblcf's declared `-1` "never touched" default), and
  field 80 is present with liblcf's own literal `[-1]*7` sentinel default
  even when no Change Battle Commands ever ran (field 83,
  `changed_battle_commands`, stays absent alongside it, gated on
  `Actor#battle_commands_changed?` as before). Fields 41-44
  (attack/defense/spirit/agility mod) keep the opposite "omit at zero"
  convention the same save confirms, unchanged.
