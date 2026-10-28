- bc2cpp roots the value a compiled store replaces
  ([GC_KEEP_OVERWRITTEN](docs/bc2cpp-gc-roots.md)). A compiled register is a C local the collector does not scan,
  so a value read from a slot that the method then overwrites (`r = @list; @list = []; r`) was left referenced only
  by that local, and a GC step in the caller freed it. This caused the `declared -> Array | nil` hint violation
  on map 255 in `bc2cpp-sweep`. Embedded ivar, global, upvar, element and attr-writer stores now root the old value
  first, and Array `[]=`/splice/`clear`/`replace` and Hash `[]=` do too. New `scripts/bc2cpp/gc_root_check.rb`
  reproduces each case with a forced GC and fails when the roots are switched off
  (`BC2CPP_GC_KEEP_OVERWRITTEN=0`).
