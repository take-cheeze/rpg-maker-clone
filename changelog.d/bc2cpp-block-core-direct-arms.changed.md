- **bc2cpp**: a literal-block send from compiled engine code to a core iterator
  (`each`, `each_with_index`, `map`, `select`, `reject`, `each_with_object`,
  `sort_by`, `downto`, ...) now tries exact-class Array/Hash/Range/Integer arms
  that call the compiled core body directly at the root context, keeping the
  block-carrying send as the else (ADR 0270). In the wio closed-world report
  the literal-block sends with no direct arm drop from 423 to 72: arms now also sit in the compiled core bodies, cover the optional-block shapes (`find`, `sum`, `any?`) and nested blocks, and a `*rest` parameter is known to be an Array.
  `scripts/bc2cpp_block_core_direct_check.rb` compares a compiled fixture with
  the interpreter.
