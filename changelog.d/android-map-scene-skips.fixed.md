- **Android map scenes: 14 -> 40-45fps (intro map), 26fps standing on the
  overworld, 53-59fps in battle.** Profiling on-device showed the frame going
  to redrawing *identical* pixels: the map layer buffers were recomposed every
  frame (clear + two full-surface copies + events, ~19ms), the picture layer
  cleared its full-screen bitmap every frame even with no pictures (~7ms), the
  scrolling panorama re-tiled with per-pixel blend blits (~49ms while walking),
  and per-frame `opacity=`/`x=`/`y=` pokes of unchanged values invalidated
  full-screen sprites through LVGL's style setter, which does not compare
  values (~13ms of re-render). The map scene now skips any compose whose
  output would not change (layers, pictures, parallax), re-blits only the
  animation-following cells when the tile animation steps, the panorama copies
  instead of blending, and the native sprite setters skip the style set when
  the value is unchanged. Remaining frame cost is mruby game logic on the
  device's CPU; known follow-ups are C-side quad batching for the
  animation-step spikes on autotile-heavy maps and the scrolling present path.
