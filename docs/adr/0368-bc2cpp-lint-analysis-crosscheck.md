# 368. bc2cpp cross-checks the closed-world lint against its own analysis

Date: 2026-10-06

## Status

Accepted

## Context

Closed forms (ADRs 0290, 0359-0364) rest on two independent scans of the same
Ruby: `scripts/rpg2k_closed_world_lint.rb` (Prism, CI-gated, baseline of 8
offences in `mruby-rgss`) and `ClosedWorld` (bytecode, run by bc2cpp). On the
real build the analysis already reports no global refusal, no
`method_missing` class and no singleton maker, so the lint adds no proof power;
what it can add is a second opinion. Nothing compared the two, so a drift (a
lint cop gone stale, an analysis scan regressing) would only surface as a
runtime guard violation.

## Decision

On a closed-world build bc2cpp runs the lint (`LintCrosscheck.enforce!`) and
aborts when:

- the lint finds an offence outside the baseline, a malformed allow comment,
  or a stale baseline entry; or
- the lint reports no `Dynamic/MethodMissing` offence while `ClosedWorld` sees a
  `method_missing` class.

The runtime guards (`bc2cpp_guard_violation`) stay as they are: the cross-check
is a build-time gate in front of them, not a replacement.
`BC2CPP_LINT_CROSSCHECK=0` disables it. `scripts/bc2cpp_lint_crosscheck_check.rb`
covers it in the `ruby-checks` CI job.

## Consequences

- A build can no longer ship closed forms from a tree the lint rejects.
- The lint script gained `closed_world_lint_run`, shared by the CLI and bc2cpp.
- Only the lint's domain (the three gems' mrblib) is cross-checked; mruby core
  and third-party gems remain the analysis's job.
