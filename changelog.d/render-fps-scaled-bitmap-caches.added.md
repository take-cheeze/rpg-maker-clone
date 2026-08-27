- RPG2000's named-graphic bitmap caches and picture tone-effect cache now
  scale their memory budgets down with `--render_fps` (e.g. `--render_fps=10`
  roughly sixths them), so a constrained device set to a low render rate
  (the PSP/Wio-class ports) also holds a smaller working set of decoded
  bitmaps in exchange for more cache-miss reloads. No effect at the default
  `--render_fps=60`.
