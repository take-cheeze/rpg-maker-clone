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

## In-place mutators (spike, measured)

`scratchpad/sealed-repro/receiver_mut.rb` treats a send of a mutating core name (`replace`, `concat`, `push`, `<<`,
`[]=`, `slice!`, `shift`, `clear`, `update`, and so on, from `MUTATORS`) as making its receiver's contents `TOP`. A
`call` on a `Method` value bound to a mutator (`@ram.method(:[]=)`) does the same to the containers that were bound.
A receiver of unknown type makes every container `TOP`.

- The earlier `ROM#peek_6000` finding is real. `@wrk.replace(sav.bytes)` and `buf.slice!` (`rom.rb`) mutate arrays that
  the spike had typed from construction alone. Those earlier element types were therefore unsound, and the earlier
  `TOP` counts (49 ivars) were optimistic.
- Sound measurement: `TOP` ivars 64 of 197. `CPU#_pc`, `data`, `_p_c` and `APU#fixed` are `TOP`. `fixed` is now `TOP`
  because `rom.rb:242`'s `slice!` has an unknown receiver (the ROM byte buffer comes from `zip_extract`), which makes every
  container `TOP`.
- Removing `<<` from `MUTATORS` did not change the result. The unknown-receiver case is what dominates.

Remaining gap: a receiver of unknown type should poison only the containers it can be, but the spike has no receiver
flow for `TOP` values. Until it does, the sound model cannot separate the memory cycle from unrelated containers.

## Escape-based receiver flow (spike, measured)

`scratchpad/sealed-repro/receiver_flow.rb` lets a `TOP` receiver of a mutator touch only containers that escaped. A
container escapes when its atom is an argument of a send, a stored `SETIDX` value, a returned value, or the receiver of
a mutator `method` value. A `TOP` escaping value may contain any container, so all containers escape. That rule is
required for soundness, not a choice.

- Sound result: `TOP` ivars 64 of 197 (unchanged). `_pc`, `data`, `_p_c` are still `TOP`.
- Of 2,251 escape sites, 735 carry a `TOP` value. Each one makes every container escape.
- Measurement only, not sound: ignoring the `TOP` escapes gives 55 `TOP` ivars and resolves `APU#fixed` and `freq`.
  That shows the contamination is the bottleneck, not the mutator model.

Conclusion: escape alone cannot separate the memory cycle, because `TOP` values are everywhere in it. Receiver flow has
to give `TOP` values a possible-container set (their provenance), so an escape only reaches the containers that can
produce the value. That is a design change, not a tweak, and it is the next step. It needs: a value lattice with a
"may-contain these container keys" component beside `TOP`, joined and propagated through the same rules, and a check
that each opaque source (unknown sends, `GETGV`, ROM reads) either contributes a finite key set or stays `TOP` for every
container.

## String#bytes element type (spike, measured)

`scratchpad/sealed-repro/receiver_bytes.rb` types the elements of a `String#bytes` result as `Integer`, taking the
signature from the compiler's own `sig/native/core_results.rbs` (`def bytes: () -> Array[Integer]`). Only three
`bytes` sites exist in the dump, and none of them feeds the memory cycle: the ROM buffer's receiver is a `TOP`
value from `zip_extract`, and `File.binread(...).bytes` is typed only where the receiver is a known `String`. The sound
count is unchanged: `TOP` ivars 64 of 197.

The next step is the provenance lattice described above. It is a design change, not a tweak, and I have not built it.

## Provenance value lattice (design, prototype checked)

The sound count stays at 64 `TOP` ivars because a `TOP` value might contain any container, so every escape poisons every
container. This section redesigns the value lattice so a `TOP` value carries the containers it may hold. The prototype is
`scratchpad/sealed-repro/lattice_prov.rb`, and its property checks pass.

**Values.** A value is a set of atoms, as before, plus one new atom `[:Unk, KS]`. `KS` is the set of container keys the
unknown value may contain, or `:any`. `TOP` is `Set[[:Unk, :any]]`.

**Consumers.** Anything that dispatches, does arithmetic, or types a value calls `consumer_view`, which turns any `Unk`
part into `TOP`. So no existing type rule can see the new atom and read it as a type. Only escape and mutation read `KS`.

**Join.** Union of atoms. `Unk` atoms merge their key sets, and `:any` absorbs. This is commutative and idempotent,
and checked.

**Reachability.** The keys reachable from a value follow container elements transitively (`reach_keys`). A key whose
contents are not recorded has unknown contents, so reaching it yields `:any`. The checks confirm this.

**Soundness obligations before wiring.** These must hold in the analysis itself, and the prototype does not discharge them:

1. Every rule that currently returns `TOP` must return `Unk` with a `KS` covering every container that can reach its
   result. Opaque sends use the reachable keys of their operands, with `:any` when an operand is `TOP`.
2. Ivars, globals (`GETGV`), constants and returns carry `Unk` sets through the same joins. A global read with no known
   writers is `Unk(:any)`.
3. A mutator with a `TOP` receiver touches exactly the containers in the receiver's `KS`. A `Method` value bound to a
   mutator touches its bound keys.
4. Core signatures may narrow `KS` only when the result cannot hold a container the signature does not declare.

**What wiring would change.** Escape sites with `TOP` values would stop poisoning every container. The measurement with
that rule ignored (unsoundly) gave 55 `TOP` ivars and resolved `APU#fixed` and `freq`. The honest expectation is between
55 and 64, and the memory-cycle question reduces to whether `data`'s provenance includes the RAM container.

