- **Compiled lambdas:** a class-body lambda that reads nothing from its frame
  is a block thunk with a direct entry that checks its arity, and a compiled
  `lambda.call(...)` or `yield` enters it (and a `Kernel#lambda` block's)
  without a VM frame; the ArgumentError text, no autosplat and
  `return`/`next`/`break` are unchanged. VM entries for block calls in a
  headless sweep fell from 5,239 to 1,100.
