# Placement harness: the gates for in-frame object placement

**Status: the gates exist and run on the heap build. In-frame placement is NOT implemented.** The experimental flag
`BC2CPP_EXPERIMENTAL_INFRAME_PLACEMENT=1` is refused by the generator (`tools/bc2cpp/inframe_placement.rb`, a stub).
Shipped codegen is unchanged, and it stays unchanged with the flag unset or set to `0`.

This is phase 2 of the placement project. [Phase 1](bc2cpp-immediate-ivars.md) classified confined `new` sites by
whether every ivar store is immediate. This phase builds the harness that any later placement must pass, and proves
the harness on a narrow class. A placement may enable only for a site that passes every gate below.

## The gates

| Gate | What it requires | Where it runs now |
| --- | --- | --- |
| Static | the site is `confined` in the escape report and its `ivars` row is `immediate` | `placement_harness_check.rb`, section B |
| 1. Frame-exit tripwire | after the frame returns, a walk of the live heap finds no ivar value or array element that points into the dead stack | section C (positive run), section D (self-test) |
| 2. GC at frame exit | a full GC right after the call; the live-object count after equals the count before (the call leaves nothing behind) | section C |
| 3. ASan, `detect_stack_use_after_return=1` | any access through a pointer kept past the frame is a report at the access | section C, smoke run only (see Limits) |
| 4. Heap-versus-stack differential | the same generated function built with the object on the heap and placed in-frame gives identical outputs and live counts | not run: placement is a stub (section E) |

Gate 2 also covers the "GC on every allocation" mode in the design doc. That mode needs a libmruby built with
`MRB_GC_STRESS`, which this check does not build, so it is not run.

## What the check does

`scripts/bc2cpp/placement_harness_check.rb` (run in the bc2cpp checks job with `MRBC` and `BC2CPP_MRUBY_FULL` set)
compiles a small Ruby fixture. `PlUse#local_cell` and `PlUse#plain_pair` each create one `PlCell` that is used only in
that method. `PlCell` stores integers, `false` and `true` in its ivars. Two negative methods, `PlLeakUse#leak_global`
and `PlLeakUse#leak_array`, keep their object in a global or an array past the frame.

- **A. Flag identity.** Generation with the flag unset and with `0` produces byte-identical C++. Generation with `1`
  aborts with a message that names the flag, so the request is never silently ignored.
- **B. Static gate.** The positive method passes (confined, immediate). Both negative methods fail with the verdict
  `escapes`. The check passes only when the negatives fail for that reason.
- **C. Runtime gates.** The fixture is built against the full-core libmruby, once for the compiled and once for the
  interpreted VM. Each call runs with a full GC before it, a full GC after it, and a tripwire scan. Every gate line
  must read `leaked=0 dangling=0`, and the compiled and interpreted outputs must match. The driver is built with
  `-fsanitize=address,undefined` when the toolchain can build and run it; otherwise the check prints an explicit SKIP
  for the sanitizers and runs without them.
- **D. Tripwire self-test.** A separate process plants a stack object's address in a heap object's ivar, then scans.
  The scan must report it. This shows the tripwire can fail. The process ends with `_Exit`, because the planted
  reference is dead memory that a later GC would traverse.
- **E. Differential.** Printed as an explicit SKIP while placement is a stub. Setting `PLACEMENT_HARNESS_REQUIRE=1`
  turns the SKIP into a failure. Set it in the same change that enables placement, so the differential cannot be
  left out.

Run it from the repository root:

```bash
MRBC=path/to/host/mrbc BC2CPP_MRUBY_FULL=path/to/full-core-build ruby scripts/bc2cpp/placement_harness_check.rb
```

Without `MRBC` the check prints a SKIP and exits 0. With `MRBC` set but not runnable it fails.

## What the tripwire scans

`mrb_objspace_each_objects` visits every object slot on the GC pages. For each live `MRB_TT_OBJECT`, the tripwire
scans its ivar values (`mrb_iv_foreach`). For each live `MRB_TT_ARRAY`, it scans the elements. An immediate value is
skipped. A heap pointer is dangling when it lies below the scanner's own frame and within 8 MiB of the scenario frame,
which is the native stack the scenario calls into. Heap memory never lies in that window, so a hit is a stack address.

## Limits

These are not covered by the check. Each one is a condition a placement PR must address or argue away.

- **Heap only.** The tripwire does not walk the VM's register stacks, the global variable table, or C locals. A stack
  reference held only in a live register is not seen. The design needs a root walk before any placement is enabled.
- **Blind spot inside the scanner's frame.** A dead frame's object that lies in the scanner's own frame (a few hundred
  bytes below the scenario) is not reported. The self-test plants its object 8 KiB deep, outside that spot. A
  production gate must run the scan from a frame below the placed frame's full extent, which needs the frame size
  from codegen.
- **The scan runs a GC.** `mrb_objspace_each_objects` calls `mrb_full_gc` itself. A C local that holds the only
  reference to an object is then collected. The harness roots its objects with `mrb_gc_protect`. A placement gate
  must do the same, or the scan can hide the object it is looking for.
- **Native stack only.** `detect_stack_use_after_return=1` moves address-taken frames to ASan's fake stack, which the
  window does not cover. The native gates therefore run with `detect_stack_use_after_return=0`. The `=1` run is a
  smoke run of the same binary: it must exit cleanly, report no sanitizer error, and show `leaked=0`. It does not
  exercise gate 3, because nothing in the heap build accesses a dead frame. Gate 3 needs a placed build.
- **No GC-stress build.** Gate 2 runs one full GC on each side of the call. The stress mode (`MRB_GC_STRESS`, a GC on
  every allocation) is not built.
- **Narrow class.** One class, two methods, integer, `false` and `true` ivars, no blocks, no arguments stored, no
  closures. Results of sends on the object are not used: the escape analysis treats a send's result as possibly
  aliasing the receiver, so a fixture that returns `c.peek` is `not_immediate`. The first fixture that did this was
  rejected by the fact, which is the conservative behaviour the fact is meant to have.
- **No placement.** The differential (gate 4) and any codegen are absent. A passing run shows the gates work on the
  heap build and that the negative fixture is refused. It shows nothing about a placed object's behaviour.

## Setup notes

- The check uses the mruby build from `3rd/mruby`. In a worktree, `3rd/mruby` and the other submodule placeholders
  must point at a checkout. Do not stage them.
- `BC2CPP_SIG_DIRS` is set to empty by the check, as the immediate-ivars check does, so the declarations of the
  engine's signatures are not read.

## Files

- `tools/bc2cpp/inframe_placement.rb`: the flag and the refusal (the TODO for the placement codegen is here).
- `scripts/bc2cpp/placement_harness_check.rb`: the check.
- `scripts/ci/bc2cpp_check_policy.yml`, `.github/workflows/build.yml`, `scripts/coverage/report.rb`: the registration.
- [`bc2cpp-immediate-ivars.md`](bc2cpp-immediate-ivars.md): the static fact the static gate reads.
