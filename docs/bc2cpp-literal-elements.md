# Immediate literal element receiver proofs

bc2cpp proves primitive elements of fresh array literals when the array is
indexed immediately with an in-bounds integer literal. Examples include
`["abc"][0].size`, `[7][0] + 1` and `[[1, 2]][0].size`.

The selected element must originate from a primitive literal in a straight-line
corridor of at most 32 instructions. Calls, aliases, mutations, unknown indices,
branch entries, exception handlers and captured writes withdraw the proof.
Out-of-bounds reads retain their existing nil behavior. No assumptions are made
about mutable ivar element hints or arbitrary Hash keys.

Set `BC2CPP_LITERAL_ELEMENT_PROOF=0` to disable the analysis. Run
`scripts/bc2cpp_literal_element_check.rb` with `MRBC` and a full mruby build for
interpreted/compiled parity, and
`scripts/bc2cpp_literal_element_mutation_check.rb` for the six withdrawal mutants
and control. See [ADR 0354](adr/0354-bc2cpp-fresh-literal-elements.md).
