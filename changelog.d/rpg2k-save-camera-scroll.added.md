- **The saved camera scroll (`.lsd` chunk 111 fields 1/2) is decoded**: it is
  the view's top-left corner in **1/16 pixel**, measured against the genuine
  `RPG_RT.exe` under wine (see `LCF::Schema::SAVE_MAP_EVENT` and ADR 0021).
  `scripts/gen-rpg2k-save.rb` now writes it whenever it moves the party, and
  grew `--clear-scene` to drop the running-event continuation (113) and the
  shown pictures (103). Without both, resuming the same save put RPG_RT and this
  engine on different parts of the map — and back in a timed cutscene — so the
  map comparison reported a whole-screen difference that was never a rendering
  fault. `LCF::Array1D#delete` removes a chunk outright (an absent chunk and an
  empty one are not the same file to the real runtime).
