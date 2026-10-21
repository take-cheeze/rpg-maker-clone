# 0533. bc2cpp: which constant proofs ADR 0501 stage 3 can retire

Date: 2026-10-21

## Status

Accepted. Stage 3 is not done: this records what the audit found and why no code was removed.

## Context

ADR 0501 stage 2 made `BytecodeIR::ConstantFacts` the source of the Fixnum-admitted names, the folded values and the
intervals. Stage 3 asks to remove the proofs the IR replaces. Before removing anything, the audit checked which of
them still reach generated code, and which only reach scripts.

## Decision

No code is removed in this change. The removal is deferred until the proofs below are replaced or their oracles are
retargeted, and generated-code evidence exists for each step.

What the audit found, by reading the live call graph of `tools/bc2cpp/bc2cpp.rb`:

- `IntegerConstants.analyze` is not called by the build. Its only callers are `scripts/bc2cpp/const_bitor_io_check.rb`
  and `scripts/bc2cpp/constant_typing_check.rb`, which use it as an in-process oracle against the IR facts.
  `IntegerConstants.class_admitted` (report-only, `integer_class_constants` for the type check) and
  `analyze_values` depend on the same resolver.
- `IntegerConstantRanges.analyze` (with `explain`, `resolve`, `source_kind`, `arith_kind`, `eval_kind`, `aliases`) is
  not called by the build. Its only caller is `constant_typing_check.rb`. The build still uses `enabled?`,
  `integer_ops_safe?`, `literal` and `combine`, which are arithmetic, not constant proofs.
- `DeclaredConstants.check` is still live (`bc2cpp.rb`, the `sig_loaded` block). It adds RBS-declared names to
  `integer_constants`, containers to `container_constants`, and elements to `ir_const_elements`. These are facts the IR
  does not derive, so removing it would change generated code wherever a declaration adds a name.

Removing the two analyzer families would delete the oracles these checks compare against. Their comparison would then
be the IR with itself, which no longer verifies anything. Retargeting them to the IR is therefore a separate step, not a
deletion. `DeclaredConstants` cannot be retired until stage 4 gives the IR the declared facts or the declarations are
shown to add no name the IR lacks. That second condition is not measured here.

## Consequences

- Stage 3 stays open. The next step is to retarget `const_bitor_io_check.rb` and `constant_typing_check.rb` to the IR's
  own rows, with the old analyzers kept as fixtures only until the retargeting is checked.
- Retiring `IntegerConstants.analyze` changes only the type-check report (`class_admitted`), not generated code. This
  should be verified with a type-check diff before it is removed.
- Not measured: whether RBS declarations add any name beyond the IR. It needs a closed-world run with the signature set.
