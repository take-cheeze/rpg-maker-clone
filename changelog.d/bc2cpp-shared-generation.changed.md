- **bc2cpp** (ADR 0464): the compiled gems of a build share one whole-program analysis. `bc2cpp.rb --units PLAN` runs
  the analysis once and forks one generation per gem where the gems' environments first differ, and each child emits
  exactly what its own run would. The `*-compiled/mrbgem.rake` rules, `never_called_registrations` and
  `static_dispatch_registrations` use it.
