# Native bc2cpp check suites

Run `ruby scripts/bc2cpp/native_registration_check.rb` for the 27 scope-parser
and per-path registration-cache assertions. Fixture modules share one reporter
and process. Scanner instrumentation is restored with `ensure`, so a failing
fixture cannot leave its wrapper installed.

Run `ruby scripts/bc2cpp/native_results_check.rb` for 41 assertions covering
return-kind inference, audited core and RGSS result declarations, hierarchy and
block-parameter declarations, and generated direct-call RBS signatures. The
suite shares loaded tables and RBS setup. Each malformed declaration still gets
its own temporary signature file. Both suites run once through the coverage
reporter in `ruby-checks`; neither needs mrbc or a native library. Both load
`tools/bc2cpp/native_names.rb`, which reads the operator table from
`3rd/mruby/lib/mruby/presym.rb`, so `ruby-checks` initializes `3rd/mruby` first.

The reporter also schedules the previously unscheduled native arity check and
clang AST return check. The latter prints a skip when clang is unavailable.
`native_format_types_check.rb` runs in `bc2cpp-build`, where the mruby source
submodule is available for its `class.c` conversion audit.

`native_owner_map_check.rb` generates separate whole programs with mrbc, and checks
the owner map's exact-class arms: the proven site gets its arm, each unsound
definition withdraws it, and `BC2CPP_NATIVE_OWNER_MAP=0` gives the by-name send.
Its generated-code part needs `MRBC`; without it the check prints a skip.
`native_result_facts_check.rb` keeps its real-source mutation audit independent
of the declaration tables, and its MRBC-generated worlds remain separate.
Its dead-fallback assertions match complete no-method markers, including the
receiver, method and `file:line` source location.
The two new suites replace `native_owner_scopes_check.rb`,
`native_path_registrations_check.rb`, `native_return_kinds_check.rb`,
`native_core_result_sigs_check.rb` and `native_sigs_check.rb`.

## Native return-kind table

`BC2CPP_NATIVE_FN_KINDS` names the table of each native function's return kind
that the unknown-receiver join reads (ADR 0537). `closed_build.bash` writes the
headers the analysis needs: `shinonome.hxx` in `closed/mrbgems/mruby-rgss`, and
the analysis overlay in `closed/analysis/include` (presym IDs for every symbol the
closed world's native sources name, and the Onigmo header; ADR 0539). The closed
library does not compile against the overlay. Then:

`closed_build.bash` generates the table and uses it. Its first rake phase writes the presym list the overlay needs;
then it writes `closed/analysis/fn-kinds.tsv`, deletes the generated `*_gen.cpp` files (rake does not track
`BC2CPP_NATIVE_FN_KINDS`), and runs rake again so the closed world is generated with the table. To regenerate the
table alone, run `ruby scripts/bc2cpp/native_fn_kinds.rb build-closed-bc2cpp/closed > fn-kinds.tsv`.

The generator reads every native source the base generator reads and every
source the closed world reads (without `test/` directories), each with its gem's
include paths, and runs clang on each. A file clang cannot parse keeps the regex
kinds and is reported on stderr. Every closed-world source parses on the patched
tree; the wio-only `io_hal.c` is outside the closed world.

The analysis reads the sources as the build does, so the generator refuses to run
until the mruby patches `standalone_prep.bash` applies are in `3rd/mruby`. Without
them `profiler.cxx` (`mrb_gc_type_counts` comes from a patch) and `symbol.c` (whose
table the compact form replaces) do not parse. `closed_build.bash` applies them
before the generator runs.

Time: each file's result is cached under `closed/analysis/kinds-cache` (keyed on
the file, its flags, the analyzer's sources and the external kinds), and files run
in `BC2CPP_TABLE_JOBS` workers (default: the CPUs, up to 4). A rerun parses only
what changed. The second pass parses a file again only when it looks up a name the
first pass added to the external kinds; the rest keep their first-pass result.
A cold run on 4 CPUs takes about 75 s (231 s with the old two-worker serial second pass).
