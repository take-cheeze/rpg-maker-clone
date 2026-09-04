- `docs/rpgvx-rgss-api-gap.md`'s own "What this means for turning the host on"
  summary had contradicted the doc's own item 1 for a while: item 1 itself
  concludes the VX/VX Ace `flags` 0x10 "above characters" layer is correctly
  flat (mkxp's `TilemapVX` puts it at a fixed z too, unlike XP's per-row
  `priorities`) and says "No follow-up wanted here," but the summary two
  screens down still called it "Tilemap item 1's remaining polish" and "the
  only item left" — the same stale claim `docs/TODO.md` had already run down
  and corrected once (its own cycle note on `tilemap_ensure_above`), just in
  the neighbouring doc this time. Re-verified against `mruby-rgss/src/lib.cxx`
  before touching the prose: `tilemap_refresh_vx` still routes every 0x10 tile
  into the single lazily-created `@_tm_above_obj` canvas at
  `z + TILEMAP_ABOVE_Z`, nothing per-row, matching the reference behaviour the
  doc already cites — so this is a doc-only correction, not a code change; all
  seven sections of the gap doc are done.
