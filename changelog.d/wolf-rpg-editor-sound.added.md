- **WOLF RPG Editor (ウディタ/Woditor)** `Sound`(140) now plays real sound
  effects: its "normal playback of an SE by filename" combination -- the
  one with a confirmed argument layout (volume and frequency/pitch each in
  their own slot, both proven varying from their 100/100 default in a real
  sample-game call) -- plays through `RGSS::Audio.se_play`, resolved the
  same `Data/`-relative way Picture(150)'s own files already are. Cross-
  confirmed byte by byte against the wolfrpg-map-parser crate's own
  `Options`/`SoundType` structs and every real `Sound` command in the
  sample game's own data (30 of them, decoded by hand). BGM/BGS playback, a
  system-database or variable sound source, and a filename that is itself
  one of WOLF's own string-interpolation escapes are logged and skipped
  rather than guessed. See `docs/adr/0071-wolf-rpg-editor-sound.md`.
