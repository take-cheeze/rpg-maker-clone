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

## Container results, block parameters, and bc2cpp's core facts (spike, measured)

- **bc2cpp's core facts.** The spike loads `sig/native/core_fresh_arrays.rbs` and `core_results.rbs` through
  `NativeCoreResultSigs` (the compiler's own loader, not a copy). `keys`, `values`, `compact`, `flatten`, `uniq`,
  `split` and `bytes` return a fresh container keyed by their call site, and `to_a` returns self or a copy. Fresh
  containers have unknown elements (`TOP`) unless an ARRAY/HASH literal built them. Predicates from
  `core_predicates.rbs` are covered by the RBS import in the previous section.
- **Block parameters.** A `BLOCK`/`LAMBDA` irep is linked to its consuming `SENDB` through the block register, as
  `yield_reach.rb` does. A block is modeled only when that register has no other reader (a stored proc could be
  called later). A modeled block gets the yielded types for `each`, `map`, `select`, `reject`, `any?`, `all?`, `find`,
  `count`, `each_with_index` and `times`. Any other block, or a block with arity above one over an Array (which
  auto-splats), gets `TOP`. The earlier spike gave unmodeled block parameters `BOT`, which was unsound. This
  revealed `TOP` values that had been hidden.
- **Self in blocks.** A block created in a method has that method's class as self, unless it is passed to
  `instance_eval`-like sends.

Measured on the same dump: 8 of 13 block consumers are modeled. `TOP` returns stay at 245 of 369, `TOP` ivars at 75
of 197. `CPU#_pc` still does not close. The `TOP` writes into `_pc`, `data`, `_a` and `_p_nz` are mostly bitwise
`&`/`|`/`>>` and `ADDI`/`ADD` on operands that are themselves in the memory cycle. Several APU ivars (`freq`,
`timer`, `frame_counter`) are `TOP` through `MUL`/`ADD` on constants set by `(1..8).map { ... }`, which needs
`Array#map` on a literal Range. That is a separate, non-cyclic source. The cycle itself still has no isolated root.

## Range and map (spike, measured)

- **Range literals.** `RANGE_INC`/`RANGE_EXC` produce `[:Range, 'Integer']` when both ends are Integer, and
  `[:Obj, 'Range']` otherwise. Only the first has an element type.
- **map.** `Array#map` and `Range#map` always build a new Array. Its elements are the join of the return types of
  the modeled block (`MAP_ELEMS`), and stay `TOP` when the block is not modeled.
- **Block escape check, tightened.** A block is modeled only when no read of its register is reached by the BLOCK
  op's value. An earlier version counted every instruction mentioning the register, which hid most blocks. Reads
  are: any SEND, arithmetic and comparison (which read `R[A]`), GETIDX/SETIDX, SETIV, SETUPVAR, SETCONST, RETURN, and
  any instruction that reads a source operand. A pure overwrite of the register is not a read.

Measured: the CLK constants set by `(1..8).map { |i| i * RP2A03_CC }` are now `Integer`. Modeled blocks go from 8 to
62 of 95 linked consumers. `TOP` ivars 68 of 197 (was 70). Counts of `TOP` returns and parameters are not comparable
with the previous section, because blocks now carry returns and parameters too. `CPU#_pc` is still `TOP`. The APU
ivars `freq` and `timer` are still `TOP` through a different source, which I did not trace.

## Tracing the remaining TOP (spike, measured)

Tracing the APU `freq` ivar found four precision gaps in the spike, all fixed in `scratchpad/sealed-repro/receiver_slot4.rb`:

1. **Scoped constants.** `GETMCNST` (`CPU::CLK_1`) was `TOP`. It now takes the join of every `SETCONST` of that simple
   name, which covers the scoped one.
2. **Local loops.** A loop counter whose reaching writes include its own update re-entered the same query until the
   depth limit, which gave `TOP`. A re-entered query now returns its current approximation, and the query repeats
   until it stops changing (at most 8 rounds, then `TOP`).
3. **Literal array slots.** `AREF` with a literal index reads that slot of an ARRAY literal, not the join of all slots.
   Without this, `rate, fixed = r, f` made `fixed` as imprecise as `rate`. A SETIDX with an unknown index writes every
   slot.
4. **Nil operands.** A `nil` operand of an arithmetic operation raises before any value is made, so it contributes
   nothing. `@wave_length` is `nil` until `reset`, so `@wave_length + 1` was `TOP`.

A fifth fix matters for soundness of the fixpoint. A modeled `map`'s result now starts at `BOT` and is filled in each
round from the block's returns. Starting at the default `TOP` let one early `TOP` stick in the cycle `freq → update_settings
→ freq`, because `TOP` absorbs. An unmodeled `map` keeps the default `TOP`.

Measured: `TOP` ivars 49 of 197 (was 67). `APU#freq`, `timer` and `fixed` are now `Integer`. `CLK_1` is
`Integer ∪ NilClass` (the `AREF` past the end of a fresh `map` array reads nil). The fixpoint converges in 8 rounds.
`CPU#_pc` and `CPU#data` are still `TOP`. Their remaining writers are `&`, `|` and `>>` on operands in the memory cycle
(`_pc` → `peek16` → `fetch` → `@fetch` → `data` → `_pc`), so the cycle still has no isolated non-cyclic root.

## Ablation of the memory cycle (spike, measured)

The spike pins a chosen set of values to `Integer` after each round (`scratchpad/sealed-repro/ablate_run.rb`, with
`ABLATE` for ivars and `ABLATE_RET` for method returns). If `CPU#_pc` becomes `Integer`, the pinned set cuts every
`TOP` path into it. Results:

- Pinning any single ivar (`_a`, `_x`, `_y`, `_p_nz`, `addr`, `data`) does not resolve `_pc`.
- Pinning all 14 CPU register and data ivars does not resolve `_pc`.
- Pinning only `fetch`'s return, or only `peek16`'s, does not resolve `_pc`. Pinning the PPU/APU read handlers does not
  either.
- Pinning `fetch` and `peek16` together with the 14 register ivars resolves `_pc`. So does pinning them with the six
  flag ivars `_p_nz, _p_c, _p_v, _p_d, _p_i, _p_b`.
- Pinning `fetch` and `peek16` with `_p_c` alone resolves `_pc`. Pinning `_p_c` alone, or with either return alone,
  does not.

So the cycle closes only when the memory read values and the carry flag are both non-`TOP`. `_p_c` is written by
`& >> SUB` on `data`, and `data` comes from `fetch`. The read side is `fetch` → `@fetch[addr]` → `peek16`, plus
`ROM#peek_6000` → `@wrk[addr - 0x6000]`. That index is `TOP` because `addr` is in the cycle.

Two notes for the next step:

- `ROM#peek_6000` reads `@wrk`, which is written by `@wrk.replace(sav.bytes)`. The spike does not model `replace` as a
  mutation of its receiver's contents. If it is not, the spike's element types for `@wrk` are unsound, not just
  imprecise. That has to be checked before any result is trusted.
- An attempt to type an `Array` read with an unknown index as "element, nil, or unknown slice" made `TOP` ivars rise
  from 49 to 79 (the extra atoms reached dispatch and overflowed). It was reverted and is not in the spike.

Next: model unknown-receiver mutators (`replace`, `concat`, `push`, `[]=`) as writes that make a container's contents
`TOP`, then recheck `_p_c`'s and `@wrk`'s types.
