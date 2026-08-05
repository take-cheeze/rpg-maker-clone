- The last unaccounted-for **map-unit chunks are declared**, so a real `.lmu`
  parses with nothing left over. Chunks 42, 50, 60–62 and 90 turn out not to be
  the save/encounter/parallax metadata they were assumed to be — they are the
  **RPG2003 random dungeon generator** block (`top_level`, `generator_height`,
  and the nine room slots' `generator_x` / `generator_y` / `generator_tile_ids`)
  plus the 2k3e save counter (`save_count_2k3e`). The wiki's マップ page does not
  document them, so the ids, types and defaults are liblcf's
  `LMU_Reader::ChunkMap` / `RPG::Map` (0x28..0x3E, 0x5A); the rest of the block
  (40–56) is declared alongside them even though no test bed writes it. The
  reading is confirmed against real bytes rather than merely tolerated: chunk 62
  read as shorts gives ordinary tile ids (49, 10000/10001/10006/10007) where an
  int32 reading gives numbers in the millions, and the fields mtf-meido-action
  leaves out are exactly those already at their liblcf default, which is what an
  eliding writer produces. `scripts/lcf_testbed_check.rb` now asserts the block's
  shape on every map — nine coordinates, eighteen in-range tile ids, and every
  field materialising from the file or its default. These are editor-only
  settings; nothing reads them at run time.
