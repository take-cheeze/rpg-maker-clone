- bc2cpp roots fewer element reads: a read held only across macros, ivar and
  class reads, write barriers or plain allocations is no longer rooted in the GC
  arena (848 B less Wio flash). The headless host's `BC2CPP_HOST_GC_STRESS`
  runs the GC without pause, so a missing root shows up in the sweep.
