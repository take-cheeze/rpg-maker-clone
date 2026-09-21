# 0175: Use typed Hash arguments for guarded indexed-value calls

Date: 2026-09-21

## Status

Accepted

## Context

The profiled `RPG2k::Scene::Map#pictures_signature` path indexes the picture
Hash and then reads several properties from each value. Array element
annotations already feed guarded call devirtualization, but a Hash argument
had no syntax for naming its value class. As a result, `pics[id].name`,
`#x`, `#zoom`, and the other picture accessors remained dynamic.

## Decision

Accept `Hash<Klass>` alongside `Array<Klass>` in bc2cpp argument annotations.
The outer `Hash` class annotation remains subject to the existing closed
registry check. Element annotation extraction records both the value class
and container kind. When a `GETIDX`/`GETIDX0` receiver traces through plain
register moves to an incoming argument explicitly annotated `Hash<Klass>`,
use that value class as the indexed expression's class hint. The ordinary
Hash exact-class guard and Ruby `[]` fallback remain in place; subsequent
typed calls retain their own exact-class check and dynamic fallback.

## Consequences

Methods with a known Hash value type can devirtualize calls on indexed values.
The annotation is explicit and local to the method, and unannotated Hashes
retain their existing dynamic behavior. The synthetic check covers the
annotation parser, typed indexed-value call, and untyped fallback.
