- **The RPG2000 map renderer no longer redraws the tile grid every frame.** It
  builds the visible grid into a pair of cached buffers and copies those into
  the frame buffers at the sub-tile scroll offset, rebuilding only when
  something the grid depends on actually changed — the camera crossing a tile,
  an animation column the visible tiles actually follow, a Tile Substitution,
  a tileset swap or a new map. `Game::ChipsetLayout.quads` is memoised on
  `(id, abf, cf)` as well, which it is a pure function of. Measured on
  Nepheshel: **20fps to 55fps** — frame work 34.1ms to 8.8ms against a 16.67ms
  budget, `map.layers` 22.7ms to 2.4ms, and mruby allocation churn ~350k/s to
  ~30k/s. The map region renders pixel-identically before and after (diffed
  frame captures; see `docs/profiling.md`).
- **`RGSS::Bitmap#copy_blt`**, a non-blending counterpart to `#blt` that
  replaces the destination pixels outright. Onto a cleared destination the two
  draw the same picture — blending over transparency returns the source
  unchanged — but `#blt` pays a per-pixel read/blend/write for it, which on the
  map renderer's two 336x256 layer copies measured ~5ms a frame.
