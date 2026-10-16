# 0478. A block call on an exact engine class is a direct call when every other definer of the name is named

Date: 2026-10-16

## Status

Accepted

## Context

After ADR 0468 (owner calls) and ADR 0472 (block iterators), about 427 call sites of the wio shipped pass
still reached `mrb_funcall_with_block` through the same arm: a guard chain of exact engine classes
(`Game::Party`, `Game::Actors`, `LCF::Array2D`, the Scene::Battle classes, `Game::State`) whose arm for
`each` and `map` was a by-name send. The arm exists because UNLISTED_CLASS_CALL (ADR 0386) asks
`ClosedWorld#exact_chain_lookup_safe?`, which refuses every name that an outside Ruby or native file
spells, except names that only RGSS natives define. `each` and `map` are spelled by mruby's own Enumerable,
Struct, Enumerator and related files, so the arm fell back.

The lookup from an exact class does not need every definer to be a registry one. What it needs is that no
outside or native definer of the name sits on the class's lookup chain: then the first definer the chain
reaches is a Ruby definition, which the registry already places.

## Decision

`CodeGen#unlisted_chain_lookup_safe?` (codegen_unlisted_class_call.rb) accepts the chain when, in order:

1. `ClosedWorld#exact_chain_lookup_safe?` accepts it (unchanged); or
2. the klass is a stable class constant and no `unknown_def?` names the method; and
3. `outside_owner_call_owners(name, allow_empty: true)` names every outside Ruby and native definer (ADR 0468:
   the owner map must be complete, with no computed unknown and no unparsed form), and none of those owners
   is on the chain.

Anything else refuses as before. No environment switch is added. The arm keeps its class test; the then-branch
is now `_impl(M, recv, ..., block)` through `direct_call_args`, which carries the block (ADR 0310).

## Consequences

- Wio shipped pass (master a21f7cf3 plus this change): `mrb_funcall_with_block` lines 616 -> 189. The `each`
  and `map` arms of engine classes become direct compiled calls; the remaining engine `map`/`any?`/`reject`
  sites are the next candidates.
- `bc2cpp_send` lines and the owner-call counts are unchanged, as are the KEPT counts.
- Checks run locally and pass: outside_owner_call_check, block_iterator_direct_check, self_new_leaf_check,
  constructor_overloads_check, define_method_check, alias_method_check, generic_block_return_check.
- The NOMETHOD_REVIEWED gate is the one to watch: a proven-dead by-name else inside an arm that is now a
  direct call may appear or disappear. CI reports either, and each is a build error to resolve, not to suppress.
- Not done: `map`/`any?` on engine receivers that the chain check still refuses for another reason, and the
  Enumerable `self` cases of compiled core bodies, which are by design.
