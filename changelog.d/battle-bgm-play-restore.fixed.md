- **Entering a fight now plays the database's battle BGM, and leaving one
  resumes whatever was playing before.** Both the Enemy Encounter event
  command and a wandering-monster random encounter route through the same
  `Scene::Map#open_battle`, which never touched the music at all — a fight
  was silent (or just kept the field track looping) despite `db.system
  .battle_music` being configured, and `Change System BGM`'s own note in
  `docs/TODO.md` had flagged "the battle scene's use of a system BGM slot"
  as simply not built. New `Scene::Map#play_battle_bgm` / `#restore_pre_
  battle_bgm` mirror the memorize/restore idiom `#play_vehicle_bgm` /
  `#restore_pre_vehicle_bgm` already use for boarding a boat/ship/airship:
  `#open_battle` remembers `@state.current_bgm` and plays `battle_music`
  (name/volume/pitch via the same `music_name`/`music_volume`/`music_tempo`
  helpers vehicle and title BGM already use) when one is configured, and
  `#finish_battle` calls the restore once the fight is over — but only on a
  victory, an allowed escape, or a defeat with a custom `[Defeat]` handler;
  a game-over defeat skips it, since `Scene::GameOver` plays its own
  `gameover_music` and the map is never shown again. A game with no
  `battle_music` set leaves whatever was already playing alone, matching
  RPG_RT's own no-op on a blank Music struct. Left unaddressed: the victory
  jingle (`battle_end_music`) and the exact RPG_RT timing of when the field
  BGM resumes relative to it — that would need the "play a fixed jingle,
  then resume" sequencing this build's `RGSS::Audio` has no primitive for,
  so the field track simply resumes immediately once the result window is
  dismissed rather than after a fanfare. Covered by a new
  `scripts/rpg2k_scene_check.rb` check (an Enemy Encounter plays the
  configured battle BGM at its own vol/tempo the moment the battle UI opens,
  and the field BGM that was playing before replays once the fight is won),
  confirmed to fail against the pre-fix code before the fix.
