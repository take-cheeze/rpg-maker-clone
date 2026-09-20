# 0168: Devirtualize indexed writes through exact compiled classes

Date: 2026-09-21

## Status

Accepted

## Context

mrbc emits indexed writes as `SETIDX`. bc2cpp specializes exact built-in
Array and Hash receivers, while other receivers use a dynamic `[]=` send even
when whole-program analysis can prove an exact compiled class. This leaves
user-defined indexed writes performing method lookup on every assignment.

`SETIDX` also has observable result semantics: the built-in Array and Hash
paths return the assigned value, while its Ruby `[]=` fallback returns the
method's result. A guarded fast path must retain this distinction and preserve
all previous behavior if the runtime class does not match the proof.

## Decision

When the receiver is traced to a class with a compiled `[]=`, ask the existing
send compiler for a guarded TYPED call. Keep that call only when the emitted
code has the exact-class guard; otherwise use the existing SETIDX lowering.
The guard's fallback contains the unchanged Array, Hash, and dynamic dispatch
paths, and the typed call returns the compiled method's result.

The synthetic `scripts/bc2cpp_setidx_devirtualization_check.rb` regression
check verifies the TYPED call, runtime guard, and fallback paths. CI runs it
with the same host mrbc used by the other bc2cpp analysis checks.

## Consequences

Proven user-defined indexed writes can bypass Ruby method lookup while
preserving runtime overrides, fallback behavior, and SETIDX result semantics.
Built-in Array and Hash paths are unchanged. The opportunity remains limited
to receiver classes and `[]=` implementations already known to bc2cpp.
