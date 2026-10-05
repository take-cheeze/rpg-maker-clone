# 0358. The Fixnum proof reaches the NATIVE_DIRECT_EXACT arm

Date: 2026-10-05

## Status

Accepted

## Context

A native entry point's `:int` argument is passed to a native `mrb_int`, and `mrb_integer()`
on a Float or a String raises where the binding's `mrb_get_args "i"` would have coerced it.
So every `:int` argument carries a runtime `mrb_integer_p` test, and the arm's else is the
by-name send that the binding would have reached anyway.

That test is only needed when the argument really can be something else. Two emitters have
long asked `native_int_arg_proven?` (ADR 0318) before emitting it: `codegen_send.rb`'s
`Bitmap.new` path and `codegen_native_exact_direct.rb`'s NATIVE_EXACT_DIRECT. ADR 0318
deferred the remaining arms with the reason that "an arm keeps its class test's else whatever
its arguments are".

That reason holds for NATIVE_DIRECT, where the receiver is still tested at run time and the
argument's own guard is not what makes the arm reachable. It does not hold for
NATIVE_DIRECT_EXACT: there the receiver is already proven exact (ADR 0280/0296), so the arm
has no class test, and the tag test's else is the *only* thing left in it. Every `:int`
argument the Fixnum proof already covered therefore kept a send that could not be reached.

The exact-class site had no way to ask the question. `exact_core_site` carries the irep, the
call index and the register offset, but not the `owner_def` that `native_int_arg_proven?`
needs, and `native_direct_wrap` had no `int_site` parameter at all.

## Decision

`exact_core_site` carries an `int_site` (`[irep, idx, owner_def, reg_offset]`), built from the
`owner_def` the caller already has. `native_direct_wrap` passes it to
`native_direct_exact_line`, and both emitters filter their `:int` positions through one new
gate, `native_int_guard_needed?`, which asks `native_int_arg_proven?` and is the only place
the new `BC2CPP_NATIVE_INT_GUARDS` switch is read.

NATIVE_DIRECT's class-tested branches are left alone. They are reached only when no
exact-core site matched, or when it matched a class with no entry point, so there is no
`int_site` to ask with; a proven receiver is routed to the exact line above instead.

## Consequences

The wio shipped pass loses 9 `bc2cpp_send` sites (`z=` 6, `x=` 2, `flash` 1), all removals:
no helper gains a caller, and the 26 remaining `mrb_integer_p` tests in
NATIVE_DIRECT_EXACT arms are the arguments the proof does not cover.

The class-tested NATIVE_DIRECT arms (68 sites with a send) are untouched and stay reachable
only by an argument the proof cannot name. Reaching them needs a receiver class fact, not an
argument fact, so the same lever does not apply there.

The kill switch reproduces the control output. The check pins the emitters' shape for every
answer the proof can give, including a position that is not the call's, and drives the real
`native_int_arg_proven?` over its own refusals; six mutants cover the gate, the switch and the
proof's register test.
