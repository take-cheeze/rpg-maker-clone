# 0472. Checked RBS declarations for methods that return their block's value

Date: 2026-10-16

## Status

Accepted. Supersedes the result proof of [ADR 0344](0344-bc2cpp-profiler-block-results.md) (PROFILER_RESULTS);
the helper-frame repairs of ADR 0344 stay.

## Context

`RGSS::Profiler.section(name) { ... }` returns its block's value, and the engine wraps map loading and party
construction in it. PROFILER_RESULTS (`codegen_profiler_results.rb`) proved this for those two names only. It pinned
the SHA-256 of `mruby-rgss/src/profiler.cxx` and required exactly one native file to define `section`. In CI that
test compared NATIVE_SRCS's unexpanded paths with the closed world's expanded ones and failed. BLOCK_SELF and
RBS_CHECKED_PARAMS both called `profiler_result_body` to learn that a call was a "known plain yielder".

RBS can already state the fact: `def self.section: [T] (String) { () -> T } -> T`. The same shape describes
`Kernel#then`/`#yield_self`, and `{ ... } -> self` describes `Kernel#tap` and `Array#each`. Before this change the
signature loader accepted those declarations and ignored them. The IR's conditional callback bounds (ADR 0443)
reported them but gave no optimizer fact.

## Decision

BLOCK_RETURNS (`tools/bc2cpp/block_returns.rb`, `codegen_block_returns.rb`) reads two declaration shapes. Any other
declaration keeps its previous role.

* `:block_value` is `[T] (A, ...) { (B, ...) -> T } -> T`: the call returns the value its block returned.
* `:self` is `(A, ...) { (B, ...) -> X } -> self`: the call returns its receiver.

The block must be required. It takes required positionals only and declares no `[self: S]`, so it runs under the
caller's self. The method takes required positionals only. T has no bound and types no parameter. A declaration
that has a block and one of these return types but breaks a rule is reported as an info and gives no fact.

**Checking.** Each declaration is checked against what defines it. A failure is a TC1010 error, and
DECLARED_RETURN_CHECK aborts the build on it, as it does for return types (ADR 0455).

* Ruby definitions come from the program, mruby's own compiled Ruby, or an outside Ruby source. An outside source
  is compiled on its own for the check, and an unconditional `alias` counts as the aliased body. Each definition
  must be a plain yielder (BlockSelf). Every yield must pass the declared number of arguments. The check then
  follows every return path the method can take with a block given; a truth test of the block register takes only
  its truthy edge. Each such path must return a value a yield produced (`yield`, `block.call`), or self. A `return`
  or `break` in a nested block refuses. So do a rescue path and an optional parameter.
* Native definitions are declared in `sig/native`. Each C function registered under the name is scanned. The block
  may be read only by `mrb_get_args`, `mrb_nil_p` and `mrb_yield`/`mrb_yield_argv`, which keep the Proc's self.
  Every yield must pass the declared arguments. Every `return` must return a yield's value, either directly or
  through a `mrb_value v = mrb_yield...;` that is never written again. The one exception is
  `return mrb_nil_value()` directly under `if (mrb_nil_p(blk))`, which a call with a literal block never reaches.
  A function the scan cannot verify must be listed in `native_block_returns_reviewed.rb` with the SHA-256 of the
  reviewed file. Otherwise the declaration is an error. Today the list is empty: profiler.cxx's `prof_section`,
  `prof_frame` and `prof_stub_yield` pass the scan.

**Call sites.** A block send with a dominating literal block gets the declaration's fact when every method it can
run is a checked declaration of one shape. The block must not `break` or `return`.

* A native singleton declaration needs the receiver to be the constant itself. It also needs the closed-world
  conditions PROFILER_RESULTS used, made generic: one native source spells the name, every binding of the constant
  is that source's own definition, and the constant and its enclosing constants keep their identity. No Ruby
  definition may sit on the module, and no prepend or unknown mixin on the module or its singleton. Nothing may
  install, alias or opaquely redefine the name.
* Otherwise the check is by name. Every bytecode definition of the name, outside sources included, must be a checked
  declaration of the same shape. No native may register the name, nothing may install or alias it, and every
  method_missing must be mruby's native one.

The facts:

* `:block_value`: the call's class set is the join of the block's returns, computed by the block flow PROFILER_RESULTS
  used and joined into RETURN_CLASS_TABLE. Its dependency edges invalidate the enclosing flow when a callee fact
  changes. RBS_CHECKED_PARAMS traces the block's returns.
* `:self`: the call's class set is the receiver's, and RBS_CHECKED_PARAMS traces the receiver.
* Both shapes: the block's self is the caller's (BLOCK_SELF).

**Declarations.** `sig/native/rgss_block_returns.rbs` declares `RGSS::Profiler.section` and `.frame`.
`sig/native/core_block_returns.rbs` declares `Kernel#tap`, `#then` and `#yield_self` (mruby-object-ext, where a
build has it). `core_block_params.rbs` now declares `Array#each` as `-> self`. Two methods stay undeclared because
neither shape fits them:

* `Hash#fetch`/`Array#fetch` with a block return the stored value when the key is present (`V | T`).
* `Hash#each` passes one `[key, value]` Array, which the declared `(K, V)` block destructures.

None of the engine's own yielding helpers fits either. `cached_bitmap` returns a cached value, and `page_field`
returns its default after a rescue.

The profiler region inliner keeps its job (it emits profiler.cxx's begin/end primitives). It now asks the checked
declaration and the same lookup conditions, and it requires that the one native source is profiler.cxx itself.

The plain-yielder test (BlockSelf) now reads the fixed register windows of the binary operators, GETIDX/SETIDX and
the immediate forms. Before, it read every register up to the frame's last one, which refused mruby's own
`Array#each`. vm.c reads only those windows, including in the method-send fallbacks.

PROFILER_RESULTS, its SHA pin and its environment switches (`BC2CPP_PROFILER_RESULTS`,
`BC2CPP_PROFILER_NAME_SCOPED`) are removed.

## Consequences

`RGSS::Profiler.section/frame` results keep their classes under a general, checked rule, with no SHA pin and no
path spelling to compare. A new block-return method needs only a declaration: the build checks it against the body
or the C source. A false declaration fails the build at its file and line.

`scripts/bc2cpp/generic_block_return_check.rb` covers the shapes and the native scan, including mutants of
profiler.cxx and the reviewed-list rules. It also runs the Ruby body check, and a fixture closed world: native,
program, `tap`/`then`/`yield_self` and nested-block facts, refused sites, BLOCK_SELF through RBS_CHECKED_PARAMS,
and false Ruby and native declarations failing the build. It takes seconds and runs in the `bc2cpp-build` job next
to the shared generation check.

Not covered:

* Receiver-class dispatch for Ruby declarations. A name with an undeclared definition anywhere, such as `each`,
  gets no by-name fact. Core receivers keep CORE_RUBY_RESULTS' body specialization.
* `V | T` results.
* Declared block self types.
