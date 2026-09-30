# 265. bc2cpp resolves rest, block and splat argument shapes to direct calls

Date: 2026-09-30

## Status

Accepted

## Context

After ADR 0258 the call-site gates of `compile_send` accept one callee shape:
mandatory positionals, optional positionals (padded with `bc2cpp_given_opt`),
and, through `compile_keyword_call`, keywords. Everything else is dispatched,
whatever the receiver proof. Measured on the wio closed-world build (all three
compiled gems, shipped output) at `39706af5`, the compiled callees' `ENTER`
shapes are:

| callee shape | methods | note |
|---|---|---|
| mandatory only | 2183 | direct |
| optional | 109 | direct |
| keyword | 29 | direct (ADR 0258 for keywordless calls) |
| optional + keyword | 3 | direct |
| rest (`*args`) | 4 | dispatched: `Tee#write/print/puts`, `Game::State#move_picture` |
| block parameter (`&blk`) | 4 | dispatched: `Actors#each`, `Party#each`, `Array#sort`, `sort!` |
| post, kwrest, destructuring | 0 | none in the sources |

Yield-based methods (mandatory arguments plus `yield`) are a fifth shape: their
`_impl` takes a trailing `bc2cpp_blk`, which no call site ever passed. They were
only reached through the entry wrapper, i.e. by `mrb_funcall_with_block`.

The caller side, by the comment each dispatching site carries in the same
build:

| caller shape | sites | resolvable to compiled code |
|---|---|---|
| literal block (`SENDB`, BLOCK_FALLBACK) | 335 | 32: `page_field` 15, `cached_bitmap` 8, `auto_battle_best_target` 3, `each_event_position` 2, typed `Actors#each` 2, typed `Array#sort` 2; the other ~300 name core natives (`each`, `map`, `times`, ...) |
| `&expr` block argument | 13 | 7 name bytecode (`select` on `EventPage`, `each`); kept dynamic, see below |
| runtime splat `f(*a)` | 9 | 6 name a compiled callee (`move_to`, `flash`, `restore_substitutions`, `Tee#*`) |
| literal-sized splat | 3 | `Combatant.new(*[...])`, unrolled but dispatched |
| splat/double splat with keywords | 3 | already direct (`compile_keyword_call`) |
| trailing keyword Hash | 15 | already direct (`KEYWORD_HASH_DEVIRT`) |
| safe navigation (`&.`) | 4 | a `JMPNIL` plus the ordinary send |
| `super` | ~20 | `super_target` |

`page_field` also showed a callee-side gap: a `yield` inside a `rescue` body is
compiled into a separate `mrb_protect_error` function that had no access to the
method's block (`#error unhandled opcode BLKPUSH`), so the whole method was
uncompiled and every caller dispatched.

## Decision

The new code is `tools/bc2cpp/codegen_arg_shapes.rb` (`ArgShapeCalls`,
prepended to `CodeGen` like ADR 0257) plus four small edits. It wraps the
helpers every `compile_send` branch already shares instead of touching each
branch.

**ARG_SHAPES_CALLEE.** Inside `compile_send`, `pure_mandatory_or_optional_arity?`
also accepts a rest-only callee (`ENTER n:0:1:0:0:0:B:0`) and a block-only one
(`n:0:0:0:0:0:1:0`), and `optional_arity` of a rest callee is unbounded, so the
existing `n.between?(mand, mand + opt)` gate admits any `n >= mand`; a shorter
call keeps the dispatch, which raises the ArgumentError. `direct_call_args`
builds the `_impl` argument list in `compile_method`'s order: the mandatory
arguments, a fresh `mrb_ary_new_from_values` Array for the rest parameter (as
`OP_ENTER` builds one per call; `mrb_ary_new` when empty), then the block, then
`bc2cpp_given_opt`. Every callee that takes a block parameter gets one: the
literal block, or `mrb_nil_value()` when the call has none. `yields_block_param?`
is now the single predicate behind both `compile_method`'s signature and this
argument list.

**ARG_SHAPES_BLOCK.** `emit_block_fallback_glue` asks
`compile_direct_block_send` first. It runs `compile_send` on a synthetic plain
send at the `SENDB`'s position with `@call_block_expr` set to the built RProc:
`dynamic_dispatch_line` then emits `mrb_funcall_with_block`, the by-name native
arms, `compile_poly_small_n`/`compile_poly_table` and the keywordless path step
aside, and `direct_call_args` appends the block. The result is used only if
every `_impl(M` call in it went through `direct_call_args` and no block-less
dynamic call remains; otherwise the site keeps its dispatch. The direct call
stays inside the glue's `try`/`catch (bc2cpp_block_break&)`, so `break` behaves
as before. Only the top-level pass (method body and rescue bodies) does this;
nested block bodies and inlined loops keep dispatch because their compile state
is not set yet when the glue is built.

