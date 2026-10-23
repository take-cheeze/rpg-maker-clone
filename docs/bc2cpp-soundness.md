# bc2cpp soundness and runtime errors

bc2cpp compiles Ruby to C++ only for closed-world builds (psp, wio, maix with
`RPGMAKER_BC2CPP=1`; see [ADR 0466](adr/0466-bc2cpp-closed-world-only.md)). In such a
build the only Ruby that can run is the Ruby bc2cpp compiles, plus the scanned core
and native sources of the build's own gems (`tools/bc2cpp/closed_world.rb`). The
compiler proves facts about that world and uses them to skip dynamic dispatch. This
page states what a proof may and may not change at run time, in particular which
runtime errors (exceptions) compiled code may raise.

## The contract

A compiled program is sound when, for every input the closed world admits, it does
the same work as the original mruby program: the same results, the same side effects,
and the same exception class and message. Two kinds of exception are allowed, and
nothing else:

1. **The error mruby itself raises.** When a proof says a call site has no method
   for its receiver, the compiled code may skip the dispatch and raise the error mruby
   would raise. The class (`NoMethodError`) and the message (`undefined method '%n'
   for %T`) come from mruby's own `mrb_no_method_error`, so a `rescue` in game code
   sees the same exception.
2. **A loud proof violation.** If the proof is wrong, compiled code may raise an
   error mruby would not raise. Those errors are never silent: each one names the
   method and the reason. It is either logged to `$stderr` with the site, or is a
   `RuntimeError` that names the class and method. Under
   `BC2CPP_NOMETHOD_VERIFY=1` (see [the verify page](bc2cpp-nomethod-verify.md)) each
   one aborts instead of raising.

A compiled program is not allowed to raise an error mruby does not raise and then
hide it, and it is not allowed to dispatch a method the proof said was missing.

## The emitted sites

| Emitted helper | Used for | Behaviour | Matches mruby? |
| --- | --- | --- | --- |
| `bc2cpp_nomethod` | A guard-chain fallback proven dead (`ADR 0210`) | Dispatches with `mrb_funcall_argv`. If no method answers, mruby raises its own `NoMethodError`. If one answers, it raises `RuntimeError` `bc2cpp: closed-world proof violated: ...` | Yes when the proof holds. The `RuntimeError` is a proof violation |
| `bc2cpp_nomethod_raise` | A reviewed dead site that dispatch would also fail on (`DIRECT_RAISE`, ADR 0226) | Calls `mrb_no_method_error` directly, without dispatching | Yes, the same error |
| `bc2cpp_guard_violation` | The else arm of a guard on a stable class constant | Never dispatches. Logs `[RPG2k] closed-world guard violation: ...` to `$stderr` and raises `BC2cppGuardViolation` (a `NoMethodError` subclass) | No. Reaching it means the proof is wrong |
| Block self check (`BLOCK_SELF_WORLD`) | A compiled block run under a different `self` than its creator's | Logs the same way and raises `BC2cppGuardViolation` | No. Reaching it means the proof is wrong |
| `FAIL_FAST_TYPE` | Optional type-error variant of `bc2cpp_nomethod` (`BC2CPP_FAIL_FAST_TYPE`) | Raises `TypeError` instead of dispatching | No. Off in every shipped build |

The only sites that can raise an error mruby would not raise are the proof-violation
paths: the `RuntimeError` in `bc2cpp_nomethod`, the guard violation and the block
self check. `FAIL_FAST_TYPE` adds a fourth one, but it is compiled out unless someone
turns it on. Under a correct proof none of these is reached, so the errors a sound
build raises are exactly the errors the original mruby raises.

## Why a rescue can hide a violation

`NoMethodError` and `RuntimeError` are ordinary Ruby exceptions. Game code can
`rescue` them, and the rescue then hides the violation. The guard-violation and
block-self paths log to `$stderr` before raising, so a log line survives a rescue.
`bc2cpp_nomethod` does not log, which is why the verify build turns a reached
dead site into an `abort()`. Use `BC2CPP_NOMETHOD_VERIFY=1` when testing a proof
against real play.

## What the contract does not cover

- It applies only to closed-world builds. Desktop, wasm and Android builds run
  plain mruby, have no `bc2cpp_nomethod` sites and make no soundness claim.
- It does not promise identical backtraces, or that the `[RPG2k]` log line and the
  error message text stay the same across releases.
- It does not cover code that runs outside the closed world, such as Ruby the build
  loads from a data file. The closed world is the premise, not a result, so the
  proof does not reach past it.

## Where the claim is checked

- `scripts/bc2cpp/impossible_as_error_check.rb` builds the `bc2cpp_nomethod` helper
  against a real mruby core. When the proof holds it must raise the ordinary
  `NoMethodError`. When the proof is false it must raise the distinct
  `RuntimeError` that names the class and method.
- Nothing in this tree runs the verify-mode abort path or the guard-violation helper
  against mruby. Those two rely on review until a check is added.

Keep the contract in this page. Other pages should link here instead of restating it.
