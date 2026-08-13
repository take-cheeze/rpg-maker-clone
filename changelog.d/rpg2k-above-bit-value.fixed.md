- **A "see-through" upper-layer decoration no longer silently overrides a
  blocked lower tile.** `ChipSet::ABOVE_BIT`, the passage-byte bit that marks
  an upper tile as decorative ground deferring to the lower layer instead of
  standing in for it, was `0x20`. EasyRPG's `Passable` enum (`src/map_data.h`)
  puts `Above` at `0x10` — `0x20` is a different flag, `Wall`, used only for a
  narrow autotile-corner carve-out on the lower layer's terrain block.
  Checking the wrong bit meant every upper tile actually flagged `Above` read
  as solid ground instead, so `passable_tile?`/`landable_tile?` skipped the
  lower-layer check they exist to make and answered passable from the upper
  tile alone. Nepheshel's near-universal blank/filler upper chip (tile id
  10000, byte `0x1F` — all four direction bits plus the real `Above` bit) hits
  this on almost every map cell: with the wrong bit, ~1.58M direction-checks
  across its maps wrongly deferred to the upper tile's own (always-open)
  passability instead of the lower tile actually painted there; with the fix,
  those same checks now correctly consult the lower layer, and the tiles that
  remain "upper overrides lower" are the ~47 real solid-object graphics that
  are not flagged `Above` at all — matching intended chipset authoring rather
  than a chip that happens to render blank.
