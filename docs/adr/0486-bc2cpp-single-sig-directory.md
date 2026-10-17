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

All hand-written signature files live in `sig/bc2cpp/`. A file declares built-in or RGSS methods when its first line is
the marker `# bc2cpp-native:`. `tools/bc2cpp/native_sigs.rb` (`NativeSigs.file?`) is the one place that reads the
marker; the trust rules that depended on the directory (no program hint, no runtime guard, a native overload is not a
hint) now call it. The fact tables that have their own loaders (`CoreFactSigs::FILES`) are still skipped by
`RbsSignatures` by name.

## Consequences

- One directory to read and to edit. Adding a native declaration means putting the marker on its file's first line.
- A program signature whose first line is the marker is treated as native. That is the only way the marker can be
  wrong, and `scripts/bc2cpp/core_facts_rbs_check.rb` and `native_sigs_check.rb` still check the native files against
  their tables and the C and Ruby sources.
- The historical ADRs that name `sig/native/` keep their text; they describe the layout at the time.
