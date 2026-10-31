# bc2cpp: the step form of Array#each (ENUM_STEP)

Stage B of the external-iteration plan: a prototype for one method, `Array#each`, behind
`BC2CPP_ENUM_STEP=1`. Off by default. Code: `tools/bc2cpp/codegen_enum_step.rb`, with two hooks
in `tools/bc2cpp/codegen_emit.rb`. Fixture: `scripts/bc2cpp/enum_step_array_check.rb`.

## Why

mruby refuses `Fiber.yield` while a C function frame is on the fiber's stack
(`fiber_check_cfunc`, `3rd/mruby/mrbgems/mruby-fiber/src/fiber.c`). A compiled `Array#each` is a
C function, so its frame cannot sit between `resume` and a `Fiber.yield` in the block.

Today `core_block_guard` (`tools/bc2cpp/codegen_method.rb`) covers this. When a fiber is running
and the block is not known to be yield-free, the entry calls `bc2cpp_core_interpreted`, which
runs `Array#each`'s saved bytecode through `mrb_exec_irep`. That replaces the C frame with a VM
frame. It works, but the whole body of `Array#each` is kept as bytecode.

## Protocol (as implemented)

- **Heap state.** The driver makes `st = [next_index, done]` once per call.
- **Step** (compiled C++, `bc2cpp_each_step`, registered privately on Array as
  `__bc2cpp_each_step`). It reads the length (`ARY_LEN` for an exact Array, otherwise a dispatched
  `length`). If `next_index >= length` it sets `st[1]` and returns nil. Otherwise it returns the
  element (`mrb_ary_ref`, or a dispatched `[]` for a subclass) and stores `next_index + 1`. Either
  way the step returns straight away, so no C frame is left for the block call.
- **Driver** (Ruby, `Array#__bc2cpp_each_driver`, private, compiled into the VM by
  `mrb_load_string` when the registration runs):

  ```ruby
  return to_enum(:each) unless block
  st = [0, false]
  while true
    v = __bc2cpp_each_step(st)
    break if st[1]
    yield v
  end
  self
  ```

- **Result.** The driver returns `self`, so `StopIteration#result` is the array, as with the
  mrblib body.

## Where the flag is read

`EnumStep.enabled?` reads `ENV['BC2CPP_ENUM_STEP']` once, when bc2cpp generates code. Nothing
reads it at run time. When it is set:

- `codegen_emit.rb` registers `Array#each` with `bc2cpp_enum_step_save` instead of
  `bc2cpp_core_save_interpreted`;
- `emit_core_guard_helpers` appends the step, the driver source, and the save helper.

When it is unset, `EnumStep` adds nothing to the output (see Measured).

## What changes in the guard (Array#each only)

- The prologue is unchanged: `if (M->c != M->root_c && !bc2cpp_block_yield_free(blk))
  return bc2cpp_core_interpreted(M, self, 0);`. The guard still runs the proc in slot 0 through
  `mrb_exec_irep`.
- Under the flag, slot 0 holds the **driver** proc, not Array#each's own body.
- Root-context calls and yield-free blocks still run the compiled `Array_each_impl`. A blockless
  `each` under a fiber takes the fallback (a nil block is not yield-free) and the driver returns
  `to_enum`.
- Every other guarded core method keeps its saved bytecode.

## Designed, not run

- Break out of the block, and `each` on a subclass that overrides `[]` with side effects, beyond
  the cases in the fixture.
- Performance. The step adds one C call per element and one heap array per `each` in a fiber.
  Not measured.
- Game behaviour. Only the fixture was run.
- Stage B2 (the next iterator) and any other method.

## Known limits

- The driver is Ruby compiled with `mrb_load_string`, so the flag needs `mruby-compiler` in the
  build (the closed build has it; the `wio` and `maix` builds may not). Not tested.
- `__bc2cpp_each_driver` and `__bc2cpp_each_step` are private methods on Array, visible to
  `Array.private_instance_methods`.
- A non-Integer `length` raises TypeError (`mrb_as_int`). mrblib compares it with `<`.
- The driver is parsed once per VM at registration. Its cost was not measured.

## Measured

- **Flag unset: byte-identical output.** Generating a core `Array` fixture with the `origin/master`
  tree and with this branch gives the same `fixture_gen.cpp`, apart from the path of
  `3rd/mruby` in one comment (normalized). The path differs only because the two copies live in
  different directories.
- **Fixture, before (origin/master) and after.** The generated-code checks fail before and pass
  after (the step is absent before). The behavioural comparison passes both times. Before, the
  compiled run has no step on Array. After, all checks pass, with the interpreted (Fiber-based,
  mruby's own body) and compiled (step) runs equal and each scenario matching Ruby's own result.
- **Mutation.** Changing the step's increment to `idx + 2` makes the comparison fail in every
  fiber scenario. So the fixture exercises the step, not the saved body.
- **Closed builds** (`scripts/bc2cpp/closed_build.bash`, same tree, flag unset and set). Flag unset:
  142 `bc2cpp_core_save_interpreted` registrations, `libmruby.a` 115,211,836 bytes. Flag set: 142
  registrations, of which Array#each's goes through `bc2cpp_enum_step_save` (the driver replaces its
  body), `libmruby.a` 115,226,128 bytes (+14,292). The closed builds were not run against
  origin/master, so the flag-unset library is not compared byte for byte with it. Runtime behaviour
  of the closed builds was not tested; only the fixture ran.
