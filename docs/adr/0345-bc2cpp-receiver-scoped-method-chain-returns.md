# 0345. bc2cpp: receiver-scoped return classes extend exact method chains

Date: 2026-10-04

## Status

Accepted

## Context

ADR 0289's exact-class flow carries a proven result into the next send, but its
return table is keyed only by method name. If `A#handoff` returns `B` and
`B#handoff` returns `A`, the table joins both classes and loses the fact even
at `A.new.handoff`. The element-layout tracer has receiver-scoped return logic,
but its linear writer walk is guarded hint evidence and cannot justify an
unguarded direct call.

## Decision

When an exact-class flow reaches an explicit `SEND`/`SEND0` with one known user
class as receiver, it may analyze the method selected for that receiver through
`closed_world_exact_target`. The target's result is read from the existing
CFG-aware `NumericFlow` return analysis. The fact is accepted only when every
return has one exact class and the closed-world name and lookup checks prove
that runtime installation, outside definitions, mixins and unresolved lookup
cannot replace the selected body. Core classes, block sends, unknown receivers,
recursive active bodies, and nil/mixed/unmodelled returns keep the old result.

The exact-target lookup now also checks the whole-program Symbol installer set.
A per-method installer check does not account for a `define_method` in another
class body, which can replace a target after the source definition is scanned.

## Proofs and measurement

`scripts/bc2cpp_return_class_check.rb` covers two classes whose `handoff`
definitions return different classes, a subclass inheriting that method,
guard-free dispatch through each resulting class, and a runtime `define_method`
withdrawal. Its compiled-versus-interpreted runtime fixture checks the results
and exceptions when a full-core build is available.

On the same workspace Wio inputs, before and after both have 2,773 cached
`mrb_funcall_with_block` sites, 897 POLY sites, and 426 guard-free TYPED calls.
The receiver-proof census is byte-identical: 1,795 explicit-receiver sends
with by-name lines, 1,629 unproven receiver sets and 1,686 unproven by-name
lines. No shipped call currently matches this receiver-specific return shape.

The generated fixture exercises the intended opportunity directly: the
`handoff` name returns a different class for each exact receiver, and the three
resulting `tag` sends (including the inherited case) become direct exact calls.
The mixed-return and runtime-installer variants stay dynamic. This proves the
mechanism while recording that it has no shipped Wio reduction yet.

## Consequences

Class-specific return bodies can now extend exact chains even when a same-named
method elsewhere returns another class. Recursive class-specific return
cycles remain unproved; summaries do not assume a result across a recursive
edge. The receiver proof still requires a class bit already produced by the
exact-class flow, so this does not infer types from hints or from the element
layout's guarded scan.
