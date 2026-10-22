# 0536. bc2cpp: the IR constant facts for `.freeze` literals and constructed values

Date: 2026-10-21

## Status

Accepted. Records the status of the two gaps ADR 0501 named under stage 1. It changes no generated code.

## Context

ADR 0501 (stage 1) said the IR constant facts did not model `.freeze` on literal containers or constructed
`RGSS::Color` / `RGSS::Rect` values, and counted 86 and 7 class disagreements against the proofs of a closed build.
Two things have changed since: stage 2 added the container freeze gate, and the stage 1 text was never updated.

## Decision

1. **`.freeze` on a literal Array, Hash or String is modelled.** `ConstantFacts` answers the receiver's class for a
   `freeze` whose class is in `freeze_classes`, the stock-freeze gate bc2cpp.rb already computes. `bytecode_ir_constants_check.rb`
   asserts this (`LIST.freeze` is class Array with no value). The stage 1 "not modelled" assertion is rewritten to the
   current behaviour. No change to the fact computation was needed.

2. **Constructed values (`Foo.new(...)`) stay unknown.** A class constant's name is poisoned by its CLASS op, so the
   receiver of `new` has no fact, and the binding has no class. Modelling it needs class identity: the defining CLASS op,
   the absence of any reopening or `SETCONST` of that name, and a stock `Class#new` / `allocate` on that class and its
   ancestors. That analysis does not exist, so the constructed case is not modelled. The check asserts the current
   behaviour (`CLR = Foo.new(1)` has no class), so a later model that gives a class has to change that assertion on purpose.

3. **Why the constructed class would not change generated C++ anyway.** `CodeGen.constant_value_classes` admits only a
   single-class fact of Array, Hash or String (bc2cpp.rb, the `constant_value_classes` block). A constructed `Color` or
   `Rect` class is filtered out there, and the integer class set (`integer_class_names`, ADR 0534) admits only Integer.
   Their consumers therefore stay unchanged when the class is added. The guard is in the consumers, not in the facts.

## Consequences

- The 86 `.freeze` disagreements of stage 1 were not re-measured here. Re-measuring needs the closed-world build log
  (`scripts/bc2cpp/ir_constant_facts_compare.rb BUILD_LOG`), which CI produces and this sandbox cannot. The fixture check
  shows the literal case is modelled, so the count is expected to be lower than stage 1 reported.
- No generated code changed. The fixture check passes 23 of 23 (host `mrbc`), and the only change is to the check.
- Still open: class identity for constructed values (point 2), and the stage 3 `DeclaredConstants` retirement, which needs
  the closed-world run ADR 0533 describes.
