# Plans for further bc2cpp Array allocation reductions

Status: proposed, not implemented. Each independently useful change gets its own
branch and PR. Start from current master and account for
[PR #2874](https://github.com/take-cheeze/rpg-maker-clone/pull/2874) (instruction read
lists) and [PR #2875](https://github.com/take-cheeze/rpg-maker-clone/pull/2875) (LCF
mask predicates). If a prerequisite is not merged, record an explicit combined
checkout. Do not reimplement those changes or mix their savings into a new
candidate's measurements.

The previous allocation profile identifies possible sites, not guaranteed savings.
Refresh the profile after those PRs land, or use an explicitly recorded combined
checkout. A full FactoryFlow result cache was already rejected: it reduced total
allocations by about 1.4% but increased elapsed time in both local comparisons.
Avoid repeating that experiment without a materially different retention strategy.

## Order and boundaries

| Order | Candidate | Initial scope | Main risk |
| --- | --- | --- | --- |
| 1 | Canonical opaque-register keys | `write_dominates?` key construction | Mutable inputs or inconsistent flag initialization |
| 2 | Temporary tuple Arrays | Symbol-read lookup keys, then factory work stacks | Cache eviction and alias-budget accounting |
| 3 | Shared reaching definitions | A measured group of read-only callers | Mutation of borrowed results or definitions |
| 4 | Collection conversions | Remaining hot `sort`, `to_a`, `uniq` and `map` sites | Ordering changes and excessive retained metadata |
| 5 | Numeric-flow state copies | One measured, provably redundant copy path | Stale aliases, element facts or class tests |

Plans 1 and 2 can be developed independently in isolated worktrees. Plan 3 needs
an ownership audit first. Re-profile before selecting Plan 4 sites: some sorting
and conversion costs overlap Plans 1–3. Keep Plan 5 separate from query/cache work
so a dataflow correctness change can be reviewed and reverted independently.

## 1. Reuse canonical opaque-register keys

**Problem.** `BytecodeIR::Program#write_dominates?` in
`tools/bc2cpp/bytecode_ir_dataflow.rb` sorts and freezes `opaque_regs` for its key.
The neighboring `reaching_definitions` query already has `reaching_opaque_key`,
which can reuse a snapshot of an immutable Integer Set.

**Implementation plan.**

1. Measure repeated dominance queries with the same frozen opaque-register Set;
   count snapshot allocations and check their whole-generator profile share.
2. Route dominance queries through the existing canonical-key helper rather than
   adding another snapshot table. Ensure both entry points initialize the
   `BC2CPP_IR_QUERY_KEYS` control consistently, including a dominance query made
   before any reaching-definition query.
3. Preserve the uncached path for mutable opaque inputs and the existing cache
   bound. Retain the distinction between absent and explicitly empty inputs.
   Only reuse identity snapshots for containers whose elements are immutable;
   do not generalize a frozen outer container to mean deeply immutable contents.

**Validation.** Extend `scripts/bc2cpp/join_dominance_check.rb` for direct first
queries, empty/nil inputs, equal distinct Sets, mutable-input changes, control-off
behavior and bounded reuse. Compare query answers against the old path and check
whole-generator output identity. Reject the change if key retention outweighs the
saved snapshots.

## 2. Remove temporary tuple keys and work items

**Problem.** `IrSymbolFlow.value_reads` creates `[index, reg]` on cache hits.
`FactoryFlow.uses` creates pairs for its work stack and visited set. Returned use
pairs are part of the current API; their removal is not automatically safe.

**Implementation plan, in two separately measured changes.**

1. Replace symbol-read lookup keys with an instruction-indexed table of
   register-keyed entries, if profiling still shows meaningful hot-hit churn.
   Preserve cached nil versus an absent entry. Preserve the current 1,024-query
   bound and FIFO eviction behavior by counting logical queries, not outer
   instruction buckets. Account for any eviction queue's own allocations.
2. Investigate a flat factory work stack that pushes origin and register values
   separately. Use integer-indexed visited data and an explicit visited-pair
   count if that is cheaper than pair keys. Preserve LIFO traversal, duplicate
   suppression, result insertion order and alias-budget refusal. Keep ordinary
   returned Sets and their pair representation unchanged.

Do not reuse a mutable Array as a stored Hash/Set key. Do not introduce packed
Integer keys without proving index/register bounds and checking whether packing
creates heap Integers. Keep caches scoped to body identity, never globally by
labels that can repeat across trees. No full use-query result cache is proposed.

**Validation.** Extend `symbol_flow_check.rb` and `struct_receiver_check.rb` for
cached refusals, eviction, equal labels in separate trees, loops, MOVE aliases,
handler reads, overwrites and budgets around the exhaustion boundary. Hot-hit
allocation checks should exercise production methods. Compare ordered results
where order is observable, not just Set equality. Measure each subchange alone.

## 3. Borrow reaching-definition results in read-only consumers

**Problem.** `reaching_definitions` normally copies the result Array and its
`Definition` objects. The existing `shared: true` option permits frozen cached
results, but not every consumer has been audited to borrow them.

