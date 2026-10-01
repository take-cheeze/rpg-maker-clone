# 0293. bc2cpp reaches `===` and `is_a?`/`kind_of?` by direct C calls

Date: 2026-10-01

## Status

Accepted

## Context

On the wio closed world (the four compiled gems, whole-program run) 577 call sites ended in a by-name
send of `===` and 46 in one of `is_a?`/`kind_of?`. They were not unknown receivers: every `case/when`
site already emitted a receiver-tag switch (`EQQ_TYPE_TAG_DISPATCH`) whose `default:` arm was the send,
and every `is_a?` site sent in its non-class-argument arm, which can only raise. Roughly 440 of the
`===` sites had a receiver the bytecode fixes (an Integer literal, or a constant such as `ITEM_SEED`
that `INTEGER_CONSTANT_VALUE_PROOF` already replaces by its number) yet still carried the 45-line
switch and its send; the rest were a class constant, a String/nil/true/false literal, or a genuinely
unknown receiver.

Every `===` the build can reach is one of: `Module#===` (class.c `mrb_mod_eqq`, which is
`mrb_obj_is_kind_of`), `Range#===` (range.c), `Kernel#===` (kernel.c `mrb_eqq_m`, which is `mrb_equal`),
mruby-set's `Set#===`, and the Ruby `Proc#===` (mruby-proc-ext) and `Regexp#===` (mruby-onig-regexp).

## Decision

1. **Shared helper.** `bc2cpp_eqq(M, recv, arg)` is emitted once per generated file
   (`tools/bc2cpp/codegen_eqq.rb`, next to the other outlined helpers). It answers Class/Module/singleton
   class, Range, Integer, Float, String, Symbol, true/false/nil, Array and Hash with the C bodies above
   and dispatches by name for every other tag (Proc, Data, Set, plain objects), the only by-name `===`
   left in the file. A `case/when` site whose receiver is not proven is one call to it.
2. **Proven receivers (`EQQ_DIRECT`).** When the register's dominating writer (`walk_dominating_writers`,
   MOVEs followed, so a join that can bypass the write refuses) is a stable class/module constant
   (`StableClassConstants`), an Integer constant or literal, or a String/nil/true/false literal, the site
   is `mrb_obj_is_kind_of` / `mrb_equal` directly, with the Integer-vs-Integer compare inline while no
   Ruby `Integer#==` exists. Inlined block bodies use `trace_idx`; core bodies use the engine world
   (`block_core_world`), as BLOCK_CORE_DIRECT does.
3. **`is_a?`/`kind_of?`.** The else arm (an argument that is not a Class/Module/SClass) raises
   `TypeError "%v is not class/module"` in place, the exact `ensure_class_type` call `mrb_get_args("c")`
   makes; a singleton class argument now takes the direct arm like `'c'` accepts it.

All of 2 and 3 need the closed-world gate `eqq_direct_safe?` / `kind_of_type_error_direct?`: the registry
holds one native `===` (resp. name), `ClosedWorld#ownerless_native_dispatch_safe?` (no unknown definer,
no outside Ruby, no global refusal) and no alias, undef, Symbol-named or computed `define_method`/
`remove_method` of the name anywhere (`symbol_installed_names`, which is nil when one is computed). A
`def self.===`, a `===` in a module that is included, prepended or extended, or a reopened Integer/
String/NilClass/Module/Kernel all put a second definition in the registry; `define_singleton_method`
and `extend` refuse the whole world. `is_a?` additionally needs `kernel_native_dispatch_safe?` (no
`BasicObject` subclass, whose instances have no `is_a?`); without it the else arm keeps the send. The
same name-level check now also stops the existing LITERAL `===` paths, the helper's Integer arm and the
`is_a?` class arm from running when the world aliases or undefs the name (those holes pre-dated this).

An open world keeps every send.

## Consequences

- Measured on the wio closed world, all four compiled gems, full (not hot-only) output: by-name `===`
  577 -> 2 (the default arm of each of the two files that emit the helper; lcf and rgss need none),
  `is_a?` 46 -> 0, `kind_of?` 9 -> 0. The rpg2k gem's output shrinks by about 660 KB.
- `scripts/bc2cpp_eqq_direct_check.rb` pins the generated code, 18 negative worlds, and runs
  interpreted vs compiled on real mruby (64-bit, and 32-bit `mrb_int`): case/when over every pattern
  and value kind, `is_a?`/`kind_of?` with classes, modules, singleton classes and non-class arguments
  (TypeError text compared), plus the dispatch count. `scripts/bc2cpp_eqq_integer_check.rb` now checks
  the helper's Integer arm against `mrb_equal`.
- Residual: `Proc#===`, `Regexp#===`, `Set#===`, bigint and plain-object receivers of an unproven
  `===` still dispatch by name, as before. `instance_of?`, `nil?`, `respond_to?` have no by-name sends in
  these builds and were left alone. A `BasicObject` receiver of an `is_a?` whose class argument is a
  class still gets the native answer instead of NoMethodError when the world has a `BasicObject`
  subclass (pre-existing for every native primitive; only the raise arm is gated here).

## Interaction with ADR 0290 (guard violation)

One path per site: a stable class/module constant receiver of `===` keeps the class/module tag test, and
its else arm is the `CLASS_EQQ` guard violation when ADR 0290's proof holds (a rebound constant still
fails loudly instead of reaching `mrb_class_ptr`), else the by-name send. For `is_a?`/`kind_of?` a stable
constant argument keeps `CLASS_ARGUMENT`; any other argument raises the TypeError in place. The unproven
`case/when` default arm, formerly the `CLASS_EQQ` site for constant receivers, is the shared helper.
