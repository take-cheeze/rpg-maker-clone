- **Change System Graphics (10680).** The event command that swaps the system
  windowskin (and font) is now handled. `Game::State` records the override — the
  windowskin graphic name from the command string and the font id — and it wins
  over the database default and persists in the save (portable `to_h` / `load`
  and the LSD `SAVE_SYSTEM` chunks 15 / 17). `Scene::Map` reloads the windowskin
  when the override changes (via a one-shot request, like Change Actor Graphic),
  so windows opened afterwards — messages, menus, battle — draw with the new
  skin; windows already on screen keep theirs until recreated. The message
  background stretch style (the command's other parameter) is not in the save and
  is not modelled. Covered by new checks in `scripts/rpg2k_logic_check.rb` (the
  command records the override and font, raises the one-shot reload request, and
  round-trips through the save) and `scripts/rpg2k_scene_check.rb` (the scene
  reloads the windowskin from the override).
