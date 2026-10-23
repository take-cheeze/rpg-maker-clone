# bc2cpp dynamic-dispatch census, 2026-10-19

Historical: the measurements on this page were taken on the former maix/wio closed world, not the current closed world, which is the sealed RPG2000/2003 desktop host.

A fresh run of the generated-C++ census (`docs/bc2cpp-dynamic-site-census.md`, `## Method`) on two trees that generate
byte-identical wio shipped output: `master` at `5e4d81e` (#2421), and the lexical-constants branch
`claude/bc2cpp-lexical-consts-ir-p3x8` (the dynamic-names and lexical-constants raw-scan migrations on top of it).

This replaces no earlier number. [`docs/bc2cpp-baseline-2026-10-02.md`](bc2cpp-baseline-2026-10-02.md) was measured
on a different tree with a different pass setup, and its totals are not comparable to these (see Caveats).

## Method

- Host `mrbc` built from the pinned mruby (`3rd/mruby` `67a569e`) by `scripts/bc2cpp/closed_build.bash`, with the
  mruby patches from `scripts/mruby/standalone_prep.bash` applied. Both trees were measured with the patches applied.
- `MRBC=<host mrbc> BC2CPP_COVERAGE_KEEP_DIR=<dir> ruby scripts/bc2cpp/coverage_report.rb` writes `shipped.cxx`
  (426,199 lines on the branch, 426,199 lines on master).
- `ruby scripts/bc2cpp/dynamic_site_census.rb <dir>/shipped.cxx`. The origin-table pass (`--origins`) was not run, so
  the receiver-origin figures below are the text-walk heuristic only.
- `coverage_report.rb` then stopped at its own summary step, because `bc2cpp.rb`'s diagnostic lacks the section label
  `integer-valued constants proven (INTEGER_CONSTANT_PROOF)`. The shipped file was written before that and is complete.
  This is a summary-label mismatch and does not change the generated C++.
- Host toolchain: Ruby 3.3.6, `rbs` 4.0.0 (the `Gemfile.lock` pin; the default `rbs` 3.4.0 cannot parse
  `sig/declarations.rbs`), bison, gperf.

## Results

Generated-method bodies; helper-region counts in parentheses.

| Measure | Count |
| --- | ---: |
| `bc2cpp_send` call sites | 758 (3) |
| `mrb_funcall_with_block` | 191 (1) |
| `mrb_funcall(_argv/_id)` | 1 (8) |
| `mrb_yield_argv` | 0 (1) |
| **Directly by-name sites** (the three rows above) | **950** |
| `BLOCK_FALLBACK` markers | 419 |
| `bc2cpp_nomethod` sites (not dynamic) | 293 |

By-name calls held in shared helpers: `bc2cpp_eqq` 1 (15 generated callers); `bc2cpp_slow_lshift` 2 (134 callers).

Else-arm of an inline fast path: 523. Bare dispatch: 231. Known-class arm still by name: 4.

Why the sites are dynamic (exclusive categories):

| Category | Sites |
| --- | ---: |
| `core_tag_chain_else:receiver_other` | 419 |
| `poly_diag:dynamic_single_registered_definition/receiver_class_unresolved` | 95 |
| `other:no_guard_nearby` | 72 |
| `poly_diag:dynamic_single_registered_definition/implicit_self_unresolved` | 60 |
| `poly_diag:dynamic_no_registered_definition/implicit_self_unresolved` | 37 |
| `poly_diag:dynamic_no_complete_candidate_set/implicit_self_unresolved` | 22 |
| `poly_diag:dynamic_no_complete_candidate_set/receiver_class_unresolved` | 16 |
| `poly_diag:chain/runtime_class` | 15 |
| all other categories | 26 |

Receiver origin (text walk, `join` / `self` / `unknown` / `other` / `direct_call_result`): 527 / 136 / 81 / 13 / 1.

Constants: the census has no constant bucket. The closest figure is the POLY_DIAG `receiver_class_unresolved/constant_lookup`
rows, 6 sites (5 with a single registered definition, 1 with none).

## What moved

Nothing. On the same patched submodules, `master` and the branch produce byte-identical `shipped.cxx`
(`diff` reports zero lines). So the two raw-scan migrations on the branch (`DynamicNames.analyze` and the lexical-constants
scans) change no generated C++ on this tree, and the counts above are the same for both.

## Caveats

- The 2026-10-02 baseline totals (3,032 by-name, 2,603 `bc2cpp_send`) are not comparable to these (950 and 758). That
  baseline was taken on `cd86085f`, with the origin table and the `SKIP_UNSUPPORTED=1` pass described in its own Method.
  This run used neither, so the gap is a pass-setup difference, not a 2,000-site improvement. Regenerating the 2026-10-02
  figures on this same setup is needed before any delta can be quoted.
- A first attempt compared `master` with *unpatched* submodules and showed about 17,000 differing lines (a new
  `Kernel___defined_cvar_scope` method and different symbol tables). That was the submodule state, not the code. The
  comparison above uses matching patches.
- The receiver-origin figures are heuristic. The origin-table pass would make them exact.
