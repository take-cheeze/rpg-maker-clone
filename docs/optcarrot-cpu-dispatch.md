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
