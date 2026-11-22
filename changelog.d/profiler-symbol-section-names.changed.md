- **`RGSS::Profiler.section` takes a Symbol name.** The engine's per-frame
  sections now use Symbols, so a frame no longer allocates about a dozen name
  Strings when profiling is off. String names still work.
