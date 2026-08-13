- **Enemy Encounter battles now honour a Change System BGM override for the
  battle slot.** `Scene::Map#play_battle_bgm` used to always play the
  database's own System `battle_music`, ignoring a Change System BGM (10660)
  override the event system already stashed on `Game::State#system_bgm` (slot
  0 is battle). A new `#battle_bgm` resolves the override first and falls
  back to the database default, the same override-then-default idiom Change
  System SFX already gets from `#system_se`. Covered by a new
  `scripts/rpg2k_scene_check.rb` check, confirmed to fail against the pre-fix
  code before the fix.
