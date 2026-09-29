# 232. Store compiler-managed instance variables in RData value slots

Date: 2026-09-27

## Status

Accepted

## Context

bc2cpp previously embedded only Fixnum, Symbol, and boolean ivars it could
prove from bytecode. Other statically named ivars remained in `iv_tbl`, and
`Game::State` had an additional hand-maintained field cap because its save and
load paths assigned values through accessors.

Typed fields require proving every assignment has one C representation. That
proof is unnecessary for storage: an `mrb_value` field preserves the value and
semantics of an ordinary Ruby ivar, including values assigned by interpreted
code.

## Decision

Each statically named ivar of an already-wired owner gets an `mrb_value` field
in that owner's RData payload. The generated `mrb_data_type` carries the slot
names, offsets, and payload size. This descriptor is the marker that tells the
mruby runtime to route matching ivar operations through the payload.

GETIV, SETIV, and synthesized native accessors address those fields directly.
The mruby ivar APIs use the same descriptor for interpreted access, reflection,
copying, and removal; the garbage collector traces every value slot and writes
retain the normal object write barrier. Slots start as `undef` so an unset ivar
still reads as nil and remains absent from `instance_variables`.

Names not present in the static descriptor continue to use the ordinary
`iv_tbl`. This preserves dynamic `instance_variable_set` behavior. The existing
RData owner allowlist and compile-safety checks remain: classes with incompatible
native instance layouts, interpreted ivar accessors, or unsafe subclass layouts
must not be switched to this payload representation.

## Consequences

The compiler no longer needs a type proof to move a known ivar out of `iv_tbl`,
and save/load setters can store arbitrary Ruby values without a generated type
check. Common ivar reads and writes use direct slot access. RData objects still
carry an `iv_tbl` for dynamic names, and classes outside the wired owner set
continue to use ordinary ivar storage.

`mrb_data_type` has optional trailing slot metadata; existing C data types leave
it zero-initialized. Any changes to the descriptor or slot lifecycle must keep
GC marking, `mrb_iv_copy`, reflection, and the write barrier in sync.

The runtime support is carried by `patches/mruby-rdata-ivar-slots.patch` and
applied through the shared mruby patch chain. The vendored submodule therefore
remains pristine; host, cross, and CI builds reproduce the same runtime changes.

## Follow-up: typed fields, NULL payloads and patch placement

The descriptor lists only `mrb_value` slots. A typed field (`mrb_int`,
`mrb_bool`, `mrb_sym`, the tagged Integer-or-nil) is a raw C value, and every
descriptor consumer (GC marking, `mrb_iv_get`/`set`/`defined`/`remove`,
`mrb_iv_foreach`, `mrb_iv_copy`) treats a slot as an `mrb_value`. So:

- `emit_structs` puts only `:value` slots in the table. A typed ivar that a
  method left on the interpreter touches is demoted to a `:value` slot
  (`demote_typed_ivars_read_by_interpreter`). An all-typed owner keeps a
  one-entry placeholder table with a count of 0: the non-NULL `ivars` pointer
  is what makes `mrb_iv_copy` copy the whole payload, typed fields included.
- A typed ivar is therefore invisible to reflection (`instance_variables`,
  `inspect`, `instance_variable_get`, Marshal): it reads as unset instead of
  being misread as an object. `dup` and `clone` still copy it with the payload.
  Code that needs the value should read it through a method.
- `data` is NULL until `mrb_data_init` runs, and stays NULL for an object whose
  `#initialize` raised first or that came from `Class#allocate`. GC marking
  skips a NULL payload like the `variable.c` consumers already do; compiled
  bodies still assume an initialised payload, which the closed-world subclass
  checks guarantee for wired owners.
- The `gc.c` hunk of the patch carries context lines. It used to be a
  zero-context insertion at a fixed line, so after `mruby-gc-type-live-counts`
  (applied first by the patch chain) shifted `gc.c`, it landed inside the
  `MRB_TT_CLASS` block, `obj->tt == MRB_TT_CDATA` was never true, and no slot was
  marked. An existing checkout patched by the old text no longer matches and
  `apply_mruby_patch.bash` reports it; reset `3rd/mruby` and rebuild.

`scripts/bc2cpp_typed_slot_check.rb` covers the emitted tables and initial
values. `scripts/bc2cpp_rdata_slot_native_check.rb` links generated code against
the patch-chain mruby and runs it under GC pressure, so a misplaced hunk or a
raw field in the table crashes it.
