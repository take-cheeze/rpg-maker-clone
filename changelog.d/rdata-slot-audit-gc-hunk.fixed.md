- The RData ivar-slot mruby patch places its GC marking hunk by context instead
  of a fixed line. Applied after `mruby-gc-type-live-counts` it landed in the
  wrong `case`, so slot values were never marked (use-after-free); marking also
  skips a NULL payload now.
