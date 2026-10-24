# bc2cpp yield analysis: the C boundary and self sends

The yield analysis (`tools/bc2cpp/yield_reach.rb`) decides which compiled methods may have their frame on the
stack when a `Fiber.yield` suspends. A compiled method is C++ code, and mruby cannot suspend a fiber across a C
frame, so a method the analysis calls may-yield stays interpreted (or compiles as a resumable step function when it
is a Fiber root). Two rules keep that set to the frames a yield can actually cross.

## Native callbacks are a C boundary

When a native method calls back into Ruby (`mrb_funcall`, `mrb_yield`, a Hash default proc and the other stored-block
reads), mruby pushes the Ruby frame as `CINFO_DIRECT` or `CINFO_SKIP`. `Fiber.yield` walks the fiber's frames and
raises `FiberError` ("can't cross C function boundary") on any such frame (`fiber_check_cfunc` in
`mrbgems/mruby-fiber/src/fiber.c`). So in the original interpreted program no yield ever suspends through a native
callback: it raises. A native callback is therefore not a yield path, and the analysis does not count one.

The natives that run Ruby inside the VM, with no C frame between, are counted as before: `send` and `public_send`
(computed sends), `Proc#call` and `Method#call` (proc calls), `eval`/`instance_eval` (eval seeds) and
`instance_exec`/`class_exec` (block executes).

`BC2CPP_YIELD_C_BOUNDARY=0` counts native callbacks and stored-block reads as yield paths again.

## A computed send on self stays in self's class chain

A send whose name is computed (`send(*DISPATCH[op])`) can reach only a method whose name the program spells as a
Symbol or String literal (`DynamicNames`). When the receiver is `self`, it can also reach only a method of self's
class, its superclass chain, a module, or that chain's `method_missing`. A computed send on any other receiver may
reach any spelled method.

A name assembled from string pieces at run time is outside the spelled set. If such a send reaches a method that
yields across a compiled frame, the yield raises `FiberError` at that C frame instead of suspending: a loud error,
never a silent one ([soundness contract](bc2cpp-soundness.md)).

`BC2CPP_YIELD_SPELLED_SENDS=0` lets every computed send reach every method again.

## Check

`MRBC=... ruby scripts/bc2cpp/yield_c_boundary_check.rb` checks both rules on a fixture in both directions, and
that each switch turns its rule off.
