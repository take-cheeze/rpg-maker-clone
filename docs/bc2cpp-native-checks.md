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
reporter in `ruby-checks`; neither needs mrbc, a native library or submodules.

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
