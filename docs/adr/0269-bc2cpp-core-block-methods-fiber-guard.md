# 0269. Block-taking core methods compile behind a Fiber guard

Date: 2026-09-30

## Status

Accepted

## Context

ADR 0264 compiled mruby's own Ruby but kept every method that takes, builds or
yields to a block as bytecode (132 in the wio gem set), because "a `Fiber.yield`
inside a block cannot cross a compiled frame". What breaks, exactly:

- A Fiber is a swapped `mrb->c` (`mrb_context`). A compiled method sits on the
  native stack and reaches the block through `mrb_yield`/`mrb_funcall_with_block`,
  which pushes a callinfo with `cci > 0` and re-enters `mrb_vm_exec`.
- `fiber_switch` calls `fiber_check_cfunc` on the context it switches to and
  raises `FiberError: can't cross C function boundary` for any `cci > 0` frame in
  it. A yield through such a frame also returns from the nested `mrb_vm_exec`
  instead of switching ("resuming dead fiber", tools/optcarrot_probe/README.md).
- The RGSS script host runs every game script inside a Fiber and yields from the
  blocks of `loop`, `each`, `times` (`Graphics.update`); `Enumerator#next` runs
  the iteration in a Fiber. So the blocks that yield are exactly those handed to
  core iterators, and they come from interpreted user code: a closed-world
  analysis of "blocks that never yield" (scheme 1) has nothing to analyse.

A frame can only be crossed by a yield if it lies between a Fiber's entry and the
yield. In the root context there is no such Fiber: a `Fiber.yield` there is a
`FiberError` with or without the compiled frame, a Fiber started from inside a
block sits above the frame (its yields return to its resumer, and
`Fiber#resume` from a C-called frame already takes the nested-exec path), and
`Fiber#resume` never reaches a suspended context that holds the frame.

## Decision

Scheme 2 (a run-time guard), chosen over scheme 1 because it needs no fact about
user blocks and is a single comparison.

**CORE_BLOCK_GUARD.** Every compiled core method that touches a block
(`CoreDefs.touches_block?`) registers an entry that begins with

    if (M->c != M->root_c [|| !each_is_builtin]) return bc2cpp_core_interpreted(M, self, index);

`bc2cpp_core_interpreted` calls `mrb_exec_irep` with the method's saved bytecode
while the VM is still in the cfunc's own frame, the mechanism `instance_exec`
uses: the frame is replaced by the bytecode frame and no C frame remains, so the
interpreter then yields, resumes and unwinds as if the method was never compiled.
The bytecode (`RProc`) is saved before registration in a hidden ivar of `Object`
(`__bc2cpp_core_interpreted__`, no `@`, so no reflection lists it), one array slot
per method. A method with no bytecode definition at registration (not an irep
proc, or an earlier registration) is left alone and logged to stderr.

Why it is sound:

1. A compiled block-touching frame exists only while `M->c == M->root_c`. Anything
   that runs Ruby in another context (`Fiber`, `Enumerator#next`, mruby-task) takes
   the bytecode.
2. By the argument in Context, no yield or resume can then cross the frame.
3. Direct `_impl` calls skip the entry, so a guarded body is never a direct-call
   target (`compiles_clean?` answers false) and never a registry definition
   (hidden like a name shared with a native). The second point keeps every
   name-keyed proof of ADR 0264 finding 1 intact: the generated code of
   mruby-rpg2k/lcf/rgss is byte-identical to before.
4. A block captured by pointer (BLOCK_FALLBACK upvars) must not outlive the
   frame. `Enumerable` methods call a user `each`, so their guard also requires
   that `each` resolves in Array, Hash or Range (`bc2cpp_core_each_is_builtin`);
   other owners call methods of their own builtin receiver.
5. A closure returned from a method would run later, outside the frame: methods
   that build a lambda stay bytecode (`CoreDefs.builds_lambda?`; `Enumerable#inject`,
   `Symbol#to_proc`, `Hash#to_proc`), as do Fiber-naming ones and mruby-enumerator.

**Compiler support needed** (all confined to core bodies or to shapes that were
`#error` before, so no engine output changes):

