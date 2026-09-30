# 0283. bc2cpp proves blocks yield-free, and refuses what a Fiber can cross

Date: 2026-09-30

## Status

Accepted

## Context

A compiled frame between a Fiber's entry and a `Fiber.yield` breaks mruby's fiber switch (ADR 0269,
`tools/optcarrot_probe/README.md`). Three mitigations were in place, each with a hole:

1. The registered entry of every compiled block-taking core method (`Array#each`, `Integer#times`,
   `Enumerable#map`, ...) hands the call to the bytecode whenever `M->c != M->root_c`, so no core
   iterator is compiled inside any Fiber, though the RGSS script host runs every game script in one.
2. Every BLOCK_CORE_DIRECT arm (ADR 0270) repeats that test and keeps a dynamic tail for the Fiber case.
3. `compute_fiber_unsafe_methods` refused only the methods a `Fiber.new` block reaches by same-owner self
   sends. A call with an explicit receiver into another class, a block, a computed send or a native
   callback left the walk (an acknowledged gap), and a miss is a `FiberError` in the browser build.

The interpreted user blocks that yield are inherent to (1) and (2): they stay on the bytecode path. But
most blocks of the engine are compiled, and a compiled block that provably cannot reach a yield does not
need the guard.

## Decision

### YIELD_REACH: a by-name, whole-program "may this suspend the Fiber?" analysis

`tools/bc2cpp/yield_reach.rb` (`YieldReach`) works on the ireps of the build. Per irep (method, block,
class body) it computes two facts.

- `nb(n)`: a yield can happen above `n`'s frame, not counting the blocks `n`'s method *received*. Those are
  accounted where they were passed: a literal block is an edge of the passing node, a forwarded one marks the
  forwarder, and a `yield` marks the receiving method.
- `own(n)`: `nb(n)`, or `n` runs the block its method received and a block passed to that method may yield.

A call edge uses `nb(callee)`, a literal-block edge `nb(block)`; `own` answers "can this frame itself be
crossed". A block or method is **yield-free** when `own` is false. A core iterator body whose `nb` is false is
**relaxable**: given a yield-free block it cannot suspend a Fiber either.

Seeds (`nb` true): `Fiber.yield` and `Fiber#transfer` (a `yield` on a receiver that is not the literal class
counts when the Fiber class flows anywhere else than `Fiber.new`/`.yield`/`.current`), an `eval` of a string
(closed worlds only), and the yielder of an Enumerator driven by `next` (below).

Edges: every call by name over all receivers (`super`, `alias`, operators and the implicit calls of bytecode
ops, `Klass.new { }` to that class's `initialize`), literal blocks and class bodies, and, in a closed world,
the unknown code of the program:

- a computed `send`/`public_send`/`instance_exec` reaches any method; `Symbol#to_proc` and `inject(:sym)` reach
  the methods some Symbol was converted for (`&:sym`, `to_proc`, `method(:x)` literals);
- a Proc called through `call`/`()`/`yield`/`[]`/`===` (index reads on a receiver that is not provably
  a literal) whose origin is unknown reaches every block that can escape (stored by `new`, `define_method`,
  `proc`, `lambda`, or handed to a method that keeps its `&blk`), computed from the block flow, which forwards
  through `&blk`, `super` and the dynamic sends;
- native code reaches the methods named in the `mrb_funcall` family of its sources, the implicit hooks of mruby
  (`initialize`, `to_s`, `each`, `call`, ...), the operators and every identifier of the foreign Ruby sources.

The proof needs the ClosedWorld with no global refusal (`YieldReach#sound?`). Outside one nothing is claimed
yield-free and the analysis only feeds the refusal below, without unknown code, which is what the compiler
did before.

**The Enumerator machinery is modelled, not treated as unknown.** `Enumerator#next` runs the enumeration in a
Fiber whose block calls `Fiber.yield`; the block reaches the `each` (or `to_enum(:name)` target) of any
object, and a generator block (`Enumerator.new { |y| y << 1 }`) reaches it through `Enumerator::Yielder`. Read
literally this makes every unknown Proc call and every dynamic send may-yield in any world that contains
mruby-enumerator, which is all of them. It is *sealed* instead when nothing lets a yielder or such a block go
elsewhere (checked: no `Yielder`/`Generator` constant outside mruby-enumerator, a generator block only sends
`<<`/`yield`/`call` to its yielder parameter, no method outside Enumerator/Generator/Yielder keeps a block the
Enumerator supplies): the yielder methods are seeds reached only from generator blocks and mruby-enumerator's own
code, blocks that only they run are not "escaping", and the names an Enumerator can dispatch to are the `each`
and the literals of `to_enum`/`enum_for`/`Enumerator.new`. Blocks and iterators with those names that run their
received block are `own`-yielding (`Actors#each`); a generator block is `nb`-yielding. When any condition fails
the machinery is unknown code and the proof shrinks to what it can prove (the check reports why).

### Blocks: a flag in the env

A direct-entry block (ADR 0271) whose irep is yield-free carries `1` in its last env slot; the entry moves to
the second-to-last. `bc2cpp_block_yield_free(blk)` reads it (a cfunc proc over `bc2cpp_block_thunk`, flag
set). A separate thunk address would not survive the linker or Binaryen merging identical functions.

### Core iterators and arms

- The registered guard of a relaxable core iterator is
  `(M->c != M->root_c && !bc2cpp_block_yield_free(bc2cpp_entry_block(M)))`, followed by the existing
  `each_is_builtin` test for `Enumerable`. The other guards are unchanged. `bc2cpp_entry_block` reads the
  block of the cfunc frame (`ci->stack[mrb_ci_bidx(ci)]`), before the entry's own argument parsing.
- A BLOCK_CORE_DIRECT arm whose literal block is yield-free and whose body is relaxable drops `M->c ==
  M->root_c`; the dynamic else is untouched.
- An interpreted user block, a compiled block with `break`/`return` (no direct entry) and every block that may
  yield keep the bytecode path.

Why it is sound: a frame crosses only if a yield happens above it. Above a relaxable compiled body run by a
yield-free block there is the block, its callees, and the body's own calls: none of them yields (`own` false
for the block, `nb` false for the body, both over the same by-name edges). The block is identified at run
time by its env, so an interpreted or unproven block never takes the relaxed path.

