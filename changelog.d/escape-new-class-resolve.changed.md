- **Escape analysis report** (`BC2CPP_ESCAPE_REPORT`) now names the class of a `new` site that the compiler proves
  to be one stable class constant, so bare and nested constants such as `Rect.new` inside `class RPG2k::Window` are
  classified by their constructor. Report only; generated code is unchanged.
