# 0165: bc2cpp guarded Array and Hash `size`

Date: 2026-09-20

## Status

Accepted

## Context

`size` has a whole-program bytecode collision with `Game::Party#size`, so the
native-only name gate cannot optimize it. Array and Hash have distinct native
size implementations that use public length APIs. String's native
implementation instead uses `RSTRING_CHAR_LEN`, a private macro whose behavior
depends on the `MRB_UTF8_STRING` build flag.

## Decision

Add a separate zero-argument `size` path for exact base Array and Hash
receivers, guarded by both the runtime type tag and exact class pointer. The
compiler also verifies that neither base class has a registered Ruby override
or a known or unresolved prepend. String and all other receivers retain normal
`mrb_funcall` dispatch.

## Consequences

- Exact base Array and Hash calls avoid dynamic method lookup.
- `Game::Party#size`, String's build-sensitive behavior, subclasses, and
  singleton overrides preserve normal dispatch.
