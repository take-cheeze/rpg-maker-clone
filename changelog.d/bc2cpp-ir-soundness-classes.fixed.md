- **bc2cpp** no longer trusts a textually nearest writer or a straight-line run where a branch join, a catch handler or
  an ALIAS on a skipped path can change the answer: a class object register at a join (`c ? [] : Foo`), the `new` of
  a join of `Foo` and `Object`, the name of a `to_enum` site, the confined lambda `.call`, and whether a core `alias`
  is on every path. Each now asks the bytecode flow graph, and refuses (keeps the dynamic path) where it cannot prove
  the answer.
