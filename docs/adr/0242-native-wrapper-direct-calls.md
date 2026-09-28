# 0242. Resolve proven native wrapper calls through frame independent bodies

Date: 2026-09-28

## Status

Accepted

## Context

Native mrbgem methods commonly enter through C wrappers that parse the active
mruby call frame with `mrb_get_args`. Calling such a wrapper directly from
compiled bytecode would inspect the caller's frame. A proven exact receiver
class identifies the implementation, but does not make that wrapper's frame
parsing safe.

## Decision

For RGSS native methods, provide frame independent entry points that accept the
already evaluated receiver and arguments. bc2cpp may call these only when its
bytecode trace proves the receiver class; generated code still checks the
native class pointer and falls back to ordinary dispatch if it differs. Keep
argument conversion, optional defaults, and validation in the shared native
body so wrapper and compiled calls have the same behavior.

## Consequences

`Bitmap#stretch_blt`, `Bitmap#copy_blt`, `Bitmap#text_size`, and both
`Bitmap#draw_text` argument forms can be called directly at RGSS Bitmap sites.
For `text_size`, the exact runtime class guard is enough even when static
receiver tracing has no class fact. Other native wrappers remain on normal
dispatch until they have an equivalent frame independent body and a class
guard.
