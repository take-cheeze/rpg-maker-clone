- **bc2cpp closed build**: compiled methods are registered through const ROM
  method tables instead of heap entries; after boot the heap method tables
  hold 165 entries instead of 531. Pinned by
  `scripts/bc2cpp/rom_method_tables_check.rb`.
