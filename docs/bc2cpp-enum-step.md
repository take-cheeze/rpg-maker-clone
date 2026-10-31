# bc2cpp: the step form of Array#each and Range#each (ENUM_STEP)

Stage B of the external-iteration plan: the step form of `Array#each`, then the same mechanism for
`Range#each`, behind `BC2CPP_ENUM_STEP=1`. Off by default. Code: `tools/bc2cpp/codegen_enum_step.rb`
(one form per owner), with two hooks in `tools/bc2cpp/codegen_emit.rb`. Fixtures:
`scripts/bc2cpp/enum_step_array_check.rb` and `scripts/bc2cpp/enum_step_range_check.rb`.

## Why

mruby refuses `Fiber.yield` while a C function frame is on the fiber's stack
(`fiber_check_cfunc`, `3rd/mruby/mrbgems/mruby-fiber/src/fiber.c`). A compiled `Array#each` or
`Range#each` is a C function, so its frame cannot sit between `resume` and a `Fiber.yield` in the
block.

Today `core_block_guard` (`tools/bc2cpp/codegen_method.rb`) covers this. When a fiber is running
and the block is not known to be yield-free, the entry calls `bc2cpp_core_interpreted`, which
runs the method's saved bytecode through `mrb_exec_irep`. That replaces the C frame with a VM
frame. It works, but the whole body of the method is kept as bytecode.

## Protocol (the same for every owner)

- **Heap state.** The driver makes `st = [next, done, ...]` once per call. `st[1]` is the done
  flag. Any further slots belong to the owner (Range keeps its stop in `st[2]`).
- **Step** (compiled C++, registered privately on the owner as `__bc2cpp_each_step`). It returns the
  element at the cursor and advances it, or sets `st[1]` and returns nil. It returns at once, so no
  C frame is left for the block call.
- **Open** (`__bc2cpp_each_open`, Range only). Decides, once per call and before any yield, whether
  the step covers this receiver. It returns the state, or nil for a case the step does not cover.
  Array's driver builds its state inline (`[0, false]`).
- **Driver** (Ruby, `__bc2cpp_each_driver`, private, compiled into the VM by `mrb_load_string` when
  the registration runs). Array's driver:

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

- **Result.** The driver returns `self`.

## Per-owner forms

`EnumStep::FORMS` maps an owner name to a form: the C step, the C open (or nil), the driver's Ruby
source, and the C++ text they need. An entry takes the form only under the flag, when it is an
instance `each` with a guard. The registration calls
`bc2cpp_enum_step_save(M, c, singleton, name, index, step, open, driver_src)`:

- Array: `(bc2cpp_each_step, nullptr, bc2cpp_each_driver_src)`;
- Range: `(bc2cpp_range_each_step, bc2cpp_range_each_open, bc2cpp_range_each_driver_src)`.

On the first registration, while `each` is still its mrblib body (bytecode), the save helper defines
the step (and the open), loads the driver, and saves the driver in the guard's slot. A second
registration finds the compiled entry and the saved driver already in place, and saves again
without loading anything.

## Where the flag is read

`EnumStep.enabled?` reads `ENV['BC2CPP_ENUM_STEP']` once, when bc2cpp generates code. Nothing
reads it at run time. When it is set, `codegen_emit.rb` registers each form's owner with
`bc2cpp_enum_step_save` instead of `bc2cpp_core_save_interpreted`, and `emit_core_guard_helpers`
appends the save helper and the text of each form used. When it is unset, `EnumStep` adds nothing
to the output (see Measured).

## What changes in the guard

- The prologue is unchanged: `if (M->c != M->root_c && !bc2cpp_block_yield_free(blk))
  return bc2cpp_core_interpreted(M, self, N);`. The guard still runs the proc in its slot through
  `mrb_exec_irep`.
- Under the flag, the slot of an owner's `each` holds that owner's **driver** proc, not its own
  body. For Range the driver runs the saved body for the cases the step does not cover (below).
- Root-context calls and yield-free blocks still run the compiled entry. A blockless `each` under a
  fiber takes the guard (a nil block is not yield-free) and the driver returns `to_enum`.
- Every other guarded core method keeps its saved bytecode.

## Range#each

The body it mirrors is `3rd/mruby/mrblib/range.rb`. That body reads `self.begin`, `self.end` and
`exclude_end?` once, and yields with `block.call`. The open reads the same three through dispatch,
once per call; the driver calls `block.call` too.

**Covered by the step** (the open returns the state):

- Integer begin, Integer end, exclusive: the values from begin up to end.
- Integer begin, Integer end, inclusive with end below `MRB_INT_MAX`: the stop is `end + 1`, boxed
  with `mrb_int_value` (word boxing has a smaller Fixnum range than `mrb_int`).
- Integer begin, nil end (endless): no stop. Past `MRB_INT_MAX` the cursor goes on through
  `Integer#+` (a bignum), as mrblib's `i += 1` does.
- Empty and reversed ranges: the first step is done, so the driver returns `self` without a yield.

**Fallback** (the open returns nil; the driver calls `__bc2cpp_each_plain`):

- A non-Integer begin: String, Float, a `succ`-based object, or nil (a beginless range, which the body
  rejects with `TypeError: can't iterate`).
- An Integer begin with a non-Integer end, e.g. `1..2.5`, which mrblib runs with `succ` and `<=>`.
- A bignum begin or end.
- An inclusive end equal to `MRB_INT_MAX`: mrblib's `end + 1` is a bignum there. The call-site
  loop inline (`RANGE_EACH_INT_MAX` in `codegen_loop_inline.rb`) refuses the same case.
