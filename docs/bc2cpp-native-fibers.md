# Native Fiber continuations

bc2cpp's closed builds compile every retained mrblib body and every Fiber support
program into native continuation branches. Fiber execution retains no instruction
byte arrays and does not compile Ruby source at registration time. This includes
nested iterators, Enumerator, escaping blocks, exception handlers, the shared
resumable driver, and the per-method drivers that were not eligible for optimized
resumable variants.

The ordinary interpreter builds are unchanged. This guarantee applies to the
statically known program in a bc2cpp closed build; it does not make arbitrary
Ruby supplied at runtime ahead-of-time compilable.

## Execution

`tools/bc2cpp/native_vm.rb` consumes mrbc's C-struct output at build time. It
preserves constants, symbols, closure relationships, register counts, and source
locations. It removes each instruction array, separates its exception-handler
table, and emits C branches with constant operands into `dispatch.inc`.

The branches enter mruby's existing operation implementations directly. They
share its call frames, closure environments, Fiber context switching, and
exception/nonlocal-return unwinding. There is no instruction-byte fetch or operand
decoding on this path. This is a native backend for the frame machine, rather
than removal of the frame machine itself.

The optimized bc2cpp bodies remain the fast path. Bodies that previously needed
an interpreted fallback now use these native continuations. The historical
`bc2cpp_core_interpreted` helper name does not indicate bytecode execution in a
native build: its saved proc holds native metadata.

`NativeVM.configure` enables the backend for every bc2cpp build. It transforms
mrblib C output, compiles generated Fiber support programs at build time, and
makes the VM object depend on the combined continuation dispatch header. mrbc's
own bootstrap remains an ordinary interpreter. Ordinary `BC2CPP_ENUM_STEP=0`
experiments also use native retained bodies when the enclosing build is native.

## Program counters and safety

A native proc's `mrb_irep::native` points to its native program metadata. Its
program counter is an integer continuation token represented in the existing PC
field. It is never dereferenced. `mrb_irep_pc`, `mrb_irep_pc_offset`, and
`mrb_irep_pc_add` perform token arithmetic without pointer arithmetic outside an
instruction array. The same helpers preserve ordinary bytecode PC behavior.
Continuation offsets and operands are bounded by mrbc's existing format; no
conversion to a Ruby integer is involved, including on 32-bit targets.

The generator verifies its instruction schema against the pinned mruby, rejects
truncated programs, and rejects native program ID collisions. Native programs
cannot be exported as bytecode by the dump API. Debug/source metadata and Proc
argument introspection remain available. Code-fetch hooks must inspect
`irep->native` and use the PC helpers rather than dereferencing a native PC.

`MRB_NATIVE_VM_REQUIRE` rejects any attempted bytecode execution inside a Fiber.
It is enabled in closed builds so a missed fallback fails visibly instead of
silently weakening the guarantee. Existing C-boundary restrictions still apply:
a C function that keeps its own stack frame cannot suddenly suspend safely.

## Validation

Run `ruby scripts/bc2cpp/native_fiber_check.rb` with the host mrbc and a full-core
reference build available as for the other bc2cpp fixtures. The check builds a
native runtime and compares its output with interpreted mruby, both with and
without optimized core wrappers. It covers the iterator variant scenarios,
custom nested `each`, keyword/rest arguments, exceptions after suspension,
`ensure`, nonlocal returns, `catch`/`throw`, escaping closures, lazy Enumerator,
Fiber resume/transfer, and extended operands. GC runs between resumes.

A code-fetch audit counts native and bytecode steps inside Fibers and requires
positive native execution with zero bytecode execution. A separate source audit
rejects retained generated instruction arrays and runtime source/bytecode loads
in generated Fiber support. The closed build and host sweep exercise the same
native-only runtime against the engine and every game map.
