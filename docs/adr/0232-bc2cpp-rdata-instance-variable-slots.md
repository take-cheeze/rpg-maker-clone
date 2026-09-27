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
