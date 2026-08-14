- **A battle/vehicle/inn BGM matching the file already playing no longer
  breaks and restarts it, and neither does restoring a pre-transition track
  afterward.** `Game::Interpreter#play_audio` already skips a same-file
  `RGSS::Audio.bgm_play` for the Play BGM event command, but `Scene::Map`'s
  own BGM-switching helpers (`#play_battle_bgm`/`#restore_pre_battle_bgm`,
  `#play_vehicle_bgm`/`#restore_pre_vehicle_bgm`, `#play_victory_bgm`,
  `#play_inn_bgm`/`#restore_pre_inn_bgm`) each called `RGSS::Audio.bgm_play`
  unconditionally, independent of that check — so a battle BGM configured to
  the same file as the field track wrongly restarted it on entry, and
  restoring the field track after the fight restarted it a second time, even
  though this scene never actually stopped it. Verified against EasyRPG
  Player's own `Game_System::BgmPlay` (`src/game_system.cpp`), the single
  native entry point every one of these transitions funnels through in the
  real engine, including battle entry (`Scene_Battle::Init`,
  `src/scene_battle.cpp`). Fixed by extracting a shared
  `Scene::Map#play_bgm(music)` using the same same-file idiom
  `Game::Interpreter#play_audio` already has, and routing all seven call
  sites through it. Covered by a new `scripts/rpg2k_scene_check.rb` check,
  confirmed to fail against the pre-fix code before the fix.
