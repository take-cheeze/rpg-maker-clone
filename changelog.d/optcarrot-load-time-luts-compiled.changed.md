- The optcarrot probe's sealed build compiles the lookup tables optcarrot builds while loading. The compiled core
  mrblib is installed right after the shims (bc2cpp's own core registration, which also fixes `install!` replacing
  onig-regexp's `String#gsub`), and class-body constant initializers that loop through blocks (`PPU::TILE_LUT`) are
  hoisted into compiled singleton methods. Startup fell from about 1.5 s to 0.76 s, and the 180-frame benchmark from
  2.65 s to 2.13 s. Checked by `scripts/optcarrot/class_body_hoist_check.rb`.
