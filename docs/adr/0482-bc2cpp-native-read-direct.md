# 0482. bc2cpp calls native IO#read and StringIO#read directly

Date: 2026-10-17

## Status

Accepted.

## Context

The profile from `BC2CPP_TRACE_RECV` (the receiver trace, see
`docs/profiling.md`) put `read` at the top of the by-name sends in the
generated code. The receivers are polymorphic: an LCF file read is a `File`
(`IO#read`), and a save or in-memory read is a `StringIO`. Each send went
through `mrb_funcall_with_block`, which looks the method up by name for every
call even when the receiver is the core body.

The receiver set is open: a game or a gem may define its own `read`, and a
receiver may be any class. The site therefore cannot be specialized to one
class at compile time without a guard.

## Decision

The IO and StringIO gems each expose a guarded direct entry:

- `mrb_io_read_direct` (`3rd/mruby/mrbgems/mruby-io`, patch
  `patches/mruby-io-direct-read.patch`) and `mrb_stringio_read_direct`
  (`3rd/mruby-stringio`, patch `patches/mruby-stringio-direct-read.patch`).
  Each one checks that method lookup from the receiver's class still resolves
  to its own core `read` body (`MRB_METHOD_CFUNC` with that function). If it
  does not, it returns FALSE and the caller falls back.
- The direct entries take explicit arguments and return the result through an
  out-parameter. They do not read the VM stack, so they can be called from
  generated C++ without a frame.
- `tools/bc2cpp/codegen_send.rb` lowers a one-argument `read` by name to
  `bc2cpp_native_read1`, a shared helper emitted once per compiled unit. It
  tries each direct entry in turn, then falls back to by-name dispatch. A
  literal block keeps the per-site dispatch.
- The helper and the extern declarations sit under `BC2CPP_NATIVE_IO_DIRECT`,
  which the compiled gems define in their `mrbgem.rake`. Without the define the
  helper is plain by-name dispatch, so the generated code still compiles
  against a libmruby that lacks the patches.

The gem changes are applied with the same idempotent patch mechanism as
`mruby-io-direct-puts` (`scripts/apply_mruby_patch.bash`).

## Consequences

- A `read` site does one guarded direct call for IO and StringIO receivers and
  no name lookup. Any other receiver, including a user override of `read`,
  takes the by-name path with the same result.
- Every new native class that gets a direct read entry adds one step to the
  chain. The chain stays a few steps long; a general mechanism for many classes
  is the interface-table work (`BC2CPP_INTERFACE_TABLES`), not this helper.
- The patches change the IO and StringIO sources of the vendored submodules.
  The submodule working trees show as dirty until the patches are committed
  upstream or reapplied from `patches/`.
- StringIO's read gains an explicit "not opened for reading" check in the
  direct path, the same as the by-name path.
