# 0517. Avoid repeated decoding and translation-unit emission in type reports

Date: 2026-10-21

## Status

Accepted

## Context

Type checking needs the compiler's settled facts and method compilation: receiver
rows, declared-return guards and nilable-index diagnostics depend on those steps.
It discards the final C++ translation unit. Context queries also repeatedly decode
the same numeric class masks and scan every registered private container shape.

## Decision

Have `TypeCheckRun` request `BC2CPP_TYPE_CHECK_ONLY=1`. Require a facts destination
and reject shared emission units in this mode. Exit successfully after method
compilation, declared-return guard validation and nilable-index collection, before
translation-unit assembly. Receiver-report writers still run through `at_exit`.
Ordinary compiler invocations retain their complete emission path.

Within each context engine, cache up to 2048 class-mask decodings, including
unknown results. Clear the cache whenever a private shape is registered. Keep an
aggregate registered-shape mask and enumerate only the set bits of each query.
The generator's native and numeric class tables are settled before these report
queries; the cache never crosses a generator instance or program world.

## Consequences

Reports retain the same facts, receiver rows, diagnostics and exit status.
Type-check `--keep` directories retain analysis diagnostics rather than final
emission listings and C++ declaration sidecars. Full emission can still be used
for comparisons through `TypeCheckRun`'s `extra_env` override. Cache growth stays
bounded and refusal invalidation has a host regression check; compiler fixtures
compare the complete facts and receiver rows against full emission.
