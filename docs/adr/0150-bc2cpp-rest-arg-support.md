# 0150: bc2cpp rest-argument (`*args`) support

## Status

Accepted.

## Context

Following ADR 0148 (optional positional arguments) and ADR 0149 (keyword
arguments), a real `*rest` splat parameter (`def foo(a, *rest)`) was the
next remaining argument-handling gap: a real closed-world survey (after
both prior rounds) found 7 real methods blocked by a rest-only `ENTER`
shape (every other non-mandatory field zero).

Real bytecode shape, confirmed directly against real disassembly rather
than assumed: `def foo(a, *rest)` compiles to `ENTER 1:0:1:0:0:0:0:0`
followed **immediately** by the method's own real first body instruction
-- nothing at all in between. Unlike ADR 0148's own `ENTER` jump table or
ADR 0149's own `KEY_P`/`KARG` instructions, a plain `*rest` needs **no
opcode-level recognition whatsoever**: mruby's own real `OP_ENTER` VM
semantics (`3rd/mruby/src/vm.c`) populate the rest register directly with
a real, already-boxed `Array` value before the method body ever starts
running. The rest register itself sits immediately after the last
mandatory argument's own register (`R2` for `mand=1`'s own `R1`) -- the
exact same contiguous layout ADR 0148's own `total_args = mand + opt`
already established for optional arguments.

## Decision

`rest_only_arity?` recognizes the one real shape (`rest` field nonzero,
`opt`/`mand2`/`kw`/`kwrest`/`block` all zero) and `compile_method` folds a
recognized `*rest` straight into the *same* `total_args`-driven mechanism
ADR 0148's own optional-argument extension already established -- one more
contiguous slot, needing no register-initialization or `_impl`-signature
change of its own at all (the generic per-position loop already assigns
whatever `mrb_value` parameter arrives at that position into its own
register, exactly as it always has for a mandatory argument). The *only*
genuinely `*rest`-specific code is the entry wrapper's own extraction:
`mrb_get_args`'s real `*` format specifier (`mruby.h`'s own format table)
hands back a raw `const mrb_value*` + `mrb_int` pair pointing directly
into the VM's own live call-frame stack -- never safe to keep past the
wrapper's own return, so it is copied into a real, independently-owned
`Array` right away via `mrb_ary_new_from_values` (the same real mruby core
API used for exactly this purpose) before being passed into `_impl`,
matching what the rest register already holds in the ordinary interpreted
path.

Devirtualization and ivar embedding are left untouched this round, same
established practice as ADR 0148/0149 -- a `*rest` method is never a
direct-call target and its `#initialize` never embeds (moot in practice:
none of the 7 real methods this round unlocks are `#initialize`).

## Verification

- Real runtime test through real interpreted Ruby call sites
  (`mrb_load_string`): a rest-only method called with 0 and N arguments;
  a mandatory-plus-rest method called with just the mandatory argument
  (rest is a real, empty `Array`) and with several extra arguments (rest
  correctly holds them in order); `#send` dispatch; and confirmation that
  the returned `Array` remains a real, usable, independently-owned object
  after the call returns (never a dangling alias into the VM's own
  transient call-frame stack). All 6 pass.
- Real end-to-end regen of all three `*-compiled` gems
  (`SKIP_UNSUPPORTED=1`, matching the real build; `OTHER_DECLS_HEADER`
  two-pass, matching each gem's own `mrbgem.rake`): zero regressions, 1
  previously-uncompiled real method (`LCF::Array1D#method_missing`) now
  compiles clean in `mruby-lcf-compiled`. The other 6 real rest-only
  survey hits stay unresolved for their own separate, already-understood
  gaps -- confirmed directly, not assumed: `LCF::File#method_missing`
  forwards via `@root.__send__ sym, *args`, a real splat-argument *call
  site* (an entirely different gap this round doesn't touch: expanding a
  splat into a dynamic-arity `mrb_funcall`, never attempted here);
  `LCF::Sections#method_missing` ends in a bare `super`, hitting the
  existing `SUPER_TARGETS` allowlist gate (ADR 0146) rather than anything
  `*rest`-related. Not wiring the 1 newly-unlocked method into
  `mruby-lcf-compiled`'s own `register.cxx` matches ADR 0148/0149's own
  established split between an opcode/calling-convention round and a
  later coverage round.
- All three gems' own `register.cxx` compile clean (`g++ -fsyntax-only`)
  against the regenerated output.

## Consequences

- A splat *at a call site* (`foo(*args)`, expanding a real Array into a
  dynamic-arity call) remains completely unaddressed -- a materially
  different gap from a `*rest` *parameter*, confirmed as the real reason
  `LCF::File#method_missing` still doesn't compile.
- `mand2` (post-splat mandatory arguments, `def foo(a, *rest, z)`) stays
  unmodeled -- zero real methods in this program's own closed world need
  it, confirmed by this round's own survey, so it was never a live gap
  worth the extra scope.
- Wiring `LCF::Array1D#method_missing` into `mruby-lcf-compiled`'s own
  `register.cxx` is a separate, later coverage-round PR, not this one.
