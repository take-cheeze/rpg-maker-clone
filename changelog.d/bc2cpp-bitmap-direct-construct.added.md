- `Bitmap.new(w, h)` (the 2-Integer-arg size shape, ~105 of 124
  real sites) devirtualizes into a new hand-written
  `rgss_bitmap_new_direct` constructor in `mruby-rgss/src/lib.cxx`
  (reproducing `bmp_init_size`'s own `alloc_obj(M, self, w, h,
  ARGB8888)` body), registered in `NATIVE_CONSTRUCT_TARGETS` with a
  new `type_guard: :int` convention: the call site checks
  `mrb_integer_p` on every argument first and falls back to ordinary
  `mrb_funcall` otherwise, so the (`String`, ...) file-load shapes
  keep working instead of raising. 114 real call sites convert (the
  residue that made the shipped whole-program count read +1 instead
  of -114 is 29 pre-existing `POLY :new` dispatches on names this
  change never touched -- mostly `LCF::Array1D`/`Array2D` inside
  `Game::State#to_lsd`, whose own `#initialize` bodies never compile
  -- plus one fewer distinct dispatched name from the removed
  `Bitmap` residuals); regenerated `docs/bc2cpp_coverage.txt` shows
  the measured whole-program impact.
