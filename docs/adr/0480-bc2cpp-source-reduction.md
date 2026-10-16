# 0480. bc2cpp source reduction without output change

Date: 2026-10-16

## Status

Accepted

## Context

`tools/bc2cpp/*.rb` had grown to 73,429 lines and 3,467,935 bytes. Over the
ADRs a number of helpers were superseded or never wired up, and a few were
written twice: identical method bodies under two names, or the same
`splat_table` method defined three times in one module.

The generator is a compiler whose output is shipped as C++. A source change
that alters that output is a behaviour change, so this cleanup is held to a
stricter bar than a refactor: the generated output must stay byte-identical.

## Decision

Remove code that is provably unreferenced and merge copies that are provably
identical. Nothing that decides output is reworded, and no check, guard,
refusal, fixture or environment variable is removed or loosened.

- Unreferenced methods removed (12): `dominates?`, `foreign_fully_compiled?`,
  `ivar_write_sites` (a wrapper; `ivar_write_sites_of` remains), `native_singleton_name_safe?`,
  `trace_float_literal_receiver`, `collect_block_upvars`, `jmp_target_after_reg`,
  `line_of`, `registered_in_source?`, `silent_call?`, `const_sites`, `may_yield?`.
  Each was checked against the whole repository with `scripts/bc2cpp/def_deletion_safety_check.rb`;
  the remaining hits are substring matches (`write_dominates?`, `message_line_offset`)
  or ADR and changelog history.
- Unreferenced constants removed (8): `CATCH_SIZE`, `COND_BRANCHES`, `CREATING`,
  `FUNCALL_RE`, `GUARD_LISTING`, `MEMBER_NOTED`, `MEMBER_OK`, `NAME_RE`.
- Duplicates merged: two of the three identical `SymbolFlow.splat_table` copies
  were removed (the last definition is kept, so behaviour is unchanged);
  `origin_ivar` (identical in `GuardHintReport` and `InterfaceTableReport`) now
  lives once as `IrepScans.origin_ivar`; `array_return_analyzable?` was an exact
  copy of `fixnum_return_analyzable?` and its single caller now uses the latter;
  the element-table queries shared by `ArrayElementLayout` and `HashElementLayout`
  (`known`, `primitives`, `unknowns`, `unknowns_by_reason`) live once in
  `ElementTableQueries`, which both classes `extend`.
- Six pre-existing `ruby -w` unused-variable warnings fixed by renaming to `_name`
  (one unused `to_h` local deleted).
- Comments that named removed methods now name their live replacements.

Kept on purpose: `tools/bc2cpp/profile_annotations.rb` (the ADR 0139 tool) and
`tools/bc2cpp/rgss_confirmed_unused.rb` (the ADR 0195 audit record). Nothing loads
them, but both are documented entry points or records.

## Evidence

Benchmark (`cat tools/bc2cpp/*.rb | wc -l` / `| wc -c`):

- before: 73,429 lines, 3,467,935 bytes
- after: 73,234 lines, 3,460,341 bytes

Byte identity, using the wio shipped-pass driver (`ship3.rb`) on origin/master
and on this branch: `shipped.cxx` is byte-identical, and `shipped.stderr` is
identical once the tree path is normalized. The guard-hint and interface-table
diagnostic reports, which exercise `IrepScans.origin_ivar`, are also identical.

## Consequences

- The generator is smaller by 195 lines and 7.6 KB. This is a modest reduction,
  because the code had little exact duplication to remove.
- Future dead-code removal can follow the same check: `def_deletion_safety_check`
  before each deletion, and the byte-identical shipped pass after it.
- Generic factoring of the closed-world guards repeated across `codegen_*.rb` was
  considered and not done: the guards differ in shape, so a shared helper would
  need arguments that make it less clear than the original.
