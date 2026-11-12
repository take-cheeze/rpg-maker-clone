- **bc2cpp**: in the closed build, `respond_to?(:name)` with a Symbol literal no longer calls `Kernel#respond_to?`.
  The answer comes from the closed world's definitions: a constant or a class check (194 engine sites). New Game
  lookups by name drop from 59,267 to 47,271 over 3,000 frames.
