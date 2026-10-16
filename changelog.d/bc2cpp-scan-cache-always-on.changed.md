- **bc2cpp** (ADR 0462): the native-source scan cache is always on, in the checkout's `build/bc2cpp-cache`, with no
  environment switch (`BC2CPP_SCAN_CACHE_DIR` is gone). Its key also covers the Ruby version and Marshal format. Any
  cache fault (an unreadable entry, an entry stored under another key, a value or directory that cannot be stored,
  a cached scan that reads `ENV`) now stops the run instead of being recomputed past.
