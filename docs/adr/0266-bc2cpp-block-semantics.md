# 266. bc2cpp compiled code honors mruby's block semantics

Date: 2026-09-30

## Status

Accepted

## Context

A block in compiled code is a cfunc-backed `RProc` (BLOCK_FALLBACK, see the
`codegen_block_fallback.rb` header): its body is a C++ function, `break` and
`return` are C++ exceptions, and captured locals are pointers into the defining
C++ frame. ADR 0265 listed four divergences from the interpreter that it left
alone. Writing a compiled-versus-interpreter differential for the whole block
surface (`scripts/bc2cpp_block_semantics_check.rb`, 162 scenarios on the
core-only VM, 28 more on a full-core VM) found more. Before this change 54 of
the 162 core scenarios and 4 of the 28 full-core ones differed, and 34 of them
killed the process (a segfault, or `std::terminate` from an uncaught
`bc2cpp_block_break`/`bc2cpp_method_return`):

1. `pr.call(x)` on a BLOCK_FALLBACK Proc from compiled code segfaulted. `Proc#call`
   is a bytecode method whose `OP_CALL` pops back to the calling frame and reads
   `ci->proc->body.irep`; a compiled method's frame has no proc.
2. `block_given?` in any compiled method was false: the dispatched cfunc sees a
   frame with no proc.
3. A block yielded more or fewer arguments than it has parameters raised
   ArgumentError (`mrb_get_args "o"`), where a proc pads and truncates; a
   `Kernel#lambda`-converted block was never strict; `->() {}` accepted
   arguments.
4. Entry wrappers said `expected 1+` / `expected 1..2` where `OP_ENTER` says
   `expected 1`.
5. A callee that reads its block as a value (`blk.call`, `&blk` passed on) was
   unsafe with a literal block: (1) and (2).
6. A `break` or `return` of a block unwound to the *innermost* catch, not to its
   own call site or method. `pass_through { break :x }` where `pass_through`
   hands its block to an inner `each { b.call }` broke out of the inner `each`
   only, and `rec(2) { return :x }` returned from the innermost recursive frame.
7. A `break`, `return` or `lambda { break }` of a proc that outlived its frame
   (`Proc.new { break }.call`, a stored block called later, `lambda { return }`)
   threw with nothing to catch it, instead of `LocalJumpError` (or, for a
   lambda, a plain return).
8. The `new` entry of `BLOCK_FALLBACK_UPVAR_SAFE_METHODS` assumes `Array.new`.
   `Proc.new { n += 1 }` and `Hash.new { |h, k| hits += 1 }` keep their block
   after `new` returns, which held a pointer into a dead C++ frame.
9. The `BLKPUSH` error said `bc2cpp: unexpected yield` (VM: `unexpected yield`).

## Decision

**Calling a cfunc Proc.** `bc2cpp_send` and the other by-name dynamic calls go
through `bc2cpp_funcall_argv`, which yields to a cfunc Proc of exact class
`Proc` directly (`mrb_yield_argv`, what `OP_BLKCALL` does) when the name is
`call`, `yield`, `[]` or `===` and it resolves to Proc's own bytecode method
(without mruby-proc-ext `===` is Object's, and a subclass or singleton override
never matches). A literal block on such a call (`pr.call(x) { }`) gets the same
guard in its glue. Doing it in the shared dispatch helper rather than per
opcode covers the `GETIDX` fallback (`pr[3]`) and `case`/`when`.

**`block_given?`.** A bare `block_given?` self call compiles to
`!mrb_nil_p(bc2cpp_blk)` when no Ruby definition of the name exists. The frame
must have its block extracted: `yields_block_param?` now also holds when the
irep, at any block depth, reads `block_given?`, and a method with a declared
`&blk` uses that parameter for `BLKPUSH` too (`frame_block_available?`). A
BLOCK_FALLBACK body forwards the block when `block_blk_needs` counts a
`block_given?` like a `BLKPUSH` from its depth; it only tests for nil, so unlike
a `yield` it needs no synchronous callee. Where the block is not available (a
method with optional arguments and no `&blk`, a nested block region, a lambda)
the site keeps `#error` and the method stays interpreted, never answering
false. `block_given?` is no longer a frame-reading name for
`block_transparent_callee?`, so such a callee is a direct call that passes the
caller's literal block.

**Proc argument semantics.** The block's entry function follows `OP_ENTER` of a
non-strict proc: missing arguments are nil, extra ones dropped, one Array
argument is spread over several parameters. If the RProc is strict at run time
(`bc2cpp_proc_strict_p`: `Kernel#lambda` flags a copy) it raises `wrong number
of arguments (given N, expected M)` like a lambda, and does not spread. `->`
bodies check a zero-parameter call too.

