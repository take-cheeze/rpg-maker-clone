- **The RPG Maker VX / VX Ace map draws.** `RGSS::Tilemap` spoke only XP's tile
  model (one `tileset` sheet, seven `autotiles`, a `priorities` table); VX and VX
  Ace replaced that with **nine sheets** (A1–A5, B–E, addressed as
  `tilemap.bitmaps[i] = Cache.tileset(name)`) and the tileset **`flags`** table,
  so a VX game booted to an empty screen. Both are now native, and a tilemap
  handed any sheet is drawn the VX way — the XP path is untouched.
  - The hard half is the tile-id decode: a VX id carries both *which* autotile
    and *which edge shape* to assemble from four quarter-tiles, with a different
    sheet layout per family — A1 water and waterfalls (each with its own
    animation cycle), A2 ground (including the "table" split that gives a
    counter its side), A3 buildings and the A4 wall rows on 16 shapes instead of
    48, and A5/B–E as plain tiles. Ported from the MIT-licensed RPG Maker MV
    corescript, which inherited VX Ace's tile system unchanged.
  - It is **differentially tested against that reference**: all 8300 tile ids ×
    a full animation cycle × the table flag — 66,400 cases — produce
    byte-identical geometry. The decode is exposed as `Tilemap.vx_tile_quads` so
    `mruby-rgss/test` pins it without needing a display, both as representative
    cases and as a checksum over the whole sweep. That run is also how the one
    real discrepancy turned up (the unused 1024..1535 id band, which must draw
    nothing rather than name a tenth sheet) and was fixed.
  - `flags` bit 0x10 routes a tile to the existing "above the characters" layer
    and bit 0x80 marks an A2 table tile. Left as polish: that layer is the same
    flat approximation ADR 0022 describes for XP, and the table *edge* tile
    drawn below its neighbour is not done. See
    [`docs/rpgvx-rgss-api-gap.md`](docs/rpgvx-rgss-api-gap.md).
