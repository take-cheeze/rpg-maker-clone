# 0347. bc2cpp: pass native float arguments directly

Date: 2026-10-05

## Status

Accepted

## Context

bc2cpp already emits direct calls for some RGSS native bindings, but excludes
float arguments even when the binding's C entry point and argument parser are
known. Those calls retain cached dynamic dispatch without adding safety.

## Decision

Allow `:float` in the native-direct compiler argument set and convert generated
arguments with `mrb_as_float`, the same conversion used by mruby's
`mrb_get_args("f")`. Calls with unsupported argument kinds and unproved
receivers continue through dispatch.

## Proofs and measurement

`scripts/bc2cpp_native_direct_check.rb` verifies that float arguments reach
the angle, zoom and transition-alpha native entry points through
`mrb_as_float`, while an unknown receiver class retains `bc2cpp_send`.
The Wio census decreases cached dynamic-send sites from 2,773 to 2,772 and
"everything else" from 1,876 to 1,875; POLY sites and compiled entry points
are unchanged.

## Consequences

Float-taking native bindings can use direct calls when the receiver and
binding are proven. The conversion retains the binding's mruby float coercion
and error behavior.
