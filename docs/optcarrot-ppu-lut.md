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
