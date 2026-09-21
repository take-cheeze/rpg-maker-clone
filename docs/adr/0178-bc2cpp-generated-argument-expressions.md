# 0178. Generate direct expressions for safe one-argument mruby methods

Date: 2026-09-21

## Status

Accepted

## Context

The source-derived native-expression generator handled zero-argument C
methods. Many simple mruby methods take one argument, but their wrappers read
it from the active VM call frame with `mrb_get_arg1`. Calling such a wrapper
from generated C++ would read the caller's frame and use the wrong value.
Reimplementing the method logic by hand would also drift from mruby's own
behavior.

## Decision

Recognize only registrations with exactly one required argument and replace
`mrb_get_arg1(mrb)` in the extracted C body with the already evaluated
call-site argument. Keep the same expression allowlist and exact receiver
guards used for zero-argument methods. For Hash key predicates, generate a call
to mruby's public `mrb_hash_key_p` helper; do not inline the hash table lookup
or equality behavior. This extends ADR 0177's accepted subset with this single
explicitly mapped frame read; other argument extraction remains unsupported.

## Consequences

`Hash#key?`, `#has_key?`, and `#member?` can use a generated exact-Hash path
while preserving normal dispatch for subclasses, overrides, and other
receiver types. The public helper retains mruby's hash/equality semantics.
Wrong arities and bodies with unsupported frame reads remain ordinary Ruby
dispatch. `Hash#include?` remains ungenerated because its name has other core
registrations with different implementations.
