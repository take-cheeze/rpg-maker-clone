- **A Change Class or Change Battle Commands edit now survives a real .lsd
  Save/Continue.** Both used to silently revert to the database default the
  moment the exported save was read back, even though the level and stats
  earned under the new class stayed -- an actor changed to a different class
  mid-game would keep their new level/HP/MP but snap back to their old
  class's skills, growth curve and battle commands on Continue.