**Implementation plan.**

1. Profile default-copy callers and select the largest small group. Inventory
   mutation of the Array, each Definition and any results passed onward.
2. Switch only consumers proven read-only to `shared: true`. Preserve default
   ownership for public/mutating callers; avoid broad automated replacements.
3. Keep cache-full, refusal-diagnostic and mutable-opaque-input paths unchanged.
   Sharing is permission to borrow an eligible result, not a promise that every
   query becomes cached or frozen. Preserve the existing sharing control.

**Validation.** Add focused ownership cases to existing IR checks: private
results remain independently mutable; eligible shared results and definitions
are frozen; cold, hot, cache-full and refused queries answer alike. Run
`ir_facts_check.rb`, `ir_join_soundness_check.rb`, `join_dominance_check.rb` and the
checks for the actual migrated consumers. Include the sharing-disabled comparison
and generated-code identity. Measure retained memory as well as copies removed.

## 4. Reduce remaining collection conversions

**Problem.** The saved profile includes Array-producing `Set#to_a`, `sort`,
`uniq`, `map` and `filter_map`. Some build metadata once; others run per query.
Only the latter justify additional retained state without further evidence.

**Implementation plan.**

1. Refresh caller attribution after the preceding changes. Exclude the work
   already removed by canonical keys and instruction-read reuse.
2. For fixed, immutable inputs, reuse an existing ordered snapshot or index.
   For predicate-only callers, consider direct iteration instead of constructing
   an intermediate Array. Hoist repeated literal opcode vocabularies where useful.
3. Inspect `indices_with_op` in `bytecode_ir_regions.rb` and predecessor/edge
   consumers, but preserve caches already present there. Do not replace a cached
   one-time builder just because it contains `map` or `uniq`.
4. Keep each chosen site a separate logical change. Preserve order, duplicate
   treatment and deterministic diagnostics. Do not substitute a Set for an Array
   unless its membership, equality and ordering semantics all permit it.

**Validation.** Use the relevant IR/region and register-flow checks. Add only
cases that establish ordering, duplicate handling, empty results or ownership
that the changed site relies on. Compare generated output and normalized
reports. Report any retention cost of replacing temporary conversions with
persistent snapshots; remove redundant snapshots rather than layering caches.

## 5. Elide additional numeric-flow state copies

**Problem.** State copying remains visible in the profile, but `join_state`,
`copy_reg_write` and unchanged-write checks already implement sharing. Equal
class masks alone do not make a write semantically unchanged.

**Implementation plan.**

1. Attribute remaining copies separately to transfers, joins and oracle work.
   In a diagnostic run, count which copies actually change state; exclude that
   instrumentation from elapsed-time comparisons.
2. Select one redundant-copy path. State the condition under which the input
   can be returned unchanged, including register/slot aliases, element facts,
   provenance, class-test facts, writes summaries and oracle side effects.
3. Preserve oracle call order and write accounting. Clone on the first real
   mutation; never mutate a state shared by incoming/outgoing CFG entries.
   Do not add an Array pool without proving all borrowers have released a state.

**Validation.** Extend `numeric_flow_speed_check.rb` and relevant numeric/IR
soundness checks. Compare all states and write summaries against the old path,
including diamonds, loops, handlers, captures and replacement values of the same
class that must invalidate aliases/tests. Run `numeric_operand_check.rb`,
`ir_join_soundness_check.rb` and affected class-narrowing checks, with runtime
comparisons where available. Keep the change only if allocation savings survive
the whole-generator measurement without an unacceptable timing regression.

## Measurement and acceptance for every implementation

- Record the exact commit/diff, Ruby/JIT version, patched mruby/mrbc identity,
  compiled/foreign/native source hashes, flags and cache regime. Use the current
  desktop closed whole-engine workload; do not compare its timings directly with
  the historical Wio workload.
- Warm each candidate after its final compiler source edit: ScanCache fingerprints
  all compiler Ruby files, so even a comment change can invalidate scan entries.
  Exclude cache-populating runs. Run baseline/candidate passes serially in
  alternating order, with at least two warm comparisons; repeat if results are
  noisy or conflicting. Avoid concurrent builds/tests during timed passes.
- Record elapsed/process-CPU time, exact total allocation counts, GC time/counts,
  live/old objects and retained/peak memory where practical. A GC.stat total is
  not an exact Array count. Use separate allocation samples or targeted production
  method probes to attribute savings to Arrays. Keep profiler/instrumentation
  runs separate from unprofiled timing comparisons.
- Compare generated C++ after normalizing only checkout paths, and diagnostic
  logs after path normalization and removing timing lines. Explain any other
  difference; do not normalize behavior changes away. Run touched semantic checks
  and relevant interpreted/compiled comparisons.
- Require stable allocation savings and no unacceptable timing or retention
  regression. Fewer Arrays alone is insufficient. A neutral or noisy timing
  result must be reported as such, without promising a speedup.
- Update feature documentation and README, add one changelog fragment, run
  pre-commit and required relevant checks, then open a focused PR with raw
  measurement provenance and the practical limits of its results.
