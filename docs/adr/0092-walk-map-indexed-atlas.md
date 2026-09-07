# 92. A palette-indexed tile atlas for the walk-map format

Date: 2026-09-07

## Status

Accepted

## Context

The minimal walk engine of ADR 61 and ADR 91 spends almost all of its RAM on
one thing. On the iPod nano 7G, of ~209 KB of `.bss`, the tile atlas was
131 KB; on the Wio Terminal, of the ~100 KB its caps allowed, 82 KB. Every
other buffer — the map cells, the passability mask, one composited tile — is
noise beside it, and the atlas is what decides how big a map either device
can take: the nano refuses a map past 256 distinct composited tiles, and the
Wio was down at 160 with a 64x64 map bound, which turned real maps away.

Format v2 stores a tile pixel as 16-bit ARGB1555, already half of what the
first slice wrote. But the colour depth was never the source data's: **an RPG
Maker chipset is a 256-colour indexed image.** RPG_RT's own editor will not
take anything else, and the exporter reads that palette out of the PNG
already — `RGSS::Bitmap`'s decoder expands it to RGBA, and the export then
re-packs each expanded pixel into 15 bits of colour, one pixel at a time. The
one thing the format did not carry was the very structure the source came
with.

And a single map uses only a slice of the chipset. Measured across all 535
Nepheshel maps the exporter accepts, a map's composited tiles hold **1 to 136
distinct colours** — never a quarter of what a one-byte index can address —
and at most 146 atlas entries.

## Decision

Format **v3**: a tile pixel is one byte, an index into a per-map palette
carried in `map.bin`'s header.

- `map.bin` gains `u16 palette_count` and `palette_count` ARGB1555 entries,
  after the fixed header and before the cell arrays. Index 0 is the
  transparent slot, so a pixel's "nothing here" is the same test as "the
  palette says nothing here", and opaque colours run 1..255.
- `tiles.bin` becomes `tile_count * 256` bytes.
- The exporter builds the palette as it composites, and **refuses** an export
  needing more than 255 opaque colours rather than dithering or quantising —
  the same "refuse, do not truncate" rule the map-size caps already follow.
  A chipset that trips it is not a 256-colour image and is not what RPG_RT
  itself accepts.
- `rw_open` validates `palette_count` (1..256, and actually present in the
  file) and `rw_palette_colour` resolves an index, treating index 0 and any
  index past the palette as transparent — so a malformed export cannot walk
  off the buffer.

This is **lossless**: the exported render of Nepheshel's map 1 is byte-for-byte
the image v2 produced. The palette is the source's own colours, not a
quantisation of them.

### What it buys

| | v2 | v3 |
| --- | --- | --- |
| nano 7G `.bss` | 214,628 B | **149,612 B** |
| nano 7G `.text` | 4,712 B | 4,808 B |
| nano 7G packed `.hbapp` | 4,940 B | 5,040 B |
| Wio Terminal caps | 64x64 map, 160 tiles (~100 KB) | **96x96 map, 192 tiles (~95 KB)** |
| `tiles.bin`, Nepheshel map 1 | 70,144 B | 35,072 B |

Measured by rebuilding the nano app against a real NanoApps checkout with
`arm-none-eabi-gcc` 13.2. 96 bytes of code — the palette lookup — buys 63 KB
of working set on the nano, and lets the Wio take a map 2.25x larger in area
with *less* RAM than before: of the 29 Nepheshel maps bigger than 64x64, 23
now fit that board, where none did. Cumulatively, since ADR 61's first slice, the
nano's `.bss` has gone 344 KB → 150 KB while the app gained transparency, a
backdrop colour and a second target.

The nano's caps are deliberately left where they are rather than raised to
spend the saving: nothing in the test data needs more than 146 atlas entries,
so the headroom is better left as headroom.

## Consequences

- **A third pass over the pixel format is unlikely to be worth it.** The
  remaining atlas is one byte per pixel of genuinely distinct image data;
  below this lies compression (RLE, a tile-level cache), which trades the
  format's defining property — a flat array the device indexes with no
  decode step — for a smaller file. That is not a trade this engine should
  make while it fits.
- **The palette is per map, not per chipset.** Two maps sharing a chipset
  export different palettes, because each carries only the colours its own
  tiles use. Nothing on-device cares, and a future multi-map bundle would
  need to decide whether to merge them (a shared palette across maps of one
  project would likely still fit in 256).
- **The exporter can now refuse for a new reason.** A truecolour chipset —
  which RPG_RT itself would not load — is rejected with a message naming the
  cause instead of silently posterised.
- The device code got slightly *simpler*, not more complex: compositing two
  layers is now two byte comparisons against index 0 and one palette lookup,
  where v2 tested an alpha bit in each 16-bit pixel.
