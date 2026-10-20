# Adding or reorganizing bc2cpp checks

Start with the proof or behavior the check must protect. Add cases to an existing
suite when its setup and execution requirements match. Keep a separate entrypoint
when it needs a different build, mutates sources or tests an independent runtime
scenario. Fewer files alone do not justify merging fixture programs.

## Preserve fixture boundaries

Give core-method replacements, repeated constant definitions and mutation variants
their own program and registry. A shared Ruby process can share loaded libraries,
while case modules keep helper methods and mutable state private. Compare the
complete assertion-label counts before and after a reorganization, including
refusal and withdrawal cases.

For small compiled-source checks, use
[`FixtureCheck`](bc2cpp-fixture-checks.md) for compiler discovery, fresh temporary
programs, visible assertions and failure reporting. Keep host-only assertions
runnable when the compiler is absent. A configured but invalid compiler must fail;
a successful host-only section does not establish that compiled fixtures passed.
Use the real MRBC and required libraries when validating compiler or runtime cases.

## Declare the execution requirements

The [tier and capability inventory](bc2cpp-check-tiers.md) distinguishes ordinary
host execution, compiler fixtures, full runtime checks, mutation audits and
argument-driven review utilities. Record the dependencies the selected sections
actually use: MRBC, native sources, a core/full library or a comparison Git base.
Host and fixture sections may have different requirements.

The workflow commands and coverage reporter remain the execution lists. Register
host checks in `scripts/coverage/report.rb`; register compiler fixtures in the
prepared compiler job as well when the host run skips those sections. Declare the
capability requirements in the registry policy so moving a check to an unsuitable
runner fails validation. A deferred check needs an explicit tier and reason;
deferral does not imply that ordinary CI runs it.

Run each entrypoint once per intended execution site. Shared helpers and case
modules should not use an `_check.rb` name unless they are standalone checks.
Prepare reusable libraries before a parallel group, and never run source-mutating
cases concurrently against the same files.

## Validate the registration and the behavior

Run `ruby scripts/ci/check_registry.rb` and the relevant focused checks. Exercise
host-only and actual compiler/runtime sections when both exist; inspect skip
messages rather than treating an exit status alone as proof of full coverage.
Use the coverage reporter's `--list` and `--only` options to check registration.

Update current commands in `/docs` and `README.md`, add a changelog fragment, and
run `pre-commit run --all-files`. Run the affected host validators and the required
CTest suite. Keep historical design rationale in the ADRs; current CI documentation
must describe commands and jobs that still exist.
