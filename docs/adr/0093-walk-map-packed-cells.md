# 93. Two and a half bytes per map cell

Date: 2026-09-07

## Status

Accepted

## Context

ADR 92 halved the walk engine's tile atlas by storing a pixel as a palette
index, which moved the bottleneck: on the iPod nano 7G, `map.bin` became the
larger half of the budget at 82 KB of ~146 KB, and the atlas the smaller at
65 KB. Almost all of `map.bin` is three per-cell arrays, and at 128x128 they
cost 82 KB on their own.

A cell was five bytes — `u16` lower-layer atlas index, `u16` upper, `u8`
passability — and none of the three needs its width:

- An **atlas index** addresses composited tiles, and the export caps those at
  256. Measured across all 535 Nepheshel maps the exporter accepts, the
  largest index any map actually references is **145**.
- **Passability** is four direction bits, checked by
  `scripts/export_nano7_map_check.rb` since the format's first version. Across
  the same 535 maps, **zero** cells carry a bit outside the low nibble.

## Decision

A cell costs **2.5 bytes**, and the format becomes v4:

- `lower` and `upper` are one byte per cell. `RW_UPPER_NONE` is `0xFF`, so an
  export holds at most 255 atlas entries (0..254) — `RW_MAX_TILES`, which
  `rw_open` now validates and the exporter's per-target caps respect.
- `passable` is a nibble per cell, two cells to a byte, the even cell in the
  low half. A map with an odd cell count pads the last byte's high nibble,
  which no cell reads.
- `RW_MAP_BYTES_PER_CELL` is gone; `RW_MAP_CELL_BYTES(cells)` computes the
  array size, and both firmwares size their buffers with it.

Lossless again: the exported render of Nepheshel's map 1 is byte-for-byte the
image v2 and v3 produced, and every cell value round-trips identically
(checked against v3 exports of maps 1, 12 and 204).

### What it buys

| | v3 | v4 |
| --- | --- | --- |
| nano 7G `.bss` | 149,612 B | **108,396 B** |
| nano 7G `.text` | 4,808 B | 4,824 B |
| nano 7G packed `.hbapp` | 5,040 B | 5,056 B |
| Wio Terminal caps | 96x96 map, 192 tiles (~95 KB) | **128x128 map, 192 tiles (~90 KB)** |
| `map.bin`, Nepheshel map 204 (100x100) | 50,110 B | 25,110 B |

Measured by rebuilding the nano app against a real NanoApps checkout with
`arm-none-eabi-gcc` 13.2. Sixteen bytes of code buys 40 KB of working set.

The Wio Terminal now accepts **exactly the map sizes the nano 7G does**,
128x128, in less SRAM than 64x64 cost it two format revisions ago; only the
atlas cap still differs (192 there against 255). That is the first time in
this port's life that the two devices have agreed on a map bound.

Since ADR 61's first slice the nano's `.bss` has gone **344 KB → 108 KB**, a
68% cut, while the app gained chipset transparency, a backdrop colour, a
palette and a second target.

## Consequences

- **255 atlas entries is now a format ceiling, not a device cap.** A map
  needing more cannot be expressed at all, rather than being refused by one
  device and accepted by another. Nothing in the test data comes close (146
  is the record), and the fix if a project ever does is a format change —
  a wider index, or splitting the map — not a silent truncation. The
  exporter and `rw_open` both refuse past it.
- **The remaining budget is roughly 60% atlas, 40% cells**, and neither has
  an obvious next halving that keeps the format's defining property: flat
  arrays the device indexes with no decode step. Compression (RLE runs, a
  shared cross-map palette, a tile cache streamed off the card) is the next
  category, and it trades that property away. This is a good place to stop
  shrinking and spend the headroom on features instead — tile animation and
  multiple maps are the two ADR 61 named.
- **Two cells share a byte, so a passability bug can now be a neighbour's.**
  The host test pins this directly: four adjacent cells with four different
  masks, each read back on its own.
