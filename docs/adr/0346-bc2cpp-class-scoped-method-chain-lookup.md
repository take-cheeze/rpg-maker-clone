# 0346. bc2cpp: scope exact method-chain lookup to the receiver class

Date: 2026-10-05

## Status

Accepted

## Context

ADR 0345 added receiver-scoped return summaries, but their exact target lookup still required
`ClosedWorld#name_fully_visible?`. That whole-name gate rejected an otherwise unique Ruby body whenever
an outside native or Ruby source defined the same name on an unrelated class. The codebase already
has `CallFacts::Answers#resolves_in_ruby?`, which audits the ordered lookup path for one receiver and
declines when a native, foreign Ruby definition, module, unknown installer or unresolved owner could
win.

## Decision

Use `CallFacts::Answers#resolves_in_ruby?` for exact-instance method selection. The owner is accepted
only when the first definition on its known lookup path is the Ruby body selected from the registry.
Receiver-scoped return analysis uses that same lookup, so a method chain can cross an unrelated
outside definition without assuming it could replace the receiver's body.

Native owner names are simple for top-level classes. A match with a declared top-level class is
unambiguous; nested classes still require the outside source to spell the full path, as enforced by
`ClosedWorld#outside_spells_class?`. A native definition on the receiver or an ancestor, a foreign
definition on that path, an unresolved native owner, or any existing world-wide refusal keeps dynamic
dispatch.

## Proofs and measurement

`scripts/bc2cpp_return_class_check.rb` covers unrelated outside Ruby and native owners, an unresolved
native owner, a native owner on the receiver, dynamic method installation, mixed return classes and
the `BC2CPP_CALL_FACTS=0` withdrawal. Its full-core fixture compares interpreted and compiled results
and exceptions.

The Wio shipped-build census (`MRBC=build/mruby/host/mrbc/bin/mrbc
ruby scripts/bc2cpp_coverage_report.rb`) remained at 2,773 cached dynamic-send sites and 897
POLY-marked sites, the same as the ADR 0345 baseline. Clean entry points also remained 3,056.
The guard-free `EXACT_TYPED` diagnostic changed from 426 to 27, but that shift did not reduce
the aggregate dynamic-send count, so it is not counted as a shipped dispatch removal. The fixture
proves the new route for unrelated outside definitions; this Wio source set does not contain a
matching chain that benefits from it.

## Consequences

Exact calls can use a Ruby method body when same-named outside definitions are confined to other
classes. This also lets CFG-aware return summaries extend more receiver chains. Unknown ancestry,
unresolved owners, and outside definitions on the receiver's lookup chain still withdraw the proof.
