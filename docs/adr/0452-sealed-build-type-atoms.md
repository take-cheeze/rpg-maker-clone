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

## Spike result (measured, not yet promoted)

`scratchpad/sealed-repro/receiver_spike.rb` implements the atoms and dispatch rules above on the optcarrot dump
(`out4/yield.dump`). What it shows:

- Receivers resolve. `@cpu` is `[:Obj "CPU"]`, and the `fetch` sites in `CPU` dispatch to `CPU#fetch` only.
- `SSEND`/`SSEND0` take self from R0, not from R(A). R(A) is the result slot. Treating R(A) as the receiver made
  every self-call look like a call on an `Integer`. Self in a method of class `K` is typed `[:Obj K]`.
- Constants take the join of their `SETCONST` values, and comparison opcodes (`EQ`, `LT`, ...) and `ADDILV`/`SUBILV`
  are typed. `CLK_*` stays `TOP` because it is set through `(1..8).map { ... }` destructuring, which needs `map`
  modeled.
- `[]` and `call` dispatch per receiver atom. A `Method` atom calls its targets, an `Array` atom indexes, and a
  `nil` atom contributes nothing, because `nil[...]` raises. This is needed because `@fetch` holds both `@ram`
  (an Array, from `add_mappings(0x0000..0x07ff, @ram, ...)`) and `Method` objects.

What it does not show: `CPU#_pc`, `CPU#fetch` and `CPU#peek16` stay `TOP`, so `CPU#run` is still not proved
yield-free. The remaining `TOP` sources sit inside the memory cycle (`_pc` → `peek16` → `fetch` → `@fetch` → `data`
→ `_pc`). Most `TOP`-producing rules inside `CPU` methods are bitwise sends (`&`, `|`, `<<`, `^`, `>>`) whose operands
are themselves in that cycle, plus unmodeled `RANGE_INC`, `BLOCK`, `each`/`times`. The spike did not isolate a single
non-cyclic root, so the cycle is not yet shown to close under an optimistic fixpoint. Next step: model `Range` and
block arguments, then rerun to see whether the cycle resolves.

Two premises are still unchecked and must be before promotion:

- No program class has a subclass whose override could shadow a method in `Obj C` dispatch. The spike assumes
  this; bc2cpp's `superclass_of` must confirm it.
- A native method with the same name on a program class (for example a `Struct`-derived class) is not dispatched by
  name. The spike dispatches program-class receivers past the native gate only when every atom is a program class.

Status stays Proposed. The atoms are a sound design for dispatch, but the measured result does not yet reach
`CPU#run`.

## Core signatures and Range (spike, measured)

- **Core RBS import.** The `rbs` gem ships CRuby 3.4 core signatures (`core/*.rbs`), and they load with
  `RBS::EnvironmentLoader`. The spike reads return types from them for Integer, Float, String, Symbol, nil, bool,
  Range, Enumerator, Array, Hash, Kernel and BasicObject. A call falls back to them only when no program method of
  that name can run on the receivers (no Object, Kernel or constructed-class method of that name). A return maps to
  an atom when it is a plain class (`Integer`, `Symbol`, `String`, `Float`, `Range`, `Enumerator`), `bool`, `nil`,
  `self`, or a union or optional of those. `Array`/`Hash` returns and type variables stay `TOP`, because a container
  needs an allocation key the core signature does not give.
- **Caveat.** These are CRuby signatures, and mruby differs (a method may be missing, or behave differently). A
  promoted version must intersect with mruby's own method list and check each entry it relies on.
- **Range.** `RANGE_INC`/`RANGE_EXC` produce `[:Obj, 'Range']`. `Integer#step` and similar produce
  `[:Obj, 'Enumerator']`. `add_mappings` now gets a `Range`/`Integer` first argument at every call site.

Effect on the same dump: `TOP` returns 261 → 245 of 369, `TOP` ivars 80 → 75 of 197, methods with a `TOP` parameter
68 → 63 of 229. `CPU#_pc`, `CPU#data` and `CPU#fetch` remain `TOP`. The memory cycle still does not close, because
its values pass through `Array` returns and block-taking methods, which this typing does not reach.
