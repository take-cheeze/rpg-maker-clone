- `tools/bc2cpp/bc2cpp.rb`'s `BLOCK_FALLBACK` mechanism can now compile a
  block that uses a real `break` -- previously rejected outright
  (`block_fallback_safe?`'s own `BLOCK_FALLBACK_UNSAFE_OPS`), since a
  plain C++ `return` from the block's own standalone cfunc only exits
  that cfunc, back into mruby's own VM dispatch inside
  `mrb_funcall_with_block` -- not far enough: real non-strict `OP_BREAK`
  (3rd/mruby/src/vm.c) unwinds all the way back to the call site that
  yielded the block, with the break value becoming that whole call's own
  result (the exact semantics `compile_block_body_insn`'s own inlined-
  loop BREAK case already reproduces with a plain `goto`, for the cases a
  same-function `goto` can reach -- this is the same semantics for a case
  it can't: a genuinely separate top-level function).

  A real C++ `throw`/`catch` reproduces this unwind directly:
  `compile_insn`'s own `BREAK` case now throws a small carrier
  (`struct bc2cpp_block_break { mrb_value value; };`, emitted
  unconditionally near the top of every generated file) when compiling a
  `BLOCK_FALLBACK` body (`@block_fallback_active`, the same consume-and-
  clear-around-one-body-compile-loop discipline `@block_fallback_upvars`
  already established), caught by `emit_block_fallback_glue`'s own new
  `try { ...mrb_funcall_with_block(...)... } catch (bc2cpp_block_break&
  e) { r<dest> = e.value; }` wrapped around the dispatch -- unconditional
  too, so a block with no real `break` at all simply never throws,
  functionally identical to today's own bare call. `LAMBDA_FALLBACK`
  keeps its own existing, unchanged translation (a strict lambda's own
  `break` is real Ruby's well-known "exits the lambda itself, exactly
  like `return`" rule, already a plain `return` -- see that case's own
  comment, confirmed against `3rd/mruby/include/mruby/opcode.h`'s
  `OP_L_LAMBDA` flags).

  Safe specifically because this project already builds mruby itself with
  `MRB_USE_CXX_EXCEPTION` (see `CMakeLists.txt`'s own comment, and
  `build_config.rb`'s wio section: mruby's own gem loader auto-enables it
  the moment any gem has a `.cxx` source, which every real build variant's
  own `mruby-rgss` dependency guarantees -- a `-fno-exceptions` build
  doesn't even compile mruby's own core) -- mruby's own `MRB_TRY`/
  `MRB_CATCH` (its real `begin`/`rescue`/`ensure` implementation) already
  compile to genuine C++ `try`/`catch`, not `setjmp`/`longjmp`, on this
  project, so a C++ exception thrown here and propagating up through
  `mrb_funcall_with_block`'s own real internals unwinds through frames
  that are already built for exactly this -- not a new architectural
  dependency, reusing an existing, load-bearing one.

  A real, separate safety question this raises (distinct from
  UPVAR_CAPTURE_SUPPORT's own pointer-lifetime hazard, which doesn't
  apply here at all -- `break`'s carried value is captured by value, not
  a pointer into anything): a callee that stores the block rather than
  invoking it synchronously, then invokes it later outside this call's
  own dynamic scope, would produce an uncaught C++ exception. Deliberately
  NOT gated on a method-name allowlist the way upvar-capture is: unlike a
  captured pointer (which would silently read/write stale memory), an
  uncaught exception is a loud crash, not silent corruption -- and `break`
  used inside a block a receiver has already detached from its own
  originating call is *already* an error case in real interpreted Ruby/
  mruby too (a `LocalJumpError`-shaped situation), so this doesn't turn a
  working program into a broken one, just changes an already-erroneous
  usage pattern's failure mode.

  `RETURN_BLK` (return from the whole ENCLOSING METHOD, not just this
  block) stays rejected -- unlike `BREAK`, it needs to unwind PAST the
  SENDB/SSENDB call site entirely, out through however much of the
  enclosing method's own body sits between here and that method's own
  top-level entry point, a real, separate change to `compile_method`'s
  own top-level function-body wrapping not attempted alongside `BREAK` in
  this same round.

  Verified against the real whole-program diagnostic: compiled entry
  points 2126 -> 2130 (+4 fully clean -- most real `BREAK`-containing
  sites already needed, and got, the GETUPVAR/SETUPVAR fix in the same
  round that preceded this one), method-level coverage 91.8% -> 92.0%,
  `#error unhandled opcode BLOCK` 165 -> 161, `SENDB` 145 -> 142,
  `SSENDB` 33 -> 32, total `#error` markers 420 -> 412, `BLOCK_FALLBACK`
  sites 177 -> 181. `scripts/rpg2k_logic_check.rb` (1201 checks),
  `scripts/rpg2k_scene_check.rb` (1062 checks), and
  `scripts/lcf_testbed_check.rb` all still pass unchanged -- the real
  control-flow-correctness evidence a compile-success count alone can't
  give (a `break` compiled as an ordinary `return` instead of a `throw`
  would corrupt the enclosing method's own control flow, not just fail
  to compile). Directly inspected real generated output for a genuine,
  non-trivial case (`Game::Battle#choose_enemy_action`'s own
  `each_with_index { ... break ... }`, three captured upvars AND a real
  `break` together): the `throw bc2cpp_block_break{r4};` inside the
  block body and the matching `try { ... } catch (bc2cpp_block_break&
  bc2cpp_brk) { r9 = bc2cpp_brk.value; }` at the real `each_with_index`
  call site, both wired correctly. A real `g++ -std=c++17 -fsyntax-only`
  compile of the actual `SKIP_UNSUPPORTED=1` generated output confirms
  zero new errors: the same 4 pre-existing, already-documented,
  unrelated categories as the immediately preceding round (a missing
  `#include <mruby/numeric.h>` for `FIXABLE_FLOAT`/`mrb_integer_to_str`,
  and the pre-existing `RPG2k::Scene::Map#vehicle_blocks?` keyword-arg
  call-site arity mismatch), each individually confirmed to occur outside
  any `bc2cpp_block_break`-related code.
