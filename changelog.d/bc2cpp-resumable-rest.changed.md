- The bc2cpp resumable step compiler (`tools/bc2cpp/codegen_resumable.rb`) now
  compiles a method with a rest positional argument (`*args`) as a step function
  when a `Fiber.new` body reaches it, alone or after optional arguments. The
  registered wrapper checks the count and builds the Array, as it does for any
  method with a rest argument, and the step reads the Array from its register. A
  method with a post or keyword argument still stays interpreted.
  `scripts/bc2cpp/resumable_rest_check.rb` covers it.
