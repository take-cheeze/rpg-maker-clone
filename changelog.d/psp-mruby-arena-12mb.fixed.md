- **PSP:** size the mruby arena at 12 MB instead of 8 MB. Nepheshel's
  New Game filled the old arena to its last byte during the first map load,
  and the failed-allocation recovery path corrupted the VM callinfo chain
  (frames left pointing into freed memory), aborting inside mruby's
  `catch_handler_find` on the next raise. The new size is measured, not
  guessed: 12 MB runs millions of New Game frames under PPSSPP-headless with
  steady-state occupancy of ~12.0 MB and one cleanly-recovered transient
  exhaustion per few minutes, while 16 MB starves the shared newlib heap
  (`std::bad_alloc`). The per-second `RPG2K_PSP_BRINGUP` heartbeat now also
  reports `arena_used=` so the next game to outgrow it shows up in numbers
  rather than as a crash.
