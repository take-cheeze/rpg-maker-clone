- **Wio Terminal:** the build now uses a minimal `Math` module
  (`app/wio/mruby-math-wio`: `PI`, `E`, `sin`) instead of mruby's full
  `mruby-math`. Those are the only members the engine uses, and RPG2000/2003
  games carry no Ruby of their own. Dropping the libm routines behind the
  rest saves 20,776 bytes of flash. `scripts/wio_dropped_gems_check.rb` now
  fails CI if engine code uses any other `Math` member. See `docs/adr/0204`.
