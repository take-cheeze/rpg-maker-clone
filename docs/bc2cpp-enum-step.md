# bc2cpp: the step form of Array#each and Range#each (ENUM_STEP)

Stage B of the external-iteration plan: the step form of `Array#each`, then the same mechanism for
`Range#each`. On by default; `BC2CPP_ENUM_STEP=0` turns it off. Code: `tools/bc2cpp/codegen_enum_step.rb`
(one form per owner), with two hooks in `tools/bc2cpp/codegen_emit.rb`. Fixtures:
`scripts/bc2cpp/enum_step_array_check.rb`, `scripts/bc2cpp/enum_step_range_check.rb` and
`scripts/bc2cpp/enum_step_range_generic_check.rb` (every Range case, the generic path included). The fixtures that
compare with the flag off set it to `0`; the rest of the doc's "flag unset" means `BC2CPP_ENUM_STEP=0`.

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
  body. For Range the driver makes the String#upto call or steps; no range runs the saved body (below).
- Root-context calls and yield-free blocks still run the compiled entry. A blockless `each` under a
  fiber takes the guard (a nil block is not yield-free) and the driver returns `to_enum`.
- Every other guarded core method keeps its saved bytecode.

## Range#each

The body it mirrors is `3rd/mruby/mrblib/range.rb`'s `each`. Under the flag no range falls back to it: the step covers every
case, and the driver keeps no alias of the body (`__bc2cpp_each_plain` is gone). The open makes the body's own dispatch in
the body's order, and the step makes the loop's. The behaviour list and how each item is matched are in "Range generic".

**Covered by the step** (the open returns the state; the step is the loop):

- Integer begin, nil end (endless): the cursor goes on through `Integer#+` past `MRB_INT_MAX`.
- Integer begin, Integer end: `lim` is `end`, or `end + 1` for an inclusive range (through `Integer#+`, so a Bignum at
  `MRB_INT_MAX`); the cursor runs while `i < lim`.
- Any other begin with `succ` (String without `upto`, a user class, a Bignum begin, an Integer begin with a Float or other
  end): the generic loop, with `succ` and `<=>` called from C.
- A begin without `succ` (nil, Float, a beginless range): `TypeError: can't iterate`, raised by the open before any `<=>`.

**Delegated to a Ruby call** (the driver makes it; no C frame): a String begin with a String end, when String responds to
`upto`, calls `begin.upto(end, exclude_end?, &block)`; a String begin with a nil end, when String responds to
`__upto_endless`, calls that. Both are mruby's own String methods (Ruby code in mruby-string-ext), so the block's
`Fiber.yield` has VM frames only.

**Block frames.** The open and the step never run the block. The driver calls `block.call(v)`. Between `resume` and the
block's `Fiber.yield` there are only the driver's VM frames, because the step has returned before the block runs.

**User succ and <=> that suspend a Fiber.** The step calls them through `mrb_funcall` from C, so their frame is on a C
frame. A `Fiber.yield` inside them raises `FiberError: can't cross C function boundary` (`fiber_check_cfunc`,
`3rd/mruby/mrbgems/mruby-fiber/src/fiber.c`), at the `Fiber.yield`, and the error propagates out of `next` or `resume`.
The body lets that yield through, and the element sequence is then corrupted (`e.next` returns the yielded array as an
element). So the change turns silent misbehaviour into an explicit error. The fixture checks both methods (`succ yields`,
`cmp yields`). The compiled entry already calls `succ` and `<=>` from C for a yield-free block, so it raises the same error
today (by reading the code; not run). Blocks that are not yield-free take the driver, where the step now does the same.

**Result values.** The step returns `self`, so `StopIteration#result` is the range for every stepped case. For the
String delegation it is the value `upto` returns, `"a"` for `('a'..'c')`, which the body also returns. MRI returns the range
for both; the fixture expects mruby's values.

