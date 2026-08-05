- **The title screen plays its music.** RPG2000's System database carries a
  title BGM (`title_music`, field 31), and `mruby-lcf` had been decoding it all
  along — but `Scene::Title` only ever played the cursor SE, so the title screen
  was silent where RPG_RT has music. It now starts the title BGM when the scene
  comes up, and restarts it on Return to Title, as RPG_RT does. The record's
  `fade_in` is not honoured: the audio backend can fade a BGM out but not in
  (ADR 0006), so the music starts at full volume.
- Audio that resolves to nothing now says so once, instead of playing silence.
  A name that matches no file under `GAME_DIR`/`RTP_DIR` (across every known
  extension) and no entry in an encrypted archive was a silent no-op, which is
  indistinguishable from a broken decoder — it sent the diagnosis of a missing
  title BGM in entirely the wrong direction.
- `scripts/rpg2k_boot_check.bash` now fails if the title BGM raises on real
  RPG2000 data. The playback is rescued, so a database-schema mismatch would
  otherwise degrade to silence rather than to a failing boot.
