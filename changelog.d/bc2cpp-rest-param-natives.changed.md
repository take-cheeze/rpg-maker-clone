- **bc2cpp calls audited Array natives on a `*rest` parameter directly.** A
  rest parameter is a fresh exact Array, so `v.__svalue` (new row, inlined from
  the static `mrb_ary_svalue`), `to_a`, `join`, `compact`, `index` and `shift`
  need neither a class guard nor the fallback send there.
