- **WOLF RPG Editor (ウディタ/Woditor)** released games now load: `Wolf::DataWolf`
  reads a packed `Data.wolf` (a DxLib DXA archive, XOR-encrypted with a key
  that differs per editor version, auto-detected the same way WolfDec's own
  tool does), cross-validated line-by-line against the archiver source
  WolfDec itself vendors, and `Wolf::Project` picks a loose project tree or a
  packed `Data.wolf` transparently. Verified by packing and re-reading the
  bundled sample game's entire real `Data/` tree (660 files) through the
  whole project pipeline. Compressed DXA entries and the older pre-2.281
  archive format are refused with a clear error rather than mis-parsed. See
  `docs/adr/0093-wolf-rpg-editor-data-wolf.md`.
