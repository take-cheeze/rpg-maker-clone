# 0149: bc2cpp keyword-argument support

## Status

Accepted.

## Context

Following ADR 0148's own optional-positional-argument round, keyword
arguments (`def foo(a, b: 1, c:)`) were the next largest remaining
argument-handling gap: a real closed-world survey found 29 real methods
blocked by a keyword-only `ENTER` shape (every other non-mandatory field
zero), every one of them with `kwrest == 0` (no real `**rest` receiver) --
confirmed directly, not assumed, so this round's own `kwrest == 0`
boundary is not a narrowing against any currently-blocked real method.

Real per-keyword bytecode shape, confirmed directly against real
disassembly for both a required and an optional keyword in the same
method (`def foo(a, b: 1, c:)`):

- A **required** keyword compiles to a single, unguarded `KARG R<reg>
  :name` -- nothing else. mruby's own `mrb_get_args` (`mrb_kwargs`) already
  raises a real `ArgumentError` for a missing required keyword before this
  instruction is ever reached.
- An **optional** keyword compiles to `KEY_P R<reg> :name` (a presence
  check, writing a bool into the same register) followed by a real
  `JMPIF`: the "given" branch jumps straight to a `KARG R<reg> :name`
  fetching the real value; the "not given" branch falls through to compute
  the default value (arbitrary, already-supported bytecode -- a literal,
  an ivar read, ...) into that same register, then `JMP`s past the
  redundant `KARG`.
- `KEYEND` (present whenever `kwrest == 0`) marks the end of keyword
  processing -- its own real effect (raising `ArgumentError` on an
  unrecognized keyword) is mruby's own `mrb_kwargs` behavior when its
  `rest` field is `NULL`.
- Whether or not a real `**kwrest` is declared, mrbc's own codegen
  unconditionally builds a `HASH`/`LOADSYM`/`MOVE` literal-construction
  sequence into an internal, always-unused (when `kwrest == 0`) `**`-named
  local -- already-supported opcodes, so this compiles as harmless dead
  code needing no special handling.

## Decision

Unlike ADR 0148's own `ENTER`-jump-table replacement (which genuinely
needed a suppressed-address/glue-at region, since the real jump table has
no direct per-instruction translation on its own), keyword arguments need
**no region-replacement mechanism at all**: `KEY_P`, `KARG`, and `KEYEND`
become three new, ordinary `compile_insn` cases, translated in place by
the same per-instruction loop as everything else. Every opcode around them
(`JMPIF`/`JMP` for the presence branch, any already-supported opcode for a
default-value expression) already works unmodified.

- `KEY_P Rd :name` → `r<d> = mrb_bool_value(bc2cpp_kw_given_<name>);` --
  reads a new, real `mrb_int` `_impl` parameter, one per optional keyword.
- `KARG Rd :name` → `r<d> = bc2cpp_kwarg_<name>;` -- reads a new, real
  `mrb_value` `_impl` parameter, one per keyword (required or optional
  alike).
- `KEYEND` → a no-op comment: the real unrecognized-keyword check is
  already done by the entry wrapper's own `mrb_kwargs` (`rest: NULL`)
  before `_impl` is ever reached.

Both new parameter names are derived purely from the instruction's own
`:name` operand (via `sanitize_c_ident`, see below) -- `compile_insn`
threads no external per-method keyword table at all; `keyword_arg_table`
(a new top-level function, the only place that *does* need the full list)
exists solely for `compile_method` to build `_impl`'s own signature and
the entry wrapper's real extraction code, both keyed by the identical
name-derivation scheme.

