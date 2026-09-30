- **bc2cpp** proves the Integer range of arithmetic, compare and Array-index
  operands (literals, masks, `%`, shifts, guarded loop counters, loop
  parameters of `times`/`upto`/`step`/`each_index`/`(a..b).each`, and the
  elements of Arrays whose every writer is visible). `+ - *` and comparisons
  whose operands and result fit the fixnum range lose the overflow tier and the
  Float/bigint arms (guarded by the target's `MRB_FIXNUM_MIN/MAX` unless they
  fit every target), `a[i]` with a non-negative `i` skips the negative-index
  wrap, and `Array.new(n)` with a proven size allocates at its final size. See
  ADR 0286.
