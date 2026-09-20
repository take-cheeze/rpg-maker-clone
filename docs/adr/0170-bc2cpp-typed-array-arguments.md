# 0170: Carry array element types through annotated arguments

Date: 2026-09-21

## Status

Accepted

## Context

bc2cpp could use `Array<Klass>` return annotations when tracing the contents of
an array, but had no corresponding argument annotation. `Game::Battle` already
declared its `allies` and `enemies` parameters as `Array`, yet the element
analysis treated those incoming arrays as opaque. That left the battle's
`@allies` and `@enemies` element calls without exact-class evidence even though
the closed-world call site builds them from `Game::Battle::Combatant` values.

## Decision

Allow `Array<Klass>` in argument positions of the existing `# bc2cpp:`
annotation. The class-argument reader records the outer `Array` class and the
element-annotation reader records `Klass` separately. The array element sweep
uses the element fact only when its backward scan reaches an untouched incoming
argument register; normal writes, aliases, and block parameters keep their
existing rules.

Consumers continue to emit exact runtime-class checks for each element and
fall back to ordinary Ruby dispatch when an element has another class. The
outer array annotation follows the existing class-annotation checks.

## Consequences

`Game::Battle#initialize` can state that both incoming collections contain
`Game::Battle::Combatant`. This resolves the `@allies` and `@enemies` element
layouts and enables guarded calls from their inlined loops. The focused check in
`scripts/bc2cpp_retclass_devirtualization_check.rb` covers typed argument
parsing, Struct element recognition, and the generated guard/fallback. The
whole-program report should show the two new element hints; its static
`mrb_funcall` count still includes the fallback by design.
