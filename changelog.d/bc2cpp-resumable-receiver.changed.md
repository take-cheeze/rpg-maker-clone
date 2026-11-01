- The bc2cpp resumable step compiler (`tools/bc2cpp/codegen_resumable.rb`) now
  resolves the receiver of a `Fiber.new` body's call by method name, so a core
  method that a fiber body reaches through a receiver (`arr.each_index { ... }`)
  is compiled as a step function as well as a call on `self`. A reached method
  that yields in its own loop is compiled as a step, so it no longer carries the
  Fiber guard or its saved bytecode.
  `scripts/bc2cpp/resumable_receiver_check.rb` covers it.
