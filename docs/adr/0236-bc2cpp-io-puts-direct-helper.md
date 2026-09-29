# 0236. Guarded direct calls to the mruby IO#puts body

Date: 2026-09-29

## Status

Accepted

## Context

bc2cpp can pass an explicit argument array to the native `IO#puts` body, but
mruby's registered C function obtains its arguments from the VM frame. Calling
that body as an ordinary C function therefore needs a small mruby-io helper.
Generated C++ is also used by core-only fixtures that do not link mruby-io.

## Decision

The mruby-io gem exposes `mrb_io_puts_direct`, which shares the original
`IO#puts` implementation after checking that method lookup still resolves to
the registered body. bc2cpp emits this call only when
`HAVE_MRUBY_IO_GEM` is defined; other builds retain normal Ruby dispatch and
do not reference the gem symbol. The declaration is emitted alongside the
generated code so fixtures do not need mruby-io's private include path.

The helper is applied to the pinned mruby source by the build's existing patch
step. The call keeps a dynamic fallback when method lookup finds an override.

## Consequences

IO puts can bypass the VM argument-frame wrapper in builds that include the
patched mruby-io gem. Core-only codegen fixtures continue to compile without
linking that gem. The helper must remain behaviorally equivalent to the
registered `IO#puts` C body and preserve its runtime method-identity check.
