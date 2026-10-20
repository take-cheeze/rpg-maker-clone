# bc2cpp fixture checks

`scripts/bc2cpp/check_support.rb` provides `FixtureCheck` for small checks that
compile Ruby snippets and inspect their bytecode. The constant-proof,
Struct-receiver and class-body checks use it; their script names remain stable
for CI and coverage registration.

Run a check with the patched host compiler:

```bash
MRBC=/path/to/host/mrbc ruby scripts/bc2cpp/class_bodies_check.rb
```

The harness uses `MRBC` when set, otherwise searches `PATH` for `mrbc`. An
explicit path that is missing or not executable fails the check. Without either
compiler source, the check prints `SKIP` and exits successfully. CI should keep
setting `MRBC` explicitly so a missing compiler cannot turn into a passing skip.
Compiler failures propagate as errors.

A check creates `FixtureCheck.new('example_check')`, calls `require_mrbc!`, then
uses `compile(source) { |ireps, root, directory| ... }`. Every call gets a fresh
temporary source/output directory, removed even when the block raises. Keep
fixtures separate when they reopen core methods or reuse constant names; sharing
a harness does not share their closed worlds. The directory is available for
fixture-specific RBS files. Checks still choose which bc2cpp modules to require
and whether to disable repository signatures.

Use `check(label, condition)` for each assertion and `finish!` for the count and
nonzero exit on failures. Labels and assertion counts remain visible rather than
collapsing multiple expectations into an opaque success result.

## Type-check report fixtures

`type_check_fixture.rb` shares the JSON CLI runner used by the argument, ivar
and context-result checks. It resolves an inherited `MRBC` before changing to
the fixture directory, builds the report command, checks the subprocess status
and parses stdout or an explicit `--out` report. Failures retain both output
streams. Callers retain their temporary directories, source programs, signature
configuration, tools overrides and feature-toggle runs; the helper neither
combines closed worlds nor caches reports from different configurations.
These checks keep their existing policy of running host assertions and skipping
compiler fixtures when `MRBC` is unset.
