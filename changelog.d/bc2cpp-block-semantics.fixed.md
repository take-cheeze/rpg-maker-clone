- **bc2cpp** compiled blocks now behave like the interpreter's (ADR 0266):
  `Proc#call` on a compiled block no longer crashes, `block_given?` reads the
  caller's block, a block with fewer or more parameters than it is yielded pads
  or truncates like a proc (and raises like a lambda once `Kernel#lambda`
  flagged it), a `break`/`return` unwinds to its own call site or method and
  raises `LocalJumpError` once that frame is gone, entry wrappers word arity
  errors like `OP_ENTER`, and `Hash.new`/`Proc.new` blocks that capture locals
  stay interpreted. Covered by `scripts/bc2cpp_block_semantics_check.rb`.
