# Cheap allocation fixes in bc2cpp

A handful of small, per-call allocations in the bc2cpp compiler are removed
without changing what it computes. The generated C++ does not change.

Sites were chosen from an object-mode profile of the sealed Optcarrot compile
(see [compiler data profiling](bc2cpp-compiler-data-profile.md)); stackprof's
frame `:edges` named the caller of each allocating leaf. One sample stands for
100 allocations; the base profile had 64,707 samples, the new one 63,566.

## Changes

- **ENTER field predicates** (irep_arity.rb). `pure_mandatory_arity?`,
  `pure_mandatory_or_optional_arity?` and `optional_positionals_only?` sliced
  `enter_fields[1..]` / `[2..]` for every call-site query, a new Array each
  time (430 `Array#[]` samples). `enter_fields_zero_from?` now walks the frozen
  field list by index. For every field list where the old slice exists it gives
  the same answer. A list shorter than the start index (a truncated decode,
  which no compiled world produces) still raises, now an `ArgumentError`
  instead of the old `nil.all?` `NoMethodError`, rather than answering true.
- **Native BasicObject scan** (codegen_native_core_direct.rb).
  `native_basic_object_registration_only?` read every native source with
  `File.foreach`, one String per line, to look at the lines that spell
  `BasicObject` (all 300 `IO.foreach` samples). It now reads the file once and
  only splits it into lines when the text contains `BasicObject`: a file that
  does not has no line that could fail the test. Lines are cut at `"\n"` from a
  binary String, as `File.foreach(path, encoding: 'BINARY')` cut them.
- **Op lists splatted from a Set** (dynamic_names.rb, lexical_consts.rb,
  escape_analysis.rb, codegen_stack_tuples.rb). `DynamicNames.analyze`,
  `LexicalConsts::Model#collect_definitions` and `EscapeAnalysis.op_sites`
  splatted `SEND_FAMILY` / `SCANNED_OPS` / `CLOSURE_OPS` (Sets) into
  `each_with_op` for each irep: a `Set#to_a` and a splat Array per call (about
  100 `Set#to_a` samples). The lists are frozen Array constants built once in
  the same order and passed to `each_with_op_in`; `indices_with_op` keys its
  cache by the list's contents, so the lookups are the same.
  `compute_reaching_definitions` also keeps its definition Set as scratch, next
  to the existing seen table and work stack. Its `Set#to_a` (about 120 samples)
  stays: it is the answer, sorted by the unique `(index, reg)`, so the set's
  insertion order never shows.
- **Resumable register scan** (codegen_resumable.rb).
  `resumable_step_function` ran `scan` over `RESUMABLE_REGISTER_TOKENS` to
  collect registers and then `gsub` over the same pattern to blank literals and
  comments, testing each token with `match?(/\Ar\d+\z/)`. One `gsub` now does
  both: only the `reg` alternative begins with a lowercase `r` (the others
  begin with `R"`, a quote or `/`), so "the `reg` group matched" and "the token
  is `r<digits>`" are the same test (263 `scan`+`gsub` samples became 160).
- **`ClassWorld.frozen_magic?`** (class_world.rb) read the first five lines
  through `File.foreach(file).first(5)`. It now `gets` at most five lines and
  stops at the first match; the load planner called it instead of keeping
  its own copy of the expression; that planner was removed. This was not measurable in the Optcarrot
  profile (the `IO.foreach` samples were all the native scan above).

## Equivalence evidence

- Generated C++ for every run below was identical to its baseline pair after
  replacing the per-run temporary world directory, both plain (185 sites) and
  inside the two `\x..` hex-escaped pool strings.
- A scratch harness compared old and new expressions directly: `frozen_magic?`
  on 17 crafted files (empty, no trailing newline, CRLF, CR-only, magic on line
  5 vs 6, 100 KB lines, blank lines, `false`, tab and newline after `#`) and
  every `.rb` under `tools`, `scripts`, `mruby-*` and `3rd/optcarrot`; the
  ENTER predicate on hand-built field lists for both start offsets; the merged
  resumable pass (register order and blanked text) on edge-case bodies and 200
  C++ sources under `src`; and the native scan on all 197 C/C++ files under
  `3rd`, `src` and `mruby-*` (3 spell `BasicObject`, 2 answer false). No
  mismatches.

## Repeated unsampled compilation

One warm-up per version, then three alternating `--mode none --optcarrot` runs
on Ruby 4.0.5; baseline `e62b2a5e9`.

| Run | Allocations before | Allocations after | Seconds before | Seconds after |
| --- | ---: | ---: | ---: | ---: |
| 1 | 4,828,896 | 4,714,686 | 5.615 | 5.575 |
| 2 | 4,828,875 | 4,714,797 | 5.562 | 5.615 |
| 3 | 4,829,040 | 4,714,707 | 5.655 | 5.545 |

This removes about 114,200 allocations per compilation (2.4%). Timing moves in
both directions and does not establish a speedup.
