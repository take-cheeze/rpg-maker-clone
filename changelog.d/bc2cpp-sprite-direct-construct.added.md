- `Sprite.new` / `Sprite.new(viewport)` (31 real sites) devirtualize
  into a new `rgss_sprite_new_direct` constructor in
  `mruby-rgss/src/lib.cxx` (delegates to `spr_init` itself, viewport
  pre-resolved, object allocated inside), registered in
  `NATIVE_CONSTRUCT_TARGETS` with a new multi-arity (`[0, 1]`) and
  `:object` (pass-through `mrb_value`, no unboxing) convention that the
  emission gate, the forward declarations, and the call-site unboxing
  all share. 26 real call sites convert (342 -> 316 bare `new`
  dispatches in `mruby-rpg2k-compiled`'s own output); regenerated
  `docs/bc2cpp_coverage.txt` shows the measured whole-program impact.
