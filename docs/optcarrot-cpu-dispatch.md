# Optcarrot CPU dispatch specialization

See [ADR 0401](adr/0401-optcarrot-static-cpu-dispatch.md) for the scope and
soundness contract.

`OPTCARROT_STATIC_DISPATCH=1` enables a mechanical CPU dispatch specialization
in the Optcarrot probe. The bundle builder and compiled runner use the same
`OptcarrotCPUDispatch.transform` helper. The default keeps the existing positional
`send` dispatch for benchmark comparisons.

The helper loads the upstream CPU's complete 256-entry `DISPATCH` table under
host Ruby and groups equal entries into opcode `case` arms. Read, write,
read/write, accumulator and no-op wrappers expand into their original ordered
operations with named calls, including addressing-mode flags and store methods.
Both the outer opcode dispatch and the nested instruction dispatch therefore
become statically visible to bc2cpp. Upstream Optcarrot files remain untouched.

This transformation assumes the probe's fixed CPU implementation and opcode
table: changing `DISPATCH` or replacing the operation wrappers at runtime is
outside the probe contract. The build rejects incomplete opcode tables,
unrecognized argument shapes, changed upstream wrapper bodies and a missing or
duplicated dispatch site.

Run `ruby scripts/optcarrot/cpu_dispatch_check.rb` to compare all 256 opcodes
against the upstream wrapper bodies. The check observes addressing flags, method
call order and accumulator/no-op state. Frame checksum comparisons in the
compiled probe cover actual CPU and peripheral execution.

Local GCC 15 validation used three alternating 180-frame runs of the compiled
dynamic and static binaries with the same generated bundle and `Lan_Master.nes`:

| Compiled CPU dispatch | Median wall time | Median wall FPS |
| --- | ---: | ---: |
| Dynamic | 5.196 s | 34.64 |
| Static | 2.817 s | 63.90 |

All six runs returned checksum `59662`, a 1.84x compiled speedup. This does not
imply the same benefit in the interpreter: the full runner's static interpreted
bundle took 21.50 s, so specialization remains opt-in. Whole-process wall timing
uses a monotonic clock and includes startup; the shim's printed FPS is separate.

## Decoded bytecode dispatch experiment

Run `BC2CPP_IR_CPU_DISPATCH=1 ruby tools/optcarrot_probe/compiled_run.rb FRAMES ROM`
with the probe's usual build settings to optimize CPU dispatch after bytecode
decoding. This mode takes precedence over `OPTCARROT_STATIC_DISPATCH=1` and
preserves upstream CPU source and wrapper arithmetic. It inserts guarded literal
calls into the decoded instruction graph before compiler analyses, including the
computed sends inside instruction wrappers. Unmatched names and argument counts
retain the original dynamic operation.

The fixed probe acknowledges its native core with
`BC2CPP_OPTCARROT_FIXED_CORE=1` for the compiler. Other compiler hosts must not
claim that contract unless their native core preserves Array length, Symbol and
Integer equality and Kernel send, and benchmark method definitions remain fixed
without instance singleton replacements. Ruby replacements withdraw the optimization.
The splat coercion and Array copy remain intact. Large rewritten wrappers may
exceed method inlining's size limit; this experimental mode has no established
speedup over static source dispatch. See
[ADR 0422](adr/0422-optcarrot-cpu-dispatch-ir.md).

The guarded IR pass groups outer dispatch arms by argument count. It reads the
copied Array's length once and compares each distinct arity once; after a
matching group exhausts its Symbol names, it goes directly to the original
splat fallback. Nested fixed-argument wrappers also include guarded literal
calls to `store_mem` and `store_zpg`. Common load/store and addressing names
are tried earlier without changing fallback behavior or hiding calls from
compiler analyses.

A paired measurement on 2026-10-13 used Lan_Master, release `-O3`, a 16384-entry
mruby gray stack, synchronous PPU, `BC2CPP_IR_CPU_DISPATCH=1` and
`BC2CPP_IR_INLINE=1`. Both binaries came from compiler revision `8beff37c`, with
only this guard factoring/storage-arm change applied to the second binary.
Three pairs alternated execution order on a quiet host; wall time includes
startup and shutdown.

| Frames | Original CPU IR median wall FPS | Factored CPU IR median wall FPS | Change |
| --- | ---: | ---: | ---: |
| 180 | 144.19 | 148.69 | +3.1% |
| 1800 | 64.79 | 66.20 | +2.2% |

All runs returned checksums 59662 and 60838 respectively. Complete final
pixels, audio, RAM and CPU/PPU registers matched at 2, 180 and 1800 frames.
These measurements compare two experimental CPU IR implementations; they do
not establish a speedup over source-specialized CPU dispatch, which remains
the faster preset. The IR path still copies the splat Array per opcode and
retains large wrapper graphs. Allocation/GC and later game workload may
contribute to the lower long-run throughput, but were not profiled here.
