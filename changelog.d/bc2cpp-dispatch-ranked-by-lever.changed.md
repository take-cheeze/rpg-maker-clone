- **bc2cpp** the receiver-proof census now ranks unproven sites by **structural lever** — what would actually
  remove each site's by-name line — rather than by how hard a receiver proof would be (ADR 0341). On master
  `921e1ee3` of 1,671 unproven sites (1,728 by-name lines): **1,046 are a consumer gap** (an answering class has no
  Ruby body to call), 384 have no floor at all, 172 are freed by any receiver proof, 69 are another cell. So the
  receiver-proof lever is 172 lines and the codegen lever 1,050 — the reverse of what ADR 0331's framing implied.
  Measured and rejected as a dead end: relaxing `direct_callable?` for a `&block` parameter looks like a 98-site win
  from the `Array#each` concentration, but 97 of those 98 carry an `absent_or_native` cell, so it would reach **1**
  site. The live lead is that `absent_or_native` is a whole-*name* fact from a C-source token scan while the
  registration is class-scoped — verified wrong for `Array#each`, which has a compiled Ruby body. Changes no
  generated code.
