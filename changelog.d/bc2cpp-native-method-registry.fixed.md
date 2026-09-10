- `tools/bc2cpp/bc2cpp.rb` now optionally merges RGSS's C++-implemented
  method names (`mrb_define_method`/`_class_method`/`_module_function` call
  sites in a `NATIVE_SRCS` file list) into its whole-program registry, so a
  bytecode-defined name can no longer look falsely monomorphic just because
  the registry never saw a same-named method registered natively on a
  different class. Wired into `mruby-lcf-compiled`/`mruby-rpg2k-compiled`'s
  own build (`NATIVE_SRCS = mruby-rgss/src/*.cxx`). Found and fixed 6 real
  collisions this way (`x`/`y`/`width`/`height`/`ox`/`oy` -- `RGSS::Sprite`'s
  own bytecode readers vs. `RGSS::Rect`/`RGSS::Viewport`'s natively
  registered same-named accessors); verified byte-identical output on both
  already-shipped compiled targets (`LCF::File`, `Game::Picture`), which
  don't happen to call any of the 6 from a compiled call site. See
  `docs/adr/0139-bc2cpp-lcf-file-aot-compile.md`'s own follow-up for why a
  *direct* devirtualized call into one of these native methods is not sound
  (mruby's `mrb_get_args` depends on VM call-frame state only `mrb_funcall`
  itself sets up) and was deliberately left out of scope.
