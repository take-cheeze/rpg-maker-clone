# Resumable compiled core methods instead of the CORE_BLOCK_GUARD fallback

Question: could the core methods behind `CORE_BLOCK_GUARD` (the "guarded" ones) stop needing their saved
bytecode if they were compiled as resumable code, the way a Fiber root method already is?

Short answer: not as a per-method change, and probably not needed in the closed build. The bytecode is only
taken when a Fiber is active. In the closed world the only Fiber is the generator of `Enumerator#next`, and no
closed-world code starts it. Removing the Fiber half of the guard is the lever, and it is a build-level proof,
not a resumable compiler. No prototype was built; the reasons are in "Why no prototype".

Measured on `origin/master` (78ecd7b). Reproduce with the committed script:

    MRBC=path/to/mrbc ruby scripts/bc2cpp/guarded_fiber_reach_report.rb --list

## What the guard does

- `CoreMethods.guarded_labels` (`tools/bc2cpp/core_methods.rb:140`) picks the core methods that touch a block, plus
  the audited Enumerator wrappers (`enumerator_wrapper?`, `core_methods.rb:35`).
- `CodeGen#core_block_guard` (`tools/bc2cpp/codegen_method.rb:1003`) puts a prologue on each entry:
  `if (M->c != M->root_c) return bc2cpp_core_interpreted(...)`. For a body that cannot suspend by itself
  (`core_body_relaxable?`, `codegen_yield_free.rb:42`) the test is narrowed to "a Fiber is active and the block may
  yield". An `Enumerable` method also falls back when its `each` is not the builtin one
  (`bc2cpp_core_each_is_builtin`), which has nothing to do with Fibers.
- At registration the VM proc of each guarded method is saved in the hidden table `__bc2cpp_core_interpreted__`
  (`codegen_emit.rb:490-530`), and the fallback runs that proc with `mrb_exec_irep`. The VM frame is what a Fiber
  can suspend. A compiled frame is not: mruby refuses a Fiber switch across a C frame
  (`3rd/mruby/mrbgems/mruby-fiber/src/fiber.c:160-166`, "can't cross C function boundary"), and a compiled
  iterator that calls its block is such a frame.

## Measured numbers

Closed world: `bc2cpp_closed_world_probe_env` with `closed_world_mrblib_srcs` (60 mrblib sources), the closed gem set,
type-check analysis only (`BC2CPP_TYPE_CHECK_ONLY`, no C++ written). Host `mrbc` from
`build-closed-bc2cpp/host/mrbc/bin/mrbc`. The worktree's `3rd/` submodules were not initialized; they were linked read-only
to the main checkout's copies, which are at the same mruby pin (`93b8ad58`).

| Measure | Count |
| --- | ---: |
| core methods under CORE_BLOCK_GUARD | 139 |
| Fiber bodies (`Fiber.new` blocks) in the closed world | 1 |
| guarded methods reached from a Fiber body (`fiber_crossable`) | 105 |
| guarded methods whose body cannot suspend (block decides at run time) | 132 |
| reached and block decides at run time | 102 |
| guarded methods no Fiber body reaches | 34 |
| `Enumerable#` guards (their guard also tests that `each` is builtin): reached / not reached | 44 (34 / 10) |
| other guards: reached / not reached | 95 (71 / 24) |
| Fiber roots (RESUMABLE_ROOTS) in the closed world | 0 |
| non-guarded methods a Fiber body can suspend through (`fiber_unsafe`) | 3 |
| `Fiber.new` call sites | 1 (`enumerator.rb`, the generator of `Enumerator#next`) |
| `Fiber.yield` / `Fiber.current` sites | 3 |
| sends named `next`, `peek`, `next_values`, `peek_values`, `zip`, `feed` | 4, all inside `mruby-enumerator/mrblib/enumerator.rb` |
| literal symbols with those names | 0 |
| dynamic sends (`send`, `__send__`, `public_send`) | 2: `enumerator.rb:322` (`@obj.__send__ @meth`), `enum.rb:203` (`inject(sym)`) |

