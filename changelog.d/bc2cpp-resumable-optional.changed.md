- The bc2cpp resumable step compiler (`tools/bc2cpp/codegen_resumable.rb`) now
  compiles a method with optional positional arguments as a step function when
  a `Fiber.new` body reaches it. The entry records how many optionals the call
  gave in the frame, and the step starts at the matching default-value code, so
  an omitted default still runs in the step. A method with a rest, post or
  keyword argument still stays interpreted.
  `scripts/bc2cpp/resumable_optional_check.rb` covers it.
