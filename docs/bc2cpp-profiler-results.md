# Profiler block return classes

bc2cpp can retain the exact class returned by a literal block passed to
`RGSS::Profiler.section(name)` or `RGSS::Profiler.frame`. Later sends, return
facts and argument pools can use that class. The original timing behavior stays
in place; proving a result does not replace the call itself.

The proof audits the complete native Profiler source, including its disabled
profiling and compiled-out implementations. It requires stable constants,
visible native registrations, a dominating literal block and zero block
parameters. Ruby or native replacements, aliases, installers, lexical shadows,
unknown mixins, nonlocal returns and descendant breaks withdraw the fact.
Captured values, ivars and entry arguments remain unknown inside this analysis.

Return facts grow from an empty set during the compiler fixpoint. A changed
callee result invalidates both the block and its enclosing Profiler result;
unknown arms are never discarded. There is no additional result cache.

Profiler helpers also keep captured slots separate from their local frame and
bind captures by reference. Nested helpers receive pointers from the correct
parent frame. Nonlocal returns retain the existing block fallback, which can
return from the enclosing Ruby method.

Set `BC2CPP_PROFILER_RESULTS=0` to withdraw the result proof while retaining the
helper correctness repairs. Compare the same source tree with the switch off
and on using `scripts/bc2cpp_coverage_report.rb`. Static call counts are not
runtime speed measurements.

```sh
MRBC=/path/to/mrbc BC2CPP_MRUBY_FULL=/path/to/full-core/build \
  ruby scripts/bc2cpp_profiler_results_check.rb
MRBC=/path/to/mrbc BC2CPP_MRUBY_FULL=/path/to/full-core/build \
  ruby scripts/bc2cpp_profiler_results_mutation_check.rb
```

The checks cover native source changes, replacement and rebinding refusals,
fixpoint dependencies, captured slots, block exits and interpreted/compiled
parity with profiling enabled and disabled. See [ADR 0344](adr/0344-bc2cpp-profiler-block-results.md).
