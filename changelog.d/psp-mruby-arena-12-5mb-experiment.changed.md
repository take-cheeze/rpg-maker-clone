- **PSP mruby arena bumped from 12 MB to 12.5 MB, as an experiment.**
  `psp-smoke-game`'s `.psp_ci_new_game` marker (docs/adr/0047-psp-memory-budget.md's
  P1c) drove Nepheshel into a real New Game and reproduced -- deterministically,
  across three separate CI runs -- a `ppsspp-headless` segfault once
  `arena_used` climbed to 94.5% of the old 12 MB ceiling. That ceiling was
  already flagged, in the commit that originally sized it, as a known sharp
  edge left open on purpose: exhausting it hits a corrupting-unwind failure
  path in mruby's own `NoMemoryError` recovery, not a clean catchable error.
  This spends 512 KiB of the ~764 KiB of OS-level headroom every heartbeat's
  `free=` figure has shown sitting untouched throughout every run so far, to
  see whether Nepheshel's specific session fits inside the larger ceiling or
  the same cliff just waits further out. Not yet re-validated against a
  fresh `psp-smoke-game` run -- follow-up.
