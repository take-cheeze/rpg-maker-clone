- **Wio Terminal: dropped the RPG_RT-interop (.lsd) save/load path.**
  `Game::State#to_lsd`/`.from_lsd` (moved into their own file,
  `mruby-rpg2k/mrblib/game/lsd_io.rb`) only exist so a save this game
  writes can round-trip through real RPG_RT/editor tooling on a PC --
  Save/Continue itself is the separate, unaffected Marshal-based
  `Game::State#to_h`/`.load` path `main.rb`'s own `#save_game` already
  documents as authoritative. Wio has no PC to hand a save file to, so
  the interop file is excluded from that build alone; `main.rb`'s two
  call sites now guard with `respond_to?` instead of relying on a
  rescued exception every save.
  Real whole-gem `mrbc --remove-lv` compile of `mruby-rpg2k`'s exact
  wio-shaped file list: 501,580 -> 477,860 bytes (23,720-byte reduction).
  See ADR 128.
