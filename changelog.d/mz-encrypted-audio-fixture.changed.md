- CI: `data/mz-sample`'s authored sound effect is now `audio/se/Beep.ogg`
  rather than `audio/se/Beep.wav` (bytes unchanged — still a hand-encoded WAV
  body, see `scripts/gen-mz-sample.py`'s `write_wav`), so
  `scripts/mz_encrypted_check.bash`'s derived encrypted project actually
  exercises the MV/MZ audio-decrypt path (PR #1500) end to end.
  `scripts/gen-mz-encrypted.py`'s `MZ_EXT` only sweeps `.png`/`.ogg`/`.m4a`
  into the encrypted copy it derives — real MZ ships no `.wav` either
  (`AudioManager.audioFileExt` in the fetched corescript always returns
  `.ogg`: `data/mz-sample/js/rmmz_managers.js:1418-1420`) — so the bed's only
  audio fixture being a `.wav` meant the derived project had zero encrypted
  audio bytes, and `mz_encrypted_check.bash`'s `--mz_audio_test` probe never
  once dispatched through `RGSS::Audio`'s `find_encrypted_loose`/
  `decrypt_mv_asset`. It still played, silently proving nothing: the plain
  `Beep.wav` sitting next to the encrypted image assets resolved through the
  ordinary disk search before the encrypted-loose fallback was ever reached.
  Renaming the fixture (not its bytes) makes `gen-mz-encrypted.py` fold it
  into `Beep.ogg_` in the derived project like any other audio asset, and the
  existing `play`-mode probe now decrypts and plays it for real — no new
  fixture, no new probe, no new dependency. SDL_mixer's `Mix_LoadWAV_RW`
  (`src/sdl_audio.cxx`) auto-detects the codec by sniffing the RIFF magic in
  the decrypted byte stream itself rather than trusting the (fake) `.ogg`
  name, which is why a plain WAV body still plays back correctly — genuinely
  decodable audio, not a placeholder blob, with no Ogg Vorbis encoder needed
  (none is present in `flake.nix`'s devShell: checked for `ffmpeg`/`oggenc`/
  `vorbis-tools`/`sox`, only the SDL2_mixer *library*, which decodes rather
  than encodes, is listed). `data/mv-sample` is untouched: it has its own,
  separate `scripts/gen-mv-sample.py`/`write_wav`/`Beep.wav`, and no script
  ever runs `gen-mz-encrypted.py --mv` against it.