### Methods a Fiber can cross

`YieldReach#fiber_unsafe` adds, to the old self-send set, every method reachable from a `Fiber.new` body by any
edge above that may yield (`own`), and every method with a block compiled into it whose block is reachable and
may yield, except the guarded core iterators. A reachable generator block is such a block (`gen` of the
fixture). A `Fiber.new` whose block is not literal, or a Fiber class that escapes, makes everything a root.
The root scheme of ADR 0273 is unchanged: the roots and yielding helpers are found as before.

## Consequences

- Wio closed world (`scripts/bc2cpp_coverage_report.rb` inputs), from the build's own table
  (`== yield-free proof (YIELD_REACH) ==` on stderr): of 2345 compiled methods 2275 are yield-free and 70
  may yield (the iterators that run their block; the bodies of all 2345 are `nb`-free); of 370 compiled
  blocks with a direct entry 350 are yield-free; all 129 guarded core methods stay compiled under a Fiber
  when the block is yield-free; of 332 BLOCK_CORE_DIRECT sites 269 have a yield-free block, and 780 of the
  961 arms lose the root-context test. Three methods are refused by the new walk (`Game::Actors#each`,
  `Game::Party#each`, `LCF::Array2D#each`: `Enumerator#next` can drive an `each` with a yielding block), so
  3045 entry points are compiled instead of 3048.
- Optcarrot (no closed world): the refusal walk adds no method there, the compiled count is unchanged (378).
- A yield-free block is also an easy place for the next optimization (an iterator taking a callback rather than
  a proc needs exactly this fact).
- Residual risks, stated because the proof is by name over a closed world: native code that builds a method name
  with `mrb_intern` from a computed string and calls it is not attributed (the `send` family is); natives keep
  a block only through the `new`, `define_method`, `proc`, `lambda` and `at_exit` names; the models of
  Enumerator above; a Fiber created by host code rather than by a `Fiber.new` in Ruby (no closed-world build has
  a script host); a Proc index read on a receiver the analysis cannot see the origin of counts as a Proc call, so
  worlds that store yielding blocks lose the proof for every such read (the wio world stores none).
- Name resolution ignores classes: a definition anywhere with a yielding name makes every call of that name
  may-yield (`Yielder#<<` is why the yielder is isolated). New engine code that defines a method named like a
  yielding one loses the proof for its callers, visibly, in the build table.
- Verification: `scripts/bc2cpp_yield_reach_check.rb` (analysis unit checks, fast) and
  `scripts/bc2cpp_yield_free_check.rb` (generated code, and a fixture compiled with the compiled core against
  the interpreter, default and incremental-GC-stress runs) are wired into `.github/workflows/build.yml`.
  The unit and generated-code checks pin the explicit-receiver case (`Helper#relay` called from a `Fiber.new`
  body in another class is refused).
