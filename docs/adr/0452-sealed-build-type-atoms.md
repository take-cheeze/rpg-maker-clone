# 0452. Type atoms for the sealed-build receiver analysis

Date: 2026-10-15

## Status

Proposed

## Context

ADR 0451 concluded that the sealed build's `Optcarrot::CPU#run` stays interpreted until the yield analysis can
bound the methods reachable through `[]`, `call` and `fetch` on the Fiber path. The spike toward that bound
progressed in three steps, all kept outside the repository:

1. **Union lattice.** A value is a set of atoms: `Integer`, `NilClass`, `Symbol`, and container and Method atoms
   (`[:Cont, kind, allocation keys]`, `[:Meth, names]`), with `TOP` as the overflow state. Parameters now carry
   unions, for example `ContArray ∪ Meth{peek_401x, peek_ram, peek_nop}` for `add_mappings`'s `peek`.
   Calling `[]` on `nil` contributes no callee, because it raises before any method runs.
2. **Upvalues.** A captured variable's type is the join of every value written to it: direct writes in the
   owning method, `SETUPVAR`s from nested blocks, and the parameter's entry value. Owners are found by climbing
   `C+1` parents for level `C`. Of 1,929 captured variables, 1,351 remain `TOP`, because their writers are sends
   the spike does not model.
3. **Return types and Method parameters.** A Ruby method's return type is the join of its `RETURN` operands, and
   a `[]` or `call` on a Method value passes its arguments to the named methods.

None of these moved the CPU register types. `@_pc`, `@addr`, `@data`, `@_a`, `@_x` and `@_y` are still `TOP`.

## Finding: parameter flow conflates by name

The binding constraint is name-level call resolution. `CPU#fetch(addr)` receives the arguments of every call named
`fetch`, including `opt.fetch(:mapping, true)` (a `Hash#fetch` in `ppu.rb:83`). That `Symbol` argument joins
with the `Integer` arguments of `@cpu.fetch(...)` and makes `addr` `TOP`, and the `_pc` cycle through `fetch`,
`peek16` and `@data` stays `TOP` from then on.

The same conflation affects every name shared by a Ruby method and a native method (`[]`, `fetch`, `call`).
A call's receiver decides which method runs, so the analysis needs the receiver's class as a value, not only the
method name.

## Decision

Add class atoms to the union lattice:

- `[:Obj, C]` for an instance of a program class `C`, produced by `C.new` where `C` is a constant the program
  defines, and carried through ivars, parameters and containers like the other atoms.
- `[:Cls, C]` for the class object itself, produced by the constant read, and consumed only by `new`.

A call `N` on a receiver set resolves to:

- the Ruby methods named `N` whose class is `C`, an ancestor of `C`, or a module, for each `[:Obj, C]` atom;
- the Ruby methods named `N` whose class is `Object`, `Kernel` or `BasicObject`, plus native methods, for
  container and scalar receivers (core classes are not reopened in the sealed build, which the closed-world
  check enforces);
- every method of that name, unchanged, if any atom is not understood. This keeps the rule sound and makes
  imprecision visible rather than hidden.

Parameter flow then follows the resolved targets only, so `CPU#fetch` receives only the arguments of calls whose
receiver can be a `CPU`.

## Consequences

- The spike's soundness rests on module membership and on "a constructed class is a class". A module cannot be
  constructed with `new`, so a class atom can be told from a module by whether the program constructs it. A class
  that is only built through `Class.new` or `dup` would be misclassified, so such constructions must be detected
  and refused in the same way.
- The change touches only the analysis, not the sealed build's runtime. Nothing in the default build changes.
- The sealed build stays at about 13 fps until the analysis carries through to `CPU#run` and a yield-analysis
  change consumes it. This ADR does not promise that outcome.
- Promotion into `tools/bc2cpp` needs its own ADR, tests, and a soundness review of each atom rule.
