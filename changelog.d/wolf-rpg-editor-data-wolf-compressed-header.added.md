- **WOLF RPG Editor (ウディタ/Woditor) `Data.wolf` now reads a Huffman+LZ-
  compressed header table** instead of only being detected and refused —
  `Wolf::DataWolf.huffman_decode`/`.dxa_lz_decode` port DxLib's own
  `Huffman_Decode`/`DXArchive::Decode`, cross-validated by compiling the
  vendored (untouched) C++ encoders and decoding their real output, not just
  self-consistently. Found via this session's first real, freely-distributable
  released WOLF RPG Editor game ("About a Certain Witch" v1.03 by Ryuu,
  freem.ne.jp) — whose own `Data.wolf` turned out to need exactly this path,
  correcting an earlier expectation that real releases would skip it. That
  same game still cannot be opened, for an unrelated reason: its `DARC_HEAD`
  fields are scrambled by a newer, WOLF-RPG-Editor-specific modified DxArchive
  (`DxArchive_WOLF_MOD_security`) this reader does not yet implement — see
  `docs/adr/0096-wolf-rpg-editor-data-wolf-compressed-header.md`.