Checked by hand as well: every `to_enum` / `enum_for` in the closed Ruby sources names its method with a literal
symbol (grep over `mruby-rpg2k`, `mruby-lcf`, `mruby-rgss` and the closed mruby mrblib), and none of those names is an
external-iteration name. The repo's C/C++ sources contain none of those names and no `Fiber` use.

Discrepancy: the scratch worklist (`/home/user/scratchpad_cb/hidden_u.txt`) has 142 guarded keys. This tree has 139.
The three missing are `Game::Actors#each`, `Game::Party#each` and `LCF::Array2D#each`, defined in
`mruby-rpg2k/mrblib/game.rb` and `mruby-lcf/mrblib/lcf.rb`, which this tree does not classify as core. The worklist
looks like it came from an earlier tree.

## Which guarded methods a Fiber can really reach

Only through `Enumerator#next`. Its generator (`enumerator.rb:406-420`) is a `Fiber.new` block that calls `each` on
the enumerator; `Enumerator#each` dispatches by name to the wrapped method (`enumerator.rb:322`), which yields to the
generator block, which calls `Fiber.yield` (`enumerator.rb:409`). So the 105 are the iterators an Enumerator can
wrap: `Array`, `Hash`, `String`, `Range`, `Integer`, `Float`, `Struct`, `IO`, `StringIO` iteration methods and the
`Enumerable` methods built on `each`. The reach analysis is by name (`YieldReach#compute_crossable`,
`tools/bc2cpp/yield_reach.rb:1323`), so 105 over-approximates what the generator can reach at run time.

## Is a Fiber ever started in the closed build?

The census says no, under the closed-world assumption:

