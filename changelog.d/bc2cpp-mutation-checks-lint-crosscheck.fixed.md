- bc2cpp mutation checks no longer abort every mutant on the lint cross-check (ADR 0368): the shared mutant pool turns
  `BC2CPP_LINT_CROSSCHECK` off for a mutant, which is a copy of `tools/bc2cpp` with no lint script beside it. The
  native-class-arms mutation check's stale mutation site in `codegen_send.rb` is updated. These checks run only on
  pushes to master, so the pull-request runs of #2054, #2055 and #2056 did not show them failing.
