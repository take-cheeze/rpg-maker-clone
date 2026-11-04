# bc2cpp: ENUM_STEP flag

ENUM_STEP used to generate Ruby drivers that replaced the saved body of a guarded core iterator, so a
`Fiber.yield` inside its block had only VM frames to cross. Those Ruby drivers and their generator
(`EnumDriverGen`) are removed.

## What remains

- `EnumStep.enabled?` (`tools/bc2cpp/codegen_enum_step.rb`) reads `BC2CPP_ENUM_STEP` once, when bc2cpp generates
  code. It is on by default; `BC2CPP_ENUM_STEP=0` turns it off.
- The flag gates the resumable variants of `CodeGen::RESUMABLE_DUAL` (`tools/bc2cpp/codegen_method.rb`). See
  [resumable block calls](bc2cpp-resumable-block-calls.md).

## Fiber path for guarded methods

A guarded core method keeps its saved body. When a fiber is running and the block is not known to be yield-free,
`core_block_guard` runs that body through `mrb_exec_irep`, so the block's `Fiber.yield` has only VM frames between
resume and yield. Closed builds compile the saved body into native continuations
([native fibers](bc2cpp-native-fibers.md)), so no instruction bytes are kept there.

## Removed

- Per-owner forms (`EnumStep::FORMS`), their Ruby driver sources and the `bc2cpp_enum_step_save` helper.
- `tools/bc2cpp/enum_driver_gen.rb`, which generated a driver from a method's `def`.
- The `enum_step_*_check.rb` fixtures, which asserted on the driver save calls.
- The Range stub that dropped `Range#each`'s body from the closed build's mrblib.
