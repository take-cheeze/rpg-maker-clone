- **bc2cpp** now knows a variable is not nil after an index or call on it
  that nil cannot answer has returned (`ui[:a]` then `ui[:b]`). The later
  index or call drops its nil test, which saves about 2.5 KB of Wio flash.
  `BC2CPP_RECEIVER_SURVIVES=0` turns this off.
