- **`RGSSAD` (the RPG Maker XP/VX/VX Ace encrypted-archive reader) no longer
  loads the whole archive into memory to open it.** `mruby-rpgxp/mrblib/rgssad.rb`'s
  `.open(path)` used to `File.read` the entire `Game.rgssad`/`.rgss2a`/`.rgss3a`
  up front; on the PSP that single `String` came out of the interpreter's
  fixed 12 MB arena, so any released game's archive at or beyond that size —
  routine for a real XP/VX release, which can pack tens of MB — couldn't even
  be opened without exhausting the arena outright. `.open`/`#initialize` now
  accept a seekable stream (a real `File`, kept open for the archive's
  lifetime) and read only the header and each version's entry table up
  front; `#read(name)` seeks to that entry's own offset and decrypts only
  its own bytes. Opening an archive now costs memory proportional to its
  entry count, not its total size. The in-memory `.new(String)` form used by
  tests and by `pack_v1`/`pack_v3`'s own round-trip callers is unchanged
  (wrapped in a `StringIO` internally). See
  `docs/adr/0047-psp-memory-budget.md`.
