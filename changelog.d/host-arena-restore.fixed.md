- **The GC arena no longer grows every frame** on the PSP, Wio (Renode),
  Maix and browser builds. The frame loops and the game construction now
  restore the arena, and the compiled `main_loop` entry no longer leaves its
  receiver behind, so a long session no longer leaks a slot per frame or
  keeps the title scene alive after the title. `scripts/bc2cpp-rpg/host_arena_check.rb`
  and the trace host check it.
