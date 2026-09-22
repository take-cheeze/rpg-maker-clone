- **bc2cpp** closes the same registration-completeness gap in
  `mruby-lcf-compiled` (14 methods across `LCF::Sections`/`Array1D`/
  `Array2D`/`File`) and `mruby-rgss-compiled` (13 methods across
  `RGSS::ErrorReport::Tee`/`Bitmap`/`Array`/three `.singleton` owners) that
  `docs/adr/0190` closed for `mruby-rpg2k-compiled`. All newly-wired owners
  verified at 100% via `scripts/bc2cpp_wired_embedding_check.rb`, coverage
  unchanged at 100.0%/0 `#error`.
