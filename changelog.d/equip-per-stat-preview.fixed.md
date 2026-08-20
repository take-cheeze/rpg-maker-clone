- **Equip screen:** The candidate item list no longer draws a summed
  Up/Same/Down arrow (it never existed in RPG_RT). The status panel above it
  now previews each of the four battle stats independently while browsing
  candidates -- `Atk 20 -> 25`, colour-coded from the windowskin's own
  swatches -- matching RPG_RT's `Window_EquipStatus::DrawParameter`. A
  candidate trading Atk for Def now visibly shows both movements at once.
  Covered by new `scripts/rpg2k_scene_check.rb` checks.
