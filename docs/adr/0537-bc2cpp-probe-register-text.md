# 0537. Skip discarded register-text optimization in eligibility probes

Date: 2026-10-22

## Status

Accepted

## Context

Embedding eligibility compiles method bodies and observes whether their generated
text contains `#error`. RegisterFlow then propagates register copies and removes
dead register writes from code these probes discard.

## Decision

Set a scoped probe flag inside `compiles_clean?` when entry specialization is off.
Specialization can cache emitted clone code, so its probes retain the full pass. Preserve instruction compilation,
capture analysis, code assembly and all existing gates. Skip only the RegisterFlow
text pass when every instruction text lacks `#error` and no runtime-installed name
audit is active. The pass only replaces register identifiers and removes writes,
so it cannot introduce `#error`. Error-bearing instruction texts retain the pass
because removing a write could remove that substring. Runtime-installed methods
retain the pass so their audit observes exactly the regular emitted text.

Keep the flag in the normal method-state save/restore table. Nested probes and
exceptions restore the caller; final emission starts with the default false.
`BC2CPP_PROBE_REGISTER_FLOW=0` restores the original probe path.

## Consequences

Eligibility avoids an unnecessary CFG/text analysis without sharing results across
worlds or layouts. Final code and eligibility caches retain their original behavior.
RegisterFlow statistics count fewer internal probe passes; emitted-method
optimization is unchanged. Differential fixtures retain error-bearing passes and
compare final generated C++ after probes.
