# bc2cpp: class-method calls with a block

`CLOSED_WORLD_CONSTANT_OBJECT` (`tools/bc2cpp/codegen_constant_object.rb`)
calls the class method that mruby's lookup finds for a stable class constant
receiver (`Klass.name(args)`) directly, instead of dispatching by name. It now
covers literal-block sends too: `Klass.each_x(n) { |x| ... }`.

## Program class methods

A block send (`SENDB`) reaches the same path as a plain send. The definition
is the program's one public singleton definition on the constant's class
object or an ancestor's (an inherited class method resolves the same way).
`direct_call_args` passes the block, as a frame-local `RProc` when the callee
only calls it (`docs/bc2cpp-stack-blocks.md`).

## Compiled core class methods

`CONSTANT_OBJECT_CORE_BLOCK`: when no program definition answers, the lookup
walks the singleton classes up the superclass chain to a compiled core class
method. For a core class the closed world doesn't declare, the superclass comes
from `declarations.rbs#core_hierarchy`. Nothing on the way may answer first or
replace it:

- a program definition or a mixin on any of those singletons;
- a definition in Ruby outside mruby's core (`OutsideRubyOwners`, which
  records `def self.x` owners);
- a native registration of the name on any of those singletons
  (`NATIVE_OWNER_MAP`).

A compiled core body needs the root context, so the call sits behind
`M->c == M->root_c`, with the by-name send as the else, as `BLOCK_CORE_DIRECT`'s
arms do. `StringIO.open { |io| ... }` takes this path, and so does
`File.open { |f| ... }`: `File < IO` in `core_hierarchy` leads the lookup to
mruby-io's `IO.open`, which compiles since `ENSURE_NESTED_RESCUE`
(`docs/bc2cpp-ensure-rescue.md`).

The receiver may also be written `::File` (`OCLASS` then `GETMCNST`, always
the top-level constant), and the send may sit inside a `rescue` or `ensure`
range: the receiver's definition is then read through the handler edges.

## Switch and check

`BC2CPP_BLOCK_CORE_DIRECT=0` turns the core class-method call off.
`scripts/bc2cpp/class_method_block_check.rb` asserts the generated shapes and
compares interpreted and compiled runs for captured writes, `break` and `next`,
an exception in the block, a block the class method stores, `StringIO.open`
closing its io when the block raises, `File.open` in a plain body, a `rescue`
body and as `::File`, `GC.stress`, and a Fiber.