**Entry wrapper arity.** `bc2cpp_check_argc` raises `OP_ENTER`'s message
(`expected <mandatory>`) before `mrb_get_args` for optional and rest methods.
A call carrying keywords is left to `mrb_get_args`, which folds them into the
positional count first.

**Frame tokens for `break` and `return`.** A `break` unwinds to the call site
that built the proc and a `return` to the method it was written in, and only
while that frame is on the C++ stack:

- Frames that can be a target are chained (`Bc2cppFrame`): a call site whose
  block body contains a `BREAK` (`bc2cpp_break_frames`), a method with a block
  containing a `RETURN_BLK` at any depth (`bc2cpp_return_frames`). Each takes a
  30-bit serial as its token; a stale token matches a live frame only after
  2^30 frames.
- The tokens travel in the proc's env after the upvars and the block:
  `[self, upvars..., blk?, return token?, break token?]`. A nested block copies
  its enclosing block's return token, a method-level site takes its own frame's.
  `BREAK` and `RETURN_BLK` read the token from the env (`mrb_proc_cfunc_env_get`;
  `M->c->ci->proc` is the running block) and call `bc2cpp_break` /
  `bc2cpp_return_from_block`, which raise `LocalJumpError` (`break from
  proc-closure`, `unexpected return`) when the frame is gone and otherwise throw
  the token with the value.
- Catches compare tokens and rethrow a foreign one. A call site with no `BREAK`
  in its block has no catch at all, and `&expr` sites have none: a break in a
  block handed to them unwinds to the site that built it, further out. On the
  shipped build `catch (bc2cpp_block_break&)` drops from 388 to 12.
- A block that is strict at run time (`lambda { break }`) only leaves itself:
  it throws `bc2cpp_proc_exit`, caught by its own entry function, which is
  emitted only for a block containing a `BREAK` or `RETURN_BLK`.

**`Proc.new`/`Hash.new` capturing locals.** The `new` allowlist entry admits a
block that captures locals only when the receiver is a `GETCONST Array`
(`array_const_receiver?`). Any other `new` with such a block leaves `#error`, so
the method stays interpreted.

**Messages.** `BLKPUSH` and `BLKCALL` raise the VM's own messages.

## Consequences

- `scripts/bc2cpp_block_semantics_check.rb` (in the `bc2cpp-checks` fast shard)
  compiles a closed-world fixture of 164 scenarios and runs each in its own
  process, interpreted and compiled, comparing the value or the exception class
  and message. With `BC2CPP_MRUBY_FULL` it adds 29 scenarios that need the
  full-core gems: `&:sym`, `&method`, `proc`, `lambda?`, `Array#each/map/inject`,
  `Hash#each`, `each_with_index`, destructuring, `times`, `sort` blocks. Every
  scenario agrees except the five known ones below, which the check requires to
  keep differing.
- Wio shipped build (`scripts/bc2cpp_coverage_report.rb`): coverage, entry point
  and dispatch counts are unchanged. 12 call sites own a break frame and 20
  methods a return frame; 113 entry wrappers use `bc2cpp_check_argc`. The whole
  output still type-checks with `g++ -fsyntax-only`.
- ADR 0265's `mrb_get_args` normalization in `bc2cpp_arg_shapes_check.rb` is
  gone (the messages now agree), and the check that a `block_given?` callee
  keeps its dispatch now asserts the direct call.
- Residual, not fixed:
  - `Proc#arity`, `#parameters` and everything built on them (`#curry`) answer
    for a BLOCK_FALLBACK proc as mruby does for any cfunc proc: `-1`
    (`mrb_proc_arity`, "TODO cfunc aspec not implemented yet"). It needs a
    mruby patch, not glue. Nothing in the sources reads a block's arity.
  - The upvar allowlist is still by callee name. A project method named `each`,
    `section`, ... that stores its block would see a dangling pointer; the
    entries were read when they were added, and the fixture's callees of these
    names yield synchronously.
  - A `lambda { ... }` (as opposed to `->`) whose body captures locals is
    interpreted (`lambda` is not on the allowlist), and so is a method whose
    `ensure` clause yields.
  - `bc2cpp_frame_serial` and the frame chains are per translation unit and
    ignore Fibers: a compiled frame between a fiber's entry and its yield was
    already unsupported (FIBER_REACHABILITY_UNSAFE_SUPPORT).
