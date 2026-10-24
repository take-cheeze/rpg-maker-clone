- **bc2cpp: a `rescue` inside an `ensure` body compiles.** A single
  `begin ... rescue C ... end` inside an ensure body, the way mruby-io's
  `IO.open` closes its io, now runs inside the ensure guard under its own
  `mrb_protect_error` instead of leaving the whole method uncompiled. A jump onto
  the first protected instruction (`return io unless block` before the `begin`)
  is accepted too. mruby-io's `IO.open` compiles as a result.