This section is design and a checked prototype. The analysis is not wired to it yet, so the sound result above still
stands.

## Wiring the provenance lattice (spike, not converged)

`scratchpad/sealed-repro/receiver_prov.rb` wires the provenance lattice into the spike:

- `rt` is now the consumer view of `rtp`, the raw query. Consumers keep their `TOP` checks. A value with an `[:Unk, KS]`
  atom reads as `TOP` to them.
- A rule that gives up (`TOP`) yields `[:Unk, KS]`, where `KS` is the reachable containers of its operand registers.
- State writes (ivars, constants, parameters, returns, upvalues, array elements) keep the raw value. Escape and
  mutation use `reach_keys` and `direct_keys` over raw values. A `TOP` receiver touches every container.
- Queries are cached per round, and a result is cached only when it read no in-progress query. This makes the run
  about 2.5 minutes.

**The run does not converge.** It reached the 60-round cap (`rounds=61`), so its numbers are not a fixpoint and I do not
report them as a result. The instrumented run shows the cause: `pulse_0` alternates between `{Pulse}` and
`{Pulse, NilClass}` every round. The `nil` comes from `aref_value`'s fallback to the elements plus `NilClass` when a
slot is missing. Mutators reset `elem_at` to empty, and the array-literal loop restores it on a different schedule, so
the same slot flips. The fallback is correct, but the reset and restore make the update non-monotone.

Next step: make the mutator reset monotone (widen to `TOP` slots instead of emptying them), so the sequence of
approximations only grows. Then rerun and check convergence before reading any count.

## Monotone mutation: converged result (spike, measured)

`scratchpad/sealed-repro/receiver_mono.rb` makes mutation sticky. A mutated container's slots stay `TOP` for the rest of
the run (`st[:mut]` only grows), and the array-literal pass no longer re-creates its slots. The run converges in 10
rounds, so its numbers are a fixpoint.

- Counting an ivar as unknown to consumers when it is `TOP` or carries an `[:Unk, _]` part: 74 of 197 (38 `TOP`, 36 with
  an unknown part). Before wiring provenance the same count was 64.
- So the wiring is converged but currently less precise than the non-provenance model. The unknown parts are mostly
  `[:Unk, {}]`: a rule gave up on operands that carry no containers, which the old model also reported as `TOP`.
  Provenance does not separate them, so the escape gain does not appear yet.
- `CPU#_pc`, `_p_c`, `APU#fixed` and `freq` are unknown to consumers. `APU#fixed` and `freq` were `Integer` in the
  unsound escape-ignoring measurement, so that result depended on an unsound assumption.

Next step: find which rules return `[:Unk, {}]` on operands that are scalars (arithmetic, comparison and sends on
`Integer`), and give them scalar results, so provenance is only attached where a container can flow.

## Next step toward avoiding the interpreter (spike, measured, not resolved)

Four changes were tried on the converged provenance spike. Each run converged, and the consumer-level unknown count
(`TOP` or an `[:Unk, _]` part) is the measure. Scratch scripts are in `scratchpad/sealed-repro/`.

- Unknown sources by producing rule (`unksrc.rb`): most counts are propagation through `MOVE`, `GETIDX`, `GETIV`, not
  sources. The give-up counts on known operands are dominated by top-level and class-body constructs (`TDEF`, `STRCAT`,
  `BLOCK`, `GETGV`, `OCLASS`, `EXEC`), which are not on the `CPU` path.
- Core guard relaxed for core receivers (`guard.rb`): unchanged, 74. A core receiver cannot be an instance of a program
  class, so only `Object`/`Kernel`/`BasicObject` methods of the same name should block a core signature. It did not move
  the `CPU` chain.
- Stores as joins (`join.rb`): a `[]=`, `<<`, `push`, or `call` through bound store methods joins the argument into the
  contents instead of making them unknown. Unchanged, 74. The RAM contents are not the blocker.
- Unknown results stay `BOT` while operands are `BOT` (`bot.rb`): converges in 10 rounds, 70 consumer-level unknowns.
  This removes a non-monotone source at round 3, where `peek16` gained an unknown part from operands that were not yet
  known.

The origin trace (`origin.rb`) shows `CPU#_pc` stuck at a self-sustaining `TOP`: `_pc = (_pc - 1) & 0xffff` keeps the
`TOP` it received from `peek16` at round 3. The `TOP` enters through `@fetch[addr][addr]` (`fetch`, `peek16`), where the
index `addr` is consumer-`TOP` because it is in the same cycle. The first `TOP` is therefore a cycle entered at round 3,
not a missing rule elsewhere.

So avoiding the interpreter for `CPU#run` still needs the address value (`_pc`, `addr`) to be typed as `Integer` in
the read path `fetch` → `@fetch[addr]` → `peek16`. Two options follow from this:

1. Type array indices from the index's own flow when the index is an `Integer` by construction (`_pc` is only
   `Integer` arithmetic and literal stores, and `addr` is only that value). This is a sound refinement, but it needs the
   index's type without the consumer `TOP`, which is the provenance problem again.
2. Keep the index `TOP` and accept an unknown element. Then `_pc` is unknown by design, and `CPU#run` cannot be proved
   yield-free without a stronger premise about the address, for example from the `Optcarrot` source.

Neither has been built. The next design step is option 1, with the index type carried as a separate component
(`Integer`-only flow), not as a rule.
