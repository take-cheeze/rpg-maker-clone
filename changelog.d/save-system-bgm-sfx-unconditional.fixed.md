- `Game::State#to_lsd` now writes chunk 101 (SAVE_SYSTEM)'s BGM/SE override
  slots unconditionally, matching a genuine kk1.12 save under wine: every
  one of `title_music`(71)/`battle_music`(72)/`battle_end_music`(73)/
  `inn_music`(74)/`boat_music`(79)/`ship_music`(80)/`airship_music`(81)/
  `gameover_music`(82) and `cursor_se`(91)..`item_se`(102) is present,
  blank-named, even on a save that never touched Change System BGM/SFX at
  all — `#to_lsd` previously omitted every one of these fields entirely in
  that case. `#bgm_chunk`/`#se_chunk` also now elide their own
  volume/pitch/balance fields at each one's schema default (100/100/50)
  instead of always writing them, matching the same genuine save's own
  blank BGM/SE records exactly.
- Field 1 (`scene`) is now written as the constant `5`, matching a legacy
  field genuine RPG_RT always sets this way for any save file (EasyRPG
  Player itself never reads it back). Field 23 (`font_id`, née `font`) is
  now elided at its own default (0) instead of always written. Field 31
  (switch count) is now elided when no switch has ever been touched, while
  field 32 (the switch data array) is still written even then — an
  asymmetric elision confirmed against the same genuine save.
