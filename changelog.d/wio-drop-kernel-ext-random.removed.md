- **Wio Terminal:** the build no longer links `mruby-kernel-ext` or
  `mruby-random`. Both exist only for a game's own Ruby scripts; RPG2000/2003
  games have none, and the engine itself calls neither. That saves 3,980 bytes
  of flash. The new `scripts/wio_dropped_gems_check.rb`, run in CI, fails if
  engine code starts calling them. See `docs/adr/0202`.
