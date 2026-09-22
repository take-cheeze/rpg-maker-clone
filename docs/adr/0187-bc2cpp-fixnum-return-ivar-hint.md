# 0187. Feed FIXNUM_RETURN_PROOF back into IvarLayout, stratified

Date: 2026-09-22

## Status

Accepted

## Context

`tools/optcarrot_probe/README.md`'s own "Why CPU's own register file stays
unembedded" section named a real gap, left unattempted: `IvarLayout.
trace_type`'s `SEND`/`SEND0`/`SSEND`/`SSEND0` case only trusted a closed set
of guarded operator names (`%`/`&`/`|`/`^`, ADR 0182/0183's `SUB`/`MUL`) as
Fixnum sources. A `SETIV` whose source is an ordinary method call --
`@_pc = peek16(RESET_VECTOR)`, `@x = current_indent` -- stayed `UNKNOWN`
even when `CodeGen#compute_fixnum_return_names` (`FIXNUM_RETURN_PROOF`) had
already proven that callee always returns a Fixnum, because that proof is
computed by `CodeGen` itself, strictly after `IvarLayout.analyze` has
already run and returned.

Feeding `FIXNUM_RETURN_PROOF` straight into `IvarLayout.trace_type`'s `SEND`
case would be circular: `compute_fixnum_return_names`' own admission rule 4
(`fixnum_return_sites_proven?` -> `proven_fixnum_operand?` -> proof source
3, `embed_type`) reads `@ivar_layout`. `ArrayElementLayout`/`ClassLayout`'s
own `ARRAY_RETURN_IVAR_HINT` stratification (the driver's own comment above
`ClassLayout.analyze`'s real, level-2 call) already solved the identical
shape of problem for a different pair of facts (`ClassLayout` <->
`ARRAY_RETURN_PROOF`), by computing two levels rather than iterating to a
full fixpoint -- this reuses that exact pattern rather than inventing a new
one.

## Decision

Stratify `IvarLayout` and `FIXNUM_RETURN_PROOF` the same way. Level 0 is
`ivar_layout` exactly as always computed (`IvarLayout.analyze`, no
`FIXNUM_RETURN_PROOF` evidence). Level 1 is `FIXNUM_RETURN_PROOF` computed
by a probing `CodeGen` instance built from level 0 -- a new `CodeGen#
initialize` mode, `analysis_only: :fixnum_return`, that runs
`drop_unsafe_embeddings` and `compute_fixnum_return_names` and stops (unlike
`ARRAY_RETURN_PROOF`'s own `analysis_only: true` probe, this one has to
filter first: `embed_type` reads the real, `drop_unsafe_embeddings`-checked
table, not the raw one, or a rejected embedding could leak a false
Fixnum-return proof). Every other whole-program table this probe needs
(`class_layout`, `element_layout`, `hash_element_layout`,
`container_constants`, ...) is already final by this point in the driver
and none of them read `ivar_layout` at all, so the probe gets the same real
tables the final `CodeGen` uses, not placeholders. Level 2 re-runs
`IvarLayout.analyze` with level 1's proof available to `trace_type`'s new
`SEND` arm, and is what the real `CodeGen` below actually receives.

The new `trace_type` arm trusts `fixnum_return_names.include?(name)`
directly, with no extra `registry`/`native_only_mono?` re-check: that
uniqueness is already `FIXNUM_RETURN_PROOF`'s own admission rule 1
(`@registry[N]` holds exactly one real-bytecode `MethodDef`) baked into the
set by construction, the identical "trust the whole-program proof directly"
precedent the neighboring `GETCONST` case already uses for
`integer_constants`. Soundness is receiver-independent for the same reason
every other MONO-keyed devirtualization in this file is: any real call to
an admitted bare name, whatever the receiver's actual class, either raises
`NoMethodError` before the destination register is ever written or reaches
that one definition and returns what it proved.

Two levels, not a full alternation (the `ENTRY_ARG_CALLSITE_PROOF <->
FIXNUM_RETURN_PROOF` shape `CodeGen#initialize` already runs internally):
level 1 is a strict subset of the ivar facts the real, final `CodeGen`
itself ends up with, so it is only ever as-or-less permissive than a
single-pass oracle, never more, and level 2's table is monotonically a
superset of level 0's (the new arm only ever turns an existing `UNKNOWN`
into `:fixnum`). The real `CodeGen` below still recomputes
`FIXNUM_RETURN_PROOF` itself against the level-2 table exactly as before,
so the final, shipped proof set gets the full benefit of the richer table;
only `IvarLayout` itself stops at level 2, matching `ARRAY_RETURN_IVAR_HINT`'s
own stated reasons for stopping there. `ArgTypes` (the sibling whole-program
call-site inference built out of this same `trace_type`) is left unchanged
-- passing `fixnum_return_names` only into `IvarLayout.analyze`'s own call
site keeps the change minimal; it makes `ArgTypes` no less sound, only
slightly less complete.

## Consequences

The real project's own 3 compiled gems gain 5 embedded ivars, all wired
classes (registration completeness already guaranteed by their existing
`emit_owner_registrations`/`BC2CPP_WIRED_EMBEDDINGS` membership, so this
introduces no new registration-completeness risk): `Game::Screen#
@fade_frames`, `Game::Interpreter#@battle_indent`/`@choice_indent`/
`@inn_indent`/`@shop_indent`. Confirmed directly against the real
regenerated output (`grep _ivars`/`DATA_PTR` in the generated `.cpp`), not
just the diagnostic count: real `mrb_int` struct fields with real
`DATA_PTR` reads/writes at every real call site. `scripts/
bc2cpp_coverage_report.rb`'s own dynamic-dispatch count drops by 9 sites
(3410 -> 3401 `POLY`-marked); method-level coverage stays 100.0% (2293/2293,
0 `#error`) -- purely additive, no regression. All 22 `scripts/
bc2cpp_*_check.rb` static checks still pass, including `bc2cpp_wired_
embedding_check.rb`'s own per-class installed-entry-point count for both
affected classes (`Game::Screen` 43/43, `Game::Interpreter` 207/207,
unchanged).

The standalone Optcarrot probe (`tools/optcarrot_probe/`) is byte-identical
before and after this change (`optcarrot_bc2cpp_coverage_report.rb`'s full
output, diffed directly) -- `CPU`'s own register file, the motivating
target named in that README's "Why CPU's own register file stays
unembedded" section, still does not embed. Traced by hand against `3rd/
optcarrot/lib/optcarrot/cpu.rb`: `@_pc`/`@data`/`@addr` bottom out at
`fetch`/`peek16`/`peek`, which read through `NES`'s own per-address memory-
mapper dispatch (`@fetch[addr]`/`@store[addr]`, an Array of per-device
callables looked up by address, then called) -- genuinely POLY across the
different mapper classes optcarrot ships, not MONO, so `FIXNUM_RETURN_
PROOF`'s own admission rule 1 correctly refuses them regardless of this
change. This ADR closes the *narrower* real gap the README named (a
whole-program name-keyed method's own return type, not yet fed back into
ivar embedding) without over-claiming it solves the CPU register file case,
which needs a fundamentally different, receiver-class-aware devirtualization
this ADR does not attempt.
