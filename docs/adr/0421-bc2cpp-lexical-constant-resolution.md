# 0421. bc2cpp: resolve a constant read through its lexical scope, not its bare name

Date: 2026-10-12

## Status

Accepted

## Context

The numeric proof (ADR 0276), the class pools (ADR 0296, 0301) and the numeric diagnostics key a constant by its bare
name: every SETCONST of `TURN_LEFT` anywhere in the world joins one group, and every GETCONST `TURN_LEFT` reads that
group. `Game::Character::TURN_LEFT` (a frozen Hash) and `Game::MoveRoute::TURN_LEFT` (17) therefore share one pool.
A read inside `Game::Character` is classed as the join of both, the element model then sees a mixed class
(HSH|INT with the unfrozen inner arrays and nil on top), and the proof can select the wrong representation. The bare
name does not say which definition a read reaches; Ruby does, through the lexical scope chain.

## Decision

`LEXICAL_CONST` (`tools/bc2cpp/lexical_consts.rb`) names the definition each GETCONST and GETMCNST reads, and gives no
definition when the bytecode does not prove one.

Scopes come from the bytecode. A class or module body entered by a plain `class X` / `module X` (its outer register is
loaded by LOADNIL) nests in its parent, so its scope is the qualified name; a method or block inherits the scope of
the body it sits in. A compact `class A::B`, `class << obj`, or anything below one is `:unknown`.

A bare read from scope `S` resolves to the first scope of the chain `S`, parents of `S`, top level that defines the
name. It is resolved only when the definitions reachable from that lookup are exactly that one: the definitions
reachable are the chain, the ancestors of `S` (superclass chain, included and prepended modules, Object and what Object
includes). A `K::NAME` read resolves when `K` defines the name and nothing reachable from `K` also does.

Refused (no key, the reader takes the fallback of ADR 0276: the integer-constant proof or OTHER):

- a read whose scope is `:unknown`, or a name with a definition in an unknown scope (singleton body, compact body,
  `SETMCNST`);
- a name also defined by an outer scope, by the top level, by a superclass, or by an included module that the read can
  reach;
- a superclass that is not `LOADNIL` and so not modelled, when the name has another definition;
- an `include`/`prepend` whose argument is not one bare constant with one world definition, which makes the ancestors
  of every scope unknown;
- a scoped read of a constant named by `private_constant` anywhere in the world, since it raises from outside;
- the whole world, when a string `class_eval` / `module_eval` / `instance_eval` exists, or the constant tables are not
  static (`const_set`, `remove_const`, `autoload`).

The keys are applied in `codegen_numeric_consts.rb` (group keys for SETCONST sites and reads, and the poison check on the
bare name), in `codegen_class_pools.rb` (`class_pool_const_mask`), and in `codegen_numeric_roots.rb` (the diagnostic).
Every other consumer of the bare name is unchanged (`IntegerConstants`, `classes_named`, `ivar_layout`, `codegen_eqq`).

Kill switch: `BC2CPP_LEXICAL_CONST=0` keys every constant by its bare name, which reproduces the pre-change output
byte for byte (`const_group_key` and `const_site_key` return the bare name).

## Consequences

- A read of a name that is defined in one scope and reached from outside it is now OTHER where the bare-name pool gave
  that definition's class set. That is the sound answer (Ruby reads something else or raises there), and it can drop a
  proof that was only right by accident.
- A read that resolves now sees only its own definition's sites, so a class set can shrink to the definition the read
  reaches.
- The rule covers the bytecode shapes the registry already recognizes; compact class bodies and singleton bodies are
  refused rather than modelled.

## Unproven

- Load order. A read that executes before the assignment it resolves to would, in Ruby, find an outer or ancestor
  definition (or raise). Ruby's ancestors and Object are refused whenever they hold a second definition, so the only
  remaining gap is a NameError, which the existing never-assigned rule (ADR 0276) already treats as contributing no
  value.
- Core constants. A name a core class or module defines and the world does not is not in the world's definitions; the
  bare-name poison (`outside_const_names`, ADR 0276) covers the native and foreign definitions, not a core ancestor's
  constants reached through an included core module.
- `eval` of a plain string (`Kernel#eval`, `binding.eval`) can define a constant the bytecode does not show. The closed
  world already forbids it in the compiled mrblib (`scripts/rpg2k/closed_world_lint.rb`); the resolver does not look for
  it beyond the three `*_eval` sends above.

## Verification

`scripts/bc2cpp/lexical_const_check.rb` compiles fixtures with the host mrbc and checks each read against the rule (the
resolved reads, the refused shadow, superclass, mixin, compact, singleton, private, eval, and non-static cases). It needs
`MRBC` and prints SKIP without it; `bc2cpp-nightly.yml` runs it in the `fast` shard and `build.yml`'s ruby-checks job
lists it (which skips there, since that job has no mrbc).

Census: see `docs/bc2cpp-constant-lookup.md`.
