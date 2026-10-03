- **bc2cpp: `RGSS::Bitmap.new(w, h)` with provably Fixnum arguments has no tag test and no by-name else.** A constant
  defined by `+ - * /` of other constants (`HEADER_H = LINE_H + Window::BORDER * 2`, `COLS = SCREEN_W / TILE + 1`) now has
  a proven Fixnum interval (the hull of every definition of its bare name, every intermediate inside the narrowest
  target Fixnum range), and the construct site asks the Fixnum proof, which it never did: 65 of the 115 engine sites
  lose the `mrb_integer_p` test and the `bc2cpp_send` else (wio closed world: 2,607 to 2,538 sends, all removals).
  Withdrawn by const_set, remove_const, autoload, const_missing, a redefined `Integer#*`, a native or foreign
  definition and the open world; `BC2CPP_NUMERIC_CONSTANTS=0` is byte-identical to the old output.
  `BC2CPP_NATIVE_INT_ARGS=<file>` and `BC2CPP_NUMERIC_CONSTANTS_REPORT=<file>` write why an argument or constant is
  unproven. Covered by `scripts/bc2cpp_numeric_constants_check.rb` and its mutation check
  (`docs/adr/0318-bc2cpp-numeric-constant-ranges-and-native-int-arguments.md`).
