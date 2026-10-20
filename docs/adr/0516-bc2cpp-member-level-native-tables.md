# 0516. Native table membership per member, not per block

Date: 2026-10-20

## Status

Proposed

## Context

`sig/bc2cpp/declarations.rbs` is one file read by several loaders. A native table is a
top-level block tagged `# bc2cpp-native: <table>` directly above the block, and each loader reads
the blocks of its own table (`NativeSigs.decls`, `NativeSigs.table_source`). The program-signature
loader (`RbsSignatures`) reads every block, and treats a native block as a declaration of the
native method rather than a program hint (`NativeSigs.native?`), and skips the fact tables
(`RbsSignatures.fact_table?`).

Because membership is per block, the same class may not be declared twice in one table, and
the same method may not be moved into another table without moving the whole block. The
consequence is measured: 1,136 method declarations repeat across the file, 480 with different
signatures. A dedupe that folds copies from different tables changes what each loader sees.
When I tried it, `Array#compact` left `core_results`, and `Array#each` and `Hash#select` moved
out of their tables, so the closed build refused two signatures. The class/module merge failed
the same way: one block has one marker, so folding blocks from different tables dropped
`rgss_constructors` membership. Groups carrying a `%a{bc2cpp:...}` annotation cannot be folded at
all, because the annotation is a generator input.

## Decision

Membership is per member. A member may carry its own marker comment directly above its
definition. A member without one takes its block's marker, so every existing block keeps its
meaning and nothing has to change in the files that are not merged.

1. `NativeSigs.table_of(member)` returns the member's marker, else the block's. `native?` and
   `fact_table?` ask about the member.
2. `NativeSigs.decls(table)` returns each block restricted to the members of that table, as a
   new declaration with the same header. A block with no member of the table is skipped.
3. `NativeSigs.table_source(table)` emits the member markers it reads, so the byte-for-byte checks
   (`constructor_overloads_check`) keep their meaning.
4. `RbsSignatures` decides native and fact-table status per member when it applies declarations.
5. The dedupe writer merges copies from different tables into one member per method, and writes
   each member's table marker above it. Groups with an annotation stay as they are. The base
   section above `# ---- block_types.rbs` is generator output and stays out of the writer's scope.
6. Class/module blocks may be merged after step 5, with each member keeping its table.

The base section keeps block markers: its generators write whole blocks and compare them byte for
byte.

## Consequences

- Loaders read the same members they read today. The only change is that a block may hold members
  of several tables, which `NativeSigs` must split for each reader.
- `RbsSignatures` becomes the riskiest change: it decides which declarations are program hints. A
  hand-owned member that shares a block with a tagged member must stay a program hint. The
  per-member decision in step 4 is the guard for that.
- Every loader check that reads a table (`core_facts_rbs_check`, `constructor_overloads_check`,
  `native_core_result_sigs_cases`, `base_rbs_check`) must still pass unchanged, which is the
  acceptance test for steps 1 to 4 before any member is re-tagged.
- The dedupe becomes possible for the 1,136 repeated declarations except the annotated groups.
- Follow-up: once the loaders read per member, a loader that needs a member's table can ask
  `NativeSigs.table_of` directly, so no new block structure is needed.
