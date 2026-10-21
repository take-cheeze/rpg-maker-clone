# 0535. bc2cpp: prune the instructions no edge reaches, in two stages

Date: 2026-10-21

## Status

Accepted. Stage A is on. Stage B is opt-in (`BC2CPP_PRUNE_ARMS=1`) and off by default.

## Context

The decided-branch folds (ADR 0532) keep a dead arm's text after a fold: a taken fold keeps the fall-through, and a not-taken
fold keeps the jump's target. The arm that no edge reaches is still compiled. A fixture measurement found two such
instructions in 70 (`Router#route`), and the engine count is not measured here (it needs the closed-world CI build).

## Decision

`CodeGen#arm_prune_analysis` (tools/bc2cpp/codegen_arm_prune.rb) computes the instructions of a method's own body that no
edge reaches. Its graph uses the operands the emitter writes (`goto`), the catch-handler edges, and the decided-branch
outcomes, so a decided jump keeps only the edge it takes. An unknown opcode falls through. A graph that cannot be built
exactly (an unresolved jump or handler target) is refused.

- **Stage A (always on).** The set is counted into `CodeGen.arm_prune_stats`. The C++ does not change. On the fixtures
  the output is byte-identical to master, with register flow on and off.
- **Stage B (`BC2CPP_PRUNE_ARMS=1`).** The text of an unreachable instruction is replaced by a placeholder while the method
  compiles, and is either dropped or restored at the end. A method is refused, and keeps every instruction, when:
  - a body with another per-instruction emitter is active (a suppressed range, a glue or prefix emitter, a guarded inline
    site, register-flow capture, or a resumable step);
  - a pruned text declares a name outside its own balanced `{ ... }` block, since live code could still name it, or its
    braces do not balance.
  Refusals are counted in `CodeGen.arm_prune_refusals`.

The analysis covers a method's own body only. A block body's registers are offset into its enclosing frame, so its
reachability is not derived here; block bodies are left unchanged.

## Consequences

- Stage A is measurement only. Its counts are not in the C++, so it cannot change behaviour.
- Stage B changes the C++ only for methods it can prove safe, and only when it is turned on. On the fixture it drops exactly
  the two instructions the folds make unreachable.
- Stage B is refused for any method that register flow captures. That is the common case, so stage B applies to few
  methods until register-flow capture is modelled. The fixture check runs with `BC2CPP_REGISTER_FLOW=0` for this reason.
- The declaration check is a text heuristic. A missed declaration would show as a g++ error in CI, not as a silent
  change. g++ was not run on a full translation unit here.
- Not measured: the engine count of pruned instructions and refusals, and the effect on compile time.

## Follow-up

- Model register-flow capture so stage B applies to methods that register flow captures.
- Extend the analysis to block bodies, using the block's own offset numbering.
- Measure the engine count and turn stage B on only after the closed-world CI build and the differential runs pass with it.
