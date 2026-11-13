- **bc2cpp**: `super` inside a Fiber step of a compiled mruby core method (`Range#max` / `Range#min` with a suspending
  block) calls its core target's entry directly; the closed build has no run-time super lookup left.
