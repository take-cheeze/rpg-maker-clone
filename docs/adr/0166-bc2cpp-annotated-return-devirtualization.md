# 0166: Use annotated return classes for guarded call devirtualization

Date: 2026-09-20

## Status

Accepted

## Context

bc2cpp reads `# bc2cpp: (...) -> Klass` return annotations for array-element
analysis, but its general typed call-site tracer did not use them. This left
calls on results such as `Game::Actors#[]` dynamic even though that method is
annotated to return `Game::Actor` (or `nil`). mrbc emits indexed reads as
`GETIDX`/`GETIDX0`, so tracing only ordinary sends cannot reach this evidence.

## Decision

Allow the typed call-site path to consume return-class annotations only after
tracing the receiver to an exact class and finding that class's method
definition. Trace the receiver of `GETIDX` and `GETIDX0` in the same way,
then read the exact class's `[]` annotation. Existing TYPED code checks the
runtime class before the compiled call and falls back to Ruby dispatch if the
check fails. In shifted block bodies, pass the real instruction index and
translate the receiver register back to the block's register numbering for
this read-only trace. Resolve bare class hints lexically against registered
owners before looking up the annotated method.

## Consequences

Annotated result chains can now devirtualize calls such as `@roster[id].stat`
without special casing the polymorphic `[]` method name. Nil results and
unexpected receiver classes continue through the runtime fallback. Return
annotations remain useful only when the exact receiver definition is known.
The synthetic check in `scripts/bc2cpp_retclass_devirtualization_check.rb`
covers both `GETIDX` and `GETIDX0` and verifies the generated guard/fallback.
