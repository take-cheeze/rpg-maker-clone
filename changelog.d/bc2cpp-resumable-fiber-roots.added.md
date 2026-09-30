- **bc2cpp** compiles a method that a `Fiber.new { root; :done }` block calls and that reaches
  `Fiber.yield` (in `while` loops, inlined `Integer#step`/`#upto`/`#downto` loops and tiny
  yielding helpers such as `Optcarrot::PPU#wait_one_clock`) as a resumable step function: its
  registers, loop counters and yield state live in a GC-marked heap frame, and a few lines of
  bytecode call it again after each `Fiber.yield`, so no compiled frame ever sits beneath a
  yield. Methods reachable from a Fiber that cannot yield are no longer refused. A root that
  does not qualify (rescue around a yield, a yield in a block that is not inlined, ...) stays
  interpreted and bc2cpp logs the reason. Covered by `scripts/bc2cpp_resumable_check.rb`
  (ADR 0273).
