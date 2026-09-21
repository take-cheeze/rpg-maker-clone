# 0180. Generate Array#push's one-argument path from mruby core C

Date: 2026-09-21

## Status

Accepted

## Context

mruby's core `Array#push` C wrapper accepts any argument count. For exactly one
argument it calls the public `mrb_ary_push` helper and returns the receiver;
for other counts it follows a separate bulk-append implementation. bc2cpp's
generated RPG2k output contains many one-argument `push` sends that still use
dynamic Ruby dispatch.

## Decision

Recognize only the one-argument branch at the start of mruby's registered
`mrb_ary_push_m` body. Emit `(mrb_ary_push(M, recv, arg0), recv)` behind the
same exact-Array class and override checks used by other C-derived paths.
Require the callsite argument count to match the extracted branch. Keep all
other argument counts on the existing method path.

## Consequences

The generated path calls mruby's public helper, preserving Array mutation,
frozen checks, capacity management, and GC barriers. Subclasses and non-Array
receivers use normal dispatch. In the existing compiled RPG2k artifact, 69
one-argument `push` sends were emitted as `mrb_funcall`; this is a static
callsite count, not a runtime speedup measurement.
