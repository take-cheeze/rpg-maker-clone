- **bc2cpp closed build:** `RGSS::Rect`'s methods and the `Color`/`Tone` component accessors are registered from
  ROM method tables like the rest of RGSS (the Wio Terminal build's `Tilemap`/`Window` stubs too), so
  `Rect#initialize` and `Tilemap#initialize` become constructor rows (host table 741 → 739) and `Rect`'s methods are
  called without a frame.
