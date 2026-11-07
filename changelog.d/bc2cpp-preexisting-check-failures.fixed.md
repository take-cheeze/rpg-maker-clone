- **bc2cpp:** Four checks that failed before this branch are fixed. TOP_LEVEL_STATEMENTS (`bc2cpp_top_level_statements`)
  wrote a `goto` for a jump inside a statement (`x = cond ? A : B` before a constant write) without its label, and left
  its sends as unrewritten `bc2cpp_owner_call_named(...)` text; it gets its jump labels and the same
  owner-call and symbol-cache passes as the class units (`self_new_leaf_check.rb`). An implicit-self send MONO-bound to a
  Kernel body is no longer a direct call inside a BasicObject subclass, which has no Kernel (KERNEL_SELF_SEND, `ClosedWorld#kernel_missing_self?`).
  The check expectations that the compiler's own evolution made stale are rewritten: `block_iterator_direct_check.rb`
  now expects the MONO direct `Kernel#loop` call and the EXACT_TYPED String literal arm in place of the removed
  root-context test, and covers the Object#loop and BasicObject worlds; `transpose_direct_check.rb` defines its
  singleton `each` in the program (a singleton class made by evaluated code outside the closed world is an owner violation) and
  adds a world for it; `sealed_hash_stores_check.rb` pins that a store breaking a `-> Thing?` declaration is trusted as written (RBS only,
  0fb29edf3) instead of expecting the deleted proof to catch it.
