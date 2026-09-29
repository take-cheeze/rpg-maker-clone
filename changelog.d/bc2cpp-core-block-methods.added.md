- **bc2cpp compiles the block-taking methods of mruby's own Ruby** (ADR 0269):
  `Array#each`, `Integer#times`/`upto`, `Kernel#loop`, `Hash#each`, `Range#each`,
  most of `Enumerable` and their aliases (`map`, `select`, `find`, ...) join the
  compiled core (56 -> 173 methods in the wio gem set). The entry of each one checks
  `mrb->c != mrb->root_c` and, while a Fiber runs (a game script, `Enumerator#next`),
  hands the call to the saved bytecode, so a `Fiber.yield` inside a block never has to
  cross a compiled frame. Also fixes `Kernel#\`` being replaced by core's
  `NotImplementedError` version over mruby-io's. New probe
  `scripts/bc2cpp_core_blocks_probe.rb` (Fibers, `Enumerator#next`, break/return/raise,
  GC pressure) runs interpreted vs compiled in `scripts/bc2cpp_core_mrbtest.rb`.
