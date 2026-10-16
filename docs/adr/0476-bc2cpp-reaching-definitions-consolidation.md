# 0476. bc2cpp: backward register walks ask BytecodeIR's reaching definitions

Date: 2026-10-16

## Status

Accepted (Part 1). Part 2 (a shared forward-dataflow engine) is Proposed and not built.

## Context

`BytecodeIR::Program#reaching_definitions` (`tools/bc2cpp/bytecode_ir_dataflow.rb`) answers "which writes can supply
register R at instruction I" exactly over the normal-flow CFG and refuses (nil) on anything it does not model. Several
passes still answered the same question with their own backward walk and their own op whitelist. The biggest was
FIXNUM_OPERAND_PROOF (`CodeGen#proven_fixnum_operand?`). It ran a textual single-path walk
(`IrepScans#walk_writers` with an unaudited-op barrier), a REGION_DOMINANCE test, and, when the write did not
dominate, a second worklist (`fixnum_proof_reaching_defs?`) over `FIXNUM_PROOF_STEP_OVER_OPS`. That list was a copy
of `BytecodeIR::WRITES_LEADING_REG_OPS`, kept equal by a check.

Checking the walk against an exact forward fixpoint found a soundness bug. When the single-path walk crossed a MOVE
and then failed the dominance test, the fallback asked about the MOVE's source at the MOVE. That MOVE need not lie on
any path to the use:

