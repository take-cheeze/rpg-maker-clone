- `tools/bc2cpp`'s whole-program ivar-embedding pass (`IvarLayout`) now
  recognizes two more provably-safe SETIV source shapes, widening how many
  instance variables get embedded as real C struct fields instead of going
  through mruby's ordinary, per-access `iv_bsearch_idx` ivar table:
  - `@x = true` / `@x = false` (a new `:bool` embeddable type, backed by a
    real `mrb_bool` struct field and mruby's own public `mrb_bool_value`/
    `mrb_true_p`/`mrb_false_p`).
  - `@x = SOME_CONST` when `SOME_CONST` is one of the whole-program-proven
    integer-valued constants `INTEGER_CONSTANT_PROOF` already tracks for
    other purposes (`GETCONST`/`GETMCNST`, embedded as `:fixnum`).
  Whole-program `ivar embedding (EMBED)` in the real project's own combined
  coverage report goes 115 -> 216, with 100.0% method-level coverage and
  zero `#error` markers unchanged. In the Optcarrot bc2cpp probe, this
  newly embeds several `Optcarrot::PPU` rendering-enable flags (`@run`,
  `@vblank`, `@vblanking`, `@sp_overflow`, `@sp_zero_hit`) and `Optcarrot::
  CPU`/`PPU` clock-cycle counters (`@hclk`, `@scanline`, ...) that were
  previously OPAQUE; the full 180-frame benchmark still checksums `59662`
  on CRuby, interpreted mruby, and bc2cpp alike.
