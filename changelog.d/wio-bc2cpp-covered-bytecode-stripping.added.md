- **A wio-only build step now deletes the interpreted-bytecode `def` of
  every method `RPGMAKER_BC2CPP=1` actually installs a real C++ override
  for** (`build_config.rb`'s `wio_strip_bc2cpp_stubs`, backed by
  `tools/bc2cpp/wio_registered_methods.rb` and
  `strip_wio_bc2cpp_stubs.rb`), out of a build-time-only source copy —
  never the checked-in source, and never touching bc2cpp's own
  whole-program registry input. The whole `def ... end` is removed
  outright, relying on Ruby's own default `method_missing` (a plain
  `NoMethodError`) to cover the narrow pre-override load-order window this
  mechanism already has to verify is unreachable per owner — no stub body
  needed, and no runtime behavior change once the real C++ override
  installs. Proved end to end on `RGSS::Sprite`'s real 17 registered
  methods (real bc2cpp diagnostic capture, a real
  `RubyVM::AbstractSyntaxTree`-based rewrite, a real clean
  `wio_rgss_boot` recompile): a real, measured **696-byte flash recovery,
  64-byte RAM recovery**, matched against a from-scratch "before" rebuild
  that itself reproduces docs/adr/0143's own already-recorded full-scope
  baseline to within 88 bytes (0.004%). Small in absolute terms because
  `RGSS::Sprite`'s own methods are all trivial one-line accessors close to
  `mrbc`'s per-method floor already, but larger than this mechanism's own
  first two shipped designs: an early message-carrying stub
  (`raise NotImplementedError, "..."`) was caught by a real measurement as
  a *regression* (a per-method string literal is never shared across
  methods), the bare `raise NotImplementedError` stub that replaced it
  measured a real 512-byte flash recovery with zero RAM change, and outright
  `def` deletion — the design that actually ships — beats both, real
  `mrbc`-compiled `.mrb` sizes and the real linked delta agreeing on the
  ranking (though not the exact linked magnitude). See
  `docs/adr/0144-wio-bc2cpp-covered-bytecode-stripping.md`.