* `i = num.to_i; while i >= m; ...; i -= 1; end` (Integer#downto, `bsearch_index`, `Range#each`): the walk followed
  `MOVE R5 R4` and `MOVE R4 R5` back to the `to_i` send and asked about R5 at the second MOVE. The loop's
  `SUBILV R4` write never reached that question.
* `obj = cond ? Generator.new(...) : NONE` (Enumerator#initialize): the walk followed `MOVE R1 R7`, which sits before a
  `JMP` that leaves the branch, and so read the other branch's write.

Over the engine's mrblib (5,394 ireps, closed world plus the wolf/rpgxp/rpgvx/mvjs gems), 520 of the 53,761 operand
questions codegen asks (arithmetic operands, send receivers and arguments, returned registers) got a definition set
from master that does not match the exact one.

## Decision

### FIXNUM_OPERAND_PROOF

`proven_fixnum_operand?` keeps its use check: the use is an audited op outside every protected range. Then it asks
`Program#every_reaching_definition(idx, reg, opaque_regs: <the child subtree's SETUPVAR destinations>)`, and every
definition must prove. An ENTRY definition goes to `fixnum_proof_entry_arg?` and any other definition to
`fixnum_proof_source?`, as before. A dominating write is the one-definition case, so the single-path walk, its
`need_idx` bookkeeping and `fixnum_proof_reaching_defs?` are deleted. The state cap is
`max(DATAFLOW_MAX_STATES, 2 * instructions)`, which stays linear in the body. The old single-path walk had no cap;
with the fixed cap, one 1,075-instruction method would lose a proof.

`FIXNUM_PROOF_STEP_OVER_OPS` *is* `BytecodeIR::WRITES_LEADING_REG_OPS`.
`FIXNUM_PROOF_READONLY_REG_OPS` is `READS_LEADING_REG_OPS & FIXNUM_PROOF_STEP_OVER_OPS`, which is JMPIF, JMPNOT and
JMPNIL. The text check that kept the two lists equal now checks the derivation instead
(`scripts/bc2cpp/origin_transfers_check.rb`).

### Two modelling facts for every caller of the default walk

Without these two facts the switch would have lost proofs that master's walk had right:

* **A JMPUW outside every protected range is a plain jump.** vm.c OP_JMPUW runs an ensure only when the ensure's
  range covers the JMPUW. A protected JMPUW is still refused: by the guard in the default walk, and by
  `:unwinding_jump` under `through_handlers`. `dataflow_effect` answers `:pass` for it, and the origin walk's
  separate JMPUW case is gone because it was the same rule. A `break` out of a `while` compiles to this kind of
  JMPUW.
* **A predecessor no execution reaches supplies nothing to a live state.** The origin walk already skipped such
  predecessors (`origin_reachable`, over normal and handler edges). The default walk now does too, but only from a
  live state. A dead query keeps every predecessor, so the answer is never a vacuous `[]`. mrbc leaves dead `JMP`s
  after a `return` inside a branch.

Both facts change answers only from a refusal to an answer. Over every register operand of every instruction of the
engine's ireps (191,316 questions per mode), the default, `follow_moves: false` and `through_handlers` walks answer
561, 361 and 610 more questions than master. No answer changes and none is lost. `Program#may_write?` (NIL_NARROWING,
the captured-parameter rule) no longer counts an unprotected JMPUW as a write. NIL_NARROWING's normal JMPUW edge
still proves nothing (`edge_out`).

The walk also allocates less per state. It uses per-index guard and liveness flags, predecessor Arrays, a flat
(index, register) stack, and a lazily built per-instruction `EffectEntry`, which `dataflow_effect` shares. Its answers
are unchanged.

### Walks reviewed and kept

| Walk | Why it stays |
| --- | --- |
| `CodeGen#fixnum_interval` (NUMERIC_CONSTANT_RANGES) | Same single-path shape. Its answers are identical on the engine. Its `why` leaves feed the native-int probe, and two mutation checks pin its join and protected-range refusals by source text. Moving it means re-targeting those mutants. |
| `CodeGen#guarded_game_integer_range` | Skips every non-arithmetic writer (`KEEP`) to find an earlier one. That is not a reaching-definition question, and its consumers guard at run time. |
| `CodeGen#return_value_sources` (RETCLASS_NILABLE_JOIN) | Walks through protected ranges and refuses only at catch targets. It reads a RAISEIF fall-through as nil. The default walk refuses protected ranges, and `through_handlers` adds the raise-before-write value, so neither answers this question. |
| `CodeGen#return_write_dominates?` / `straightline_return_reg?` | `Program#write_dominates?` refuses ENTER's packed R1 and every non-argument slot, so switching would lose return proofs for `def f(x) = x`. |
| `IrepScans#walk_writers` / `last_writer` / `source_writer` / `constant_path` (about 80 call sites) | Mostly class bodies, registry and report scans that ask "the nearest textual writer" by design (`walk_dominating_writers` adds dominance where a consumer is unguarded, ADR 0261). Switching them changes registry output in both directions, because the default walk refuses multi-write frames those scans step over. Each needs its own review. |
| `IntegerConstants.const_source_kind` | Walks a class body with a jump-target barrier, the same rule as its SETCONST entries. |
| `ENTRY_ARG_CALL_OPS` / `ENTRY_ARG_DEF_OPS` / `ENTRY_ARG_CLASSIFIED_OPS` | Classify the ops that carry a `:name` operand. They are not register walks. `CodeGen::CLASS_OBJECT_DEFINING_OPS` happens to equal `ENTRY_ARG_DEF_OPS`, but it serves another audit. |

### Part 2: a shared forward-dataflow engine (design, not built)

Three passes run their own forward worklist over the same `Program` facts (`successor_lists`, `raise_targets`,
`rescue_only_targets`, `decoded`):

| Pass | Loop | Lattice and join | Specialisations in the loop |
| --- | --- | --- | --- |
| `NumericFlow.states` (997-line file, 8 call sites, about 26,700 runs per wio pass, ADR 0467) | ~60 lines, FIFO, Boolean queued array | dense mask Array, union below `prov_base`, equality above; `join_state` returns `old` itself when nothing grows | raise state computed once per instruction; per-edge refinement (`step_refine_edge`); class-test threading that redirects the successor; `context_edges`; no-return calls drop normal successors |
| `CallFacts::Flow.states` (9 call sites) | ~25 lines, FIFO, `Set` queued | [copy-origin Array, facts Array], intersection | raise edge = join(raise_state, out) |
| `RecordHash#alias_scan` (5 call sites) | ~20 lines, LIFO, `seen` of (index, alias set) | none: it enumerates (index, set) states up to `STATE_LIMIT = 4000` and fails fast | per-branch truthiness edge (`edge_states`); handler edge carries `state ∪ next` |

The proposed shape is `BytecodeIR::Forward.run(program, spec)`. `spec` answers `entry`, `transfer(i, state)`,
`join(old, new)` (returning `old` itself when nothing grows), and optionally `edge(i, s, out)` (nil drops the edge,
which covers refinement and no-return calls), `raise_edge(i, in, out)` and `redirect(i, s, edge)`. The engine owns
the FIFO, the Boolean queued array and the identity change test.

Measured with a prototype (scratch only, not committed): `CallFacts::Flow.states` on that engine, with a duck-typed
spec object, against the specialised loop. Over all 5,372 supported engine ireps ×3 the states were equal and the
times were 0.85×–1.09× of the loop's in five interleaved runs on a loaded 4-CPU host. That is noise: the loop is not
where CallFacts spends its time.

Risks and recommendation:

* **Speed.** ADR 0467's 2× came from removing closures and allocation from NumericFlow's transfer and join
  (integer step kinds, `while` loops, identity joins), not from the worklist skeleton. An engine that calls
  `spec.transfer` by method dispatch keeps that, but a Proc-per-hook design would put a block call on every edge of
  the pass that runs 26,700 times. Hooks must be methods on a spec object, and NumericFlow's
  `step_refine_edge` / `step_thread_class_test` must stay inlined behind a single `edge` hook.
* **Fit.** `alias_scan` is not a fixpoint over a lattice. Moving it onto a join (the union of alias sets) changes
  when `STATE_LIMIT` trips, so it is not byte-identical and stays out.
* **Payoff.** About 85 lines of loop code across two passes. Do it when a fourth forward pass arrives, or together
  with a NumericFlow change that is already re-verified differentially (ADR 0467's replay harness), not on its own.

## Consequences

* FIXNUM_OPERAND_PROOF answers 520 engine questions differently, and in each case master's walk disagreed with the
  exact fixpoint. Where the new set has more definitions, some proofs disappear. Where the old set held a write that
  cannot reach the use, a proof may appear or disappear. It also proves 472 questions master refused: joins with an
  unaudited op in another branch, `break` JMPUWs, and dead predecessors. It refuses 7 that master answered. All 7 are
  RETURNs left dead after a RETURN_BLK or BREAK, where `fixnum_return_sites_proven?` already fails on that op. So the
  generated C++ changes. Unchecked `mrb_fixnum()` calls on loop-carried values that may overflow become dual-path,
  and more joins compile native. NOMETHOD_REVIEWED, STRICT_HINTS_REVIEWED and PROVEN_MISS entries may go stale, and
  CI names them.
* The equivalence harness (`walks.rb`, `check.rb`, `rd_dump.rb`, run outside the repository against a master copy)
  checks every new answer against an independent forward reaching-definitions fixpoint with copy propagation,
  poisoned multi-writes and unmodelled ops, and poisoned handler entries. It runs in about 15 s. Given master's walk
  as the new walk, it fails on the 527 questions above, so it is a working negative control.
* Speed: on the first ask, the proof costs 1.6–1.8 s against master's 0.8–0.9 s over the 53,761 questions. Repeat
  asks hit `reaching_definitions`' cache and cost 0.3–0.4 s against 1.0 s. Codegen asks most operands more than
  once (`compiles_clean?` probes, the ENTRY_ARG/FIXNUM_RETURN alternation), and at two asks the costs are equal.
* `fixnum_proof_region_ok?`, `fixnum_proof_edge_sources` and `ctx[:entries]` remain for the kept walks.
  `fixnum_barrier_shadow.rb` loses its hook on the deleted method.
