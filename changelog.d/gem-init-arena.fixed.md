- **The engine's gem init no longer pins its temporaries in the GC arena.** `rpg_maker_init_shared_gems` and the
  per-maker gem inits now restore the arena after each gem, as mruby's own `mrb_init_mrbgems` does. Afterwards
  they shrink the arena back to its default size. The objects a gem's init created and dropped become collectable,
  which frees about 23 KB of the Wio Terminal's boot heap.
