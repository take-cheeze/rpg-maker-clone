# 0402. bc2cpp: a compact class definition is named by its resolved outer constant

Date: 2026-10-11

## Status

Accepted

## Context

A class written in compact form, `class Outer::Name`, opens `Name` inside the constant `Outer`, not
inside the lexical namespace. `registry.rb` named every CLASS by `namespace::name`, where `namespace`
is the lexical nesting, so a compact definition at top level was named just `Name`, and the same
definition inside `module M` was named `M::Name` even when `Outer` is a different constant.

`closed_world.rb` guarded this with a single global refusal, `qualified_class_definition`, raised for
any class whose outer register is not a literal `nil` (`class_decls[...][:outer_nil]`). The refusal
hid the naming error by refusing the whole closed world, so one compact class anywhere in a build
made every reviewed-list gate see zero sites. The typed save-state work (see the bisect notes for
ADR 0400) hit this: a single `class SaveTyped::Record` inside `module LCF` turned the reviewed-list
gate into 2,934 "stale" keys, all of them the result of the refusal and not of any real site change.

## Decision

Resolve the outer constant of a compact definition in `tools/bc2cpp/registry.rb`
(`compact_outer_name`):

- The outer is the constant path of the CLASS/MODULE's outer register (`constant_path`, rooted at a
  GETCONST, with GETMCNST segments).
- At top level (no lexical namespace) the first segment is taken as written: it is an exact global
  name, so no lookup can be ambiguous.
- Inside a namespace the first segment resolves only to `Namespace::First` when that module has
  already been walked in this file (`module_names`). Any other case, including a constant from
  another file, a module defined later, or an unrecognised register write, resolves to nil.
- A resolved definition is named `"#{outer}::#{name}"` and recorded in `class_decls` with
  `outer_qualified: true`. The body walk uses that name as its namespace, so its methods are owned by
  the qualified class.

`closed_world.rb` refuses a class only when it is neither nil-outer nor qualified-resolved:

    global!(:qualified_class_definition) if ... { |d| !d[:outer_nil] && !d[:outer_qualified] }

Unresolved compact definitions keep the refusal, so the rule stays fail-closed.

## Consequences

- Compact definitions at top level and inside a namespace whose outer module is declared earlier in
  the same file now generate code. Their methods are owned by the correct qualified class, and the
  "never called" and dispatch listings print `Outer::Name#method`.
- The refusal now fires only for a compact definition the registry cannot resolve from its own file.
  That is the case the refusal was meant to catch.
- The reviewed-list gate no longer turns one compact class into a whole-build failure. A real
  unreviewed or stale key is reported as itself.
- Follow-up: resolving a compact outer against a module declared in another file needs a
  whole-closed-world constant table, which build_registry does not have yet. Until then such a class
  is refused, as before.
- Covered by `scripts/bc2cpp/compact_class_check.rb`: three fixtures that must generate (top-level
  and namespaced compact classes, with qualified owners) and one that must still be refused.
