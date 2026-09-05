- **RPG Maker MV/MZ "Encrypt Audio" is now honoured.** A project with it
  ticked never has a plain `audio/bgm/foo.ogg` on disk — only
  `audio/bgm/foo.ogg_` (MZ) or `foo.rpgmvo` (MV), obfuscated with a fixed
  16-byte header plus the file's own first 16 bytes XORed against
  `System.json`'s `encryptionKey`. The corescript's own `AudioManager` decrypts
  this itself over `fetch`, but this project's audio bridge
  (`mruby-mvjs/mrblib/mv.rb`'s `AUDIO_BRIDGE_JS`) intercepts `playBgm`/`playSe`
  *before* that and redirects to `RGSS::Audio` by plain filename instead — so
  every BGM/SE in an encrypted project logged "no BGM/SE found" even though the
  file was right there. Found against a real downloaded MZ release
  (EgoicAnswers, `hasEncryptedImages`/`hasEncryptedAudio`) whose every track
  missed this way. `RGSS::Audio` now has an `encryption_key` (set once at boot
  from `System.json`) and, when set, a loose-encrypted-file fallback
  alongside its existing packed-archive one — searched the same
  GAME_DIR/RTP_DIR × MUSIC_DIRS/SOUND_DIRS the plain disk search already uses,
  crossed with `.ogg_`/`.m4a_`/`.rpgmvo`/`.rpgmvm`, decrypted and handed to the
  existing `_bgm_play_mem`/`_se_play_mem` native entry points a packed archive
  already uses. A project with no encrypted audio (the common case, and every
  RPG2000/XP/VX/Ace bed) leaves `encryption_key` at its `nil` default — zero
  behaviour change.
