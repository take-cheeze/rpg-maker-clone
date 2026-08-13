- **The field Equip menu's candidate list now shows an Up/Down/Same
  comparison indicator** against whatever the slot currently holds — RPG_RT
  computes it from the *sum* of all four combat-stat equip-bonus fields
  (`atk_points1`/`def_points1`/`spi_points1`/`agi_points1`), not a per-stat
  verdict, so a candidate trading `-2` Atk for `+3` Def still draws a single
  Up arrow rather than a mixed readout. `Scene::EquipMenu#build_cand_window`
  draws it as a third column (`^`/`v`/`-`) between the item name and its bag
  count; RPG_RT itself draws small triangle icons here, which this build has
  no icon-cell blit for yet, so a plain glyph stands in. Covered by a new
  `scripts/rpg2k_scene_check.rb` check (a strictly-better, strictly-worse and
  exactly-equal candidate against a fixed worn item), confirmed to fail
  against the pre-fix code before the fix.
