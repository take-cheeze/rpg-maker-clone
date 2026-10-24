- **bc2cpp: `Array.new(n) { }` is inlined in the engine again.** The
  `ARRAY_NEW_BLOCK` inliner refused when any native source other than an
  `array.c` spelled `initialize` and named the Array class, and mruby's own
  `random.c` does both (`Random#initialize`, Array's random methods), so every
  engine site stayed a by-name `new` with a heap block. The test now reads the
  native registrations (`NATIVE_OWNER_MAP`): only a registration of
  `initialize` on Array other than mruby's `src/array.c` refuses. A new
  `array_new_block_check.rb` compares interpreted and compiled runs of the loop.
