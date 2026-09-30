# 0274. bc2cpp replaces three families of dynamic sends with audited direct code

Date: 2026-09-30

## Status

Accepted

## Context

After ADR 0257 and ADR 0270 the wio closed-world report still counted 10,956 cached
`bc2cpp_send` / `mrb_funcall_with_block` sites. A ranked look at the remaining names found
three families whose receiver is fixed by construction, not by a class guess:

- implicit-self Kernel natives: `raise` (71 sites), `__id__` (1), and `exit` (4),
  `alias_method` (2) and `to_enum` (63);
- `blk.call(...)` where `blk` is the compiled core method's own `&blk` (77 `call` sites);
- `v.__svalue` and a few other Array natives on a `|*v|` rest parameter (48 sites).

The arms of ADR 0257 cannot help: they keep the send as their else, because nothing proves
the receiver is exact. The three families do have a proof.

## Decision

**KERNEL_DIRECT.** `NativeCoreDirect::KERNEL_ENTRIES` are audited rows for natives every
object inherits. An implicit-self send of the name is replaced by the native's body with no
guard and no fallback when

- the registry has only native definitions of the name, no outside Ruby defines or installs
  it, and no dynamic installer names it (`ClosedWorld#ownerless_native_dispatch_safe?`);
- no class in the build derives from `BasicObject` (`kernel_native_dispatch_safe?`), so every
  receiver includes Kernel;
- the audit passes: the ROM registration still binds the audited function to the name with
  the audited aspec, the function bodies equal the audited text, the name is registered on no
  other class and by no unattributable call, and each public API named is `MRB_API` (the
  `mrb_make_exception` declaration in `mruby/internal.h` is checked to exist).

`raise` cannot be called (`mrb_f_raise` reads `mrb_get_args`), so `bc2cpp_raise1` and
`bc2cpp_raise2` replay its one- and two-argument arms on `mrb_make_exception` and
`mrb_exc_raise`; the audit pins the whole `mrb_f_raise` body, including `ci->mid = 0` (the
raise frame is absent from a backtrace either way, `backtrace.c` skips a frame with no
method id). A bare `raise` (re-raises `$!`), three arguments and `cause:` keep their send.
`__id__` is `mrb_fixnum_value(mrb_obj_id(self))`. `exit` (unattributable registration) and
`alias_method` (`mrb_get_args`) are left alone. `to_enum` is Ruby, not native (mruby-enumerator
defines it on Kernel and again on `Enumerator::Lazy`), so a Kernel row would be wrong for the
Enumerable-family owners whose `self` may be a Lazy; it is not converted.

**BLOCK_PARAM_CALL.** In a compiled core method, `blk.call(...)` where every definition of the
receiver register is the block the method was entered with (ENTER's block slot, directly or
through the `MOVE R2 R1 ; R2:blk` copy mrbc makes, or through GETUPVAR from a nested block)
compiles to `if (mrb_proc_p(r)) { yield-style proc call } else { bc2cpp_nomethod }`. The value
is nil or a Proc (`vm.c` `ensure_block`), and `nil.call` raises exactly what dispatch raises
because the build has no Ruby `call`, no `NilClass#method_missing` and native `call` only on
Proc/Method/UnboundMethod. The class test of CORE_PROC_CALL is dropped for the same reason: any
Proc, subclass or singleton included, answers `call` with `Proc#call`. The proof is
`BytecodeIR.reaching_definitions` plus a no-writer check of the slot and of nested SETUPVARs. To
make it hold for optional-argument methods (`Integer#step`, `Array#find`), `BytecodeIR` now
gives OP_ENTER its jump-table successors (vm.c `ci->pc += o*3`): the table entries were
unreachable nodes and every dataflow query through them refused.

**NATIVE_CORE_DIRECT_REST.** A receiver whose only reaching definition is the entry value of a
`*rest` slot (rest and mandatory parameters only) is a fresh exact Array, built by ENTER and by
every compiled entry. The audited Array rows without an argument guard are then called with no
guard and no send. New rows: `Array#__svalue` (`mrb_ary_svalue` is static, mirrored as
`bc2cpp_ary_svalue`) and `Array#to_a`.

Not added: `cover?` (`mrb_get_arg1`, static `r_less`), `read` (`mrb_get_args`), `eof?`
(gem-private struct macros), `pack`, `__to_int`.

## Consequences

Measured on the wio whole-program report (`scripts/bc2cpp_coverage_report.rb`): cached sites
fall from 10,956 to 10,775. KERNEL_DIRECT removes 70 (`raise` 69, `__id__` 1; the two bare
`raise` sites stay), BLOCK_PARAM_CALL 63 of the 77 `call` sites and NATIVE_CORE_DIRECT_REST 48
(all `__svalue`). The `call` sites that stay are not a `&blk` (`ifnone&.call`, `pattern.call`,
the LCF engine's own callees) or sit in methods whose dataflow still refuses (unreachable code
after a `return`).

Compiled `rescue` does not set `$!`, so a bare `raise` in a compiled rescue re-raises nothing
where the interpreter re-raises the rescued exception. That predates this change and is why the
zero-argument arm keeps its send; it is not fixed here.

The direct calls allocate in the enclosing function's GC arena without the save/restore
`mrb_funcall` performs, like the other direct `mrb_*` calls (ADR 0257). `bc2cpp_nomethod` sites of
BLOCK_PARAM_CALL carry no NOMETHOD_REVIEWED marker: calling a nil block is an ordinary user
error, not a dead branch (ADR 0226).

`scripts/bc2cpp_direct_natives_check.rb` re-proves each claim (audit mutations, withdrawal
reasons, and a compiled-versus-interpreted run of every form). Any mruby upgrade that changes
one of the audited bodies disables its row.
