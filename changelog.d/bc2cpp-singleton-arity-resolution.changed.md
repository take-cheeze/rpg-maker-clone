- **bc2cpp resolves singleton calls on class constants and argument-count
  mismatches at compile time** (docs/adr/0259). `Const.name` follows the
  singleton lookup through superclass constants, optional parameters, `class <<
  self` accessors and module_function copies with blocks; an implicit-self call
  in a module's `def self.x` is a direct call in the closed world too; a send
  that provably reaches a plain signature with the wrong argument count raises
  mruby's own `ArgumentError` statically; optional-parameter definitions join
  POLY chains; and exact-class arms next to a chain call their definition
  instead of dispatching. On the shipped wio build dispatching sites go from
  10185 to 9976 and excluded `singleton_owner`/`arity`/`unsupported_arity`/
  `owner_not_emitted` definitions from 319/214/19/13 to 239/177/9/0. Covered by
  the new `scripts/bc2cpp_singleton_arity_check.rb`.
