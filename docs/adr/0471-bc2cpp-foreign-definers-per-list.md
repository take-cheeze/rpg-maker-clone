# 0471. bc2cpp: one ForeignDefiners scan per file list, and one scan per multi-owner question

Date: 2026-10-16

## Status

Accepted

## Context

This uses the StackProf profile of the wio closed-world shipped pass on master 3d348c10 (CPU mode, 2 ms, 30,840
samples), the same one ADR 0470 reads. In it, `ForeignDefiners.scan` took 876 samples (2.8%). Nearly all of them
(792) came from `ClosedWorld#nil_foreign_definition_free?`, which runs inside NumericFlow's oracle.

`scan(paths)` memoized one result, keyed by the `[path, mtime, size]` of every file, and cleared the whole cache on
any miss. Its callers pass different lists:

* the closed world's outside Ruby (`nil_foreign_definition_free?`, `core_native_arm_safe?`);
* the same list without core sources (`core_ruby_arm_safe?`);
* the frozen tables' `FOREIGN_RUBY_SRCS` list (`frozen_table_name_refusal`).

Each switch between lists evicted the other list's entry, so the next call walked every syntax tree of the list
again (`scan_files`, with the `Collector` visitor). That rewalking was 573 of the 876 samples. Most of the rest was
the stat key itself, built once per `defines?` call. `nil_foreign_definition_free?` and the frozen-table refusal
called `defines?` once per owner of the same question, so they built the key once per owner.

## Decision

`FOREIGN_DEFINERS_PER_LIST`:

* The cache holds one entry per list of files: files => [stat key, Result]. An entry is reused only when the list's
  current stat key is `eql?` to the stored one, which is the comparison the old Hash key made. The key is the same
  one as before, so a rewritten or deleted file is still seen. A changed list replaces only its own entry.
* `ForeignDefiners.defines_any?(paths, owners, name)` answers `owners.any? { defines?(paths, owner, name) }` from a
  single scan. With no owners it scans nothing, as the `any?` / `none?` loops it replaces did, so a foreign file
  that does not parse still raises only when a question is asked.
* `nil_foreign_definition_free?` and the frozen-table refusal ask through `defines_any?`.

No answer changes. Each result is still `scan_files` of the list under its current stat key, and each question
reads the same Result it would have read before.

## Consequences

* An out-of-tree equivalence harness (about 9 s) loads master's `ForeignDefiners` next to the new
  one. It runs 3,000 interleaved scans over the wio lists (24 outside Ruby files, the core-free list, 41
  `FOREIGN_RUBY_SRCS` files). Every result equals master's and a fresh `scan_files`. It also compares `defines?` and
  `defines_any?` over every owner of the scan plus NilClass, Object, Kernel, BasicObject and Hash against master's
  `defines?`, for 203 names, and covers a rewritten and a deleted file. Nothing differed. On that sequence master
  took 2.5–3.9 s and the new code 0.56–0.73 s.
* No whole-engine pass was run for this change. The attributable cost was 876 samples, or about 1.8 s of CPU on that
  pass. The rewalks (573 samples) go away, and the remaining stat-key work is divided by the number of owners asked
  about together.
* `scripts/bc2cpp/foreign_definers_cache_check.rb` (host only, about 0.3 s) checks the following:
  * alternating lists are walked once each;
  * each answer equals a fresh walk;
  * a rewritten file is walked again, and a deleted one drops out;
  * `defines_any?` agrees with `defines?`;
  * no owners means no scan, and an unparseable file raises when asked;
  * both callers use `defines_any?`.

  With the old single-entry cache, its alternation check fails.
* Memory: one Result per distinct file list. A run has three or four lists.
