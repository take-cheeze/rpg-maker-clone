- **RPG2000/2003 save files:** Losing the last copy of an item (selling it,
  a Take Item event draining the last one) no longer leaves a phantom
  zero-count entry behind in the party's bag — it's erased outright, matching
  RPG_RT's own `Game_Party::AddItem`. Previously invisible in ordinary play,
  but the leaked zero-count id was written into the save file's inventory
  chunk and read back on every subsequent Continue, accumulating one row per
  item ever fully depleted for the life of a save. Covered by a new
  `scripts/rpg2k_logic_check.rb` check.
