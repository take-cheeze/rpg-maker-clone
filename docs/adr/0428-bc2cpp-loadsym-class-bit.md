# 0428. bc2cpp: a Symbol literal in a register carries the Symbol class bit in the numeric flow

Date: 2026-10-12

## Status

Accepted

## Context

ADR 0424 gave a Symbol element of a frozen literal table the Symbol class bit (`CodeGen#frozen_symbol_bit`, the bit the
exact-class run gives `LOADSYM`). A `LOADSYM` in a register outside a table stayed OTHER in the numeric flow, because
`NumericOracle` has no literal class mask. ADR 0424 left this as a follow-up that needs its own consumer audit, since
the numeric masks reach more emitters than the frozen-table reads do.

The numeric oracle and the exact-class oracle answer different questions. The exact-class run (`ExactOracle`, ADR 0289)
already gives `LOADSYM` the Symbol bit, and its consumers (return classes, class narrowing, escape, instance receivers)
have shipped with it. The numeric flow is read by the arithmetic and comparison proofs, the numeric return table,
native direct calls and the step loop, and the frozen-table reads.

## Decision

* `NumericOracle#literal_class_mask` gives a `LOADSYM` register the Symbol bit, `CodeGen#frozen_symbol_bit`, the same
  bit the frozen-table slot reader uses. The bit is allocated only where it already is (`setup_frozen_tables`), so a
  run without it keeps every other bit's numbering.
* A kind_of test on a class bit decides the Symbol bit through `SYMBOL_CLASS_CHAIN` (`%w[Symbol]`) in
  `class_test_chain`. The closed world has no class parent for Symbol, so without it the bit is unknown and passes both
  edges of every test. Only a name `class_test_constant` admits reaches the chain, and none of those is a superclass or
  a module of Symbol, so the verdict is exact. It is not added to `CLASS_TEST_CORE_CHAIN`, which also decides
  `respond_to?` and does not model Symbol's native methods.
* The kill switch `BC2CPP_LOADSYM_CLASS=0` removes both: the numeric `LOADSYM` is OTHER and the chain is unknown. It is
  independent of `BC2CPP_SYMBOL_CLASS` (which removes the table bit) and of `BC2CPP_IMMEDIATE_CLASS_BITS`.
* The consumer audit is in `docs/bc2cpp-symbol-class.md`. Each consumer of a numeric mask either requires
  `NumericFlow.numeric?`, `== INT`, or no OPAQUE bit (so refuses a Symbol), maps the bit to OTHER (`arith`, the tuple
  positions, the LCF index), reads the exact-class flow (which already carries the bit and never reads a numeric
  mask), or treats the bit as a class bit whose verdict is exact (class narrowing).

Gate: `scripts/bc2cpp/loadsym_class_check.rb`. Kill switch: `BC2CPP_LOADSYM_CLASS=0`.

## Consequences

* A Symbol held in a register is known to the numeric flow. A `kind_of` test on a value that may be a Symbol removes
  the Symbol on the edge that cannot hold one. The same test on a mixed INT|SYM value now narrows to INT (before, the
  Symbol was unknown and kept both edges, which would have lost the numeric proof the OTHER bit used to get).
* The exact-class run (RETURN_CLASS_TABLE and the other exact consumers) also decides the Symbol bit through the chain,
  so a `kind_of` test on a literal Symbol gets an exact verdict there too. Such a test is claimed by a
  CLASS_NARROWING guard, and a test that can never hold leaves its edge without a value. Output changes are therefore
  in the exact flow as well; the measurements in `docs/bc2cpp-symbol-class.md` record them.
* The numeric return table can track a method that returns a Symbol (`NUMRET name (SYM)`). A caller takes the bit as a
  class bit only through the return value, the same route a frozen-table Symbol already takes (ADR 0289).
* Not done: a frozen table refused for another reason (`frozen_tables_refusal`) allocates no Symbol bit, so a
  `LOADSYM` register stays OTHER there. `LiteralElementProof` still gives a Symbol element of a non-frozen literal
  OTHER. TrueClass and FalseClass literals stay OTHER in the numeric flow.
