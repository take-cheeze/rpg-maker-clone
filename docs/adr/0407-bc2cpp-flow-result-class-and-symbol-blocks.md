# 0407. bc2cpp: use the flow's core class for call-result receivers; Symbol block arguments

Date: 2026-10-12

## Status

Accepted

## Context

The coverage run lists 164 dynamic sites whose receiver is the result of another
send (`send_result` origin). Measuring them against the exact-class flow
(ADR 0289) showed three causes, none of them a project `def keys`/`def map`:

1. The flow already proves the receiver exactly Array/Hash/String/Range (`h.keys`,
   `.values`, `x.to_s`, a core `select`), but `compile_send` only consulted that
   proof when the receiver trace (`trace_new_target`) had named the same class, and
   a call result has no trace. 31 `map`/`keys`/`reject`/`select` sites were in this
   state or in cause 2 or 3. 12 of them went away with the rules below.
2. `list.reject(&:dead?)` compiles to `LOADSYM` plus `SENDB`. The core-body
   specialization (ADR 0338) accepted only a literal `BLOCK` writer, so every
   Symbol-block collection call returned an unknown class.
3. `Game::Battle#turn_order` ended in `each_with_index.sort_by { }.map { }`; the
   blockless call is an Enumerator, which the flow cannot name, so the result
   (and with it the `@queue` class pool) was unknown.

The remaining 19 `map`/`keys`/`reject`/`select` sites have an unproven
receiver (parameters, hash elements, project attr readers: about 12 `OTHER`),
an Array-or-Hash union (3), or are the else arm of a compiled core body's
BLOCK_CORE_DIRECT (2). A name-wide claim withdrawn by an unrelated `def map`
is not among them: these are receiver-class gaps, which a receiver-aware rule
cannot close without a receiver class.

## Decision

* EXACT_FLOW_RESULT_CLASS: when the trace names no class and the flow proves the
  receiver exactly one core class (non-nil), that class is the receiver class of
  the typed lookup. The existing EXACT_TYPED path then calls the Array/Hash/String/
  Range body with no class test and no fallback. A nilable flow set still goes
  through NILABLE_RECEIVER. `BC2CPP_EXACT_FLOW_RESULT_CLASS=0` withdraws it.
* SYMBOL_BLOCK_ARG: a block register written by a dominating `LOADSYM` is as safe
  as a literal block without `break` (calling a Symbol proc cannot replace the
  callee's result). A block held in a local, forwarded, or chosen by a join is
  still refused. `BC2CPP_CORE_RUBY_SYMBOL_BLOCKS=0` withdraws it.
* `turn_order` collects its sort keys into a literal Array and sorts that; the
  order is identical (Array#sort_by breaks key ties by position). `@queue` is now a
  class pool (ARR).

No proof was weakened and no reviewed-list entry was added.

## Consequences

Shipped Wio `bc2cpp_send(M` live sites 1885 -> 1840 and `mrb_funcall*` 389 -> 382
(same tree and submodules; 1835 -> 1790 and 386 -> 379 on the earlier tree).
Roughly 16 sites come from the flow class, 24 from Symbol blocks and 5 from
`@queue`. `send_result` origins 164 -> 137. These are static counts.

`exact_receiver_flow_check` (generated code, nil and union negatives, kill switches,
full-core parity) and `core_ruby_results_check` cover them; three and two mutants
were added to the respective mutation checks.
