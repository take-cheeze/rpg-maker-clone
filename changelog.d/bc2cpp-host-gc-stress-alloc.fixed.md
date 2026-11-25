- **bc2cpp**: `BC2CPP_HOST_GC_STRESS=N` for the headless host and `host_sweep.bash` now runs a full GC before every
  Nth object allocation (1: every one). The old mode never collected sooner than 1024 allocations apart, so a build
  with every GC root switched off passed the whole sweep under it; that build now fails 34 maps.
