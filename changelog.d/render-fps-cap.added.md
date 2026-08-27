- Added `--render_fps=N` (e.g. `30`/`15`/`10`) to cap how often the screen
  actually redraws, cutting rendering CPU/GPU work and memory bandwidth on
  constrained hardware. Game logic, `Graphics.frame_count`, animation timers
  and `Wait` keep running at the normal rate every call — only the LVGL
  redraw itself is skipped on the frames a lower rate does not need, so the
  game plays and times identically, just visibly updating less often.
