- **bc2cpp**: a receiver the exact-class flow proves is one RGSS native class
  (`Bitmap`, `Sprite`, `Window`, `Viewport`, held in an ivar, built locally or
  returned by a proven call) now calls the wrapper body (`fill_rect`, `blt`,
  `stretch_blt`, `copy_blt`, `draw_text`, `text_size`, `clear`, `bitmap=`,
  `opacity=`, `tone=`, `openness=`, `update`, `dispose`, ...) with no class
  test and no by-name fallback; a nil-or-one-class receiver takes one nil test
  first. The wio closed world has 179 fewer `bc2cpp_send` sites (158 in the
  rpg2k and game classes). `BC2CPP_EXACT_NATIVE_WRAPPERS=0` restores the
  guarded calls. See `docs/adr/0307-bc2cpp-exact-native-wrapper-calls.md`.
