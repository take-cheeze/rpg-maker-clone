# 0271. Compiled blocks have a direct entry, and yields from compiled code skip the VM frame

Date: 2026-09-30

## Status

Accepted

## Context

ADR 0270 makes the call into a core iterator direct, but the block is still an RProc that the
iterator yields to with `mrb_yield_argv`. Measured on a closed-world fixture linked into a
full-core mruby (5-element collections, 200,000 calls, unoptimised libmruby), the arms alone
change nothing measurable: `each`, `map`, `select` take the same time with and without them.
The cost is per yield, not per call: `mrb_yield_argv` pushes a callinfo, extends the stack,
copies the arguments, calls the block's cfunc wrapper, which parses the arguments again with
`mrb_get_args`, and pops the frame.

The wrapper is a cfunc because the block must be an RProc that the VM can yield to, and it
reads its captured environment through `mrb_proc_cfunc_env_get`, which reads the *current*
callinfo's proc. The two things a block body reads from that frame are its `break` and `return`
tokens, which live in the env of the calling cfunc.

## Decision

**BLOCK_DIRECT_ENTRY.** A block whose body neither breaks nor returns (no `needs_brk`,
`needs_ret`, no `BREAK`/`RETURN_BLK`; `BC2CPP_BLOCK_DIRECT_ENTRY=0` turns the mechanism off)
gets a *direct entry* instead of the cfunc wrapper:

    static mrb_value F_direct(mrb_state* M, struct REnv* env, bool strict, mrb_int argc, const mrb_value* argv)

It reads the captured self, upvar pointers and forwarded block from `env->stack`, binds the
arguments as OP_ENTER binds them for a non-strict proc (missing ones nil, extra ones dropped,
one Array spread over several parameters; a rest-only block takes them all as an Array), raises
`ArgumentError` on a wrong count when `strict` (a `Kernel#lambda` copy), and calls the block's
`_impl`.

The block's RProc is a cfunc proc over one shared function, `bc2cpp_block_thunk`, with the entry
as the **last env slot** (a fixnum, so it allocates nothing). The env layout before it is
unchanged, and blocks with `break`/`return` keep their wrapper and layout. The thunk is `inline`
with external linkage, so it has one address in every translation unit of the link, which is what
identifies a proc as ours. Reached through the VM (an interpreted iterator, a Fiber, `Proc#call`)
it reads its arguments with `mrb_get_args` and calls the entry, as the wrapper did.

**`bc2cpp_yield_argv`** replaces `mrb_yield_argv` in the code bc2cpp emits for a yield: BLKCALL,
the core `block.call(x)` form, the keyword-splat call and `Proc#call` on a cfunc proc
(`bc2cpp_funcall_argv`). For a non-strict proc built over the thunk it calls the entry
directly, restoring the GC arena and protecting the result exactly as `mrb_yield_with_class`
does; every other value takes `mrb_yield_argv`.

## Consequences

- Measured as above, `map` and `select` over a small Array run about 27 percent faster than
  with the arms alone (the block runs through the entry, not a frame), `each` over 5 elements,
  `Hash#each` and `Range#each` show no difference at that size: a fixed cost per call remains
  (building the proc, its env and one cptr per captured variable).
- The entry is skipped for a strict proc, so `lambda(&blk)` copies and their ArgumentError
  keep going through the VM, and for a block that breaks or returns.
- A block called through the entry has no callinfo of its own: a backtrace omits it and deep
  recursion through such blocks is limited by the C stack, not by mruby's call depth. Both are
  what a direct call to a compiled method already does.
- Code size: a block with an entry has the entry instead of the wrapper (same shape), plus one
  shared inline thunk. 403 block bodies of the wio closed-world build get an entry, and 52 keep the wrapper (they break or return, or are not plain blocks).
- `scripts/bc2cpp_block_core_direct_check.rb` now also covers the entry's argument binding:
  zero-parameter, rest and multi-parameter blocks yielded to by interpreted iterators with too
  many, too few and spread arguments, and a strict copy.
- Not done: the fixed cost per call. A callee taking a callback instead of a proc would remove
  it, but needs the callee to be proven not to let its block escape; that analysis does not
  exist yet.