**Subclass caveat.** The open and the step dispatch `begin`, `end` and `exclude_end?` as the body does (`self.begin` is a
call), so a Range subclass that overrides `end` to add one yields 1, 2, 3 for `(1..2)`. MRI reads the bounds without a call
and yields 1, 2. The body's behaviour is matched, not corrected.

**Bytecode.** Under the flag the closed build drops the body. The stub rule admits Range#each (`Form#stubs_body`,
`MrblibStubs.stub_keep_reason`), and `bc2cpp_stub_top_mrblib` (build_config.rb) compiles a copy of
`3rd/mruby/mrblib/range.rb` with only `Range#each` emptied, through a wrapper of the build's mrbc. The wrapper is needed
because mruby's `tasks/mrblib.rake` takes its file list from the submodule, which is not edited. Flag unset, neither applies.

## Range generic

Designed from the source (`3rd/mruby/mrblib/range.rb`, `3rd/mruby/src/range.c`, `3rd/mruby/src/numeric.c`,
`3rd/mruby/mrbgems/mruby-string-ext/mrblib/string.rb`). The reference values are the body's, and the fixture runs each case
against the body (interpreted) and the step (compiled); see Measured.

The body, in order. `D(x)` is a dispatch of `x`.

1. Blockless: `to_enum(:each)`. The driver checks this before the open.
2. `val = D(self.begin)`, then `last = D(self.end)`. Both are dispatched, every call.
3. `D(val.kind_of?(Integer)) && D(last.nil?)`: an endless loop, `block.call(i); i += 1`. It never returns normally; `break`
   and a raise leave it. No `<=>`, no `succ`.
4. `D(val.kind_of?(String)) && D(last.nil?)`: `val.__upto_endless(&block)` when `D(val.respond_to?(:__upto_endless))`;
   otherwise the generic loop with the size break.
5. `D(val.kind_of?(Integer)) && D(last.kind_of?(Integer))`: `lim = last`; `lim += 1 unless D(exclude_end?)`; `while i < lim`
   yields; return self. `exclude_end?` is dispatched once; `lim + 1` is `Integer#+` (a Bignum at `MRB_INT_MAX`).
6. `D(val.kind_of?(String)) && D(last.kind_of?(String))`: `val.upto(last, D(exclude_end?), &block)` when
   `D(val.respond_to?(:upto))`, and the call's value is returned; otherwise the generic loop with the size break.
7. `raise TypeError, "can't iterate" unless D(val.respond_to?(:succ))`. No `<=>` has run yet.
8. `return self if D(D(val <=> last) > 0)`. `>` is dispatched on whatever `<=>` returned, so a nil result raises
   `NoMethodError` (`undefined method '>' for NilClass`).
9. `while D(D(val <=> last) < 0)`: `block.call(val)`; `val = D(val.succ)`; for a String range without `upto`,
   `break if D(D(val.size) > D(last.size))`.
10. `block.call(val) if !D(exclude_end?) && D(D(val <=> last) == 0)`; return self. `exclude_end?` is read before `<=>`, so an
    exclusive range makes no final `<=>` call.

**Observable behaviour, and how the step matches it:**

- Return value: `self` for every generic, Integer and endless-String-generic case; the `upto` value for String delegation.
  The step returns `self`; the driver returns the delegated call's value. Endless Integer never returns normally.
- `StopIteration#result`: the each's return value (above). A `break` value replaces it, as for any block.
- `begin` and `end`: dispatched twice, first, before any type check. The step's open does the same, in that order.
- `exclude_end?`: once for an Integer range, once as the `upto` argument, once for generic at step 10, never for endless.
- `succ`: called after the block returns, never before (a raising block sees no further `succ`). The step's advance runs at the
  next step call, which is after the driver's `block.call`.
