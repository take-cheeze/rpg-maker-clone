# 0247. Resolve qualified constants in constructor analysis

Date: 2026-09-29

## Status

Accepted

## Context

Constructor analysis walks backward from `new` through `GETMCNST` and
`GETCONST`. For an explicitly qualified receiver such as
`Namespace::Record.new`, the recovered name is already rooted at the constant
read. Prefixing the caller's lexical owner can invent a nonexistent name such
as `Caller::Namespace::Record`, leaving a direct constructor path undiscovered.

## Decision

When a constructor receiver has an explicit constant path, resolve the complete
written name directly against the closed-world class-name set. Continue using
lexical nesting for relative, unqualified names. Direct construction still
requires the existing stable constant, standard constructor lookup, initializer
arity and compilation, and emitted-owner proofs.

Use a qualified nested-class fixture to verify both the selected initializer
and generated C++ compilation.

## Consequences

Qualified class constants can reach the existing compiled-initializer direct
construction path from nested lexical scopes. The proof does not change
constructor admission or remove runtime fallback for classes that fail those
checks. The same guarded `mrb_obj_new` path also handles `Array.new` using
`Array`, `Hash`, and `Range` through their captured mruby class pointers, while
leaving each initializer to normal runtime dispatch.
