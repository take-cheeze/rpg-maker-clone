- The bc2cpp resumable step compiler (`tools/bc2cpp/codegen_resumable.rb`) now
  compiles a method that takes a block as a step function when its `yield`
  is in the method's own loop. The step suspends for each yield, and the
  bytecode driver calls the block, so a `Fiber.yield` in the block suspends
  through VM frames only. `scripts/bc2cpp/resumable_block_check.rb` covers it.
