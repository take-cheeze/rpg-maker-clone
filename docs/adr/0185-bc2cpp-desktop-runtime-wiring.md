# 0185. Make the desktop RPGMAKER_BC2CPP build boot: init order, instance types, VM unwind, embedding

Date: 2026-09-21

## Status

Accepted

## Context

`RPGMAKER_BC2CPP=1` compiled and linked on desktop, but no CI job ever ran the
result (`bc2cpp` only builds `mruby_build`; `wio-bc2cpp` only links firmware).
Running it showed four independent defects, each hiding the next:

1. `rpg_maker_gem_dispatch` put `mruby-rpg2k-compiled` in the shared init group,
   which runs before any maker gem, so its `mrb_module_get(M, "Game")` raised.
2. The generator's ivar embedding stores ivars in an `RData` struct, which needs
   the class to be `MRB_TT_DATA` and every ivar-touching method to be an
   installed compiled method. `register.cxx` wires that by hand and had drifted
   (20 classes embedded, 9 wired; 474 of 2141 compiled entries never installed).
   `Game::Actor#initialize` was compiled but not installed, so the interpreted
   one ran, allocated no struct, and a compiled accessor dereferenced NULL.
3. `bc2cpp_block_break` and `bc2cpp_method_return` are foreign C++ exceptions.
   mruby's own `MRB_CATCH` does not intercept them, so unwinding through real VM
   frames left `mrb->jmp` dangling and the callinfo stack deep, which
   `mrb_vm_run` asserts against.
4. mrbc's `local = [literal]` is a three-operand `ARRAY Rd Rs N`. The code
   generator read only the two-operand form, so it compiled to an empty Array.

## Decision

- The dispatcher initialises a non-maker gem that depends directly on a maker
  gem inside that maker's init function, right after the maker.
- The generator emits `bc2cpp_set_instance_tts` for exactly the classes it
  embeds; each compiled gem calls it at init, and classes not yet defined are
  skipped and picked up by a later gem's call.
- Embedding is restricted to `BC2CPP_WIRED_EMBEDDINGS`
  (`tools/bc2cpp/compiled_gems.rb`), the classes whose `register.cxx` wiring is
  known complete. A class outside it keeps its ivars in the ordinary table.
- Every emitted catch for the generator's own unwinds takes a
  `Bc2cppVmMark` before its `try` and calls `bc2cpp_vm_restore` in the catch,
  which resets `mrb->jmp` and pops the leftover callinfos the way `cipop` does.
- `ARRAY Rd Rs N` is compiled explicitly.

## Consequences

The desktop bc2cpp build boots Nepheshel and reaches the map like the
interpreter build. The embedding restriction gives up the optimisation for the
unwired classes; the complete fix is generating every registration from the
compiled entry list instead of hand-maintaining `register.cxx`. The unwind
restore mirrors an internal VM function through public APIs, so a pinned mruby
bump must re-check `cipop`. `Ensure` clauses of Ruby frames skipped by such an
unwind still do not run (unchanged). There is still no CI job that boots the
desktop bc2cpp binary; adding one is the follow-up that would have caught all
four.
