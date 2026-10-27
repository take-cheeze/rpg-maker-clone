- **bc2cpp**: the whole-program ivar proof behind the class pools no longer turns itself off for an `eval` no
  definition answers (a build without mruby-eval), or for a computed `instance_variable_set` on the implicit
  self, which now fails only that self's class family ([ivar proof scope](docs/bc2cpp-numeric-ivar-scope.md)).
  The optcarrot probe gets its first 42 ivar class pools, and the frame loop drops from 36.00M to 35.16M
  instructions per frame (callgrind). New check `scripts/bc2cpp/numeric_ivar_scope_check.rb`.
