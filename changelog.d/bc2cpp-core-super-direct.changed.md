- **bc2cpp**: `super` from a compiled mruby core method into a core module method (`Range#max` / `Range#min` with a
  block into `Enumerable`) is a direct call; the closed build has no run-time super lookup left outside Fiber steps.
