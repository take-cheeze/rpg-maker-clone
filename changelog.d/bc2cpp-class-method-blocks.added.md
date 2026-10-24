- **bc2cpp: class-method calls with a block are direct calls.** A literal-block
  send to a stable class constant (`Klass.each_x(n) { |x| ... }`) now calls the
  class method's compiled body instead of dispatching by name: a program class
  method (own or inherited) with the block, and a compiled core class method
  such as `StringIO.open { |io| ... }` at the root context, with the send kept
  for a Fiber. `File.open { }` still dispatches, because mruby-io's `IO.open`
  does not compile yet (a `rescue` inside its `ensure`).
