# 0232. Embed Integer-or-nil ivars, and make the ADD trace sound

Date: 2026-09-26

## Status

Accepted

## Context

`IvarLayout` embedded three scalar types into a class's `RData` payload:
`mrb_int`, `mrb_sym`, and `mrb_bool`. Every one is an immediate, so the
payload needs no GC rooting, no write barrier, and no `dmark` callback
(`RData` has none: `gc_mark_children`'s `MRB_TT_CDATA` case marks only
`iv`). The natural next scalar is a nilable one -- `@x = nil` in
`#initialize`, a value afterwards -- which is common in engine state and
was previously unrepresentable, because `LOADNIL` returned `UNKNOWN` and
one nil write poisoned the whole field.

Two things blocked simply treating nil as a concrete value.

**`String#split` eats `#@`.** Ruby splits a string on a whitespace-
delimited `#` comment marker, so `split('#', 2)` silently truncates
`"Optcarrot::CPU#@opcode"` to `"Optcarrot::CPU"`. The declaration parser
scans for the literal separator instead; `scripts/bc2cpp_fixnum_nil_ivar_check.rb`
covers it.

**`trace_type`'s `ADD`/`ADDI` arm was unsound on its own.** It returned
`:fixnum` without reading its operands, but `ADD` is `+`, which is
`Integer#+` only when both operands are Integers -- `ary + ary` is
`Array#+`. This was invisible while a nil write poisoned the field:
`RPG2k::Scene::EquipMenu#@candidates` (`@candidates = real + [[0, 0]]`,
written nil in three places) embedded as `fixnum_nil` the moment nil
stopped poisoning, which would have raised `TypeError` in the game.

`codegen_insn`'s own `ADD` arm was never subject to this: it gates the
bare `mrb_fixnum_value(a + b)` fast path on `proven_fixnum_pair?`, so
only the analysis disagreed with the emitter.

## Decision

Add `IvarLayout::FIXNUM_NIL` as a real embeddable type and a
`NILABLE_EMBED_SUPPORT` join, and fix the `ADD` arm.

- `LOADNIL` contributes `NIL`, a concrete fact. `NIL` joined with
  `:fixnum`, in either order, widens to `FIXNUM_NIL`; a nil-only field
  stays `NIL`, which has no storage, so `@x = nil` alone still leaves the
  ivar dynamic. Every other disagreement still poisons to `UNKNOWN`, and
  `UNKNOWN` is still sticky, so the sweep's method order cannot change a
  field's fate (ADR 0139's property).
- `ADDI` traces its destination (`+= lit` keeps the destination's type)
  instead of assuming a Fixnum. `ADD` recurses into both operands with
  the same `left == :fixnum && right == :fixnum` rule
  `codegen_insn` already uses, so inference and the emitted fast path
  cannot disagree.
- Storage is `struct Bc2cppFixnumOrNil { mrb_bool present; mrb_int
  value; }`, emitted only when a field uses it, ahead of every owner
  struct. Reads box; writes go through `bc2cpp_fixnum_or_nil_set` after
  the existing guarded-check-then-store sequence. The check is
  `mrb_fixnum_p`, not `mrb_integer_p`, so a heap-backed Bignum can
  never be truncated into the unboxed `mrb_int` on a non-word-boxed
  target. `present` comes first and `mrb_calloc` zeroes the payload, so
  a fresh instance reads nil before its first write.

The type is inferred, not opted into: a field written only Integers and
nil widens by the ordinary join with no declaration.

`FIXNUM_NIL_IVARS` (an `"Owner#@ivar"` list) exists only for the case
the sweep cannot see at all -- a field whose only Fixnum write is an
opaque send, so every non-nil contribution is `UNKNOWN`. The Optcarrot
probe uses it for `CPU#@opcode`, whose single write is
`@opcode = fetch(@_pc)`. On a declared field an UNREADABLE contribution
is read as "Integer or nil"; a contribution the analysis can read and
resolves to something else still poisons, which is what keeps
`@candidates` an Array field even when declared. The generated writer
raises `TypeError` for a wrong declaration, so the failure mode is a
raised exception, never wrong storage.

## Consequences

- The real build's `EMBED` count falls from 290 to 281 and its compiled
  entry points from 2521 to 2520, entirely from the sound `ADD` arm:
  `@n = @n + x` with an unproven `x` no longer types as a Fixnum. This is
  a correctness trade, not a regression to paper over -- the old count
  included fields whose type the analysis had not actually proven.
  Method-level coverage stays 100.0% with zero `#error`, and the real
  build embeds no `fixnum_nil`.
- Two real bugs were fixed on the way, both required to run the probe
  at all: an embedded ivar with both an `attr_reader` and an
  `attr_writer` emitted the SAME entry wrapper twice (the writer now uses
  the `_eq` convention `emit_hot_only_registration_stubs` and
  `bc2cpp_hot_profile.rb` already assume), so the generated C++ could not
  link; and `tools/optcarrot_probe/compiled_run.rb` applied one mruby
  patch while bc2cpp's generated code needs
  `patches/mruby-dollar-bang-scoped.patch` for `mrb_state::errinfo`.
- A general union (an `mrb_value` arm, `std::variant`) is still
  rejected: `RData->data` is not a GC root and there is no mark callback
  for the payload, so an object-valued arm would be an immediate
  use-after-free. Immediate-only scalars are the whole of what this
  representation can carry safely.
- This does NOT make ivar access the Optcarrot bottleneck. With
  `CPU#@opcode` embedded the probe's `.text` is byte-identical to the
  control, and the profile has `iv_bsearch_idx` unchanged by embedding
  (244 embedded ivars across 50 classes either way). The dominant
  regression on that benchmark is the GC arena (`gc_gray_rescan`), not
  ivar lookup. The union is infrastructure for nilable scalars, not an
  FPS win on its own.
