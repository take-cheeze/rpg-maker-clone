- **bc2cpp** (`CLASS_READ_INLINE`): every exact-class guard in the compiled C++ (MONO_EMBED_GUARD, TYPED,
  IVAR_ACCESSOR, POLY_SMALL_N, NATIVE_OWNER_MAP, the RGSS native wrappers and the rest) now goes through one
  inline helper, `bc2cpp_class_is`, and every hoisted class read (INHERITED_GUARD, POLY_INTEGER_TAG,
  USER_RECEIVER_CASES) goes through `bc2cpp_obj_class`. Before, each one called mruby's out-of-line
  `mrb_obj_class`. A heap object whose class pointer is a plain class is answered inline. Immediates, singleton
  classes and extended objects still make the call, so every guard gives the same answer as before. In the
  optcarrot probe the frame loop falls from 23.67M to 23.49M instructions per frame (−0.75 %), and startup falls
  by 0.09 %. `BC2CPP_CLASS_READ_INLINE=0` turns it off. See `docs/bc2cpp-class-read-inline.md`; the new check is
  `scripts/bc2cpp/class_read_inline_check.rb`.
