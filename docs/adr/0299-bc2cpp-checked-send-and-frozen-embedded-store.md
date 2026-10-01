# 0299. bc2cpp by-name sends make the VM's checks, and embedded ivar stores honour `frozen`

Date: 2026-10-01

## Status

Accepted

## Context

Three divergences between compiled code and mruby were known and recorded, none of them fixed:

1. **The kept by-name call skips what the VM checks.** A compiled `SEND` that stays a by-name
   `bc2cpp_send` (every guard chain's fallback, a POLY candidate whose owner is not compiled, an arm
   withdrawn by ADR 0297's proofs) is an `mrb_funcall`. `OP_SEND` in `3rd/mruby/src/vm.c` first raises
   `NoMethodError` ("private method 'x' called for ...") for a private method, and for a protected one
   when the receiver is a kind_of the class the method was found in; `OP_SEND` and `OP_SSEND` both raise
   `ArgumentError` for a cfunc proc flagged `MRB_PROC_NOARG` (what `attr_reader` creates) called with
   arguments. `mrb_funcall_with_block` checks none of it, so `obj.secret` answered and `reader(1)`
   returned the value where the interpreter raises. ADR 0297's known-class arms already raise
   correctly; only the by-name arm did not (its Consequences section says so).
2. **A compiled `SETIV` on an embedded ivar skips the frozen check.** An embedded ivar is a field of the
   instance's RData struct, stored directly. `mrb_iv_set` begins with `mrb_check_frozen`; the direct
   store did not, so a frozen object silently took the write. ADR 0297 fixed this for the synthesized
   attr_writer (`emit_ivar_accessor_pair`) only; every `SETIV` and every devirtualized accessor on
   `self` goes through `ivar_set_code`, which did not.
3. **`bc2cpp_guard_violation_check` did not build under 32-bit `mrb_int`.** The script replaced
   `BC2CPP_CXXFLAGS` with its own per-variant flags, dropping the caller's `-DMRB_32BIT -DMRB_INT32`,
   so the fixture was compiled with a 64-bit `mrb_int` against a 32-bit libmruby.

## Decision

### CHECKED_SEND (1)

`CheckedSend` (`tools/bc2cpp/codegen_checked_send.rb`) wraps `compile_send`. For a send that is the
original instruction (its irep and index name an `SEND`/`SEND0` or `SSEND`/`SSEND0` of the same symbol,
no substituted receiver or arguments) it rewrites that instruction's by-name `mrb_funcall(M, recv,
"name", ...)` to `bc2cpp_funcall_explicit` (an explicit-receiver `SEND`) or `bc2cpp_funcall_noarg` (an
implicit-self send of a name some attr_reader defines, with arguments). `SymbolCache` gives such a call a
symbol slot of its own, flagged in a `bc2cpp_sym_check[]` table, and `bc2cpp_send` runs
`bc2cpp_check_send` for a flagged slot: one `mrb_method_search_vm`, then the VM's own tests
(`MRB_METHOD_PRIVATE_FL`, `MRB_METHOD_PROTECTED_FL` with `mrb_obj_is_kind_of` on the class the lookup
returned, `MRB_PROC_NOARG` through an alias), raising through `mrb_no_method_error` with vm.c's
`vis_error` text and arguments, or `mrb_argnum_error`. An undefined method is left to `mrb_funcall`, which
reaches `method_missing`. The call text and every `bc2cpp_send(M, recv, i, ...)` pattern the checks scan
for are unchanged; the table and helper are emitted only when a site uses them.

Left unchecked on purpose, because the VM checks none of it there: an operator's slow path (`OP_ADD`
and the rest are not an `OP_SEND`), the synthetic send of an inlined loop body, and an implicit-self send
without arguments. Left unchecked because this change does not reach them: by-name calls made through
`mrb_funcall_with_block` (block sends), the splat and keyword shapes, and POLY/TYPED arms that call a
listed private candidate directly (ADR 0297: "only unlisted arms raise").

### FROZEN_EMBEDDED_STORE (2)

`ivar_set_code` emits `if (mrb_unlikely(mrb_frozen_p(mrb_obj_ptr(self)))) mrb_check_frozen(...)` before an
embedded store (boxed and typed slots alike, before the typed slot's `TypeError` test, as `mrb_iv_set` runs
it first). The flag test is inline: only a frozen receiver pays for the out-of-line raise.

`ClosedWorld#user_objects_unfrozen?` drops the test when no instance of a class the world defines can be
frozen. Every route to a frozen user object is a `freeze` (or a clone of a frozen one), so the world
refuses unless each is accounted for:

- a `freeze` send in the world's own Ruby is accepted only when its receiver is, on every path
  (`walk_dominating_writers`), an Array/Hash/String/Range literal or a class/module constant no
  `SETCONST` binds; any other receiver, `freeze` as an implicit-self send, `:freeze` or `"freeze"` spelled
  where a computed-name send could reach it (`DynamicNames`, the rule of ADR 0276/0279) refuses;
- project native code that calls `mrb_obj_freeze`, sets the frozen flag or funcalls `freeze` refuses
  (registering a method named `freeze` does not), and so does non-core foreign Ruby that spells `freeze`;
- mruby's own core is exempt, audited against `3rd/mruby`: it freezes only strings, arrays, hashes, ranges
  and `Data` instances, and its Ruby (`enum-chain`) freezes a rest array.

The open world, and any closed world that cannot prove it, keeps the test.

### Tooling (3)

`bc2cpp_guard_violation_check` appends its `-DBC2CPP_*` flags to the caller's `BC2CPP_CXXFLAGS` instead of
replacing them, as the other 32-bit-aware checks do.

## Consequences

- `scripts/bc2cpp_checked_send_check.rb` (CI `bc2cpp-checks`, fast shard) pins the slot table, which
  sites are marked, and runs a fixture interpreted against compiled on a 64-bit full-core build (closed and
  open world), a core-only build and, with `BC2CPP_MRUBY_FULL32`/`BC2CPP_MRBC32`, a 32-bit `mrb_int`
  build: private and protected explicit sends, attr_reader arguments with and without `self`, a
  `method_missing` receiver, and the implicit and `self.` private sends that must still answer.
- `scripts/bc2cpp_embedded_frozen_check.rb` (same shard) pins the test in the open world and in every
  closed world that has a route to a frozen user object, its absence in the worlds that do not, the order
  (test before store), the outside-source scans on `ClosedWorld` itself, and runs FrozenError and
  value-preservation for a boxed and a typed Fixnum slot against the interpreter on the same builds.
- A by-name explicit-receiver send now costs one more method-cache lookup. Direct calls, guarded arms and
  every arithmetic path are untouched, and a hot embedded store pays one load and branch only in a world
  that cannot prove no user object is frozen.
- The proof is deliberately conservative. The engine's own Ruby has `freeze` sends on `(A + B)` results
  and on a local array (`mruby-rpg2k/mrblib/scene/map.rb`, `game.rb`, `mruby-rgss/mrblib/lib.rb`) that
  the literal rule does not accept, so on the shipped gems the test stays on until receivers are typed
  (class pools, ADR 0296, could supply that). The mechanism and its negative worlds are in place.
- ADR 0297's remark that the kept dispatch ignores visibility and the reader's argument count is
  superseded for every site `CheckedSend` marks.
