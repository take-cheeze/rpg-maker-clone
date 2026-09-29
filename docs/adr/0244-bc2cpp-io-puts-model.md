# 0244. bc2cpp models IO#puts with explicit arguments

Date: 2026-09-28

## Status

Accepted

## Context

`IO#puts` is a native mruby-io C function, but its ordinary entry point obtains
arguments from the active VM frame with `mrb_get_args`. bc2cpp already has the
arguments in generated C++ registers, and its unresolved receiver diagnostics
were dominated by calls through `$stdout.puts`. Calling the private C function
directly from generated C++ is impossible, while assuming `$stdout` is an IO or
that its method has not been replaced would change Ruby behavior.

## Decision

Factor the implementation into a private argv-based body, keep the registered
frame-based C wrapper, and expose `mrb_io_puts_direct`. The helper looks up
`puts` on the receiver at runtime and invokes the argv body only when the
resolved C function pointer is exactly mruby-io's registered `io_puts_method`; a
different target returns false so generated code uses ordinary `mrb_funcall`.
The helper is carried as `patches/mruby-io-direct-puts.patch` and applied
idempotently by the host and cross-platform mruby build scripts.

## Consequences

Generated explicit-receiver `puts` calls avoid VM-frame argument extraction
when lookup reaches the original native method. Reassignment of `$stdout`, a
subclass override, a prepend or any custom receiver keeps normal dispatch.
`scripts/bc2cpp_io_puts_model_check.rb` checks generated calls for zero and one
argument, including the fallback. The helper preserves the original native
body's output conversion, array recursion, write preparation and return value.
