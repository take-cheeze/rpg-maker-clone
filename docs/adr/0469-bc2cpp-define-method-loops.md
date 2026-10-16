# 0469. bc2cpp: a class-definition-time `define_method` is a method definition whose body is the block

Date: 2026-10-16

## Status

Accepted. Extends [ADR 0288](0288-bc2cpp-define-method-sites.md) (literal class-body sites) and reuses the loop
interpreter of [ADR 0304](0304-bc2cpp-loop-installed-accessors.md).

## Context

ADR 0288 made `define_method(:name) { |a| ... }` written straight in a class body an ordinary registry
definition. Two shapes that also run exactly once while the class is defined were still dynamic installers:

- `define_method` inside a class-body loop over a literal container,
  `%i[a b].each { |n| define_method(n) { ... } }` or `NAMES = %i[a b].freeze; NAMES.each { ... }`. The name
  is not a literal at the send, so `CodeGen#symbol_installed_names` went nil and every name in the program
  counted as installed at run time (`KEPT dynamic_install` in the closed-world reports), and `DynamicNames`
  counted it as a computed name.
- a literal site whose block uses `return`, which ADR 0288 refused although mruby's `OP_RETURN_BLK` returns
  normally from a strict proc (`vm.c`: `if (!MRB_PROC_ENV_P(ci->proc) || MRB_PROC_STRICT_P(ci->proc)) goto
  NORMAL_RETURN`), and `Module#define_method` makes the proc strict.

A survey of the compiled sources (mruby-rpg2k, mruby-rgss and mruby-lcf mrblib) and of the outside Ruby
(`foreign_mrblib_srcs`: mruby's mrblib and gem mrblib, mruby-marshal, mruby-onig-regexp, mruby-stringio) finds no
`define_method` call at all. The installers there are `alias_method` (mruby-rgss `lib.rb` and `array_sort.rb`, the
mruby gems), which this ADR does not change. So this changes no current build; it is for code written in these
shapes from now on.

## Decision

`LoopInstallers` (ADR 0304) now also models `define_method(name) { ... }` in the loop block it interprets on the
literal container. A loop that installs methods this way registers one `MethodDef(installer: :define_method)` per
name. Each expansion's body is a copy of the block irep, `DefineMethodSites.expand`, labelled `<block>~dm<i>` (i is
the iteration), in which every `GETUPVAR` of the loop variable is a `LOADSYM` of the Symbol that iteration bound.
Each name then gets its own irep, so no per-irep analysis mixes the call sites of two names. Everything after
that is the existing method path: the registry, the closed world, the method entry and wrapper, and the owner
registration that replaces mruby's proc with the compiled entry after the class body has run (one definition per
name at run time, as for ADR 0288).

The semantics are those of `src/class.c`'s `define_method_m`:

- the method is public, on the class or module whose body runs the loop;
- arity is strict like a lambda: the block may have required parameters only (`ENTER` with no optional, rest,
  post, keyword or block parameter), and the wrapper's `mrb_get_args` raises `ArgumentError` as the strict proc
  does;
- `self` is the receiver;
- the block's own frame is the method: `block_given?`, `binding`, `__method__` and the other frame sends, `yield`
  (`BLKPUSH`), `super`, `break` and definition opcodes stay refused;
- a `return` in the block itself (`RETURN_BLK` at depth 0) returns from the method. This now holds for ADR 0288's
  literal sites too. A `return` in a nested block stays refused.

A loop site qualifies when all of ADR 0304's conditions hold (a literal container no call could have reached, a
loop that runs once per body, untouched core iterators, an interpreter that refuses every opcode it does not
model) and also:

- the loop runs in a class or module body of the engine's own Ruby: not at top level (where `define_method` is
  `Object`'s private one), not in a singleton-class body or a `Struct.new` block, not in mruby's core Ruby;
- the name is a Symbol the walk built, an identifier optionally ending in `?`, `!` or `=`;
- the body has no nested block (a child irep shared by several expansions would be compiled under several
  methods), and every upvar it reads is a register of the loop block itself (level 0). A class-body local, or any
  deeper frame, is refused;
- each register the body reads holds a Symbol when the iteration's frame ends. That is the value the block's env
  keeps from then on. A loop variable reassigned after the install, or one bound to a non-Symbol value (a Hash
  value, a String), refuses the loop.

`DefineMethodSites.settle` then keeps the expansions only in a closed world that trusts `define_method` (ADR 0288),
and keeps all of one send's expansions or none: a second body for any expanded name on that owner (a `def`,
another `define_method`, the same name twice in the list) drops the whole send. `settled?` answers for a loop send
only while its expansions are in the registry, so `symbol_installed_names` skips exactly the settled sends.
`DynamicNames.settled_sends`, which `bc2cpp.rb` sets after settling, lets a settled send count as the names it
installs instead of as a computed name.

Every refusal leaves the loop the dynamic installer it was. Its `define_method` send keeps
`symbol_installed_names` nil, and the interpreted strict proc is the method.

## Consequences

- `scripts/bc2cpp/define_method_check.rb` (in the `bc2cpp-build` job of `build.yml`) checks four things.
  - The registry: the expansions, their labels, the loaded Symbols, and each refusal and settle withdrawal. A
    refused send keeps the installed names unknown.
  - The generated code: direct calls, and a Symbol constant where the upvar was.
  - The interpreted and compiled answers on real mruby, for a literal site with `return`, a loop over a frozen
    `%i[]` constant, the captured loop variable, `self`, and strict arity through `OP_SEND`.
  - A refused loop, which stays a dynamic send and answers alike.

  The run uses a full-core build, or the tree's core-only `build*/mruby/host/mrbc` with an `Array#each` polyfill.
- `call_facts_check.rb` and `class_narrowing_check.rb` used `[:x].each { |n| define_method(n) { } }` as their
  "computed definition" world. That shape is now a definition, so those worlds spell the name as a String
  (`%w[x].each`), which stays a dynamic installer. `define_method_sites_check.rb` now treats a top-level `return`
  as a positive and keeps the nested-block `return` as a negative.
- Other passes still read a `define_method` send conservatively: the escape analysis' naming sends,
  `numeric_aliased_names`, and the numeric ivar self-rebinding scan. This loses precision, not soundness.
- Residual risk is the same as ADR 0288's. The trust test is lexical, and a compiled method replaces the proc only
  where registration runs. An unregistered one stays the strict proc, which is equivalent.
