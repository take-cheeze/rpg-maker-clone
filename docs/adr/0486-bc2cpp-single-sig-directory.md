# 0486. One signature directory for bc2cpp, with native declarations marked

Date: 2026-10-17

## Status

Accepted

## Context

bc2cpp's hand-written signatures were split between `sig/bc2cpp/` (the program's declarations) and `sig/native/`
(built-in and RGSS method facts). The split was decided by path: a loader asked whether a declaration's file name
contained `sig/native/`, and the default signature directory read both. A reader had to know two directories and the
rule that connects them.

## Decision

All hand-written signatures live in one file, `sig/bc2cpp/declarations.rbs`. Its program declarations come first; the
built-in and RGSS declarations follow, grouped into native tables. Each native declaration is preceded by the marker
`# bc2cpp-native: <table>`. `tools/bc2cpp/native_sigs.rb` is the one place that reads the marker: `NativeSigs.table_of`
gives a declaration its table, and `NativeSigs.decls` gives a table's loader its declarations. A loader names its table
as `NativeSigs.table('core_results')` (`sig/bc2cpp/declarations.rbs#core_results`). The trust rules that depended on
where a declaration lived (no program hint, no runtime guard, a native overload is not a hint) now read the marker
through the declaration's location. The fact tables (`CoreFactSigs::TABLES`) are skipped by `RbsSignatures` by table.

Declarations of one method in two tables are resolved by file order: program declarations first, then native tables in
file order, so a native declaration of a method the program also declares wins.

## Consequences

- One file to read and to edit. Adding a native declaration means putting the marker above it, inside the native table
  it belongs to.
- A program declaration placed under a marker is treated as native. `scripts/bc2cpp/core_facts_rbs_check.rb` and
  `native_sigs_check.rb` still check the native tables against their sources.
- The loaded declarations were compared against the layout before this change (`HEAD`): the same 988 methods with the
  same native flags, argument and return types, the same ivars and supers, and the same diagnostics.
- The base stubs from `scripts/bc2cpp/base_rbs*.rb` are committed as one native table per gem (`base_<gem>`), at the top of
  the file so that every program and native declaration after them still wins where both declare a method. Their
  superclasses are left out: the hierarchy is read from `core_hierarchy`, and a stub's superclass could otherwise trigger
  TC1016. The stubs are a snapshot; regenerating them means rerunning the generators and replacing those blocks.
- The historical ADRs that name `sig/native/` keep their text; they describe the layout at the time.
