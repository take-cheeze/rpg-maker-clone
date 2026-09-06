- **RPG2000 field menu** (`Scene::Menu`) re-measured against genuine
  `RPG_RT.exe` under wine (cycle #240): the party-status panel now draws
  three lines per member in RPG_RT's own columns (name; `LV`/level/condition
  and `HP cur/max`; `EX cur/next` and `MP cur/max`, with the current EXP and
  the next level's threshold right-aligned in 6-cell fields and six dashes
  each at the maximum level), with the `LV`/`EX`/`HP`/`MP` labels in the
  windowskin's system colour (index 1) and the shadow+gradient text every
  other window uses; the Gold window right-aligns the amount and its unit
  term (unit in system colour); the actor-selection cursor frames the text
  column to the panel's right edge while the command cursor stays drawn;
  and the End Game prompt hides the command list, party panel and Gold
  behind it, placing its help window at y 72 and the Yes/No window 16px
  below it. Covered by new `scripts/rpg2k_scene_check.rb` checks.
