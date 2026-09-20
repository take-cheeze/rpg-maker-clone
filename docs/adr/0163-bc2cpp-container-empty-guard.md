# 0163: bc2cpp guarded container `empty?`

Date: 2026-09-20

## Status

Accepted

## Context

The native-only primitive gate cannot optimize `empty?` because the closed
world also defines `Game::MoveRoute#empty?`. mruby has separate native
implementations for Array, Hash, and String, each of which checks whether its
container length is zero. The flat method-name registry cannot use one direct
target for all of those registrations.

## Decision

Add a separate guarded path for zero-argument `empty?`. It handles only
receivers whose runtime type and class pointer identify the exact base Array,
Hash, or String class, and reproduces the corresponding length check. Subclasses,
singleton classes, and all other receiver types use ordinary `mrb_funcall`.
The compiler declines to emit this path if a registered Ruby definition
replaces one of the three base-class methods, or if a known or unresolved
prepend can intercept it.

## Consequences

- Exact base container calls avoid dynamic method lookup.
- The unrelated `Game::MoveRoute#empty?` definition remains correct because
  it uses the fallback.
- Future base-class overrides or prepends conservatively disable this fast path.
