# 0373. `blk.call(*args)` on a core method's own block yields to the Proc, with no by-name else

Date: 2026-10-07

## Status

Accepted

## Context

"Could we unroll proc call?" The census (`scripts/bc2cpp_dynamic_site_census.rb`, wio closed-world measurement at
`38f7267a`) counted 28 generated core-body sites that still dispatch `"call"` by name through
`mrb_funcall_argv`. All 28 are emitted by `compile_dynamic_splat_send` (CORE_PROC_CALL) and all 28 sit in the
`Enumerable` block bodies of mruby's own `enum.rb`:

- 26 are `block.call(*val)` inside `self.each { |*val| ... }` (`all?`, `any?`, `collect`, `detect`, `find_all`,
  `grep`, `grep_v`, `partition`, `reject`, `drop_while`, `take_while`, `group_by`, `count`, `flat_map`, `max_by`
  (2), `min_by` (2), `minmax_by` (3), `none?`, `one?`, `find_index`, `filter_map`, `sum`);
  the receiver is the enclosing method's own `&block`, read through `GETUPVAR`.
- 2 are `yield(*val)` in `Enumerable#cycle` (two block bodies); the receiver is a `BLKPUSH`.

Fixed-arity `blk.call(x)` already has a proof (BLOCK_PARAM_CALL, ADR 0274): a Proc arm that yields and an else arm
that can only be `nil`'s NoMethodError. The splat form never got it because `compile_splat_send` handed every
non-literal splat to `compile_dynamic_splat_send` without the receiver's identity.

The splat is not unrollable (`val` is a `*rest`: its length is the `each` yield's arity, known only at run time),
and it does not need to be: `bc2cpp_yield_argv` takes `(argc, argv)`, which `RARRAY_LEN`/`RARRAY_PTR` of the Array
mrbc builds in `R(dest+1)` already are. Only the else arm was by name.

## Decision

**BLOCK_PARAM_CALL_SPLAT.** `compile_dynamic_splat_send` takes the proof inputs (`irep`, `idx`) and, for an
explicit-receiver `call` in a compiled core body, asks `block_param_call_splat_code`. It is taken when

- the receiver register's every definition is the method's own block (`block_param_receiver?`, the BLOCK_PARAM_CALL
  proof, ADR 0274) or a `BLKPUSH` (`blkpush_receiver?`; `yield` raises LocalJumpError for a nil block first, see
  `codegen_insn.rb`), and
- `block_param_nil_call_dead?` holds: no Ruby `call` anywhere, none on or via `NilClass`, no dynamic installer.

The code is `if (mrb_proc_p(r)) { yield with the Array's length and elements } else { bc2cpp_nomethod_named(M, r,
"call") }`. The class test of CORE_PROC_CALL is dropped for the same reason as in ADR 0274: any Proc answers `call`
with `Proc#call`, and a compiled cfunc-backed Proc is never put through OP_CALL (ADR 0266), `bc2cpp_yield_argv`
is the path. The else raises with no arguments: nil has no `call`, and the NoMethodError text does not name them.

Every other receiver (a plain parameter, a block reassigned to nil, a block replaced on one path, a `Method` object,
a user callable) keeps CORE_PROC_CALL unchanged, and so does any build in which a `call` definer or installer
exists.

**Runtime guard.** The else arm is the existing `bc2cpp_nomethod`: if dispatch finds a method there the proof was
wrong and it raises `RuntimeError: closed-world proof violated` (ADR 0262); under `BC2CPP_NOMETHOD_VERIFY` it aborts
(ADR 0275).

## Consequences

- The 28 by-name `"call"` sites in generated core bodies go to 0; body `mrb_funcall*` sites fall from 30 to 2.
  The remaining body `mrb_funcall*` are not `call`.
- Core bodies are compiled only in the measurement world and a `BC2CPP_HOT_ONLY=0` closed build (ADR 0371): the
  three shipped firmware builds are hot-only, so no shipped byte changes.
- Not closed, by construction: `call` on a receiver that is not a block (a stored callable, a `Method`) in any core
  or engine body. The census has none with a runtime-sized splat; fixed-arity ones are `dynamic_dispatch_line`
  sites with their own tiers.
- `scripts/bc2cpp_block_param_call_splat_check.rb` (build.yml) checks the taken forms and every withdrawal: a
  block rewritten to nil, replaced on one path, a plain parameter, a block rewritten from a nested block, open
  world, outside-core Ruby, and a Ruby `call` on any class / NilClass, `method_missing` on NilClass, a singleton
  `call`, a dynamic installer.
