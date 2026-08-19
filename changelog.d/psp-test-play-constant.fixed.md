- **The PSP EBOOT now defines the `TEST_PLAY` mruby constant**, matching
  every other target's own entry point (`src/main.cxx`). RPG2k#initialize
  (`mruby-rpg2k/mrblib/main.rb`) calls `native_test_play?`, which
  references `TEST_PLAY` directly (rescuing `NameError` if it's
  undefined) — the PSP build never defined it, so constructing an RPG2k
  game with a real project always raised and rescued a `NameError` on
  its very first line, a code path CI's `psp-smoke` job never exercises
  (it has no project at `kGameDir`, so it only ever runs the idle HAL
  loop). `app/psp/main.cxx` now sets `TEST_PLAY` to `false` (this build
  has no command line to carry a real Test Play flag on), matching
  `RTP_DIR`/`GAME_DIR`'s existing pattern.

  Found while testing against a real project (Nepheshel, this repo's own
  `data/Nepheshel206beta` test fixture) — the first time this whole EBOOT
  has ever been driven with real game data rather than the idle path.
  This closes one genuine gap, but is not sufficient on its own:
  constructing `RPG2k` with a real project still crashes shortly after,
  in a different, not-yet-root-caused way (a low-level mruby VM
  assertion reached only after several bytecode-level method calls
  succeed) — see `docs/adr/0047-psp-memory-budget.md` for where this
  stands.
