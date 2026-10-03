# 0319. bc2cpp: one definition per (owner, name), the last (double definitions)

Date: 2026-10-03

## Status

Accepted

## Context

An owner that defines one name twice runs the LAST definition in the interpreter: `attr_reader :v` then
`define_method(:v)`, `def v` twice, a reopened class, `alias b a` over a `def b`, `def self.m` then `class << self; def m`.
The registry (`build_registry`) appended every definition, and each consumer chose its own:

- the C++ symbol is `cpp_name(owner, name)`, so two bodies of one pair were both emitted under one symbol (the
  translation unit failed to build: `redefinition of ...`), and an instance method `singleton_make` and a singleton
  method `make` (`Widget_singleton_make`) or `Foo#bar_baz` and `Foo_bar#baz` shared one too;
- `@registry[name].find { |d| d.owner == lex_owner }` (LEXICAL_SELF, the keyword call, `initialize` for embedding)
  took the FIRST definition: a self-call compiled to the dead `attr_reader` or `def`;
- `DefineMethodSites.settle` dropped a `define_method` that shared its owner with another definition, leaving the
  other one live: the synthesized embedded accessor, or the `def`, was registered over the `define_method`;
- the registration of every compiled entry runs after the mrblib has loaded, so a dead `def` registered over a live
  `attr_reader`/alias/`define_method`, and an `alias` or `undef` after a `def` was never seen by the registry at all;
- `private :v` marked the first definition of `v`, not the latest.

Measured on master `cd86085f` with the fixture of `scripts/bc2cpp_double_definition_fixture.rb`, each form alone on a
full-core mruby, compiled against the interpreter (all with every optimisation switch on; none of it needs one):

| Form | Master |
| --- | --- |
| `attr_reader` then `def` | wrong value (compiled `1`, interpreter `10`) |
| `def` then `attr_reader` | wrong value (compiled `10`, interpreter `7`) |
| `attr_reader` then `define_method` | wrong value (`1`, interpreter `42`) |
| `def` then `define_method` | wrong value (`1`, interpreter `2`) |
| `alias`, `alias_method` over a `def` | wrong value (the `def`'s body, interpreter the aliased one) |
| `module_function` over a redefined `def` | wrong value |
| `def` then `def`, three defs, reopened class, `def self.m` twice, `class << self`, `private` after two defs, `super` into one, a live def that raises, a call between the defs, a conditional later def | build failure (C++ redefinition) |
| `singleton_make` / `make`, `bar_baz` / `bar` + `baz` | build failure (one symbol) |
| `attr_accessor` then `def w=`, `define_method` then `attr_reader`, `define_method` then `def` | already right (by luck of the order) |

The shipped engine has no double definition: `shipped.cxx` of all four compiled gems, hot-only and full, is
byte-identical before and after this change.

## Decision

`DoubleDefinitions.settle(registry)` (`tools/bc2cpp/double_definitions.rb`) runs right after the core shadowing of
ADR 0264, before the closed world or anything else reads the registry, and leaves at most one definition per
(owner, name):

- the LAST one when it is unconditional. The earlier bodies are dead once the class bodies have run: the compiled
  entries are registered after the mrblib has loaded, so a call made between the two definitions (class-body code,
  never compiled) still runs the interpreter's earlier body, and an alias or `method(:x)` taken earlier keeps it, both
  interpreted as before. A dropped body is neither emitted, registered nor a call target;
- otherwise one body-less marker (`kind` nil, the same shape as a Struct member): the name stays POLY, nothing is
  compiled or registered for it, and an `ivar` of the same name is not embedded. That is the case when the last
  definition may not run (`MethodDef#conditional`: a forward jump spans it, recorded where the registry registers it)
  or when one definition's position is unknown (a loop-installed accessor, ADR 0304, registers after the walk);
- a `module_function` copy whose source body was dropped becomes a marker too (its irep would no longer be a leaf).

The registry learns the definitions it did not model: an `alias`/`alias_method`/`undef`/`undef_method`/
`remove_method` of a name its owner already defines appends a marker in order (a first alias adds nothing, so a
program without a double definition has the registry it had), and `private :v` marks the latest definition so far.

`cpp_name` gives a pair whose spelling another pair already has a `$n` suffix (`DoubleDefinitions.symbol_suffixes`,
first in sorted order keeps the plain name; `$` cannot come out of `sanitize` followed by one digit), used by the entry,
the `_impl`, the block and loop functions derived from it, the synthesized accessors and the hot-only stubs. Programs
without a clash get the spelling they always had.

## Consequences

- Compiled and interpreted behavior agree for every form above on full-core, core-only and 32-bit `mrb_int` builds
  (`scripts/bc2cpp_double_definition_check.rb`, values and exceptions; thirteen generator mutants and a control in
  `scripts/bc2cpp_double_definition_mutation_check.rb`; CI shard `double-definitions`).
- A withdrawn name (conditional last definition) loses its compilation; none exists in the engine.
- Not covered: two definitions of one owner in different gems (the registry of a run sees them, but the gems are
  loaded and registered in turn; `foreign_definers` territory), and a method called directly by an explicit receiver
  ignores `private` when it has a single definition (found on the way, independent of this change: the MONO call does
  not check visibility).
- Cross-owner collisions of class structs (`A::B` and `A_B` both spell `A_B_ivars`) are the same kind of problem and
  are not handled here.
