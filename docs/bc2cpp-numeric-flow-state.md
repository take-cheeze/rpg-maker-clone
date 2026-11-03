# NumericFlow state deltas

`NumericFlow.states` (`tools/bc2cpp/numeric_flow.rb`) keeps one class-mask state
per instruction: a flat Array of Integer masks (registers, ivar slots, element
masks, provenance, class-test ids). Every instruction that wrote anything used to
`dup` its entry state and edit a few entries, and the flow kept that copy as the
next instruction's state. On the sealed Optcarrot compile that was about 78,000
Arrays of about 90 entries each (two objects per copy: the Array and the shared
root `dup` creates), and nearly all of them survived into the result.

Copying differently does not help (`[*state]` and `[].concat(state)` were both
measured and rejected). This change alters what is kept.

## Representation

The worklist, the visit order (`worklist_rank`), every transfer, edge refinement,
join and oracle question are unchanged. Two things differ:

- **Scratch buffers.** Each run has two scratch Arrays. A transfer that writes gets
  its copy from `NumericFlow.fresh`: the spare buffer, filled by a splice
  assignment (`buf[0, size] = state`), which neither allocates nor shares a buffer,
  unlike `dup` and `replace`. The transfer still reads its input and writes the
  other buffer, so read-before-write order is unchanged. Edge refinement, raise
  states and joins still `dup`; they are rare.
- **VIRTUAL chain states.** `chain_links` marks instruction *s* when the flow's only
  edge into it is the fall-through from *s − 1*, and *s − 1* is neither a branch nor
  `RAISEIF`, so `step_refine_edge` and `step_thread_class_test` return that edge
  unchanged. If *s − 1*'s out state is in a scratch buffer and *s* has not been
  reached, `ins[s]` becomes `VIRTUAL` (`false`). Instead of the Array, the run logs
  the entries where the out state differs from *s − 1*'s entry state: a count, then
  (position, value) pairs in one flat Integer log. Any other state that is stored
  (join points, handler targets, refined edges, `outs`) is copied out of the
  scratch buffer with `materialize`.

The next visit reads *s*'s entry state from the scratch buffer it was just written
to (the cursor). If another visit came in between, it is replayed into a scratch
buffer from the nearest Array before *s*.

The result is a `NumericFlow::States`. `#[]` returns a stored Array as before. For a
`VIRTUAL` entry it builds the Array once, from the nearest Array or already-built
entry before it plus the logged deltas, and keeps it. `#each`, `#to_a` / `#to_ary`
and `#==` make it compare and iterate like the Array it replaces, so
`old_states != node.states` (`ir_context_results.rb`) and the leaf-evaluation
snapshot are unchanged.

`BC2CPP_NUMERIC_STATE_DELTAS=0`, or `deltas: false`, restores the copying
worklist. `share_states: false` uses it too.

## Why it is sound

- **A VIRTUAL entry never changes.** Its only edge comes from *s − 1*, which is
  revisited only after `ins[s − 1]` changed. Every assignment to a reached
  `ins[t]` first calls `unvirtual(t, old, …)`, which turns a `VIRTUAL` `ins[t + 1]`
  into an Array, computed from the old `ins[t]` plus *t*'s delta. So a join never
  meets a `VIRTUAL` state (the flow raises if it does), and the delta of *s − 1*
  is never overwritten while `ins[s]` depends on it. `chain_links` counts context
  ENTER edges and handler edges. A threaded class-test edge always targets the
  successor of a branch, which is never a chain instruction.
- **`outs` keeps its meaning.** `outs[s − 1]` stays nil while `ins[s]` is
  `VIRTUAL`, since their contents are equal. `unvirtual` stores the materialized
  Array in both slots, as the sharing flow did, so `outs[i] == out` skips
  propagation exactly as before.
- **Identity.** A transfer that writes nothing still returns its input. When that
  input is a stored Array, the successor shares it as before; only scratch states
  become `VIRTUAL`. `copy_reg_write`'s `equal?` "unchanged" contract is the same.
