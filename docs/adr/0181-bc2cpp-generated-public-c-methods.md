# 0181. Generate direct calls to public frame-independent mruby C methods

Date: 2026-09-21

## Status

Accepted

## Context

Some mruby core methods are their own public C implementation. Their bodies
are too complex for expression extraction, but generated C++ can call the
registered function itself and let mruby retain the full implementation.
That is safe only when the function has a public header declaration, its
registration accepts no arguments, and the body does not read the active VM
call frame. C++ method registrations on classes created with
`mrb_define_class_under` also need their class names resolved so unrelated
methods do not disable built-in exact-class paths.

## Decision

For a zero-argument registration, generate `function(M, recv)` only when the
source definition is `MRB_API mrb_value function(mrb_state*, mrb_value)`, the
function is declared in one of the mruby headers included by bc2cpp, and its
body has no direct VM-frame reads. Continue to require an exact built-in class
guard and the existing whole-program override/prepend checks. Resolve literal
class names from `mrb_define_class_under` when collecting otherwise opaque C++
registrations. Unsupported bodies, undeclared helpers, other arities, and
unrecognized owners keep ordinary Ruby dispatch.

## Consequences

The generator can use the existing core implementations for Array `clear` and
`pop`, Hash `clear`, `keys`, and `values`, and String `intern`/`to_sym`, while
preserving each C function's allocation, mutation, frozen checks, and GC
behavior. The dedicated Optcarrot frame-buffer `Array#clear` path remains
separate because it intentionally retains backing capacity. In the existing
compiled RPG2k artifact, dynamic `clear`, `pop`, `keys`, and `values` sends
numbered 32, 17, 19, and 2 respectively; these are static send-site counts,
not runtime fast-path counts or FPS measurements.
