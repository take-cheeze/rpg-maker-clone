# 0297. bc2cpp resolves the exact-class arms of unlisted definers

Date: 2026-10-01

## Status

Accepted

## Context

ADR 0252 gives every definer class a guard chain cannot list (a mixin in the way, a definition that is
not a direct-call candidate) its own exact-class branch, and ADR 0259 made that branch a direct call of
the definition mruby's lookup finds. The arm stayed a by-name `bc2cpp_send` whenever
`closed_world_lookup_target` could not hand back a public definition with a body, or
`inherited_lookup_safe?` refused the name. On the wio closed world (whole-program run, the four compiled
gems) 1,198 of the 5,081 remaining `bc2cpp_send` sites were such arms, although the guard had already
proved the receiver's exact class. The reasons, per arm:

- **`lookup_unknown`** (the bulk): an `attr_reader`/`attr_writer` (no irep, e.g. `ShopState#party`,
  `Picture#id`, `Combatant#hp`), or a private def reached with an explicit receiver
  (`@state.party` where `Game::Interpreter#party` is private).
- **`not_inherited_safe`**: `inherited_lookup_safe?` refuses a name any native also spells, however far
  the native class is from the receiver (`RPG2k3::Scene::Battle#dispose`, `x`, `y`, `contents=`).
- **`no_target`**: the lookup from the class ends without a definition. `RPG2k3::Scene::Battle <
  RPG2k::Scene::Battle` was listed as a descendant of `Game::Battle` because `ClosedWorld#class_parent`
  and `descendants` match a superclass by its simple name, `Battle`. The over-approximation is sound for
  its purpose (more required classes) and the class really answers nothing.

## Decision

`CodeGen#unlisted_class_call` (now `tools/bc2cpp/codegen_unlisted_class_call.rb`, with the site
instruction passed from `closed_world_site`) resolves the arm from the exact class's own lookup:

1. **Name proof per chain.** `ClosedWorld#exact_chain_lookup_safe?` replaces the global
   `inherited_lookup_safe?`: the class must be a stable class constant and the name not an unknown
   definer, and a name that is also in `outside_names` must be spelled only by the RGSS natives, every
   registration of it parsed to a class (`NativeDirect.registered_owners`), none of them on the
   class's chain (superclasses and every included or prepended module, `unlisted_lookup_chain`).
2. **Lookup.** `closed_world_lookup_target(..., any_visibility: true)` also returns an attr definition and
   a non-public one, and the arm decides:
   - public with a body: the direct call of ADR 0259, unchanged;
   - an attr_reader/attr_writer: `ivar_accessor_call_code`, a bare `mrb_iv_get`/`mrb_iv_set` or the owner's
     synthesized accessor. The storage class is the owner, reached through superclasses only, with no class
     on the way embedding the ivar in its own struct (the INHERITED_GUARD rule); a count other than 0
     (reader) or 1 (writer) is `mrb_argnum_error`, which is what the native's argument check raises;
   - private, reached by an `SSEND` (implicit or `self.` receiver; mruby 4.0 compiles `self.foo` that way):
     the direct call, as the VM allows it;
   - private, reached by an explicit-receiver `SEND` whose receiver is not provably `self`:
     `mrb_no_method_error` with the message and `args` of vm.c's `vis_error`, without running the method;
   - no definition on the chain: the `bc2cpp_nomethod` the final `else` already uses, with the same
     NOMETHOD_REVIEWED key (method + name), so the list does not change;
   - protected, an unnamed `SEND`/`SSEND` (an inlined block body without its instruction), or a private def
     whose name `private :x`/`public :x` or a dynamic `send(:private, ...)` mentions anywhere
     (`ClosedWorld#visibility_stable?`; build_registry follows visibility only inside the defining
     class body): the dispatch stays.
3. **Frozen receivers.** The synthesized embedded attr_writer (`emit_ivar_accessor_pair`) now begins with
   `mrb_check_frozen`, as `mrb_iv_set` does. Without it an embedded `x=` on a frozen object silently
   stored; this already affected every listed class, and the new arms would have spread it.

Everything else is withdrawn by the existing registry and closed-world facts, each pinned by a negative
world in `scripts/bc2cpp_unlisted_class_call_check.rb`: alias/alias_method/undef/remove_method (the name
is in `symbol_installed_names`, so no unlisted arm is built), a computed `define_method` (global
refusal), a literal `define_method` next to the attr (two definitions on the owner), `method_missing`,
singleton definers (`def self.x`, `def obj.x`, `class << obj`, `define_singleton_method`), a prepended or
included module defining the name, `extend`, `Struct.new`, `Class.new`, reopening the class, and a
subclass override (the guard is `mrb_obj_class ==` the exact class, so the subclass has its own arm).

## Consequences

- Measured on the wio closed world, full output: `bc2cpp_send` sites 5,081 -> 3,918 (-1,163); the
  "known-class arm still by name" category of `scripts/bc2cpp_dynamic_site_census.rb` 1,198 -> 35;
  `bc2cpp_nomethod` sites 4,562 -> 4,648 (+86, the `no_target` arms).
- Residual 35: 30 private explicit-receiver arms inside inlined block bodies, whose site instruction
  the code generator does not carry (`idx` is nil there), and 5 of a name mentioned by `private :x`.
- The kept dispatch is `mrb_funcall`, which neither checks visibility nor an attr_reader's argument
  count: with an arm withdrawn, `obj.secret` on a private def answers where the interpreter raises
  `NoMethodError`, and `reader(1)` returns the value where it raises `ArgumentError`. The converted
  arms now match the interpreter; the withdrawn ones keep the old answer (not changed here).
- POLY and the other listed arms still call a private candidate through an explicit receiver
  (`@state.party` with `Interpreter#party` listed); only unlisted arms raise.
- `scripts/bc2cpp_unlisted_class_call_check.rb` pins the generated code, 29 negative worlds and 3
  controls, the chain proof against the real native sources, and runs interpreted vs compiled on real
  mruby (64-bit full-core and core-only, and 32-bit `mrb_int` full-core): values, exception classes and
  messages (private `NoMethodError` text, `FrozenError`, `ArgumentError`), no dynamic dispatch in the
  converted arms, and `UCC_MUTANTS=1` removes one of seven proofs at a time from a copy of the generator.
- No `mrb_int` width dependence: no integer constant or arithmetic is emitted.
