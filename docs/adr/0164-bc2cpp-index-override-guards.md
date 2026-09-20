# 0164: bc2cpp exact-class guards for indexed access

Date: 2026-09-20

## Status

Accepted

## Context

bc2cpp translates `GETIDX`, `GETIDX0`, and `SETIDX` with native Array, Hash,
and String fast paths. The fast paths checked only the runtime type tag, while
mruby's VM also checks that the receiver has the exact built-in class before
bypassing Ruby method dispatch. A subclass or singleton class can override
`[]` or `[]=`, so a type-tag-only check can return a different result from the
interpreter.

## Decision

Require both the built-in type tag and exact base-class pointer for generic
Array, Hash, and String fast paths. Apply the same class check to statically
proven Array and Hash paths. If the tag is the expected container type but its
class is a subclass or singleton class, call the real `[]` or `[]=` method.
Keep the existing TypeError for a receiver whose type tag contradicts a
statically proven container class.

## Consequences

- Base containers keep their current native fast paths.
- Subclasses and singleton overrides now follow mruby's normal method lookup.
- A wrong static type proof still raises instead of silently applying an
  unrelated container operation.
