- **Show Inn** (RPG Maker 2000, command 10730) now plays the inn's own BGM.
  `Scene::Map#drive_inn` never touched the music at all — staying at an inn
  played in total silence, or just let the field track keep looping — no
  matter what the database's System `inn_music` named. New
  `Scene::Map#play_inn_bgm` / `#restore_pre_inn_bgm` mirror the memorize/
  restore idiom `#play_battle_bgm` / `#play_vehicle_bgm` already use: the inn
  BGM (a Change System BGM slot-2 override, else the database default) starts
  the moment the Show Inn request is seen — prompted or free (price 0) alike
  — and the prior track resumes once the stay is resolved. Covered by new
  `scripts/rpg2k_scene_check.rb` checks, confirmed to fail against the
  pre-fix code before the fix.
