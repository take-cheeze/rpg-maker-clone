# 0416. bc2cpp: the class a `klass.new` builds, from the constants its callers pass

Date: 2026-10-12

## Status

Accepted

## Context

CONSTRUCTOR_POOLS (ADR 0313) pools the arguments of an `initialize` over every `Klass.new`, `super(...)` and `new`
rooted in the class itself. A `new` whose receiver is none of those is `unresolved`: it could build any class, so
it withdraws every `initialize` that accepts its argument count (`found[:open_argc]`).

The wio build has two such sites, both in one generic helper of the typed save records
(`mruby-lcf/mrblib/save_typed.rb`):

```ruby
def table(id, klass, name)            # called as `table 100, Title, :title`
  child = klass.new(r, "#{@path}.#{name}")
def rows(id, klass, name)             # called as `rows 103, Picture, :pictures`
  arr.each { |i, row| klass.new(row, "#{@path}.#{name}[#{i}]").check! }
```

Both pass two arguments, so 28 constructors were refused by that one reason ("unresolved new with 2 arguments (new at
save_typed.rb ...)"): `Game::Party`, `Actor`, `Map`, `Picture`, `Troop`, `LCF::Array1D`, most `RPG2k::Scene::*`, and
the rest. None of them is built by the helper (it only builds the `LCF::SaveTyped::*` records), but the analysis had no
fact to say so. The refusal blocks their argument pools, the ivar pools those feed, and with them the class of every
receiver read from those ivars (the `core_tag_chain_else` census categories: a core-class guard chain whose else arm
is a by-name send).

The census of the shipped build before this change (`docs/bc2cpp-baseline-2026-10-02.md` method, 3rd/mruby patched
as `cmake/build-mruby.cmake` does) found the fact missing, not the sites: the receiver of the `new` is a *parameter*, and
the class set of a parameter is only ever computed for instance classes (ADR 0295), never for class objects.

## Decision

`tools/bc2cpp/codegen_class_object_args.rb` resolves the receiver of a `new` that CONSTRUCTOR_POOLS cannot name to the
constants its callers pass. It is a pass over the existing BytecodeIR reaching definitions, consulted by
`constructor_new_site` only after `constructor_named_classes` has failed; a site it cannot resolve stays `unresolved`.

The receiver register's reaching definitions (handler edges included) must each be

* a `GETCONST`/`GETMCNST` of a name that only ever names classes (`ClosedWorld#class_valued_constant?`); the classes
  are the ones declared under that last segment, as for a named site;
* the entry value of mandatory parameter *k* of a method body (plain mandatory arity, so ENTER does not rebind it); or
* a `GETUPVAR` of such a parameter of the enclosing method body. A block runs after any later write, so the parameter
  must have only its entry definition at every instruction of the body, no nested block may write it, and the build must
  have no by-name local writer (the precondition of CAPTURED_LOCAL_CLASS, ADR 0308).

A parameter's classes are the join over the call sites of its method name:

* The sites are enumerated by name like ENTRY_ARG_CALLSITE_PROOF's (ADR 0276 header), with the same poison: a Symbol,
  an alias, a splat or keyword call, any other mention of the name. A name that code outside the analysed bytecode can
  call is refused by the test SETTER_POOLS uses (ADR 0370): a native funcall or foreign Ruby identifier names it, or an
  outside native source spells it as a string other than a registration's name. That replaces ENTRY_ARG_CALLSITE_PROOF's
  blunter "the name is any identifier token of a native file" rule, which refuses `table` and `rows` because mruby's C
  has variables of that name. A C identifier is not a method name unless a stringizing macro makes it one; the same
  assumption SETTER_POOLS already makes.
* A site counts only when its argument count is the method's arity. Any other count raises ArgumentError in ENTER
  before the body reads a parameter. This replaces the single-definition rule: `rows` has a second, zero-argument
  definition in `RPG2k::Scene::ChipsetEditor`, which no three-argument call enters. Another definition of the name whose
  body (blocks included) contains `super` could reach this body with arguments no site shows, so it withdraws the name.
* Each site's argument resolves by the same rules, to a depth of three; a parameter that reaches itself again is
  refused (a cycle is not solved). Only a non-empty answer is kept.

`BC2CPP_CLASS_OBJECT_ARGS=0` turns it off; the shipped C++ is then byte-identical to the previous behaviour. The
`CONSTRUCTOR_POOLS` diagnostic counts the resolved sites as `param_named=N`.

## Consequences

Before/after on the shipped pass of the wio closed world (host `mrbc`, 3rd/mruby patched as `cmake/build-mruby.cmake`
applies it, `LANG=C.UTF-8`, `scripts/bc2cpp/coverage_report.rb`): the 28 constructors refused as `unresolved new with 2
arguments` leave the refusal list, pooled `initialize` argument sets go from 16 to 44, `bc2cpp_getidx(` callers from
1,956 to 1,807, `bc2cpp_slow_*` callers from 3,310 to 3,305, `mrb_funcall_with_block` sites from 379 to 378, and
`bc2cpp_nomethod(` sites (a guarded fallback proven to be an error) from 279 to 401. 32 of 3,447 functions change, all
in the `Game::Actor`/`Party`/`Troop`/`EnemyAi` database accessors whose `@db` argument is now a pooled `LCF::Database`.
`bc2cpp_send` call sites, and with them the `core_tag_chain_else` census categories, do not move: the pools this
unlocks mostly stop at the next missing fact (a constructor argument that is a caller's own parameter, an ivar of
another class with no pool, an element read), the flat tail ADR 0382 describes. The shipped C++ is byte-identical with
`BC2CPP_CLASS_OBJECT_ARGS=0`.

Measuring on an unpatched `3rd/mruby` hides part of the picture: `NativeClassResults` pins the SHA-256 of
`mrbgems/mruby-array-ext/src/array.c` as `patches/mruby-expose-collection-op-bodies.patch` leaves it, so on a plain
checkout `Array#compact` has no result fact, `ids.map { }.compact` is no Array, and every ivar assigned from it
(`Game::Party#@actors`) loses its pool and shows up as a `core_tag_chain_else` receiver. Apply the patches
`scripts/wio/bc2cpp_measure.bash` applies before reading a census.

Soundness rests on the call-site enumeration being complete, as for the existing pools. What a wrong answer costs is
a `new` site naming too few classes, so a constructor pool would miss a caller and an unguarded receiver proof would be
wrong; the guarded consumers of those pools re-check the class at run time, the unguarded ones do not. The conditions
above are each a negative in `scripts/bc2cpp/class_object_args_check.rb`.

Not done: a class object stored in an ivar, a constant array (`[A, B].each { |k| k.new }`), or passed through a
default argument is not resolved (those would need the class-object analogue of the class pools).
Two names that differ only in a class-valued constant's scope (`Title` is also `RPG2k::Scene::Title`) are both
candidates, as for a named `Title.new`; a precise lexical resolution would shrink the set.

## Checks

`scripts/bc2cpp/class_object_args_check.rb`: the resolver on hand-built bytecode (host, no mrbc), then the generated
code of a closed-world fixture with the kill switch, a computed class argument, a Symbol naming the helper and a
`super` override. It rides in the `ruby-checks` job and the coverage reporter's `CHECKS` list; the generated-code half
is a `class-object-args` shard of the nightly `bc2cpp-checks` job.
