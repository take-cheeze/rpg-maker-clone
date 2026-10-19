# 0467. bc2cpp: a cheaper NumericFlow, with the same questions and the same answers

Date: 2026-10-16

## Status

Accepted

## Context

On the wio shipped pass (master a7e439e6, 1m59s wall, 116.6 s user, 756 MB max RSS), StackProf put 37% of the
samples under `NumericFlow.states`. About 21 points of that were the flow's own bookkeeping (`join_state`, `transfer`,
`clear_class_tests`, `refresh_slots`, the `Integer#times` and `each_with_index` blocks inside them), and the rest was
the oracle. GC took another 15%. Per visited instruction the flow allocated a `set` lambda, a `nil_raises` lambda,
`%w[...]` arrays, an `r.to_s` String per register write, a `Set` per narrowed branch, and an `each_with_index.map`
copy per join even when nothing grew; every run also re-checked the supported ops, the ENTER edges and the handler
edges of the irep.

Memoizing `NumericFlow.states` was measured first and not done. An instrumented pass made 23,944 calls on 9,452
distinct (irep, oracle, opaque) keys; the callers already memoize per label (`numeric_states_for`,
`return_class_states`, `return_class_scoped_states`, the scoped return cache) and invalidate when a fixed-point table
grows. A repeated call therefore differs in what the oracle answers, and the only complete key is the oracle's answer
sequence. Checking that key means asking the oracle again, and the oracle is where the rest of the time goes. The
oracle also has side effects whose order matters (class bit allocation, cut counters, `note_class_test`), so answers
cannot be reused without asking. The other remaining case, context flows whose negative answer was computed under a
recursion cut, must not be cached (ADR 0461).

## Decision

`tools/bc2cpp/numeric_flow.rb` keeps its algorithm, its state layout and its oracle protocol, and changes only how it
does the work:

* `NumericFlow::Plan`, built once per irep and stored on the irep like `BytecodeIR.for`. It holds the decoded `Step`
  per instruction (kind, leading register, second register, ivar, branch target index), the supported-op verdict,
  the successor lists with the ENTER edges, the handler edges and the rescue-only targets. It holds bytecode facts
  only, never an oracle answer. A plan whose irep no longer has the instruction list it decoded raises.
* `NumericFlow::Ctx` replaces the per-run Hash: a precomputed opaque-register table instead of
  `opaque.include?(r.to_s)`, and the oracle's optional methods looked up once with `respond_to?`.
* `transfer` dispatches on an integer kind. `set_reg`, `clear_provenance`, `clear_class_tests`, `refresh_slots` and
  `clobber_class_test_copies` are `while` loops with no closures. Clearing every slot test is a single pass, and the
  "aimed at a slot" and "highest register" facts of each recorded test are cached by id.
* `join_state` allocates nothing until the first entry that changes and returns the old state itself otherwise, so
  the worklist tells growth by identity. It keeps the old `nil | nil` result for a nil entry.
* The worklist's queued set is a Boolean array, and a handler's raise state is computed once per instruction instead
  of once per handler target. It needs no oracle question.

Every oracle method except `respond_to?` and the `context_enter_edges` reader is called with the same arguments, in
the same order, as before. `transfer`, `raise_state` and `silent_call?` still accept the old Hash ctx.

## Consequences

Measured:

* Flow alone, with the oracle replayed from a log of 8,000 real calls (859,735 oracle answers) captured from the
  shipped pass: 4.0–4.7 s and 3.3 M allocated objects, against master's flow at 7.7–10.6 s and 9.0 M objects.
  The candidates ran interleaved on a shared 4-CPU host, so the times vary. The results were equal for every call.
* Differential pass: every `NumericFlow.states` call of a full wio shipped pass (26,713 calls, 3,183,080 oracle
  questions) also ran master's flow against a replay of the new flow's answers. The question sequences, the states and
  the writes were identical for every call, and the generated C++ was byte-identical to master's (431,313 lines).
  That pass took 2:20 wall because it ran both flows and StackProf, so its time is not a benchmark. The end-to-end
  time comes from CI's bc2cpp-build job.
