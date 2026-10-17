# 0483. bc2cpp: a guarded block loop needs no compiled core body

Date: 2026-10-17

## Status

Accepted. Amends ADR 0420 (the arm gate of the guarded loops).

## Context

GUARDED_BLOCK_INLINE (ADR 0420) inlines a literal block's loop for a receiver that is not proven, behind a run-time
exact-class test. The arm gate admits a class only when `block_core_arms(name, argc)` names it, i.e. when the compiled
core body of `name` is what that class answers with (ADR 0270).

mruby's `Array#each` is a Ruby definition with `&block` (`3rd/mruby/mrblib/array.rb`). The closed world drops it from
the registry before any proof reads it (it is ineligible for compilation), so `block_core_arms` names no class for
`each` and no guarded loop is emitted. The effect was visible on `Game::Party#initialize`: `ids.each do |i| ... end`,
where `ids` is an untyped parameter, stayed a block fallback with a by-name dispatch on every call.

## Decision

`guarded_plain_chain_arm?` (`tools/bc2cpp/codegen_guarded_block_inline.rb`) is the second admission for a guarded
loop. It applies when `block_core_arms` names nothing, and only to zero-argument sends. It admits the class when:

- no project definition of `name` is on the class's chain (the registry check of ADR 0270);
- every owner on the chain is plain (`block_core_owner_plain?`: no native registration, prepend, unattributed mixin or
  outside definer, `core_ruby_arm_safe?`);
- `name` is not a dynamically installed name;
- a core mrblib file defines `name` on the class itself (`ClosedWorld#core_ruby_defines?`, read from the source with
  `ForeignDefiners.defines_named?`, not from the registry).

The loop does not call the core body. It replaces the send with the same iteration, which is what the proven-receiver
recognizers already emit for `Array#each` (`while idx < length; yield self[idx]; end`, re-reading the length each step).
The exact-class test and the root-context test are unchanged, so every other receiver takes the send as before.

## Consequences

- Untyped `each`, `map`, `select`, `reject`, `any?` and the other zero-argument block iterators on an Array (or Hash)
  receiver get the inline loop in the closed build, where the core body is not compiled. `Game::Party#initialize`
  is the first such site.
- The arm is no longer proof that a compiled body exists. The existence check is a source scan, so a core definition
  that the scan cannot read by name still leaves the site a send.
- The original gate of ADR 0420 still answers first: a named compiled body keeps its arm.
- `ForeignDefiners.defines?` treats a wild owner as defined; the new `defines_named?` does not. Use the latter for
  existence proofs.
