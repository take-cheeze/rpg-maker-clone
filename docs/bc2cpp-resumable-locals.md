# Resumable step functions keep registers in locals (RESUMABLE_LOCAL_REGISTERS)

A method that reaches `Fiber.yield` compiles to a step function (`tools/bc2cpp/codegen_resumable.rb`): every
call runs from the state the last yield saved until the next yield, and a heap frame carries the registers
from one call to the next. The registers used to be C++ references into that frame:

```cpp
mrb_value& r15 = R[15];
```

Every register access was then a memory access, and every store through a register could alias any other
`mrb_value` in memory, such as an embedded ivar field. The compiler had to reload ivars and registers after
nearly every store. In optcarrot's `PPU#main_loop`, `@hclk += 2; Fiber.yield if @hclk_target <= @hclk` read
`@hclk` back from memory right after storing it.

The step function now declares the registers as locals, loaded from the frame on entry:

```cpp
// RESUMABLE_LOCAL_REGISTERS
mrb_value r15 = R[15];
```

Each yield stores every register back into the frame before the frame's write barrier and the return:

```cpp
R[0] = r10;
F->state = 3;
bc2cpp_step_guard.yielding = true;
R[2] = r0; R[3] = r2; ... R[20] = r19;
mrb_write_barrier(M, (struct RBasic*)mrb_ary_ptr(bc2cpp_regs_ary));
return bc2cpp_frame_value;
Lbc2cpp_resume_3:;
r9 = R[1];
```

A resume enters through the `switch` on the saved state. That `switch` sits after the loads, so every resume
label sees the registers the last yield stored.

## Why it is sound

- **Values across a yield.** The frame holds every register from the store at the yield until the next entry
  loads it again. The frame's register array is reachable from the frame object, and the write barrier runs
  after the stores, so the GC sees the values while the fiber is suspended, as it did before.
- **Values within a step.** Between two yields, a register is a C++ local, as it is in every non-resumable
  compiled method. It is rooted the same way: an object the step creates stays in the GC arena until the
  driver returns, and a value it reads is held by the object it was read from. The frame keeps its own copies
  from the last yield too, so it can only keep a value alive longer, never shorter.
- **Finishing or raising.** A step that returns or raises without yielding is finished. `Bc2cppStepGuard`
  clears the frame, as before, and nothing reads the locals afterwards.
- **Pointers to a register.** A stack block hands its captured locals to the block body as pointers
  (`mrb_cptr_value(M, &r2)`). A pointer taken before a yield must still reach the same cell after the
  resume, and a C++ local of the earlier call does not survive it. A body that takes the address of any
  register outside a literal or a comment therefore keeps the references into the frame.

Exception handlers do not change this. A resumable method or helper with a `rescue` or `ensure` is refused
before code generation (`resumable_shape_problem`, `resumable_helper_problem`). A protected range elsewhere
runs in its own function through `mrb_protect_error`, which reaches the registers through pointers. That
takes their address, so such a step function keeps the references.

`BC2CPP_RESUMABLE_LOCALS=0` restores the references, for comparison.

## Check

`MRBC=path/to/mrbc ruby scripts/bc2cpp/resumable_locals_check.rb` compiles a Fiber root with two yielding
helpers. It asserts that the step function declares its registers as locals and that every yield stores them
back before returning. It also asserts that a step function handing a block to a compiled method (which
captures `&rN`) keeps the references, and that `BC2CPP_RESUMABLE_LOCALS=0` does too. It then compares the
interpreted and compiled output, with a fresh Array held across both yields and `GC.start` between resumes.

## Measurement

These figures come from the optcarrot probe (Lan_Master). Instructions per frame are the difference between
callgrind runs of 21 and 1 frames, divided by 20. Checksum `59662` at 180 frames is unchanged.

| Build | Instructions per frame | `PPU#main_loop` step function, self |
| --- | ---: | ---: |
| References into the frame (`BC2CPP_RESUMABLE_LOCALS=0`) | 35,997,826 | 6,710,127 |
| Locals | 33,725,182 | 4,248,925 |

The step function's own instructions drop by 2.46M. GCC also stops inlining `bc2cpp_getidx` into
`PPU#render_pixel`, which moves some cost between those two, so the frame as a whole drops by 2.27M (6.3%).
Startup is unchanged (1,506.85M instructions for a 1-frame run).