- **Scratch buffers do not escape.** Oracles receive the input state during a
  transfer, and the input is not written during that transfer. An audit of every
  oracle method that receives a state (`send_mask`, `block_send_mask`,
  `super_mask`, `class_test`, `preserves_ivar_slots?`, `block_element_mask`,
  `array_mask`, `hash_mask`, `index_mask`, `aref_mask` and `operator_mask` in
  `codegen_numeric_proof.rb`, `codegen_return_classes.rb`,
  `codegen_core_ruby_results.rb` and `ir_context_results.rb`) found none that
  keeps the Array itself. They read entries, copy it (`state.dup`), or keep a
  slice copy (`ir_context_results` array/hash shapes). The equivalence harness
  below copies every state argument at call time and compares the copies too.
- **A frozen buffer is replaced, not written.** `numeric_flow_speed_check`
  freezes every state at the solver boundary, and the flow then uses a new
  buffer.

## Consumers

Every reader of a result reads `states[i]` and then a few registers of it, or
passes it to an oracle: `numeric_raw_mask`, `numeric_upvar_mask`,
`exact_flow_mask`, `exact_flow_class`, `return_class_raw_mask`,
`bytecode_ir_call_result_classes`, the `NumericClasses.exit_mask` family,
`return_class_context_upvar_mask` and `ir_context_results#readonly?`.
`ir_context_results` also compares whole results (`!=`), and
`IrContextLeafEvaluations` maps and sums them. None mutates a result state, and
none relies on two results being the same object. On Optcarrot, 2,309 runs were
queried at 6,128 distinct (run, instruction) points. Only those `VIRTUAL` entries
are ever built.

## Equivalence

A `ruby -r` hook ran both worklists on every `NumericFlow.states` call, through
recording proxies of the same oracle. It compared every per-instruction state,
the `writes` side table, and the full oracle question log, with each state
argument copied when the oracle was called:

| World | Runs | States compared | Oracle calls compared | Differences |
| --- | ---: | ---: | ---: | ---: |
| Sealed Optcarrot | 2,309 | 112,974 | 226,347 | 0 |
| Closed rpg2k build | 58,253 | 2,955,861 | 5,930,822 | 0 |

The generated C++ matched the `e62b2a5e9` baseline byte for byte: Optcarrot after
normalizing the per-run temp-world path, and the 24 MB closed rpg2k output without
any normalization.

On Optcarrot, 94,334 transfers left a `VIRTUAL` successor, with 84,978 logged
(position, value) pairs: under one changed entry per instruction. 1,458 were
materialized again by `unvirtual`, the cursor missed 4 times, and readers built
5,304 entries. The logs total 264,290 Integers, compared with about 7.1 million
entries in the copied states.

## Measurements

Sealed Optcarrot compile (`compiler_profile.rb --mode none --optcarrot`), Ruby
4.0.5 with YJIT, warm scan cache for each version. Five alternating runs per
version, after one warm-up each. Baseline `e62b2a5e9`.

| Version | allocated_objects | gc_count | gc_milliseconds | elapsed_seconds | process_peak_rss_kib |
| --- | ---: | ---: | ---: | ---: | ---: |
| baseline (median) | 4,828,898 | 33 | 655 | 5.653 | 278,108 |
| deltas (median) | 4,706,688 | 30 | 597 | 5.624 | 264,184 |
| baseline (mean) | 4,828,882 | 32.8 | 644 | 5.637 | 275,978 |
| deltas (mean) | 4,706,700 | 30.4 | 606 | 5.637 | 263,963 |

Per-run results: baseline 5.585/5.608/5.653/5.674/5.664 s, deltas
5.601/5.604/5.694/5.663/5.624 s.

The change saves about 122,000 allocations (2.5%), three GCs and about 12 MB of
peak RSS. Elapsed time is unchanged within noise. On the closed rpg2k pass, the
two versions took 33.3/31.0 s (baseline) and 30.9/30.8 s (deltas) wall time.
