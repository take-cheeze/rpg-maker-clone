- **RPG2000 battle:** The party status panel's HP/SP text no longer overlaps
  or bleeds off the panel for a well-stocked party member — an ally's name,
  condition, HP or SP text drew unclipped past its own column (`Bitmap
  #draw_text`/`#blend_text` only use their `w`/`h` for centre/right alignment,
  never to clip), so a wide HP value ran into the SP column and SP's own text
  routinely ran off the panel's 26px-wide column entirely. `#battle_status_
  window` now clips every segment to the gap before its own neighbour (or the
  panel's inner edge, for SP) via the shared `#clip_text_to_width` helper —
  previously local to the message window's own face-graphic clipping, now
  moved onto `Scene::Base` so both share it. Covered by a new
  `scripts/rpg2k_scene_check.rb` check.
