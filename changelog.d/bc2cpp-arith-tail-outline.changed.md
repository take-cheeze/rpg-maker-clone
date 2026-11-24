- **bc2cpp**: an `+`/`-`/`*`/`/` site keeps only its Integer fast path inline;
  the overflow, heap-Integer, Float and by-name arms share one outlined helper
  (COLD_COMPACT_TAIL, `BC2CPP_COLD_COMPACT_TAIL=0` turns it off). The Wio
  firmware shrinks by about 22 KB.
