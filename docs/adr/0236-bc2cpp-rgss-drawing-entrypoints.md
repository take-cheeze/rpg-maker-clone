# 0236. Frame-independent RGSS drawing entry points

Date: 2026-09-28

## Status

Accepted

## Context

RGSS drawing calls such as `Sprite#bitmap=` and `Bitmap#fill_rect` are native C
methods. Their registered wrappers use `mrb_get_args`, which reads arguments
from mruby's active C call frame. bc2cpp has receiver-class proofs for some of
these calls, but calling the registered wrapper directly from generated C++
would read the wrong frame.

## Decision

Keep each registered wrapper for ordinary Ruby dispatch and factor its body
into a frame-independent C++ entry point. bc2cpp may call that entry point only
when its receiver trace names the expected RGSS class, the runtime class
identity matches the gem-init-captured class, and the call shape is supported.
Inlined callers use their original bytecode index, register mapping, and
enclosing method's argument and ivar class facts for the receiver proof. The
generated branch retains ordinary dispatch as its fallback.

## Consequences

The supported `Sprite#bitmap=` and five-argument `Bitmap#fill_rect` sites can
skip method lookup without changing subclass or rebound-receiver behavior.
Other drawing methods and overloads remain dynamic until equivalent helpers
preserve their argument conversion and error behavior.
