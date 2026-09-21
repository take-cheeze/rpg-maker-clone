- Fixed a real `bc2cpp` code-generation bug in
  `tools/bc2cpp/native_expression_devirt.rb`'s
  `exact_array_no_argument_element_expression` (the codegen behind
  `Array#first`/`Array#last`): it re-derived the receiver's `mrb_ary_ptr`
  independently for each use in the assembled C++ expression instead of
  materializing it once, the way `Array#last`'s real mruby C body does.
  For `#last` that produced a single expression calling `mrb_ary_ptr(recv)`
  three times, nesting the `ARY_EMBED_P`/`ARY_LEN`/`ARY_PTR` macros three
  levels deep -- a shape that triggered a genuine GCC code-generation defect
  (confirmed via `gdb` against a real `-O0` build: a live, fully valid
  `RArray*` with one code path reading an uninitialized register instead),
  causing a real, CI-reproducible SIGSEGV in the Optcarrot bc2cpp probe's
  `Optcarrot::Video#tick`. The generated expression now hoists the repeated
  `mrb_ary_ptr(recv)` call into a single local via a GNU statement
  expression and reuses it. `tools/optcarrot_probe/compiled_run.rb`
  recompiles and reinstalls `Optcarrot::CPU`/`Optcarrot::NES`/
  `Optcarrot::Video`/`Optcarrot::APU` (previously excluded as a workaround
  for this exact bug); the full 180-frame benchmark now completes with
  checksum `59662` on CRuby, interpreted mruby, and bc2cpp alike.