- Only one `Fiber.new` exists, and it is the `Enumerator#next` generator.
- The only external-iteration names in the closed world are inside `enumerator.rb` (`arg.next` inside `zip` at line 707,
  plus the Enumerator's own `next`, `next_values`, `peek_values`). No call site outside that file names them, and
  `zip` has no call site.
- Dynamic sends can only reach `next` if a name is computed at run time. The two dynamic sends are Enumerator's
  dispatch of `@meth`, whose names come from `to_enum` calls (literal in every closed call site, none of them an
  external-iteration name), and `inject(sym)`, where no closed-world symbol literal `:next` exists (census: 0).
- The closed build does not contain user Ruby. `bc2cpp` compiles closed worlds only (`closed_world_env.rb` header);
  the open-world gems (`mruby-rpgxp`, `mruby-rpgvx`, `mruby-wolf`, `mruby-mvjs`, `mruby-eval`, ...) are not in it
  (`compiled_gems.rb:336`).

If all of that holds, no Fiber is ever active in the closed build, and the Fiber half of every guard never fires.

## Why a resumable compiled form is not a small extension

Representative method: `Array#each`, `3rd/mruby/mrblib/array.rb:15-23`:

    def each(&block)
      return to_enum(:each) unless block
      idx = 0
      while idx < length
        yield self[idx]
        idx += 1
      end
      self
    end

The current resumable machinery (`tools/bc2cpp/codegen_resumable.rb`) does not handle it:

1. Shape. A core method is refused (`resumable_shape_problem`, line 149, "is a core method"), and so is one that takes
   arguments or a block (line 150). `&block` sets a non-zero ENTER field.
2. Where the suspension sits. The step function suspends only at a `Fiber.yield` in its own body, or in helpers
   inlined into it (`resumable_yield_site`, `resumable_helper_call`, `RESUMABLE_HELPER_DEPTH = 4`). Here the
   `Fiber.yield` is in the generator block, and `Array#each` is an intermediate frame.
3. Block bodies. They are separate C++ functions and are not flat (`with_resumable_flat`, `ResumableFlatGuards`,
   lines 42-61), so a yield in a block cannot be resumed.
4. Dispatch. `Enumerator#each` reaches the iterator by name (`__send__ @meth`), so the chain
   Enumerator#each -> iterator -> generator block -> `Fiber.yield` is not known at compile time. Every iterator the
   name could reach would need the resumable form.
5. Frames. A resumable `Array#each` returns to a driver at every block call, keeping `self`, the block and `idx` in a
   heap frame, and the block itself must then be resumable. That is a per-Fiber frame stack with a driver, not a step
   function per method. Its size is weeks of work, not hours.

Sketch of the resumable form (pseudocode, not generated, not run):

    // F: heap frame { self, blk, idx, state }
    mrb_value array_each_step(mrb_state* M, Frame* F) {
      if (F->state == 0) F->idx = 0; else F->idx++;      // resumed after the block returned
      if (F->idx >= RARRAY_LEN(F->self)) return F->self;
      F->state = 1;
      return call_block_as_step(M, F->blk, F->self[F->idx]);   // returns to the driver if the block suspends
    }

The driver would then re-enter the whole chain on each resume. That is the work the design would have to do.

## What could move

| Route | Keys | Status |
| --- | ---: | --- |
| Per-method resumable `Array#each`-style forms | 0 near term | Needs the frame chain above; the 102 reached-and-block-yielding keys all depend on it. Not a few hours. |
| Drop the Fiber half of the guard in the closed build (no Fiber start) | 95 other guards | Their guard and saved bytecode never fire. Holds only if the census holds in a real build, and needs a runtime check. |
| `Enumerable#` guards | 44 keep the fallback | Their `each`-is-builtin test is not a Fiber test. Needs a separate static proof for the receivers. |
| Keep `Enumerator#next` in the closed build | 102 keep bytecode per `next` | This is the only case where resumable code would matter. |

## Why no prototype

- A per-method resumable form (the representative case here) needs the frame chain above. That is weeks of
  compiler work, not the few hours a prototype would have to fit in.
- The cheap lever, dropping the Fiber half of the guard, changes what the production closed build emits. Validating
  it needs the closed build and its test suite. This worktree has no build directory and its `3rd/` submodules
  were not initialized; the main checkout is busy with another build.
- A small fixture would not show it. `FixtureCheck` (`scripts/bc2cpp/check_support.rb`) compiles only the fixture's
  own sources, so it contains none of these guards. The probe environment (`closed_world_env.rb`) does include the
  core, but a run in it is a whole closed-world analysis like the one this report does.

## Recommendation

1. Do not build a resumable `Array#each`. It needs a frame stack, and it only pays off if the closed build must support
   `Enumerator#next`.
2. Decide whether the closed build may ever start a Fiber. If not, turn the census into a check that fails when a
   `Fiber.new` or an external-iteration send appears in a closed world (the report script is the start of it), and
   then try removing the Fiber half of the guard for the 95 non-Enumerable keys behind a flag. Validate with the closed
   build's tests and measure the saved-bytecode table and binary size before and after.
3. If `Enumerator#next` must work in the closed build, the choices are a frame-chain resumable design (large) or
   index-based external iterators for the core receivers (a semantic change for other receivers). Pick one before
   spending more on guard code.

## Not verified

- No build of the closed world and no run of any generated or fallback code. No fixture ran under a Fiber.
- The census is by name over bytecode and literal symbols. A method name computed at run time, from data, is not
  covered; the argument that none exists is a grep, not a proof.
- The closed-world assumption (no user Ruby reaches the closed build) is not checked against the game data pipeline.
- Bytecode bytes and binary size were not measured.
- The analysis constructs several CodeGen objects; the report keeps the last one that has a sound closed world
  (`yield_reach.sound?`). Some constructions are unsound and report different values.
- The 142 versus 139 discrepancy is explained by a different tree, not by measurement.
