# 0333. A Fiber-reachable body that cannot suspend, behind a guard

Date: 2026-10-04

## Status

Accepted

## Context

Three of the remaining whole-program `#error` markers were "is reachable from a
Fiber.new block": `LCF::Array2D#each`, `Game::Actors#each`,
`Game::Party#each`.

The refusal (FIBER_REACHABILITY_UNSAFE_SUPPORT, ADR 0283) is real: a `Fiber.yield`
inside a block cannot cross a compiled frame -- vm.c `fiber_switch` calls
`fiber_check_cfunc` and raises `FiberError: can't cross C function boundary` for
any `cci > 0` frame. But it was **blanket**: any method reachable from a
`Fiber.new` body was kept interpreted, and the RGSS script host runs every game
script in a Fiber (`mruby-wolf/mrblib/interpreter.rb`'s
`@fiber = Fiber.new { execute }`), so that is a lot of methods.

Instrumenting the three showed the refusal is wider than the hazard. All three
only FORWARD the caller's block:

```ruby
def each(&blk); all.each(&blk); end            # Game::Actors
def each(&blk); @actors.each(&blk); end          # Game::Party
def each; @data.size.times { |i| ...; yield i, v unless v.nil? }; end  # LCF::Array2D
```

`body_yield_free?` (YieldReach, ADR 0283) answers **true** for all three: their
own bodies never suspend. `@own` — the stronger predicate that also counts a
nested block — is true only because the method passes a block on. The yield, if
any, happens in the block the CALLER supplied, which is not running inside this
frame.

## Decision

Compile such a method anyway, behind the run-time hand-off CORE_BLOCK_GUARD
already uses for core methods (ADR 0269). The entry becomes:

```c
if (mrb_unlikely(M->c != M->root_c)) return bc2cpp_core_interpreted(M, self, N);
```

and its bytecode is saved into the same hidden-`Object`-ivar table the core
guard uses, at registration, before the compiled entry replaces it. Outside a
Fiber the compiled frame runs and the block is reached by the ordinary dynamic
dispatch the body already performs; under one the bytecode runs instead, so no
compiled frame is left between the fiber entry and a yield. That is exactly the
condition ADR 0269 already applies to a core body that is merely
`body_yield_free?` — `core_block_guard` narrows its condition to
`M->c != M->root_c && !bc2cpp_block_yield_free(...)` for such a body.

A method that calls `Fiber.yield` **itself** is never admitted: there the yield is
in its own frame, which no hand-off from its own entry can step around.

What this does NOT claim: that the caller's block is yield-free. It is not, and
it cannot be known — that is precisely what the guard makes irrelevant.

`BC2CPP_FIBER_BODY_GUARD=0` restores the blanket refusal.

## Consequences

The whole-program `#error` count goes 8 to 5. `LCF::Array2D#each`,
`Game::Actors#each` and `Game::Party#each` compile behind the guard instead of
staying interpreted.

`scripts/bc2cpp_fiber_body_guard_check.rb` pins the safety property rather than
the fixture's reachability, because a fixture cannot reproduce the engine's Fiber
root (mruby-wolf's `Fiber.new { execute }` plus the RGSS gem set) — that part is
measured by `bc2cpp_coverage_report.rb`. What the check does pin: a body that
suspends the Fiber itself is never given the guard, and a block that really does
`Fiber.yield` from inside a Fiber resumes correctly **through the compiled
entry** (`"1|2|3|[1, 2]"`, identical interpreted and in two compiled VMs, no
FiberError) — the case that would raise or crash if a compiled frame were left in
place.

A method that calls `Fiber.yield` **itself** is never admitted: there the yield is
in its own frame, which no hand-off from its own entry can step around.

Neither is a method that hands a literal block to `Enumerator.new` / `Lazy.new` /
`Generator.new`. mruby-enumerator runs a generator on a Fiber
(`CoreDefs.fiber_gem?`), so the frame that matters is that **block's**, and it
sits below a fiber entry by construction rather than by a caller. YieldReach
marks only `Fiber.new` blocks as fiber bodies (`scan_fiber_call`), so
`body_yield_free?` reads a generator builder as yield-free when its block is not.
That gap predates this ADR -- nothing compiled those methods before, so it had no
effect -- and admitting one would put a compiled frame under a Fiber for real.
`bc2cpp_yield_free_check` already asserted the builder is not compiled, and caught
exactly this on the first CI run of the branch.

What this does NOT claim: that the caller's block is yield-free. It is not, and
it cannot be known — that is precisely what the guard makes irrelevant.

`bc2cpp_block_arm_reach_check.rb` needed one assertion rewritten rather than
fixed. It asserted that a Ruby `Array#each` "leaves no proven Array direct call
alone" — true only while `Array#each` was itself kept interpreted by this very
refusal. Now that it compiles, a direct call appears where the receiver **is**
proven Array. The check now pins what must stay true: no `BLOCK_CORE_DIRECT` arm is
re-enabled for a Ruby body (that arm is for the *core* body), and with
`BC2CPP_FIBER_BODY_GUARD=0` the same site keeps its by-name tail. The guard widens
what COMPILES, not what is PROVEN.

Still 5: `EXCEPT` 2 (`IO.singleton#open`, whose ensure body is a `rescue`),
`SUPER` 2 (`File#initialize`, whose `super` reaches a native needing a call
frame), `IO.singleton#popen` 1 (non-mandatory arguments).

Not run here: the 32-bit `mrb_int` leg, firmware smokes, optcarrot
open-world comparison.
