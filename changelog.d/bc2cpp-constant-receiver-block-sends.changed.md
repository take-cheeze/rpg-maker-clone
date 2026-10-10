- **bc2cpp inlines `Array.new(n) { |i| }` and more `RGSS::Profiler` blocks**: the closed world turns a proven
  `Array.new` with a block into a counted loop, and inlines `Profiler.section`/`frame` inside `rescue` ranges and
  beside same-named Ruby methods. 21 of 51 unguarded by-name block sends are gone; kill switches
  `BC2CPP_ARRAY_NEW_INLINE=0`, `BC2CPP_RESCUE_PROFILER_INLINE=0`, `BC2CPP_PROFILER_NAME_SCOPED=0`. See
  `docs/adr/0391-bc2cpp-constant-receiver-block-sends.md`.
