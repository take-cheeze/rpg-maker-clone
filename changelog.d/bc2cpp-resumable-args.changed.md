- The bc2cpp resumable step compiler (`tools/bc2cpp/codegen_resumable.rb`) now
  compiles core methods, and methods that take required positional arguments,
  as step functions when a `Fiber.new` body calls them on `self`. Arguments
  are copied into the frame at the call, and the bytecode driver takes the
  frame on its first step. Optional, rest, post, keyword and block arguments
  and native argument types still stay interpreted.
  `scripts/bc2cpp/resumable_args_check.rb` covers the argument path.
