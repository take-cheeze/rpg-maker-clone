- **bc2cpp native base RBS** is less `untyped`: a native method returning one
  kind or nil is declared `K?` (`Dir#read -> String?`,
  `StringIO#getbyte -> Integer?`), and `Math` functions take `Numeric`. Only a
  return expression's outermost call counts now. That corrects `Math.frexp`
  (`Integer` → `Array`), `RGSS.window_title` / `default_font_path` (`nil` →
  `String?`) and the RGSS `visible` getters (an unproven `bool` → `untyped`).
  `mrb_assoc_new` is a known `Array` constructor, so `divmod`, `IO._pipe` and
  `Math.frexp` also get `Array` in the compile-time native kinds.
