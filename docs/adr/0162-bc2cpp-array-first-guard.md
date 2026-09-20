# 0162: bc2cpp exact-Array guard for zero-argument `first`

Date: 2026-09-20

## Status

Accepted

## Context

bc2cpp already devirtualizes `first` with a runtime type guard for Range. The
Array implementation, `mrb_ary_first`, cannot be called directly from generated
code because it reads the active VM call frame's argument count to distinguish
`first` from `first(n)`. The native primitive path only admits zero-argument
calls, so the Array zero-argument behavior can be reproduced without consulting
that frame.

## Decision

For zero-argument `first`, use the Array fast path only when the receiver has
the exact base Array class. Return element zero for a nonempty array and `nil`
for an empty array, matching `mrb_ary_first`. Subclasses, singleton classes,
Range values outside the existing Range path, and all other receivers retain
the ordinary `mrb_funcall` fallback. The existing whole-program native-only
gate still excludes names with a compiled bytecode override.

## Consequences

- Exact base Array calls avoid method lookup without calling a helper that
  depends on the active VM call frame.
- Array subclasses and singleton overrides preserve normal Ruby dispatch.
- Calls with an argument, including `first(n)`, remain outside this fast path.
