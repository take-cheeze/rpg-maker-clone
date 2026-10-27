# Assured ivar slots (SLOT_ASSURED)

An embedded `mrb_value` ivar slot (see [embedded struct families](bc2cpp-embed-families.md)) starts as `undef`,
the runtime's "not assigned" marker, so `instance_variables`, `instance_variable_defined?`, `dup` and `inspect`
skip it the way they skip an ivar that was never set. A compiled read therefore normalises the slot on every
access:

```cpp
r4 = (mrb_undef_p(((PPU_ivars*)DATA_PTR(self))->ivar_hclk) ? mrb_nil_value() : ((PPU_ivars*)DATA_PTR(self))->ivar_hclk);
```

`tools/bc2cpp/ivar_slot_assured.rb` proves, per family and ivar, which reads can never see the slot unassigned.
Those reads take the field as it is. Reflection is unchanged, because the slots still start as `undef`.

## The argument

A read of `@x` with `self` = an object `O` can only see `undef` while `O` has not yet assigned it. The proof
establishes three facts:

1. **Every construction assigns `@x`.** For every class an instance of the read's class can be (it and its
   descendants), the `#initialize` that instance runs assigns `@x` on every normal exit. A self-call counts when
   its single target assigns `@x` on all of its own normal exits, and `super` counts when the superclass's
   `#initialize` does. A raise is not a normal exit. A `rescue` starts from the state before the instruction that
   raised, so an assignment made by a call that raised does not count. A block's `return` would leave the method
   from inside a call, so a body whose blocks contain one assures nothing.
2. **No instance is a value before its `#initialize` returns.** The code that may run with `self` = an object
   under construction is the *construction reach*. It holds `#initialize` and everything reachable from it
   through self-calls, `super`, blocks it creates, and the literal names `send`/`method` dispatch to. That code
   never loads `self` as a value (`LOADSELF`, `RETSELF`, `self` as an operand), opens a singleton class, or
   defines a method. A native self-call is accepted only from a short list of natives that neither call back
   into the object nor hand it out (`raise`, `lambda`, `respond_to?`, `method`, ...). `Method#receiver` (and
   `Proc#binding` with `Binding#receiver`) would hand the object out, so the world must not name them when a
   `Method` or a block is made there. Because of this, a family object that some code holds as a value has
   finished its `#initialize`. So does every object a Method or block made during construction can reach, unless
   that `#initialize` raised. In that case only construction-reach code can still run on the object, and its
   reads keep the test.
3. **Nothing makes an instance another way, unassigns a slot or changes what the construction calls.** The
   world never names `allocate` or `remove_instance_variable` (also counting the names computed sends can carry,
   `DynamicNames`), and `new` is not redefined. String `eval` (and the String forms of
   `instance_eval`/`class_eval`/`module_eval`) and `ObjectSpace.each_object` are either undefined or never
   named. No outside source spells a family class, an ancestor that `#initialize` or its `super` resolves
   through, or `@x`. A self-call whose name has a computed definer, or that a `remove_method`/`undef_method`/
   `undef` can reach, refuses the family. `Marshal.load` of data that no constructed object dumped is outside
   the model, as it is for every embedded ivar.

A read in an irep outside the construction reach therefore needs no test, and a read inside it keeps the test.
The synthesized `attr_reader` of an embedded ivar is treated the same way: it skips the test when no
construction-time self-call names it.

## Construction arguments

`ivar_slot_assured_args.rb` lets the reach skip arms that a self-call's literal arguments switch off.
`PPU#initialize` calls `reset(mapping: false)`, and the `mapping` arm of `reset` builds `method(:peek_2xxx)`
objects for the CPU's memory map. Without the binding, the reach would include every I/O handler and, through
them, the whole frame loop. The decided tests are the following:

- a JMPIF/JMPNOT/JMPNIL on a parameter bound to a literal (or a MOVE of one);
- a test of `param.fetch(:key, literal)` or `param[:key]` on the keyword Hash of the call, when every use of the
  parameter is such a read and Hash#fetch, #[] and #key? are mruby's own;
- the optional-argument entry ENTER takes for the call's argument count.

A parameter keeps its literal only while no live instruction (and no block) writes it. Pruning is applied again
until nothing changes.

## Switches and checks

- `BC2CPP_SLOT_ASSURED=0` keeps every test, for comparison.
- `BC2CPP_SLOT_ASSURED_REPORT=1` prints one line per family to stderr: the assigned ivars per class, the size
  of the construction reach and the names it self-calls, or why the family was refused.
- `MRBC=path/to/mrbc ruby scripts/bc2cpp/slot_assured_check.rb` asserts the generated shape (bare reads,
  kept tests, refusals, argument pruning, `super`) and compares interpreted and compiled runs over reflection,
  `dup`, a block kept from a construction that raised, `GC.stress` and a Fiber.

## Effect

In the optcarrot probe (Lan_Master, callgrind, instructions per frame from the difference of 21-frame and
1-frame runs) the frame loop drops from 42.72M to 38.53M instructions (about 9.8%). The undef tests left in
`PPU` fall from 574 to 53. `PPU` and `CPU` are assured. `APU` hands `self` to its oscillators' constructors
and is refused. `Oscillator`'s hot ivars are first assigned by `reset`, which `#initialize` does not call, so
they keep the test.