The entry wrapper builds mruby's own real `mrb_kwargs` struct
(`3rd/mruby/include/mruby.h`) directly: a `mrb_sym` table listing every
required keyword first (the API's own documented requirement), then every
optional one; `mrb_get_args(M, "...:", ..., &kwargs)` fills `values[]`,
`mrb_undef_p` distinguishing an omitted optional keyword (mapped to a real
`mrb_nil_value()` placeholder before being passed into `_impl`, the same
trust model ADR 0148's own optional-positional-argument placeholder
already established) from a genuinely given one; `rest: NULL` reproduces
`KEYEND`'s own real semantics for free. Devirtualization and ivar
embedding are left untouched this round, matching ADR 0148's own established
practice -- a keyword-arg method is never a direct-call target and its
`#initialize` never embeds.

### A real, previously-latent bug found and fixed along the way

Building and verifying this round surfaced a real, pre-existing bug in
every `JMPNOT`/`JMPIF`/`JMPNIL` target-address extraction in this file:
`a[/(\d+)\s*$/, 1].to_i`, anchored to the true end of the arguments
string, silently returns `0` (`nil.to_i`) the moment that string ends in a
real disassembly comment that doesn't itself end in a digit (`"R5\t016\t;
R5:b"` -- a comment mrbc only ever emits when the branch register happens
to be a genuinely *named* local variable). Every real `JMPIF`/`JMPNOT`
call site anywhere in this codebase before this round tested an unnamed
temp register instead, so no comment ever appeared and the bug stayed
silent; `KEY_P`'s own translation is the first opcode in this file to ever
write its result directly into a named register that a `JMPIF` then
branches on. Caught for real (not hypothetical) building `def foo(a, b: 1,
c:)`: the generated code read `if (mrb_test(r5)) goto L0;` instead of
`goto L16;`, a real, silent wrong-target `goto` that would have jumped to
the top of the function's own register declarations instead of the real
keyword-value fetch. Fixed with a new shared `jmp_target_after_reg` helper
(anchored right after the register operand instead of at the true string
end, correct with or without a trailing comment) and applied to all 7 real
call sites across `jump_targets`, `recognize_rescue_regions`, its own
escape-check lambda, `compile_block_body_insn`'s three `JMPNOT`/`JMPIF`/
`JMPNIL` cases, and the main `compile_insn`'s own three cases -- re-verified
every existing real test harness (optional-arg, `.times` block-inlining,
RESCUE) still passes unchanged afterward.

## Verification

- Real runtime test (through real interpreted Ruby call sites, `mrb_load_string`
  -- the only way to exercise mruby's own real keyword-argument calling
  convention; the public `mrb_funcall*` C API has no way to mark a
  trailing hash as real kwargs, that distinction only exists at the real
  bytecode/call-site level): a required + optional keyword together
  (default and explicit value), an all-optional-keyword method with both
  keywords defaulted and both given, `#send` dispatch, a keyword name that
  collides with a C++ reserved word (`default:`), a missing required
  keyword correctly raising `ArgumentError`, and an unrecognized keyword
  correctly raising `ArgumentError` (no `**rest` declared). All 9 pass.
- Every pre-existing real test harness from ADR 0145/0147/0148 (RESCUE,
  `.times` block inlining, optional positional arguments) re-run and still
  passing, confirming the `jmp_target_after_reg` fix is a strict
  correctness fix with zero regressions.
- Real end-to-end regen of all three `*-compiled` gems (`SKIP_UNSUPPORTED=1`,
  matching the real build; `OTHER_DECLS_HEADER` two-pass, matching each
  gem's own `mrbgem.rake`): zero regressions (the before/after set of real
  compiled function names is identical apart from real additions), 17
  previously-uncompiled real methods in `mruby-rpg2k-compiled` now compile
  clean (zero in `mruby-lcf-compiled`/`mruby-rgss-compiled` -- no
  keyword-only method exists in either gem's own currently-covered
  owners). None of the 17 wired into `register.cxx` this round, matching
  ADR 0148's own established split between an opcode/calling-convention
  round and a later coverage round.
- All three gems' own `register.cxx` compile clean (`g++ -fsyntax-only`)
  against the regenerated output.

## Consequences

- `*rest`/`**kwrest` (a real `**opts` receiver) and a block parameter
  remain unconditionally unmodeled -- a real `**kwrest` needs its own
  register populated directly by the VM's own `ENTER` semantics rather
  than any `KARG`/`KEY_P` instruction at all, a materially different shape
  this round doesn't attempt.
- Devirtualization and ivar embedding both still treat every keyword-arg
  method exactly as unsupported (dynamic dispatch only, never embedded),
  same as ADR 0148's own optional-positional-argument round.
- Wiring any of the 17 newly-unlocked methods into `mruby-rpg2k-compiled`'s
  own `register.cxx` is a separate, later coverage-round PR, not this one.
- `jmp_target_after_reg`'s own fix is now the one, single place every real
  `JMPNOT`/`JMPIF`/`JMPNIL` target extraction in this file goes through --
  a future opcode round that writes its own result into a named register
  and then branches on it (the exact shape that surfaced this bug) inherits
  the fix for free.
