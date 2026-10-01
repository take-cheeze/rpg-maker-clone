- CI: new `bc2cpp-width` jobs (gated by the `bc2cpp` status) run the
  width-sensitive bc2cpp checks (`bc2cpp_numeric_slow_check`,
  `bc2cpp_fixnum_overflow_check`, `bc2cpp_step_inline_check`,
  `bc2cpp_unlisted_class_call_check`, `bc2cpp_lcf_row_flow_check`) on a
  32-bit-`mrb_int` mruby build and a no-bigint build, the widths of the
  Emscripten/Wio/PSP targets. `bc2cpp_lcf_row_flow_check` gained its 32-bit leg,
  and `scripts/bc2cpp_width_build.rb` builds the libmruby. The CI workflow also
  triggers on `merge_group`; `docs/ci.md` lists the merge-queue repository
  settings the owner must enable. See `docs/adr/0300`.
