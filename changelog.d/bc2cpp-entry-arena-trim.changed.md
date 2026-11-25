- **bc2cpp**: a host entry call gives a grown GC arena back (`bc2cpp_entry_arena_trim`), on the protected-region
  path too, so the arena no longer stays at the few thousand slots a map load grew it to. On the Wio game firmware
  it ends a run at 100 slots (0.4 KB) instead of 3.0 KB at the title and 5.3–8.4 KB after a map visit.
