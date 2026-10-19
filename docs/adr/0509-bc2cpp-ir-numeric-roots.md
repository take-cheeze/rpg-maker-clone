# 0509. bc2cpp: numeric roots come from reaching definitions

Date: 2026-10-19

## Status

Accepted

## Context

`BC2CPP_NUMERIC_ROOTS` (ADR 0311, `tools/bc2cpp/codegen_numeric_roots.rb`) reports, for every guarded numeric
operator that NumericFlow could not prove, the leaves each unproven operand is computed from. Its walk kept a
private worklist: the textually nearest earlier writer of the register, plus every later MOVE or arithmetic writer of
the same register (for loop-carried values). Neither part follows control flow:

- a join (`x = h[k] || 0`, an `if` with a write in one arm) loses the writes of every arm but the textually nearest;
- a write later in a loop body that is not a MOVE or arithmetic op (a SEND, an ivar read) is missed when it reaches
  the read through the back edge;
- a later arithmetic or MOVE write of a register that is reused for an unrelated value is attributed to the read even
  though it cannot reach it;
- a write made inside a closure (`SETUPVAR`), or a value seen through an exception handler, is not visible at all.

BytecodeIR already answers the question the worklist approximates: `BytecodeIR.reaching_definitions`
(`bytecode_ir_dataflow.rb`) returns the set of writes that can supply a register at an instruction, through joins,
loops and (with `through_handlers:`) handler edges, or refuses with a cause when the model cannot account for a state.

Output of the measurement is not generated code, but the numbers it reports drive the choice of which operands to
build (ADR 0311 and its successors), so a wrong leaf set sends a reader to the wrong root.

## Decision

`CodeGen#numeric_root_leaves(irep, at, reg, owner_def)` now takes the leaves of `reg` as read by instruction `at`
(the state before it) from `BytecodeIR.reaching_definitions(irep, at, reg, through_handlers: true, refusal:)`:

- each definition is a writer whose operands are queried at the writer (`ROOT_ARITH`, `ROOT_ARITH_IMM` and
  passthrough sends), or an entry value (`param:`) when it is the method's argument; MOVEs are followed by the query;
- a query the IR refuses contributes `unproven:<cause>` as a leaf, so an unknown set is never reported as empty;
- the caller convention moves from "inclusive of `idx - 1`" to "the read instruction `idx`" (`numeric_root_probe`,
  the tuple dump, the parameter-status and flow-fail culprits, `native_int_arg_leaves`).

The GETIDX key and AREF labels still name the textually nearest writer. They are names, not feed sets, and changing
them would change every label in the dump; they are left for a follow-up.

The generated C++ does not change: `numeric_root_leaves` feeds only the `BC2CPP_NUMERIC_ROOTS` and NINT diagnostics.

### Measurement

Shipped whole-program pass (`coverage_report.rb`, `SKIP_UNSUPPORTED=1`), 2,627 rows (2,520 `ROOT`, 107 `TUPLE`). Rows
are paired by position (the keys match on every row). "Visited" writers are the writer instructions and entry values
each walk reached, recorded in a scratch-only instrumented copy of both trees.

| Class | Rows |
| --- | ---: |
| Identical | 641 |
| Old visits writers that cannot reach the read (over-attribution only) | 1,340 |
| Old misses reaching writers (with or without over-attribution) | 558 |
| New refuses (`unproven:` leaf) | 88 |
| **Changed** | **1,986** |

Of the 1,340 over-attribution rows, 31 keep the same leaf multiset and differ only in order (the extra visited writers
produce no leaf). Of the 558 omission rows, 25 have no over-attribution at all.

The 88 refusal rows name these causes (a row can name two): a register written by a nested block (`opaque_reg`,
57 rows), an unmodelled `EXCEPT` on a handler path (22 rows), the 400-state cap (10 rows), an unmodelled `RESCUE` (3 rows).

### Per-class decision

Each row's class is fixed by which writers each answer visits, so the decision per class follows from the
reaching-definition answer. Examples below were read against the source; the other rows were not read one by one.

- **Over-attribution: the new query is right.** Example: `Array#include?` (`mruby-rgss/mrblib/array_include.rb`).
  The `<` operand `n` (R6) is overwritten at index 5 on every path, but the textual walk also visited the later
  `MOVE R6 R1` (the `obj` argument, read by `EQ`), reached the argument's entry value, and reported `param:r1`.
  The reaching-definitions answer is `send:length` only.
- **Omission: the old answer was unsound.** Example: `Game::Interpreter#monster_change_amount`,
  `cmd.param(3) * (battler.hp || 0) / 100`. The `*` operand joins a `battler.hp` send and the literal `0`; the textual
  walk saw only the literal and lost the send.
- **Refusal: the new answer is honest, the old one was incomplete.** A nested block can write the register at any
  time once it exists (`opaque_reg`), a rescue body can see values from before the protected write, and the old walk
  reported only the textual neighbour in each case. The refusal is a leaf so the consumer can see it.

## Consequences

- `BC2CPP_NUMERIC_ROOTS` output changes: 1,986 of 2,627 rows, in the directions above. The change is an unsoundness
  fix of the measurement, not a generated-code change; the shipped C++ is byte-identical between master and this
  branch under the same directory layout.
- Some rows become less informative (`unproven:` in place of a list), because the IR refuses closure- and
  rescue-touched registers. Counting those as "known" would be the unsound choice.
- Cost: each leaf query runs `reaching_definitions` with a `refusal:` hash, which bypasses its cache. The
  diagnostic runs only under the env var (and NINT lines), so the default build is unaffected.
- Not done: the GETIDX key and AREF labels still use the textual walk; the NINT leaves
  (`codegen_native_int_args.rb`) changed with the same walk and were not measured separately.
- Follow-up: the `||`/`&&` join and rescue cases are the ones that would matter for a root that is currently
  unproven only because its leaf is missing; re-measure when a consumer starts reading these leaves.
