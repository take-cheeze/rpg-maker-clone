- bc2cpp's closed world is now the sealed RPG2000/2003 desktop host instead of
  maix's cross build. The `closed` build is a native desktop build with the
  RPG2000/2003 format only, and its gem set is the desktop host's minus the
  XP/VX/Wolf/MV formats. The `src/main.cxx --script` arbitrary-Ruby loader is
  compiled out under the CMake option `RPG2K_SEALED_HOST` (off by default).
- The closed-world scanner ignores comments and prose string literals when it
  collects names, and resolves a `mrb_funcall` method name held in a
  `const char*` local, so the desktop entry no longer marks RPG2k opaque.
- `RPG2k#initialize` loads `@db` first.