- `<=>`: once at step 8, once per loop test (step 9), and once at step 10 when the range is not exclusive. The step makes the
  same calls. For `(v1...v3)` with user methods the body's log is: `<=>`, `<=>`, `<=>`, yield 1, `succ`, `<=>`, yield 2, `succ`,
  `<=>`, `exclude_end?`. The fixture compares this log for both runs.
- Results of `<=>`: `<` and `>` and `==` are dispatched on the result, so a nil result raises `NoMethodError` naming the operator
  (`undefined method '<' for NilClass`, `'>'`). Integer results are compared natively, as the VM compares Fixnums.
- Nil or incomparable end: a nil end with a generic begin is endless, so step 8 runs `<=>` with nil and raises the NoMethodError
  above. An Integer begin with a String end (`1..'a'`) cannot be constructed: `Range.new` raises `ArgumentError: bad value for
  range`, because `Range.new` calls `<=>` once (`r_check`, `3rd/mruby/src/range.c`). Nothing in `each` changes that.
- Errors and classes: `TypeError` ("can't iterate") for a begin without `succ`; `NoMethodError` for a nil comparison result;
  any exception from a user `succ`, `<=>`, `size` or the block propagates unchanged. A user `succ` or `<=>` that calls
  `Fiber.yield` raises `FiberError` under the step (above).
- Beginless range (nil begin): `TypeError: can't iterate` (step 7).
- Float begin (`1.0..3.0`): `TypeError: can't iterate`, because Float has no `succ` in mruby (step 7). Integer begin with a Float
  end (`1..2.5`): the generic loop, yielding 1, 2 (step 5 does not apply, since `last` is not an Integer).
- Bignum: `kind_of?(Integer)` is true for a Bignum begin or end, so steps 3 and 5 apply, with `<` and `+` dispatched on the
  Bignum (the step does not use the native path for those). `(9223372036854775806..9223372036854775808)` yields three values.
- Empty and reversed ranges: no yield; step 8 (generic) or the Integer loop finds nothing to do.
- `String#upto` and `__upto_endless` run in mruby-string-ext's Ruby, so `succ` and `<=>` inside them are Ruby calls. Their
  results come back through the driver.

## Designed, not run

- Performance. The step adds one C call and one heap array per element of a fiber's `each`, and the open makes about six
  dispatches per call (begin, end, the kind checks, exclude_end?). Not measured.
- Game behaviour. The closed builds were compiled and linked; only the fixtures ran.
- Break out of the block: the fixtures have a `break` in a root block and under a fiber (both 20, as in Ruby). Other cases
  are not covered.
- A Range subclass whose `begin` or `end` calls `Fiber.yield`: the open dispatches them from C, so this is the same
  `FiberError` as for `succ` and `<=>`. Designed, not run.
- Stage B2 (the next iterator) and any other method.

## Known limits

- The driver is Ruby compiled with `mrb_load_string`, so the flag needs `mruby-compiler` in the build (the closed build has
  it; the `wio` and `maix` builds may not). Not tested.
- `__bc2cpp_each_driver`, `__bc2cpp_each_step`, and on Range `__bc2cpp_each_open`, are private methods, visible to
  `private_instance_methods`.
- A non-Integer `length` on an Array subclass raises TypeError (`mrb_as_int`). mrblib compares it with `<`.
- The driver is parsed once per VM at registration. Its cost was not measured.
- Range#each's step form is registered only while `each` is still bytecode, as Array's is.
- The generic `String` loop (`str_each`) runs only where `String#upto` is undefined. The fixture undefines it last; the closed
  build has mruby-string-ext, so the closed build never reaches it.

## Next

- Array#each: the same stub would drop its saved body, since its driver has no alias. Not done here (the change is for Range).
- The two yield cases are a behaviour change, not a regression of the step: a user `succ` or `<=>` that suspends a fiber now
  fails with `FiberError`. Whether the Range step should keep the body for such ranges is a design question; the answer
  here is no, because the body cannot be kept (it is dropped under the flag).

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
