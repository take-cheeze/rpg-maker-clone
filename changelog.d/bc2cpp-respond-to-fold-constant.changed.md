- **bc2cpp**: `respond_to?(:name)` on a class or module constant (`RGSS::Audio.respond_to?(:bgm_pos)`) is answered at
  compile time from the object's singleton methods, so the closed build no longer looks the name up and misses on
  every frame.
