- `tools/bc2cpp/bc2cpp.rb`'s native-method-name registry extraction now
  also recognizes mruby core's own ROM method-table registration idiom
  (`MRB_MT_ENTRY(fn, MRB_SYM(name)|MRB_OPSYM(op), flags)` and
  `mrb_define_method_id(..., MRB_SYM(name)|MRB_OPSYM(op), ...)`), not just
  RGSS's literal-string `mrb_define_method(klass, "name", ...)` calls --
  mruby 4.0 registers most of its own core (`Array`/`Hash`/`String`/
  `Kernel`/`Symbol`/...) the first way, which the original RGSS-only regex
  could never see at all. `mruby-lcf-compiled`/`mruby-rpg2k-compiled` now
  feed `3rd/mruby/src/*.c` plus every enabled core mrbgem's own C source
  into `NATIVE_SRCS` alongside `mruby-rgss/src/*.cxx`. Found 21 further
  real collisions beyond the earlier 6 RGSS ones, including a genuinely
  serious one: `LCF::Array1D#delete` colliding with core `Array#delete`/
  `Hash#delete` (previously, any `.delete` call anywhere in the whole
  program on a real Array/Hash could have been unsoundly devirtualized
  into `LCF::Array1D`'s own implementation instead). Verified
  byte-identical output on both already-shipped compiled targets via the
  real Rake build path. See
  `docs/adr/0139-bc2cpp-lcf-file-aot-compile.md`'s own follow-up.