- A blockless `each`: the driver returns `to_enum` before the open, as mrblib does.

`__bc2cpp_each_plain` is an alias of Range#each's mrblib body, made by the driver's source while
`each` is still that body. It is the same proc, so the fallback adds no second copy of the body.

**Result values.** For Integer ranges `StopIteration#result` is the range (`self`). For a String range
mruby's body returns the receiver of `String#upto`, so `('a'..'c').each` ends with `"a"`; the fallback
keeps that value, and MRI returns the range. A Range subclass that overrides `end` (to add one, say)
changes what mruby's body yields, because the body dispatches `end`; the open dispatches the same way,
so the step matches mruby and yields 1, 2, 3. MRI reads the bounds without a call and yields 1 and 2.
The fixture expects mruby's values for both.

**Bytecode size** (measured with the host `mrbc`, no debug info, the mrblib def wrapped in
`class Range ... end` for the body): Range#each's mrblib body is 813 bytes, the Range driver 408
bytes. The Array driver is 309 bytes. The fallback alias keeps the body resident, so under the
flag the driver is added on top of the body rather than replacing it. The guard's saved slot
shrinks; the mrblib bytecode in `libmruby.a` does not. A real reduction for Range#each needs the step
to cover the generic `succ`/`<=>` path too, so the body can go (see Next).

## Designed, not run

- Performance. The step adds one C call and one heap array per element of a fiber's `each`. Not
  measured.
- Game behaviour. The closed builds were compiled and linked; only the fixtures ran.
- Break out of the block: the Range fixture has a `break` in a root block and under a fiber
  (both 20, as in Ruby). Other cases are not covered.
- A Range subclass whose `begin` or `end` raises, or calls `Fiber.yield`. The open dispatches
  `begin`, `end` and `exclude_end?` from C, so a user method that yields there hits the same C-frame
  check as a dispatched `length` in Array's step.
- Stage B2 (the next iterator) and any other method.

## Known limits

- The driver is Ruby compiled with `mrb_load_string`, so the flag needs `mruby-compiler` in the
  build (the closed build has it; the `wio` and `maix` builds may not). Not tested.
- `__bc2cpp_each_driver`, `__bc2cpp_each_step`, and on Range `__bc2cpp_each_open` and
  `__bc2cpp_each_plain`, are private methods, visible to `private_instance_methods`.
- A non-Integer `length` on an Array subclass raises TypeError (`mrb_as_int`). mrblib compares it with `<`.
- The driver is parsed once per VM at registration. Its cost was not measured.
- Range#each's step form is registered only while `each` is still bytecode, as Array's is.

## Next

The recommendation is to take the generic Range path (`succ` and `<=>`, the `(val <=> last) > 0`
checks, and the `str_each` size break) into the step and drop the alias. That would make the driver
the only saved bytecode for Range#each. It moves user `succ` and `<=>` calls into C frames, the
same hazard as an Array subclass's `[]`, so it needs its own fixture. String ranges through
`String#upto` need a separate look.

## Measured

- **Flag unset: byte-identical output** (both owners). A core fixture with `Array#each` and
  `Range#each` generated on the stage-B HEAD and on this branch gives the same `fixture_gen.cpp`
  (`cmp`). The fixture `.mrb` differs only in the directory name in its debug filename.
- **Fixtures, before and after.** The Range fixture on the stage-B tools (HEAD `tools/bc2cpp`, run
  through `BC2CPP_TOOL`) fails 5 checks: the four Range generated-code checks and "the compiled run
  registers the step on Range". Its behavioural comparison passes there, since the saved body is
  mruby's. After, all 33 checks pass, the interpreted and compiled runs print the same, and every
  scenario matches Ruby's own result (with the two mruby-specific values above). The Array fixture
  passes after; its registration regex was updated to the per-owner call shape, and the other
  assertions are unchanged.
- **Mutation.** Changing the Range step's increment to `+ 2` fails "interpreted and compiled runs
  print the same". So the fixture exercises the step, not the saved body.
- **A defect found and fixed while measuring.** The first Range step built the next cursor with
  `mrb_fixnum_value`. Word boxing has a smaller Fixnum range than `mrb_int`, so an endless range
  reaching `MRB_INT_MAX` wrapped to `-1`. The fixture caught it; the step now boxes with
  `mrb_int_value`.
- **Closed builds** (`scripts/bc2cpp/closed_build.bash`, this branch's tree; flag unset and set, built
  in `build-bc2cpp/closed-unset` and `build-bc2cpp/closed-set`). Both succeed.
  - Flag unset: 142 `bc2cpp_core_save_interpreted` registrations, no step registrations;
    `libmruby.a` 115,206,612 bytes.
  - Flag set: 140 `bc2cpp_core_save_interpreted` registrations and 2 `bc2cpp_enum_step_save`
    registrations (Array#each and Range#each); `libmruby.a` 115,234,988 bytes (+28,376 over unset).
  - Not compared with stage B's recorded figures (115,211,836 and 115,226,128): those came from a
    different build, and this unset library differs from them by -5,224 bytes. The cause was not
    checked. The +28,376 covers both owners' steps, opens and driver texts; stage B measured +14,292
    for Array alone.
  - Runtime behaviour of the closed builds was not run; the fixtures ran against the full-core
    library built by the fixture runtime.