- `yield` in a method that declares `&blk` (BLKPUSH reads the parameter's register),
  also inside a rescue range (`Kernel#loop`, the try body receives the block).
- Optional arguments together with `&blk` (`any?(pattern = NONE, &block)`).
- Rest-only blocks `{ |*args| }`, the shape of every `Enumerable` iterator.
- CORE_PROC_CALL: `block.call(x)` (also `call(*args)`) yields to a plain Proc.
  `mrb_funcall(:call)` of a compiled block (cfunc proc) from a C frame crashes in
  OP_CALL (`ci->proc->body.irep` of the caller); the yield is what BLKCALL does.
- CORE_ALIASES: `alias map collect` and the like register the compiled body under
  the alias too (`Array#map`, `#select`, `#find`, `Hash#each_pair`, ...); the alias
  copied the method it replaced, so the fallback is the same bytecode.

Fixes found on the way: `Kernel#\`` from core's mrblib was compiled over the
later mruby-io definition (core raises NotImplementedError); it is refused.

## Consequences

- Wio gem set (`core_gems: :canonical`): 215 core-source bytecode methods, 173
  compiled (was 56), 13 unsupported shapes skipped (`Range#min/max/to_a` use
  `super`; `Array#permutation/combination`, `Hash#transform_values(!)`,
  `Enumerable#cycle/each_entry`, `File.foreach`, `IO.open/popen`), 29 kept as
  bytecode by decision (25 mruby-enumerator, lambdas, `Kernel#\``). 118 of the 173
  are guarded. Hot-only builds (wio, psp, maix) still compile none.
- Engine output (mruby-rpg2k/lcf/rgss-compiled, all gems, canonical world) is
  byte-identical to the base commit, so the 449 generic dispatch sites and the
  unresolved `min`, `sort`, `uniq`, `first`, `compact`, `inspect`, `read`, `open`
  names are unchanged: they need per-class native knowledge or a root-context check
  at the call site, which this does not add. The gain is the compiled bodies:
  a microbenchmark (unoptimised libmruby) shows `each`/`map`/`select`/`inject`/
  `each_slice`/`Hash#each` 10-35 percent faster at the root context and no change
  inside a Fiber (the guard costs one comparison).
- Size (x86-64 text, -O3, full-core desktop world): the core translation unit grows
  from 39 KB to about 370 KB; 0 bytes for wio/psp/maix.
- Observable differences, as for every compiled method: `Method#arity`,
  `#parameters` and `#source_location` read `-1`, `[]`, `nil`; an `ArgumentError`
  for a wrong count is raised by the registered aspec (`expected 1+`), and a keyword
  hash is counted as an argument (`given 2` where OP_ENTER said `given 1`).
- Residual risk: a monkey-patched `Array#each`/`Hash#each` that stores its block
  passes the Enumerable check; nothing runs a 32-bit `mrb_int` build (no bigint
  literals compile); the XP/VX/Wolf/MV makers still keep the bytecode core
  (registration is tied to mruby-rpg2k) because no script host but RPG2000/2003
  has run with the guard, although the guard is what would make it safe.
- Verification: `scripts/bc2cpp_core_mrbtest.rb` (mruby's own `rake test`,
  1846 assertions, identical interpreted and compiled) now also runs
  `scripts/bc2cpp_core_blocks_probe.rb` (473 lines: Fibers, nested Fibers,
  `Enumerator#next` over compiled `each`, `loop`, break/return/throw/raise
  through compiled frames, GC pressure) under both builds and requires identical
  output; `scripts/bc2cpp_core_mrblib_check.rb` checks the guard statically (every
  block-touching entry guarded, saved under its own index, never called directly,
  hidden, every `call` dispatch guarded) and runs 5,929 differential cases.

## Update (ADR 0283)

A guarded body whose own calls provably cannot suspend a Fiber checks the run-time block instead of the
context alone: `(M->c != M->root_c && !bc2cpp_block_yield_free(bc2cpp_entry_block(M)))`. Every other
guard, an interpreted block and the `each_is_builtin` test are unchanged.
