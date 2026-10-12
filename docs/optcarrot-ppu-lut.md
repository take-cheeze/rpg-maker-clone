# Optcarrot PPU table startup

The mruby probe bundles construct the same upstream `PPU::TILE_LUT` using eight
fixed pixel expressions for each pattern, then build independent rows for the
three nonzero attributes from those base colors. This avoids repeated bit
extraction and nested block calls, including the original transpose passes.
Zero remains transparent; attribute bits only affect colors 1, 2 and 3.

The validated upstream generator uses nonnegative patterns `0...0x10000` and
bit positions `0..15`, so `(i >> bit) & 1` matches bit indexing. All operands fit
32-bit mruby integers. Each of the four attribute tables owns 65,536 distinct
rows of eight pixels; no mutable row is shared between patterns or attributes.

This improves startup, without changing CPU dispatch or emulation methods.
CRuby's comparison bundle retains the upstream generator. Set
`OPTCARROT_ORIGINAL_LUT=1` to restore upstream construction in the mruby bundles.
The sealed benchmark uses the same bundle builder, so its analyzed compilation
input and embedded runtime use the same generator.

`OptcarrotPPULUT.transform` requires the exact original generator, including
its bounds, and rejects missing, duplicated or changed generators. It leaves
the upstream submodule untouched. Run `ruby scripts/optcarrot/ppu_lut_check.rb`
to compare all 2,097,152 pixel values and dimensions against upstream, verify row
independence and mutation isolation, and check source drift and bundle modes.
The Optcarrot CI shard runs this check.

Local release validation used the same existing mruby binaries and ROM for
180 headless frames, alternating upstream and factored bundles. The static
bc2cpp comparison used three pairs; the interpreter used two pairs.

| Runtime | Upstream median wall time | Factored median wall time | Upstream wall FPS | Factored wall FPS |
| --- | ---: | ---: | ---: | ---: |
| mruby + static bc2cpp | 2.891 s | 1.300 s | 62.26 | 138.50 |
| mruby interpreter | 8.618 s | 6.998 s | 20.89 | 25.72 |

All ten runs returned checksum `59662`. The static whole-process improvement
was 2.22x; the interpreter improvement was 1.23x. Optcarrot's emulation-only
reported FPS stayed similar (roughly 194–201 static, 26–27 interpreted): this
change reduces table initialization, rather than making steady emulation faster.

## Bytecode IR lowering

The ordinary compiled probe accepts `OPTCARROT_IR_LUT=1`. It extracts the
original generator into `PPU.__bc2cpp_tile_lut` and retains it as the
interpreter and runtime guard fallback. This extraction is a source scaffold,
not the optimization: `BytecodeIR::TileLUT` recognizes the complete decoded
method tree against the canonical generator, including register operands,
child indices, symbols, pools, control flow and absence of catch handlers.
Any generator drift refuses native lowering.

The compiled gem installs this one helper before the class assigns `TILE_LUT`.
Native C++ builds ordinary mruby Arrays, extracts base colors once and creates
independent rows for the remaining attributes. Runtime guards preserve dynamic
Ruby behavior by declining installation or calling the original helper if
core methods change. Integer bit indexing must be either the unchanged
bootstrap implementation or the exact decoded probe shim, whose shifts and
mask operators are guarded too. No arithmetic exceeds 65,535.

This opt-in ordinary-host path has a distinct `irlut` build target. Sealed
mode is refused until it has a matching bootstrap protocol. The existing
source optimization stays the default. No steady-emulation improvement is
claimed: this migration targets initialization.

`MRBC=/path/to/mrbc ruby scripts/optcarrot/ppu_ir_lut_check.rb` checks decoded
refusal cases. Add `MRUBY_BUILD=/path/to/compatible/mruby/build` to compile
the emitted native builder and compare all 2,097,152 pixels with upstream,
check every row identity and mutation isolation, and test changed core
method fallback both during installation and on subsequent calls.

The bootstrap method snapshots belong to the probe's single mruby VM per
process. Embedding this helper in a process with multiple independent VMs
requires per-VM storage before this protocol can be reused.

Local initializer-only comparison used one compatible optimized native mruby
host with a 16,384-pointer gray stack and three alternating fresh-process
pairs. Both paths retained all four final tables and validated their shape
and final row. Median generation time was 110.37 ms for the previous factored
Ruby algorithm and 21.54 ms for native IR lowering (5.12x, about 88.83 ms saved).
Other agent builds ran on the shared host, so these are indicative startup
measurements, not a controlled whole-emulator FPS comparison.

The nightly Optcarrot shard runs the native check after its first ordinary
probe benchmark, reusing that interpreter build and its exact ABI flags and
regexp gem. Missing native libraries fail the check; an explicit direct
IR-only invocation without `MRUBY_BUILD` reports the native half as skipped.

The ordinary runner passes its selected compiler path explicitly to the IR
initializer proof, so `OPTCARROT_IR_LUT=1` works with the default probe compiler
when `MRBC` is unset. The check covers this path in an isolated subprocess.

The full release preset was then compared in three alternating pairs on the
Ryzen AI MAX+ 395 host, without concurrent compiler jobs. Both binaries used
static CPU dispatch, the synchronous PPU, bytecode IR method inlining and a
16,384-pointer gray stack. Only table initialization differed. Whole-process
wall time includes startup; each process retained the complete table.

| Workload | Factored Ruby LUT | Native IR LUT | Factored / native wall FPS |
| --- | ---: | ---: | ---: |
| 180 frames, cold | 0.9508 s | 0.8478 s | 189.32 / 212.32 |
| 1,800 continuous frames | 7.1957 s | 7.0762 s | 250.15 / 254.37 |

All twelve checksums matched (`59662` at 180 frames, `60838` at 1,800).
Cold wall time improved by 12.1% as a ratio, saving about 103 ms. The longer
run still includes one initialization; its 1.7% difference does not establish
faster steady emulation. The advertised full-preset runner also passed with
`MRBC` unset and installed 356 compiled methods.
