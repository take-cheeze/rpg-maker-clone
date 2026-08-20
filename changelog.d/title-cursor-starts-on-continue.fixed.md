- **Title screen:** The cursor now starts on Continue instead of New Game
  when a save exists, matching RPG_RT (`Scene_Title::Refresh`'s
  `command_window->SetIndex(1)`). Covered by two new
  `scripts/rpg2k_scene_check.rb` checks.
