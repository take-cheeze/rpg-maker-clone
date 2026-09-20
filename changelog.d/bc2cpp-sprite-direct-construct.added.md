- `Sprite.new` / `Sprite.new(viewport)` (31 real sites) devirtualize
  into a new `rgss::sprite_new_direct` constructor in
  `mruby-rgss/src/lib.cxx` (namespace `rgss` at file scope, delegating
  to `spr_init` itself, viewport pre-resolved, object allocated
  inside), registered in `NATIVE_CONSTRUCT_TARGETS` with a new
  multi-arity (`[0, 1]`) and `:object` (pass-through `mrb_value`, no
  unboxing) convention that the emission gate, the call-site unboxing,
  and the new `include/rgss_construct.hxx` header (the single source
  of truth for these signatures, `#include`d by the generated TU
  instead of re-spelled `extern "C"` decls) all share. The pre-existing
  `Rect`/`Color`/`Tone`/`Bitmap` entry points move to the same header +
  namespace, deleting the whole `extern "C"`-in-anonymous-namespace
  arrangement. 26 real call sites convert (342 -> 316 bare `new`
  dispatches in `mruby-rpg2k-compiled`'s own output); regenerated
  `docs/bc2cpp_coverage.txt` shows the measured whole-program impact.
