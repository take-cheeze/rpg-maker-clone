# Generated register declarations

Ordinary compiled methods and fallback block functions initialize argument
registers directly from their parameters. Native arguments use the same boxing
operations and parameter order as before; rest, optional and explicit block
slots retain their existing positions. Other registers still start as nil.

After the method body is emitted, bc2cpp drops nil-only declarations whose
register identifier occurs nowhere else in that body. Address-taken registers
and references in exception or block glue are retained. The scan also counts
comments and string literals, so it can conservatively retain extra declarations.
It does not remove assignments or perform bytecode liveness analysis.
Resumable methods keep their separate frame-based register assembly.

For a local full-world rpg2k generation, this removed 7,520 lines and 229,623
bytes (1.2% of the original source). This is a source reduction; optimized
binary size and compile-time benefits depend on the C++ compiler.

`scripts/bc2cpp/arg_shapes_check.rb` compares interpreted and compiled arguments,
conditional nil locals and captured locals. Its native-argument case checks
fixnum, float and bool boxing. The full compiled-core mruby suite checks the
remaining core methods and Fiber behavior.

## Dead copies and constant loads (REGISTER_FLOW)

The step above only removes declarations. A second pass, `RegisterFlow`
(`tools/bc2cpp/register_flow.rb`, ADR 0415), runs on each ordinary compiled
method after all of its instruction texts exist and removes assignments the
declarations scan cannot see:

- **Dead writes.** A backward liveness fixpoint over the method's
  `BytecodeIR` CFG drops a `MOVE`, `LOADI*`, `LOADL`, `LOADSYM`, `LOADNIL`,
  `LOADSELF`, `LOADTRUE` or `LOADFALSE` whose register no path reads before it
  is overwritten or the method returns.
- **Copy propagation.** `rD = rS;` is removed when every reader of `rD` is a
  plain-operand instruction (`MOVE`, `RETURN`, `JMPIF/JMPNOT/JMPNIL`,
  `SETIV/SETGV/SETCV/SETCONST`) that can read `rS` instead: the copy reaches it
  on every path and `rS` is not written in between.

What a register reads and writes is taken from the emitted C++ text of each
instruction, not from the opcode: only a text of the exact shape
`  rD = <expression>;` is a definition, and any other text reads every register
it names. A method is left untouched when it has a `goto` the IR does not
explain (an inlined block loop that jumps between instruction texts), a
reference alias, a catch handler the handler model below does not cover, or is
resumable. `r0`, registers a nested block reaches by upvar, registers whose
address is taken (`&rN`) and registers redeclared inside a text are never
removed or substituted. Window consumers (`SEND`, `ARRAY`, `ADD`, ...) keep the
copies that feed them.

**Rescue regions (handler edges).** A `begin ... rescue` region is emitted as a
glue at its begin address that runs the try body under `mrb_protect_error`, and
the clause tests follow it. The pass models the exception path as one edge from
every instruction the region protects (the half-open range `[begin, end)`) to
the region's except address, which the IR reads as an ordinary handler edge
(`BytecodeIR`, `include_handlers:`). A write is never killed along that edge: a
raise can come before the write completes, so the handler still sees the value
the write replaced. The model applies only when all of these hold, and any
other handler refuses the method:

- every catch handler is a rescue region codegen recognized, one for one (same
  begin, end and target), and the IR's handler targets resolve;
- each glue names every outer register its try body reads: a saved copy
  (`rN`) or a `&rN` alias. Argument values reach the try body through the
  method's parameters, not through a register name, and the pass never changes
  a parameter;
- every instruction in a protected range except the glue emitted no text, so the
  outer function enters a handler only through the glue.

Ensure regions and methods with an ensure guard are not optimized, as before.
`BC2CPP_REGISTER_FLOW_HANDLERS=0` refuses every handler method again;
window mode (`BC2CPP_REGISTER_FLOW_WINDOWS=1`) keeps refusing them.

`BC2CPP_REGISTER_FLOW=0` turns the pass off and the generated C++ is then
byte-identical to the output without it; `BC2CPP_REGISTER_FLOW_STATS=1` prints
the counters at exit. `BC2CPP_REGISTER_FLOW_WINDOWS=1` is an experimental,
default-off extension that also rewrites reads inside window consumers; it is
exercised by the same check but not by default CI builds.

Measured on the full closed-world generation (`coverage_report.rb`, 7,622
compiled methods, kill switch on versus off at the same revision):

| | off | on |
| --- | ---: | ---: |
| lines | 409,582 | 408,906 (-676, -0.17%) |
| bytes | 19,954,696 | 19,942,878 (-11,818, -0.06%) |
| `rN = rM;` copies | 20,825 | 20,336 |
| `mrb_value rN = mrb_nil_value();` declarations | 15,000 | 14,817 |

1,094 methods changed; 1,352 `MOVE`s, 6 `LOADI` and 2 `LOADNIL` were dropped
and 1,227 copies propagated; 650 methods were refused for a `goto` and 430 for a
handler. Most copies stay because they feed argument windows. The experimental
window mode on the same input gives 404,626 lines (-4,956 against off, -1.2%),
19,876,990 bytes (-0.39%) and 16,680 copies. The optimizer already removes these
stores: compiling the whole output with `g++ -O1 -c` gives the same `.text` (6,142,800
bytes off, 6,142,782 on), so the gain is source size and parse time, not code size.
`scripts/bc2cpp/register_flow_check.rb` holds hand-built soundness shapes and a
compiled-versus-interpreted run with the pass on, off and in window mode.
