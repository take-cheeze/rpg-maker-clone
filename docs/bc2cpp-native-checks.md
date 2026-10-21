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

`native_owner_map_check.rb` remains independent: it generates separate whole
programs with mrbc and compares a kill-switch world with an archived base tree.
`native_result_facts_check.rb` keeps its real-source mutation audit independent
of the declaration tables, and its MRBC-generated worlds remain separate.
Its dead-fallback assertions match complete no-method markers, including the
receiver, method and `file:line` source location.
The two new suites replace `native_owner_scopes_check.rb`,
`native_path_registrations_check.rb`, `native_return_kinds_check.rb`,
`native_core_result_sigs_check.rb` and `native_sigs_check.rb`.

## Native return-kind table

`BC2CPP_NATIVE_FN_KINDS` names the table of each native function's return kind
that the unknown-receiver join reads (ADR 0537). The closed build writes the
generated headers it needs: `closed_build.bash` leaves `shinonome.hxx` in
`closed/mrbgems/mruby-rgss` next to the presym IDs in `closed/include`. Then:

```bash
scripts/bc2cpp/closed_build.bash build-closed-bc2cpp
ruby scripts/bc2cpp/native_fn_kinds.rb build-closed-bc2cpp/closed > fn-kinds.tsv
BC2CPP_NATIVE_FN_KINDS=$PWD/fn-kinds.tsv ...   # the bc2cpp run that should use it
```

The generator reads every native source the base generator reads, with the same
include paths, and runs clang on each. A file clang cannot parse keeps the regex
kinds and is reported on stderr. Still unparsed: `mruby-dir` (its presym IDs are
outside the closed build), wio's `io_hal.c`, `mruby-onig-regexp` (needs
oniguruma) and `profiler.cxx` (`mrb_gc_type_counts` is not in this build).
