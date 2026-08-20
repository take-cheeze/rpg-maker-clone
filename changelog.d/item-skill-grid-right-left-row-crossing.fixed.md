- **Item/Skill lists:** Right/Left now flow across a row boundary in the
  two-column grid instead of stopping at the row's own edge, matching
  RPG_RT -- Right off a row's last cell moves onto the next row's first
  cell (and Left the mirror), rather than doing nothing. Covered by two
  new `scripts/rpg2k_scene_check.rb` checks.
