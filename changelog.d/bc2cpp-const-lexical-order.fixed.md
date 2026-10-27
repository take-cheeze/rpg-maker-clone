- **bc2cpp**: a compiled bare-constant read follows mruby's lookup order: every lexical scope's own table (innermost
  first, Object last) before the innermost scope's ancestors. It used to search each scope together with its
  superclasses, so `W` in a class nested in a module that defines `W` read the superclass's `W` instead, and a
  top-level class read its superclass's constant over a top-level one. See `docs/bc2cpp-constant-lookup.md`.
