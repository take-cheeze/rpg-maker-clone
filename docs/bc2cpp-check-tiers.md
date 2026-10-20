# bc2cpp check tiers and capabilities

Run `ruby scripts/ci/check_registry.rb` to audit registration and print the
explicitly classified checks. Execution remains defined by
`.github/workflows/build.yml` and `scripts/coverage/report.rb`; the policy in
`scripts/ci/bc2cpp_check_policy.yml` does not schedule any commands.

The policy distinguishes four tiers:

| Tier | Intended use |
| --- | --- |
| `fast` | Focused host or compiler-fixture checks suitable for routine CI. |
| `runtime` | Generated-world or compiled/interpreted checks needing a deliberate runtime budget. |
| `mutation` | Repeated runs against deliberately broken compiler copies. |
| `review` | Argument-driven checks applicable to a particular proposed change. |

These names describe purpose, not measured duration. Deferred runtime and
mutation checks remain deferred until explicitly added to an execution list.
A scheduled mutation check is permitted; the tier itself never selects a job.

Capabilities describe an inspected check's prerequisites: `mrbc` is a host
compiler, `native_sources` is the populated native mruby source tree,
`core_library` and `full_library` are prepared mruby link libraries, `cxx` is
a C++ compiler. `git_base` is an available comparison revision/history,
`closed_build` is the closed build directory with generated headers, and `clang`
is the native AST parser/preprocessor.
For checks accepting several library configurations, policy records a supported
configuration sufficient to exercise the full check. Runner declarations describe
what their setup provides, not what happens to be installed on a developer's
machine. Update them together with workflow setup changes.

`checks` records known active requirements. `capabilities` applies to every
registration; `fixture_capabilities` adds requirements for the complete fixture
slice. Thus a coverage registration may exercise the host portion of an IR
check without satisfying its MRBC fixture gate. A fixture gate defaults to
required: at least one workflow job must provide all requirements for that slice. An inspected coverage-only optional section
may set `fixture_gate: false` with a nonempty reason; the report explicitly
shows that its fixture is unscheduled. This records gaps without scheduling
heavy tests. `host_phase: false` marks an entrypoint whose coverage registration
skips every assertion without fixture prerequisites. The native format audit,
which always reads native sources, cannot be moved into a source-free host job.

`deferred` records the tier, capabilities, and reason for every discovered check
outside execution lists. The audit rejects unknown tiers/capabilities, missing
paths, empty reasons, duplicate registrations, unscheduled new checks, stale
scheduled deferrals and incompatible placements for classified checks.

Every current active entrypoint has inspected metadata. A newly scheduled check
without a policy record fails the audit, so registration alone cannot imply that
its capability requirements were reviewed. Update both the execution list and
policy when adding or moving a check.

Generation through the wio world or fixture runtime records `native_sources`
because those paths read real native registrations. Runtime metadata names a
supported library configuration, not every accepted fallback. Optional
width/no-bigint variants in tuple and LCF checks remain separate local extensions;
`workflow complete` describes the listed requirements, not every platform variant.
A pure host registration reports `host complete`; an optional fixture whose
prerequisites are not declared for an execution site remains visible as a gap.
