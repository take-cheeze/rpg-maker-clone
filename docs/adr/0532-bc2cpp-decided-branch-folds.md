# 0532. bc2cpp: fold conditional jumps the flow decides

Date: 2026-10-21

## Status

Accepted

## Context

A conditional jump on a register whose value the NumericFlow state already fixes (always truthy, always falsy, or
exactly nil) still compiled to a runtime `if (mrb_test(rN))`. The flow's masks prove the outcome; the emitter did not use
them. Earlier measurement with the Ruby checks showed the hot predicates are mostly not constant, so the gain is limited to
the proven cases, and the proof has to come from the flow rather than from observed runs.

## Decision

`CodeGen#decided_branch_outcome` (tools/bc2cpp/codegen_decided_branch.rb) reads the flow's mask of the tested register
before a `JMPIF`, `JMPNOT` or `JMPNIL` (`numeric_raw_mask`):

- a mask with no `NIL` and no `OTHER` is truthy on every path, since `OTHER` holds `false` and every unknown value;
- a mask of exactly `NIL` is falsy on every path;
- `JMPNIL` is taken exactly when the mask is `NIL`, and never when it has no `NIL` bit;
- a mask of 0 (unreached) decides nothing, and any other mask keeps the test.

A decided taken jump emits `goto` with a `DECIDED_BRANCH` comment. A decided not-taken jump emits only a comment. Nothing
is cut: the fall-through code stays, so no jump-edge check is needed. The fold is applied on the `compile_insn` path only
when `reg_offset` is 0, because a shifted instruction names the enclosing frame's registers. The loop-region emitter reads
the unshifted register at its real index, so it is folded as well. `BC2CPP_DECIDED_BRANCH=0` restores every test.

## Consequences

- On the engine, the closed-world build folds 126 conditional jumps in the rpg2k generated file: 41 taken `JMPIF`s become a
  `goto`, and 85 not-taken tests are removed (75 `JMPNIL`, 10 `JMPNOT`). The `mrb_test(` count drops by 51 and the
  `mrb_nil_p(` count by 75 against the same build with `BC2CPP_DECIDED_BRANCH=0`. Each fold removes exactly the test it
  replaces. An earlier figure of 57 came from a setup that could not be reproduced and is withdrawn.
- The default build strips `//` comments (CompactOutput, ADR 0463), so the `DECIDED_BRANCH` markers are absent from its
  output. The taken folds' `goto`s and the removed tests are still there. Generate with `--annotated` to see the markers.
  `scripts/bc2cpp/decided_fold_count.rb` counts the markers and checks the drops against the folds. Its check,
  `decided_fold_count_check.rb`, runs without `mrbc`.
- Folding does not remove code, so the generated C++ keeps its unreachable arms and labels. A later change could cut
  arms that no edge reaches, using `BytecodeIR` jump edges; that is not done here.
- The fold trusts the NumericFlow masks. A wrong mask would now change control flow, not only a proof, so soundness rests on
  the flow's own tests. `scripts/bc2cpp/decided_branch_check.rb` checks the four decided and three undecided shapes
  of one fixture, and the gate.
- `decided_branch_check.rb` needs a host `mrbc` and is not in the coverage reporter's `CHECKS`, because the reporter
  runs without `MRBC`.
