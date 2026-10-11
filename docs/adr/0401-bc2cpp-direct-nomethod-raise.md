# 0401. Reviewed dead fallbacks raise directly, not through dispatch

Date: 2026-10-11

## Status

Accepted. Supersedes ADR 0226 for reviewed sites (the runtime `bc2cpp_nomethod` arm, see Decision).

## Context

ADR 0226 lists every closed-world dead fallback (a `bc2cpp_nomethod` site, ADR 0210) in
`NOMETHOD_REVIEWED`, and keeps the runtime `bc2cpp_nomethod` at each reviewed site. That helper
dispatches first (`mrb_funcall_argv`) and only then raises: a NoMethodError when nothing answers,
and a RuntimeError "closed-world proof violated" (ADR 0262) when a method is found. ADR 0275 adds a
verify switch that aborts instead of dispatching.

On the shipped wio pass, all 4206 dead-fallback sites are reviewed (2935 keys). Each still costs an
out-of-line dispatch that can never find a method, so the 4496 `bc2cpp_nomethod(M` / `_named(M`
calls in the shipped output are mostly these sites.

## Decision

A reviewed dead fallback emits `bc2cpp_nomethod_raise`, which raises the NoMethodError directly
without dispatching. It calls `mrb_no_method_error` with the same format as mruby's
`mrb_method_missing` (`"undefined method '%n' for %T"`), which is what dispatch reaches when no
method answers and `method_missing` is the basic one. The closed world proves both premises for
every site it emits (a `bc2cpp_nomethod` marker is only written when the proof holds). The
`NOMETHOD_VERIFY` abort is kept.

Only sites whose key is in `NOMETHOD_REVIEWED` change (`NomethodReviewed.direct_raise`, run in
`bc2cpp.rb` before the symbol rewrite). The `/* CLOSED_WORLD nomethod: ... */` marker stays on the
new call, so the gate still counts and checks every site. Unreviewed sites keep the dispatching
fallback. No keys are added or removed.

Two behaviours change, both accepted by the session owner:

- A proof violation (a method exists for a reviewed site) no longer runs that method and then
  raises RuntimeError. It raises the NoMethodError directly. ADR 0262's distinct RuntimeError is
  lost for reviewed sites in non-verify builds. The verify build (ADR 0275) still aborts naming the
  site.
- At the call-depth limit (`MRB_CALL_LEVEL_MAX`) dispatch raised SystemStackError, because
  `mrb_funcall_with_block` needs a new frame. The direct raise gives NoMethodError.

## Consequences

- Shipped wio pass: `bc2cpp_nomethod(M` / `_named(M` calls 4496 -> 290; `bc2cpp_nomethod_raise(M`
  0 -> 4206; `bc2cpp_send(M` 2096 -> 2096; live `mrb_funcall` 393 -> 393; gate markers 4206 -> 4206.
  Apart from the callee rename and the new helper, the generated C++ is unchanged.
- Verified: the NoMethodError (class, message, name, args, backtrace) matches the dispatching form
  against a real mruby core (`scripts/bc2cpp_nomethod_raise_check.rb`). The verify abort is
  unchanged. The reviewed-list, proven-miss and nested-compile-state checks pass.
- Unreviewed sites and sites outside the closed world are unaffected.
