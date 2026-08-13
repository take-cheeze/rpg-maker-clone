- **A Common Event Parallel Process's Show Battle Animation (11210) now
  actually plays**, instead of the "wait until it finishes" flag being
  silently ignored. `Scene::Map#drive_parallel_wait`'s wait-kind dispatch had
  no `:animation` branch, so a parallel process blocked on one fell into the
  generic "background: ignore message/choice/teleport requests" case and was
  `#resume`d immediately — the animation was never built or drawn. Fixed by
  generalizing `#drive_map_animation`/`#init_map_animation`/
  `#start_map_animation` to take the waiting interpreter explicitly (a new
  `@map_animation_interp` tracks which one currently owns the single on-screen
  animation slot, so `#step_map_animation`/`#step_animation_wait` resume the
  right one rather than always the foreground `@interpreter`) and adding a
  `:animation` branch to `#drive_parallel_wait` that reuses it — matching
  yado.tk's "only one Battle Animation is ever on screen at a time" now
  holding for a parallel-process request too, not just a foreground one. If
  the slot is already held by a different interpreter's animation, the new
  request simply waits its turn rather than modelling one animation cutting
  another short (unconfirmed against real RPG_RT). Covered by two new
  `scripts/rpg2k_scene_check.rb` checks (the parallel process is held while
  the animation plays and resumes once it finishes; the animation actually
  renders — sprite shown, flash fired — for a parallel-process request, not
  just a foreground one), both confirmed to fail against the pre-fix code.
