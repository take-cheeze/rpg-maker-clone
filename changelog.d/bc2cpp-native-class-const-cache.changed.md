- The const-site cache (`StableClassConstants`, `tools/bc2cpp/const_site_cache.rb`)
  now also caches a bare `GETCONST` for a class/module a native mrbgem defines
  (`Symbol`, `Array`, `Struct`, and every other core/builtin class, plus
  gem-defined native classes), not only a name a Ruby `class`/`module`
  statement introduces. `LCF::Array1D#[]`'s `idx.is_a? Symbol` (and its
  siblings) previously paid the full scope-chain lookup on every call: ~70
  executed `mrb_const_get`s per rendered frame in the RPG2k map scene for that
  one name alone. The native definition is derived from the real
  `mrb_define_(class|module)(_id|_under)?`/`boot_defclass` call shapes (the
  same parser `NativeExpressionDevirt.analyze_exact_class_expressions` already
  uses to resolve an owner's runtime class), never a hand-written list of
  "well-known" builtins, and is refused when the same bare name has more than
  one distinct native definition, is reassigned, or a foreign Ruby source also
  defines it. A Ruby-level reopening of the same native class (adding methods,
  never rebinding the constant) does not disqualify it. New
  `scripts/bc2cpp_native_class_const_check.rb`.
