- **Build:** `patches/mruby-rdata-ivar-slots.patch` now uses context hunks. Its
  zero-context GC hunk landed inside the class case of `gc_mark_children` once
  `mruby-gc-type-live-counts.patch` was applied first (the CI order), so RData
  ivar slots were never marked and the compiled optcarrot run died with
  `undefined method '>='`. `scripts/mruby_patch_context_check.rb` rejects
  zero-context hunks in `patches/mruby-*.patch`.
