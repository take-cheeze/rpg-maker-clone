- **bc2cpp** `bc2cpp_slow_mod` and `bc2cpp_slow_neg` no longer dispatch by name when the closed
  world proves only Integer, Float and String answer `%` and only Integer, Float, Numeric and
  String answer `-@`: the new `patches/mruby-expose-misc-bodies.patch` exports the bodies of
  `Integer#%`, `Float#%` (the static `flodivmod`), `String#-@` and the sprintf formatter under
  `*_impl` names (the registered methods call the same bodies, so interpreted behaviour is
  unchanged), and the helpers call them directly; any other receiver raises the proven
  NoMethodError, removing 209 generated sites from the by-name census. `CoreMisc`
  checks the wrapper text, so a tree without the patch keeps the by-name helpers. The patch is
  registered in the cmake chain, `scripts/maix_mruby_build.bash` and
  `scripts/wio_bc2cpp_measure.bash`. `zero?`, `===` and the Hash arm of `< <= > >=` stay by
  name (ADR 0367 says why); `scripts/bc2cpp_numeric_slow_check.rb` compares the helpers with the
  real methods on 64-bit, 32-bit and no-bigint mruby.