* `scripts/bc2cpp/numeric_flow_speed_check.rb` (host only, under 0.1 s) checks four things. The plan is built once and
  reused. A changed oracle answer or opaque set still reaches the result. Every run asks every question again, in
  the same order. A stale plan raises.

Not done, and left for later: the flow still copies the whole state per visited instruction, and bignum class masks
still allocate on every union. Sharing unchanged edge states, and a nil-free fast path in the join, were measured at
about 7% fewer allocations and no clear time win, so they were left out.

## Follow-up: the bytecode facts live on BytecodeIR::Program

Date: 2026-10-16

`NumericFlow::Plan` was a second per-irep cache next to `BytecodeIR.for`. Its analysis-independent part has moved
onto `BytecodeIR::Program` (BYTECODE_IR_FACTS), each built lazily on first use and kept frozen:

* `Program#successor_lists`: each instruction's normal-flow successors. The Program's edges already carry OP_ENTER's
  jumps into its optional-argument JMP table, so `NumericFlow.enter_edges` merged nothing new; it is gone.
* `Program#raise_targets` (instruction index => the distinct handler targets it may raise into, in handler order) and
  `Program#rescue_only_targets` (rescue targets no ensure shares), both from `Program#handler_edges`.
* `Program#decoded` and `BytecodeIR.decode`: per instruction its op, conditional-branch kind (`COND_IF`, `COND_NOT`,
  `COND_NIL`), leading register and resolved branch target index (`Decoded`).

NumericFlow keeps what is its own: `SUPPORTED_OPS`, the step, call and silent kinds, the arithmetic symbols and which
operands an op's rule reads. `NumericFlow.table(program)` derives the supported verdict and the `Step` table from
`Program#decoded` once per Program and keeps it in the Program's one analysis slot, `Program#numeric_flow_table`.
A Program whose irep no longer has the instruction list it was built from (`Program#built_from?`) still makes
`NumericFlow.states` raise.

Other passes now read the same facts instead of rebuilding them: the call-facts flow (`CallFacts::Flow.states`) uses
`successor_lists` and `raise_targets` in place of its own ENTER edges and handler grouping; `successors_of`, the
origin walk's reachability (`origin_reachable`, `origin_closure_reach`) use `raise_targets`; and the record-hash
alias scan takes its branch kind and target from `decoded`. Each is a behaviour-identical substitution: on all 5,019
ireps of the engine's mrblib sources the successor lists, raise and rescue-only targets, steps, `successors_of`
answers and reachability sets are equal to master's, and `NumericFlow.states` returns the same states and writes and
asks a logging oracle the same questions in the same order. The record-hash alias scan keeps its own handler-target
lists, because its depth-first work stack would visit duplicate targets in another order.


## Follow-up: avoid redundant wide-mask and register-name allocations

Date: 2026-10-19

The per-register join compares Integer masks by value with `Integer#eql?`
before forming their union. Equal bignums can have different object identities; when a different
register grows, the whole-array equality fast path cannot skip their union.
The join still copies the old state on growth, preserves provenance only when
both edges agree, and retains the existing behavior for nil entries and invalid
non-Integer masks. It does
not share incoming edge states or cache oracle answers.

An empty opaque-register set now builds an all-false register table directly,
without converting every register number to a temporary String. Nonempty sets
use the same canonical string membership checks as before.

A Ruby 4.0.5 + YJIT Wio whole-engine pass against `d3296ff5`, with all compiled
gem owners, `BC2CPP_HOT_ONLY=0`, no hot-method list and warmed scan caches,
measured 78,856,464 allocated objects before and 77,919,603 after (936,861
fewer, or 1.19%). Elapsed time was 41.27 s before and 40.65 s after; a single
pair is insufficient to attribute that difference to this change. The 20,909,643-byte generated C++ and diagnostics
with timing lines removed were identical. This excludes RBS regeneration and
C++ compilation.

The host flow check covers 2,000 randomized joins including wide and negative
masks, preservation of the old states and provenance, nil behavior, and empty
and nonempty opaque sets. Existing flow cases verify oracle question order,
loops, changing answers and captured-register handling.
