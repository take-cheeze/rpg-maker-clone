- **PSP EBOOT links `libmruby.a` and boots the interpreter.**
  `app/psp/CMakeLists.txt` now builds `uni-algo` (mruby-rgss/mruby-lcf's
  Unicode dependency) and invokes the `psp` mruby cross-build via the same
  rake-based process the root CMakeLists.txt uses for desktop/wasm, then
  links the resulting `libmruby.a` into the EBOOT — dropping the now-redundant
  direct compile of `mruby-rgss/src/psp.cxx`, which the gem now supplies.
  `app/psp/main.cxx` calls `mrb_open()` right after the display/input HAL
  comes up and reports success via a new `RPG2K_PSP_MRUBY_OPEN` marker. No
  RGSS methods are registered and no game starts yet — mruby opens with its
  own default allocator (not yet routed through `lv_malloc`; see ADR 0047's
  P2) and the interpreter just sits there. See `app/psp/README.md`'s "Not yet
  wired" section for what's left before a real game can boot (the `GAME_DIR`
  convention, the RGSS scene tree, and the allocator decision).
