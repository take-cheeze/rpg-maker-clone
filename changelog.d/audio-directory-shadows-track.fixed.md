- A BGM/ME/BGS/SE whose name matches one of the game's own asset **folders** now
  plays instead of failing to load. `RGSS::Audio`'s disk search probed each
  candidate with `File.exist?`, which is also true for a directory — and because
  `EXT_SPELLINGS` leads with the empty extension and `MUSIC_DIRS`/`SOUND_DIRS`
  with the empty folder, the very first candidate for a track called `title` is
  the bare `#{GAME_DIR}/title`, right where a released game keeps `Title/`,
  `Battle/`, `Movie/` and friends. Nepheshel ships its title-screen graphics in
  `Title/` beside its title theme in `Music/title.mid`; on a case-insensitive
  filesystem (macOS, Windows) the folder matched first, the search stopped on it,
  and `Mix_LoadMUS` was handed a directory — `Audio: failed to load music
  '.../title'` for a MIDI sitting right there, so the title screen was silent.
  The search now requires a regular file (`File.file?`), in both the plain and
  the NFD spelling, and keeps looking past a directory. Covered by a new
  `mruby-rgss` test.
