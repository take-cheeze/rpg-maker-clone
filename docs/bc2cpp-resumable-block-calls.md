# Resumable block calls: replacing the enum-step drivers

Status: design, not implemented. Scope: the 89 guarded core methods that get a generated driver under the enum
step (`tools/bc2cpp/codegen_enum_step.rb`, `docs/bc2cpp-enum-step.md`).

## Why the drivers exist

A `Fiber.yield` inside a block suspends the fiber only if every frame between the fiber's root and the yield is a
VM frame. mruby refuses a suspension across a C frame (`fiber_check_cfunc`, `FiberError: can't cross C function
boundary`). A compiled core iterator calls its block from C, so the iterator needs a VM frame around the block call.
The enum step provides that frame: its saved body is a small Ruby driver that makes the block call itself.

Two costs follow from the drivers:

1. Each driver is Ruby source, compiled into bytecode by `mrb_load_string` when the owner registers. That is VM
   compilation at runtime, which the bytecode-free goal does not allow.
2. Each driver is one more method per owner, which is what the method-table gate counts.

## What already exists

`tools/bc2cpp/codegen_resumable.rb` compiles a method that reaches `Fiber.yield` as a step function. The step keeps
its registers and state in a heap frame, and a shared bytecode driver calls it again after each suspension:

```ruby
module ::Bc2cppResumable
  def drive(&step)
    f = step.call(self, nil, nil)
    while ::Bc2cppResumable::Frame === f
      f = step.call(self, f, ::Fiber.yield(f.value))
    end
    f
  end
end
```

The driver is one for every resumable method, not one per method. The step compiler refuses three things a block
iterator needs:

- a method that takes arguments or a block (`codegen_resumable.rb`, `resumable_shape_problem`);
- a call to a yielding method with an explicit receiver or a block (`:175`);
- a `Fiber.yield` inside a block or loop that is not inlined into the step function (`:246`).

## Proposal

A block call becomes a suspension kind, and the shared driver performs it:

```ruby
module ::Bc2cppResumable
  def drive(&step)
    f = step.call(self, nil, nil)
    while ::Bc2cppResumable::Frame === f
      resume = f.kind == :block ? f.block.call(*f.args) : ::Fiber.yield(f.value)
      f = step.call(self, f, resume)
    end
    f
  end
end
```

- The block is held in the frame, and the step asks for it: it returns a frame of kind `:block` with the arguments.
- The driver calls the block from VM code, so the block's own `Fiber.yield` has only VM frames between it and the
  root. The step is not on the stack while the block runs.
- The block's return value is the resume value. `break` and exceptions unwind through the driver as they do through
  an ordinary Ruby method.
- Outside a fiber, the C entry steps to completion, as today; a block that yields there raises as it does now.

The driver is still Ruby, but it is one shared method for every block-taking step, so it is compiled once rather than
per method. The step functions are compiled C++ and do not go through the VM compiler.

## Coverage, measured

I classified each of the 89 eligible methods by where its block is called (`yield`, or a call on the `&block`
parameter), using Prism on the mruby sources:

| Class | Count | Meaning |
|---|---|---|
| Direct | 38 | The block is called from the method's own loop. |
| Nested | 48 | The block is called only inside a block passed to another call, usually `self.each do ... end`. |
| Mixed | 3 | Both: `Array#combination`, `Array#permutation`, `Enumerable#each_slice`. |

The direct 38 include `Array#each`, `Array#each_index`, `Array#reverse_each`, `Array#select!`, `Hash#each`,
`Hash#delete`, `Hash#fetch`, `Integer#times/upto/downto`, `Integer#step`, `Float#step`, `String#each_line`,
`String#each_char`, `String#each_byte`, `IO#each`, `String#upto`.

The 48 nested methods, such as `Enumerable#inject`, `Enumerable#group_by` and `Hash#select`, call the block from inside
`each`. Their suspension has to cross the inner `each`, which is user code for an arbitrary receiver. That `each` would
need to be a resumable step as well. A user class's `each` is compiled only if bc2cpp compiles it that way, so this
cannot be guaranteed generically. These 51 methods (nested and mixed) keep a VM-resident loop, which means the
Ruby driver stays for them unless their receiver is a known core type.

## Phases

1. **Block-taking steps.** Lift the refusal for a block parameter and add the `:block` frame kind and the shared
   driver above. Convert the 38 direct methods. Existing resumable methods keep their behaviour: their frames have
   no block and never take the `:block` path.
2. **Nested methods.** Either keep the driver for them, or make their inner `each` resumable where the receiver is a
   known core type (`Array`, `Hash`, `Range`). Decide after phase 1 is measured.

## Verification

- The default-drivers fixture (`scripts/bc2cpp/enum_step_default_drivers_check.rb`) compares interpreted and compiled
  runs over these methods against MRI. Phase 1 must keep it passing.
- A fixture for the new frame kind: a `Fiber.yield` in the block, `break`, a raise in the block, an enumerator
  (`Enumerator#next`), and a block that does not yield, for each converted method.
- The method table does not change for converted methods: each keeps one saved entry, so the threshold question stays
  as it is on the draft PR.

## Open decisions

- Whether phase 2's 51 methods keep the Ruby driver. If they do, the closed build is not bytecode-free for them, and the
  design only removes the drivers for the 38 direct methods.
- Whether the fixed set of core receiver types is an acceptable precondition for compiling the nested `each`.
