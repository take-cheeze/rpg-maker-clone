- **PSP mruby arena: tried 12.5 MB, confirmed it doesn't fix the `Scene::Map`
  crash, reverted to 12 MB.** `psp-smoke-game`'s `.psp_ci_new_game` marker
  (`docs/adr/0047-psp-memory-budget.md`'s P1c) drives Nepheshel into a real
  New Game and reproduces -- deterministically, across three separate CI
  runs -- a `ppsspp-headless` segfault once `arena_used` climbs to 94.5% of
  the 12 MB ceiling. Bumping the arena to 12.5 MB (spending 512 KiB of the
  ~764 KiB of OS-level headroom every heartbeat's `free=` figure has shown
  sitting untouched) didn't help: the same run reached one heartbeat
  further before crashing the same way, at 99.0% of the *new* ceiling --
  the cliff tracks whatever ceiling is in force almost exactly, confirming
  this is genuine capacity exhaustion hitting a known, already-documented
  corrupting-unwind failure path in mruby's own `NoMemoryError` recovery
  (not a clean catchable error, and not an unrelated PPSSPP HLE gap).
  Reverted to 12 MB since the bump bought nothing but permanently spent
  headroom the newlib/sbrk heap may need. The real fix is hardening that
  unwind path itself, not raising the arena size further -- out of scope
  for a PSP-port change; see the ADR's P1c for the full trail.
