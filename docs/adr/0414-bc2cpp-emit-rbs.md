# 414. Emit the inferred types as RBS

Date: 2026-10-12

## Status

Accepted

## Context

The type check (ADR 0412) holds the inferred types as JSON and text, and signatures (ADR 0413) read RBS. Steep, TypeProf and
RBS-aware editors read RBS only. The cheap compatibility is to write what bc2cpp proved as RBS; full mruby-core RBS is out
of scope (CRuby's core RBS stands in where the names overlap).

## Decision

`type_check.rb --emit-rbs DIR` writes one `.rbs` per class / module (`tools/bc2cpp/type_check_rbs.rb`): superclass, `def`
with the inferred mandatory parameter types and return type, `@ivar: T`, `NAME: T`, `private`, `def self.x`. Unknown types are
`untyped`; optional/rest/keyword parameters are `untyped` and every method takes an optional block (the facts do not say
which yield). Classes the CRuby core RBS declares are not redeclared; only methods it lacks are written. A type naming a class
nobody declares becomes `untyped`; every line is parsed with the rbs gem before it is written.

The output directory is not read by the compiler unless named in `BC2CPP_SIG_DIRS`: reading it back turns inferred facts
into declared hints, and the type check then reports nothing (checked as a round trip, and a wrong edit is a located TC1001).
Facts gained the class/module kind and superclass, every constant (typed or not) with its owner, and the
keyword/rest shape of each method.

## Consequences

Steep can check CRuby-loadable code against what bc2cpp inferred; the honest results and the remaining work are in
docs/bc2cpp-type-check.md. The emitted text is a snapshot of an inference, not a maintained interface.