**ARG_SHAPES_YIELD.** A method with a `yield` inside a `rescue` now passes
`bc2cpp_blk` to its `mrb_protect_error` body through the context struct (a
`bc2cpp_blk` extra field, `@blk_param_name` set while the body compiles).

**ARG_SHAPES_SPLAT.** A literal-sized splat is compiled as the n-argument send
it is (arguments read with `mrb_ary_ref`, as before). A runtime-sized splat
switches on `RARRAY_LEN` of the argument Array that `mrbc` always builds, with
one arm per argument count some definition of the name accepts (at most 8),
each arm the ordinary `compile_send` code for that count; any other length
reaches the old `mrb_funcall_argv`, which is where the ArgumentError comes
from. An arm exists only where the send resolves to compiled code.

Soundness conditions, each enforced in one place:

- **No proof from a unique name.** The registry lists project definitions and
  native sources, not core Ruby-level ones (`Enumerable#sort`), so a by-name
  `MONO` on an explicit receiver proves no class. `compile_send` therefore
  compiles again with `monomorphic_target` disabled when an explicit-receiver
  send to a new shape came out as `// MONO :`; guarded (`TYPED`,
  `MONO_EMBED_GUARD`), exact-class and self resolutions remain. (`x.sort` with an
  unknown receiver would otherwise call `Array#sort`'s body on a Hash.)
- **A block-taking callee must not read its frame.** `block_transparent_callee?`
  refuses one whose body (at any block depth) calls `iterator?` or `binding`
  (`block_given?` is modelled since ADR 0266), or contains `SUPER`/`ARGARY` (which forward the block): with no
  frame of its own, those would see the caller's. None exist in the sources.
- **Chain arms have no block slot**, so `poly_candidates` drops a block-taking
  definition (its class then dispatches, as for any other excluded definition).
- **`&expr` block arguments stay dynamic.** `mrb_funcall_with_block` coerces the
  value with `to_proc`, and `BLKCALL` does not model a cfunc-backed Proc (see its comment in
  `codegen_insn.rb`): a `&:sym` handed to a compiled `yield` is not reproduced.

Also: `keyword_hash_devirt_line` now builds its arguments with
`direct_call_args` instead of its own padding, so the new shapes reach it too.
The three `bc2cpp_nomethod` sites this adds (`Game::State#move_picture` from
`Game::Interpreter#do_move_picture` and `Game::State.restore_pictures`,
`Game::Map#restore_substitutions` from `RPG2k#continue_game`) are in
`NOMETHOD_REVIEWED`: their receivers are `Game::State` (`@state`, the
`state = new(...)` of `from_lsd`) and `Game::Map` (`load_map`) only.

## Consequences

- Wio shipped build (`scripts/bc2cpp_coverage_report.rb`, `39706af5` ->
  this change): cached dispatch sites 10134 -> 10108, generic POLY sites
  392 -> 390, `unsupported_arity` definitions across sites 15 -> 14; 32 literal
  block sites, 3 runtime splat sites and 2 literal splat sites become direct
  calls, `page_field` compiles clean, and `move_picture` (rest) is a guarded
  direct call. The population is small because the dominant shapes were
  already covered; the rest is native callees (`each`, `map`, ...) and
  receivers no proof reaches.
- `scripts/bc2cpp_arg_shapes_check.rb` compiles a fixture with every shape
  under a closed world, runs it interpreted and compiled on a real mruby core
  and compares the transcripts (values, break/next/return, exceptions, arity
  errors, rest freshness, empty/nil/non-Array splats, hash-last arguments, `&:sym`,
  `&nil`). It also asserts which sites are direct.
- The full shipped output type-checks (`g++ -fsyntax-only`), which is what
  proves the `_impl` argument lists agree with the signatures.
- Known divergences found and left alone, all in code this ADR does not touch
  (ADR 0266 fixes all four):
  an entry wrapper's `mrb_get_args` spells a rest/optional arity error
  `expected 1+` / `1..2` where `OP_ENTER` says `expected 1` (the fixture
  normalizes it); a BLOCK_FALLBACK block with fewer parameters than it is
  yielded raises ArgumentError instead of padding; `block_given?` in any compiled
  method is false (a cfunc frame has no proc); and calling a BLOCK_FALLBACK
  Proc through `Proc#call` from compiled code crashes (`OP_CALL` reads the
  calling cfunc frame's `proc`). The last two mean a callee that reads its block
  as a value (`blk.call`) is unsafe with a literal block whether reached by
  dispatch or directly; none exists in the sources.
- Not done: post arguments, kwrest and destructuring parameters (no callee has
  them), a rest callee combined with optional or keyword parameters, `&expr`
  block arguments, and blocks in nested block bodies.
